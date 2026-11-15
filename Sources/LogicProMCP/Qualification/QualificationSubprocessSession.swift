import Foundation
import Darwin

private struct RPCResponse<Result: Decodable>: Decodable {
    struct RPCError: Decodable {
        let code: Int
        let message: String
    }

    let jsonrpc: String
    let id: Int
    let result: Result?
    let error: RPCError?
}


/// One `read(2)` on a descriptor, without Foundation's exceptions and without its blocking.
///
/// #843. Two Foundation APIs were tried here and both are wrong for a pipe carrying small frames:
///
///   * `availableData` returns what is there, which is the right SHAPE, but it raises an
///     Objective-C `NSFileHandleOperationException` when the descriptor goes bad — and a Swift
///     `catch` cannot see one, so it unwinds past the handler and kills the process.
///   * `read(upToCount:)` throws a Swift error like it should, but it WAITS for the count. Measured
///     2026-09-09: swapping it in made the qualification transport time out on its handshake, a
///     small frame that never fills a 64 KiB request. The suite went from 27 seconds green to a
///     45-second `timeout:handshake`.
///
/// POSIX `read` has both properties: it returns whatever is available, and it reports failure
/// through the return value rather than by unwinding. `EINTR` is retried; anything else is an
/// error the caller can route. Zero bytes means end of file, exactly as an empty `Data` did.
///
/// #947. The descriptor comes in as a number, read from its `FileHandle` once before any reader
/// starts, because `fileDescriptor` raises the same uncatchable exception on a closed handle, and
/// the shutdown path used to close these handles under a running reader. `stop` replaces that
/// close. It becomes readable when shutdown gives up waiting for end of file, and `poll(2)` waits
/// on it beside the stream, so the reader leaves without anyone closing its descriptor. Closing it
/// would not be safe even without the exception: the number goes back to the process and the next
/// `open` can receive it, and a reader still looping would then read another file's bytes.
private func readAvailable(_ descriptor: Int32, stop: Int32, upTo limit: Int = 64 * 1024) throws -> Data {
    var buffer = [UInt8](repeating: 0, count: limit)
    while true {
        var ready = [
            pollfd(fd: stop, events: Int16(POLLIN), revents: 0),
            pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0),
        ]
        if poll(&ready, 2, -1) < 0 {
            if errno == EINTR { continue }
            throw QualificationTransportError.malformedFrame("poll failed on fd \(descriptor): errno \(errno)")
        }
        // Stop first: a writer that never pauses keeps the stream readable, and a reader that
        // looked at the stream first would never see the stop.
        if ready[0].revents != 0 {
            throw QualificationTransportError.malformedFrame(
                "read on fd \(descriptor) stopped at shutdown before end of file")
        }
        let n = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, limit) }
        if n >= 0 { return Data(buffer.prefix(n)) }
        if errno == EINTR { continue }
        throw QualificationTransportError.malformedFrame("read failed on fd \(descriptor): errno \(errno)")
    }
}

/// #947. How shutdown stops the pipe readers without closing their descriptors: a pipe of its own.
/// One byte written makes its read end readable, and nothing ever reads that byte, so every reader
/// polling it sees the stop, however late it looks.
private final class QualificationReaderStop: @unchecked Sendable {
    let descriptor: Int32
    private let writeEnd: Int32

