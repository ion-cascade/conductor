import AudioToolbox
import Foundation
import MCP

struct ProjectPCMBounceSettings: Codable, Sendable, Equatable {
    enum Format: String, Codable, Sendable {
        case wav
        case aiff

        var label: String { self == .wav ? "WAVE" : "AIFF" }
        var outputExtension: String { self == .wav ? "wav" : "aif" }
        var fileType: AudioFileTypeID { self == .wav ? kAudioFileWAVEType : kAudioFileAIFFType }
    }

    let format: Format
    let sampleRate: Int
    let bitDepth: Int
    let includeAudioTail: Bool

    enum CodingKeys: String, CodingKey {
        case format
        case sampleRate = "sample_rate"
        case bitDepth = "bit_depth"
        case includeAudioTail = "include_audio_tail"
    }

    var sampleRateLabel: String { sampleRate == 44_100 ? "44.1 kHz" : "\(sampleRate / 1000) kHz" }

    static func parse(_ raw: Value?, artifacts: [String]) throws -> Self? {
        guard let raw else { return nil }
        guard case .object(let values) = raw,
              Set(values.keys).isSubset(of: ["format", "sample_rate", "bit_depth", "include_audio_tail"]),
              artifacts.contains("bounce"),
              case .string(let label) = values["format"],
              let format = Format(rawValue: label),
              case .int(let sampleRate) = values["sample_rate"], [44_100, 48_000, 96_000].contains(sampleRate),
              case .int(let bitDepth) = values["bit_depth"], [16, 24].contains(bitDepth)
        else {
            throw ExportPlanError.invalid("bounce_settings requires a bounce artifact, format wav or aiff, sample_rate 44100, 48000 or 96000, and bit_depth 16 or 24")
        }
        let includeTail: Bool
        switch values["include_audio_tail"] {
        case .none: includeTail = false
        case .bool(let requested): includeTail = requested
        default: throw ExportPlanError.invalid("bounce_settings.include_audio_tail must be a Boolean")
        }
        return Self(format: format, sampleRate: sampleRate, bitDepth: bitDepth, includeAudioTail: includeTail)
    }

    func matchesFile(_ path: String) -> Bool {
        var file: AudioFileID?
        let url = URL(fileURLWithPath: path)
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else { return false }
        defer { AudioFileClose(file) }
        var type: AudioFileTypeID = 0
        var typeSize = UInt32(MemoryLayout.size(ofValue: type))
        var stream = AudioStreamBasicDescription()
        var streamSize = UInt32(MemoryLayout.size(ofValue: stream))
        return AudioFileGetProperty(file, kAudioFilePropertyFileFormat, &typeSize, &type) == noErr
            && AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &streamSize, &stream) == noErr
            && type == format.fileType && stream.mFormatID == kAudioFormatLinearPCM
            && stream.mSampleRate == Double(sampleRate) && stream.mBitsPerChannel == UInt32(bitDepth)
            && stream.mChannelsPerFrame == 2
    }
}
