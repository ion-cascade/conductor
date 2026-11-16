import Foundation

func installScriptContractRepositoryRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

func scriptContents(_ relativePath: String) throws -> String {
    try String(contentsOf: installScriptContractRepositoryRootURL().appendingPathComponent(relativePath), encoding: .utf8)
}

struct ScriptRunResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var combinedOutput: String {
        stdout + stderr
    }
}

private final class ProcessOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func store(_ value: Data) {
        lock.lock()
        data = value
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

@discardableResult
func runProcess(
    executable: String,
    arguments: [String],
    currentDirectoryURL: URL,
    environment: [String: String] = [:]
) throws -> ScriptRunResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectoryURL
    var mergedEnvironment = ProcessInfo.processInfo.environment
    for key in mergedEnvironment.keys where key.hasPrefix("LOGIC_PRO_MCP_") {
        mergedEnvironment.removeValue(forKey: key)
    }
    for (key, value) in environment {
        mergedEnvironment[key] = value
    }
    process.environment = mergedEnvironment

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    try process.run()

    let stdoutCapture = ProcessOutputCapture()
    let stderrCapture = ProcessOutputCapture()
    let drainGroup = DispatchGroup()

    func drain(_ pipe: Pipe, into capture: ProcessOutputCapture) {
        drainGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var data = Data()
            do {
                while let chunk = try pipe.fileHandleForReading.read(upToCount: 64 * 1024),
                      !chunk.isEmpty {
                    data.append(chunk)
                }
            } catch {
                // Preserve whatever the child wrote before the pipe became unreadable.
            }
            capture.store(data)
            drainGroup.leave()
        }
    }
    drain(stdoutPipe, into: stdoutCapture)
    drain(stderrPipe, into: stderrCapture)
    process.waitUntilExit()
    drainGroup.wait()

    let stdout = String(
        data: stdoutCapture.snapshot(),
        encoding: .utf8
    ) ?? ""
    let stderr = String(
        data: stderrCapture.snapshot(),
        encoding: .utf8
    ) ?? ""
    return ScriptRunResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
}

func runShellScript(
    _ relativePath: String,
    environment: [String: String] = [:]
) throws -> ScriptRunResult {
    try runProcess(
        executable: "/bin/bash",
        arguments: [installScriptContractRepositoryRootURL().appendingPathComponent(relativePath).path],
        currentDirectoryURL: installScriptContractRepositoryRootURL(),
        environment: environment
    )
}

func makeInstallScriptTempDir(_ name: String = UUID().uuidString) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func writeExecutable(_ url: URL, contents: String) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

func writeFile(_ url: URL, contents: String) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try contents.write(to: url, atomically: true, encoding: .utf8)
}
