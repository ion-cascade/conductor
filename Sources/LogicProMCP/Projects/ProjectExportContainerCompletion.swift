import Foundation

/// AVAudioFile can silently shorten its reported frame count when a container
/// is truncated. For the qualified PCM WAV/AIFF export route, additionally
/// require the container and every declared chunk to fit the actual file.
/// Other containers remain unqualified rather than borrowing decoder success.
enum ProjectExportContainerCompletion {
    static func isComplete(at path: String, size: Int64) -> Bool {
        guard size >= 12, let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return false }
        defer { try? file.close() }
        func bytes(at offset: UInt64, count: Int) -> [UInt8]? {
            do {
                try file.seek(toOffset: offset)
                guard let data = try file.read(upToCount: count), data.count == count else { return nil }
                return Array(data)
            } catch { return nil }
        }
        guard let header = bytes(at: 0, count: 12) else { return false }
        func label(_ data: ArraySlice<UInt8>) -> String { String(bytes: data, encoding: .ascii) ?? "" }
        let family = label(header[0..<4])
        let kind = label(header[8..<12])
        let wave = (family == "RIFF" || family == "RIFX") && kind == "WAVE"
        let aiff = family == "FORM" && (kind == "AIFF" || kind == "AIFC")
        guard wave || aiff else { return false }
        let littleEndian = family == "RIFF"
        func uint32(_ data: ArraySlice<UInt8>) -> UInt64 {
            let values = littleEndian ? Array(data.reversed()) : Array(data)
            return values.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
        let length = UInt64(size)
        guard uint32(header[4..<8]) + 8 == length else { return false }
        var offset: UInt64 = 12
        var metadata = false
        var audio = false
        var chunks = 0
        while offset < length {
            chunks += 1
            guard chunks <= 4096, length - offset >= 8,
                  let chunk = bytes(at: offset, count: 8) else { return false }
            let name = label(chunk[0..<4])
            let count = uint32(chunk[4..<8])
            let padded = count + count % 2
            guard padded <= length - offset - 8 else { return false }
            if wave && name == "fmt " { metadata = count >= 16 }
            if aiff && name == "COMM" { metadata = count >= 18 }
            if wave && name == "data" { audio = count > 0 }
            if aiff && name == "SSND" { audio = count > 8 }
            offset += 8 + padded
        }
        return offset == length && metadata && audio
    }
}
