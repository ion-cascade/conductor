import Foundation
import MCP
import Testing
@testable import LogicProMCP

struct ProjectSurroundSettingsTests {
    private var settings: [String: Value] {
        ["format": .string("wav"), "sample_rate": .int(48_000), "bit_depth": .int(24),
         "include_audio_tail": .bool(false), "channel_layout": .string("5.1")]
    }

    @Test func explicitSurroundProfileRequiresSixChannelsAndRoundTrips() throws {
        let requested = try ProjectPCMBounceSettings.parse(.object(settings), artifacts: ["bounce"])
        let parsed = try #require(requested)
        #expect(parsed.channelCount == 6 && parsed.channelLayout == "5.1")
        let readback = try JSONDecoder().decode(ProjectPCMBounceSettings.self, from: JSONEncoder().encode(parsed))
        #expect(readback == parsed)
    }

    @Test(arguments: ["format", "sample_rate", "bit_depth", "channel_layout"])
    func rejectsUnqualifiedSurroundSettings(_ field: String) throws {
        var invalid = settings
        switch field {
        case "format": invalid[field] = .string("aiff")
        case "sample_rate": invalid[field] = .int(96_000)
        case "bit_depth": invalid[field] = .int(16)
        default: invalid[field] = .string("7.1")
        }
        #expect(throws: (any Error).self) {
            try ProjectPCMBounceSettings.parse(.object(invalid), artifacts: ["bounce"])
        }
    }

    @Test func earlierStereoReceiptStillDecodesAndRequiresTwoChannels() throws {
        let old = Data(#"{"format":"wav","sample_rate":48000,"bit_depth":24,"include_audio_tail":false}"#.utf8)
        let parsed = try JSONDecoder().decode(ProjectPCMBounceSettings.self, from: old)
        #expect(parsed.channelLayout == nil && parsed.channelCount == 2)
        var request = settings
        request.removeValue(forKey: "channel_layout")
        #expect(try ProjectPCMBounceSettings.parse(.object(request), artifacts: ["bounce"]) == parsed)
    }
}