    init() throws {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else {
            throw QualificationTransportError.launchFailed("reader stop pipe: errno \(errno)")
        }
        // Not the child's to inherit. Its own pipes are the only descriptors it should hold.
        _ = fcntl(ends[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(ends[1], F_SETFD, FD_CLOEXEC)
        descriptor = ends[0]
        writeEnd = ends[1]
    }

    func stop() {
        var byte: UInt8 = 1
        _ = Darwin.write(writeEnd, &byte, 1)
    }

    deinit {
        Darwin.close(descriptor)
        Darwin.close(writeEnd)
    }
}

final class QualificationSubprocessSession: @unchecked Sendable {
    struct ShutdownOutcome {
        let status: Int32
        let forced: Bool
    }

    private let request: QualificationDriveRequest
    private let requestTimeout: TimeInterval
    private let shutdownGrace: TimeInterval
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let frames = QualificationFrameQueue()
    private let stderr = QualificationStderrBuffer()
    private let readers = DispatchGroup()
    private var readerStop: QualificationReaderStop?
    private let exit = QualificationProcessExit()
    private let stateLock = NSLock()
    private var started = false
    private var shutdownOutcome: ShutdownOutcome?
    private var framesTranscript: [QualificationWireFrame] = []

    init(
        request: QualificationDriveRequest,
        requestTimeout: TimeInterval,
        shutdownGrace: TimeInterval
    ) {
        self.request = request
        self.requestTimeout = requestTimeout
        self.shutdownGrace = shutdownGrace
    }

    var stderrTail: String { stderr.text }

    var transcriptFrames: [QualificationWireFrame] {
        stateLock.withLock { framesTranscript }
    }

    func start() throws {
        guard FileManager.default.isExecutableFile(atPath: request.executableURL.path) else {
            throw QualificationTransportError.launchFailed("not executable: \(request.executableURL.path)")
        }
        try verifyExecutableIdentity()
        // #394: qualification now attests the SHIPPED DEFAULT for ADR-002
        // target_ref (default ON), not the `=0` kill-switch it used to pin. The
        // session-random target/trace IDs this surfaces are ID-normalized (made
        // cross-run stable in the ID dimension) by `QualificationTranscriptNormalizer`
        // at transcript-emit time. See `QualificationTransport.qualificationEnvironment`.
        let environment = QualificationTransport.qualificationEnvironment(
            base: request.environment
        )
        process.executableURL = request.executableURL.standardizedFileURL
        process.currentDirectoryURL = request.executableURL.deletingLastPathComponent()
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let stop = try QualificationReaderStop()
        exit.start(process)
        do {
            try process.run()
            try verifyExecutableIdentity()
        } catch {
            if process.isRunning { process.terminate() }
            throw QualificationTransportError.launchFailed(String(describing: error))
        }
        stateLock.lock()
        started = true
        readerStop = stop
        stateLock.unlock()
        startReaders(stop: stop)
    }

    private func verifyExecutableIdentity() throws {
        guard let expected = request.expectedExecutableSHA256 else { return }
        let data = try Data(contentsOf: request.executableURL, options: .mappedIfSafe)
        guard SupportBundleBuilder.sha256(data) == expected else {
            throw QualificationTransportError.launchFailed("qualification executable changed")
        }
    }

    func request<Result: Decodable>(
        id: Int,
        method: String,
        params: [String: Any],
        phase: String,
        timeout: TimeInterval? = nil
    ) throws -> Result {
        // Writing or resuming the caller must not start a fresh response budget.
        let deadline = DispatchTime.now() + (timeout ?? requestTimeout)
        try writeJSON([
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ], direction: .request, operationID: phase)
        let data = try frames.response(id: id, phase: phase, deadline: deadline)
        record(direction: .response, operationID: phase, data: data)
        let response: RPCResponse<Result>
        do {
            response = try JSONDecoder().decode(RPCResponse<Result>.self, from: data)
        } catch {
            throw QualificationTransportError.protocolViolation("\(phase): invalid response shape")
        }
        guard response.jsonrpc == "2.0", response.id == id else {
            throw QualificationTransportError.protocolViolation("\(phase): mismatched JSON-RPC envelope")
        }
        if let error = response.error {
            throw QualificationTransportError.protocolViolation(
                "\(phase): rpc \(error.code) \(error.message)"
            )
        }
        guard let result = response.result else {
            throw QualificationTransportError.protocolViolation("\(phase): missing result")
        }
        return result
    }

    func notify(method: String) throws {
        try writeJSON(
            ["jsonrpc": "2.0", "method": method],
            direction: .notification,
            operationID: method
        )
    }

    func shutdown() throws -> ShutdownOutcome {
        stateLock.lock()
        if let shutdownOutcome {
            stateLock.unlock()
            return shutdownOutcome
        }
        let didStart = started
        let stop = readerStop
        stateLock.unlock()
        guard didStart else { return ShutdownOutcome(status: 0, forced: false) }

        try? inputPipe.fileHandleForWriting.close()
        var forced = false
        if !exit.wait(timeout: shutdownGrace) {
            forced = true
            process.terminate()
            if !exit.wait(timeout: shutdownGrace) {
                Darwin.kill(process.processIdentifier, SIGKILL)
                guard exit.wait(timeout: shutdownGrace) else {
                    throw QualificationTransportError.shutdownTimeout
                }
            }
        }
        if readers.wait(timeout: .now() + shutdownGrace) == .timedOut {
            // A process the server started can still hold the pipes open, so end of file may
            // never come. The readers are stopped, not closed under (#947, `readAvailable`).
            stop?.stop()
            guard readers.wait(timeout: .now() + shutdownGrace) == .success else {
                throw QualificationTransportError.shutdownTimeout
            }
        }
        let outcome = ShutdownOutcome(status: exit.status, forced: forced)
        stateLock.lock()
        shutdownOutcome = outcome
        stateLock.unlock()
        return outcome
    }

    private func writeJSON(
        _ object: [String: Any],
        direction: QualificationWireFrame.Direction,
        operationID: String
    ) throws {
        let data: Data
        do {
            var encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            encoded.append(0x0A)
            data = encoded
        } catch {
            throw QualificationTransportError.protocolViolation("request encoding failed")
        }
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
            record(direction: direction, operationID: operationID, data: data.dropLast())
        } catch {
            throw QualificationTransportError.closedPipe(phase: "write")
        }
    }

    private func record(
        direction: QualificationWireFrame.Direction,
        operationID: String,
        data: Data
    ) {
        stateLock.withLock {
            framesTranscript.append(QualificationWireFrame(
                sequence: framesTranscript.count,
                direction: direction,
                operationID: operationID,
                payload: String(decoding: data, as: UTF8.self)
            ))
        }
    }

    private func startReaders(stop: QualificationReaderStop) {
        // Each reader holds its handle, and the handle owns the descriptor, which stays open
        // until the last reader is done with it (#947).
        //
        // Each reader is a thread of its own, not a block on a global queue. A reader blocks for
        // as long as the server lives, and a block queued behind a saturated pool does not start,
        // so it never polls the stop either. Measured with the readers on global queues and the
        // test's 3 s grace: shutdown returned after 3.0 s with a free pool and timed out after
        // 6.0 s with a saturated one. On threads it returned after 3.0 s in both.
        let output = outputPipe.fileHandleForReading
        let outputDescriptor = output.fileDescriptor
        readers.enter()
        startReaderThread(named: "stdout", qualityOfService: .userInitiated) { [frames, readers, output, stop] in
            defer { readers.leave() }
            defer { withExtendedLifetime(output) {} }
            var pending = Data()
            do {
                while true {
                    let chunk = try readAvailable(outputDescriptor, stop: stop.descriptor)
                    guard !chunk.isEmpty else { break }
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 0x0A) {
                        let line = Data(pending[..<newline])
                        pending.removeSubrange(...newline)
                        if !line.isEmpty {
                            try frames.append(line)
                        }
                    }
                    if pending.count > QualificationFrameQueue.maximumFrameBytes {
                        throw QualificationTransportError.malformedFrame("frame exceeds size limit")
                    }
                }
                if pending.isEmpty {
                    frames.finish()
                } else {
                    frames.fail(QualificationTransportError.malformedFrame("unterminated frame"))
                }
            } catch {
                frames.fail(error)
            }
        }

        let error = errorPipe.fileHandleForReading
        let errorDescriptor = error.fileDescriptor
        readers.enter()
        startReaderThread(named: "stderr", qualityOfService: .utility) { [stderr, readers, error, stop] in
            defer { readers.leave() }
            defer { withExtendedLifetime(error) {} }
            // The stdout reader at least LOOKED like it handled a bad descriptor. This one had no
            // `do`/`catch` at all. A stderr read that fails is not fatal to the run — the
            // diagnostic is truncated, not the transport — so it is recorded and the loop ends.
            do {
                while true {
                    let chunk = try readAvailable(errorDescriptor, stop: stop.descriptor)
                    guard !chunk.isEmpty else { break }
                    stderr.append(chunk)
                }
            } catch {
                stderr.append(Data(
                    "\n[qualification-transport] stderr capture ended early: \(error)\n".utf8))
            }
        }
    }

    private func startReaderThread(
        named name: String,
        qualityOfService: QualityOfService,
        _ body: @escaping @Sendable () -> Void
    ) {
        let thread = Thread(block: body)
        thread.name = "logic-pro-mcp.qualification.\(name)"
        thread.qualityOfService = qualityOfService
        thread.start()
    }
}

final class QualificationFrameQueue: @unchecked Sendable {
    static let maximumFrameBytes = 8 * 1024 * 1024

    private struct ReceivedFrame {
        let data: Data
        let receivedAt: DispatchTime
    }

    private let condition = NSCondition()
    private var responses: [Int: ReceivedFrame] = [:]
    private var terminalError: Error?
    private var finished = false

    func append(_ data: Data) throws {
        let receivedAt = DispatchTime.now()
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw QualificationTransportError.malformedFrame("top-level frame is not an object")
            }
            object = decoded
        } catch let error as QualificationTransportError {
            fail(error)
            throw error
        } catch {
            let malformed = QualificationTransportError.malformedFrame("invalid JSON")
            fail(malformed)
            throw malformed
        }
        guard object["jsonrpc"] as? String == "2.0" else {
            let malformed = QualificationTransportError.malformedFrame("missing jsonrpc 2.0")
            fail(malformed)
            throw malformed
        }
        guard let number = object["id"] as? NSNumber else {
            return
        }
        condition.lock()
        responses[number.intValue] = ReceivedFrame(data: data, receivedAt: receivedAt)
        condition.broadcast()
        condition.unlock()
    }

    func response(id: Int, phase: String, deadline: DispatchTime) throws -> Data {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let response = responses.removeValue(forKey: id) {
                // A late frame can already be queued when a delayed waiter wakes.
                // Conversely, an on-time frame remains on time despite that delay.
                guard response.receivedAt < deadline else {
                    throw QualificationTransportError.requestTimeout(phase: phase)
                }
                return response.data
            }
            if let terminalError {
                throw terminalError
            }
            if finished {
                throw QualificationTransportError.closedPipe(phase: phase)
            }
            let now = DispatchTime.now()
            guard now < deadline else {
                throw QualificationTransportError.requestTimeout(phase: phase)
            }
            let remaining = Double(deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000_000
            _ = condition.wait(until: Date().addingTimeInterval(remaining))
        }
    }

    func finish() {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    func fail(_ error: Error) {
        condition.lock()
        if terminalError == nil {
            terminalError = error
        }
        condition.broadcast()
        condition.unlock()
    }
}

private final class QualificationStderrBuffer: @unchecked Sendable {
    private static let maximumBytes = 64 * 1024
    private let lock = NSLock()
    private var data = Data()

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        if data.count > Self.maximumBytes {
            data.removeFirst(data.count - Self.maximumBytes)
        }
        lock.unlock()
    }
}

private final class QualificationProcessExit: @unchecked Sendable {
    private let condition = NSCondition()
    private var exited = false
    private(set) var status: Int32 = 0

    func start(_ process: Process) {
        process.terminationHandler = { [self] process in
            condition.lock()
            status = process.terminationStatus
            exited = true
            condition.broadcast()
            condition.unlock()
        }
    }

    func wait(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !exited {
            guard condition.wait(until: deadline) else { return exited }
        }
        return true
    }
}
