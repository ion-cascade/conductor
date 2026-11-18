import Foundation
import Testing
@testable import LogicProMCP

struct ProjectADMArtifactTests {
    @Test func attributesPCMChannelsThroughTrackUIDsAndObjectMembership() throws {
        let parsed = try inspect(fixture())
        #expect(parsed.channels == 11 && parsed.sampleRate == 48_000 && parsed.bitDepth == 24)
        #expect(parsed.frames == 4)
        #expect(parsed.objects.map(\.name) == ["Bed", "Conductor Object"])
        #expect(parsed.objects[0].channels == Array(1...10))
        #expect(parsed.objects[1].channels == [11])
    }

    @Test func readsRF64LengthsWithoutTreatingSentinelsAsPCMBytes() throws {
        let riff = fixture()
        let content = riff.dropFirst(12)
        let fileSize = riff.count + 36
        let ds64 = number(UInt64(fileSize - 8), 8) + number(4 * 33, 8) + number(4, 8) + number(0, 4)
        var rf64 = Data("RF64".utf8) + number(UInt64(UInt32.max), 4) + Data("WAVE".utf8)
        rf64 += chunk("ds64", ds64) + content
        let dataRange = try #require(rf64.range(of: Data("data".utf8), options: .backwards))
        rf64.replaceSubrange(dataRange.upperBound..<(dataRange.upperBound + 4), with: number(UInt64(UInt32.max), 4))
        let parsed = try inspect(rf64)
        #expect(parsed.frames == 4 && parsed.channelMapping.count == 11)
    }

    @Test(arguments: ["duplicate_track", "missing_uid", "wrong_depth", "truncated", "external_xml", "oversized_chunk", "crosswired_stream"])
    func refusesUnattributableOrIncompleteArtifacts(_ fault: String) throws {
        var data = fixture(fault: fault)
        if fault == "truncated" { data.removeLast() }
        if fault == "oversized_chunk" { data.replaceSubrange(16..<20, with: [255, 255, 255, 127]) }
        #expect(throws: (any Error).self) { try inspect(data) }
    }

    private func inspect(_ data: Data) throws -> ProjectADMArtifact {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try data.write(to: path, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: path) }
        return try ProjectADMArtifact.read(path)
    }

    private func number(_ value: UInt64, _ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    private func chunk(_ name: String, _ data: Data) -> Data {
        Data(name.utf8) + number(UInt64(data.count), 4) + data + Data(repeating: 0, count: data.count % 2)
    }

    private func fixture(fault: String = "") -> Data {
        let format = number(1, 2) + number(11, 2) + number(48_000, 4) + number(48_000 * 33, 4)
            + number(33, 2) + number(fault == "wrong_depth" ? 16 : 24, 2)
        var chna = number(11, 2) + number(11, 2)
        var trackUIDs = ""
        var bedRefs = ""
        var formats = ""
        var bedChannels = ""
        for index in 1...11 {
            let uid = String(format: "ATU_%08X", index)
            let trackRef = String(format: "AT_%08X_01", index)
            let pack = index == 11 ? "AP_00031001" : "AP_00010017"
            chna += number(UInt64(fault == "duplicate_track" && index == 11 ? 10 : index), 2)
            chna += Data(uid.utf8) + Data(trackRef.utf8) + Data(pack.utf8) + Data([0])
            trackUIDs += "<audioTrackUID UID=\"\(uid)\"><audioTrackFormatIDRef>\(trackRef)</audioTrackFormatIDRef><audioPackFormatIDRef>\(pack)</audioPackFormatIDRef></audioTrackUID>"
            let streamRef = String(format: "AS_%08X", index)
            let channelRef = String(format: "AC_%08X", index)
            formats += "<audioTrackFormat audioTrackFormatID=\"\(trackRef)\"><audioStreamFormatIDRef>\(streamRef)</audioStreamFormatIDRef></audioTrackFormat>"
            formats += "<audioStreamFormat audioStreamFormatID=\"\(streamRef)\"><audioChannelFormatIDRef>\(channelRef)</audioChannelFormatIDRef><audioPackFormatIDRef>\(pack)</audioPackFormatIDRef><audioTrackFormatIDRef>\(trackRef)</audioTrackFormatIDRef></audioStreamFormat>"
            formats += "<audioChannelFormat audioChannelFormatID=\"\(channelRef)\" audioChannelFormatName=\"Channel \(index)\"/>"
            if index == 11 {
                formats += "<audioPackFormat audioPackFormatID=\"\(pack)\"><audioChannelFormatIDRef>\(channelRef)</audioChannelFormatIDRef></audioPackFormat>"
            } else {
                bedChannels += "<audioChannelFormatIDRef>\(channelRef)</audioChannelFormatIDRef>"
            }
            if index <= 10 { bedRefs += "<audioTrackUIDRef>\(uid)</audioTrackUIDRef>" }
        }
        let objectUID = fault == "missing_uid" ? "ATU_000000FF" : "ATU_0000000B"
        let declaration = fault == "external_xml" ? "<!DOCTYPE root [<!ENTITY x SYSTEM \"file:///etc/passwd\">]>" : ""
        let xml = """
            <?xml version="1.0"?>\(declaration)
            <ebuCoreMain><coreMetadata><format><audioFormatExtended>
            <audioObject audioObjectID="AO_1001" audioObjectName="Bed"><audioPackFormatIDRef>AP_00010017</audioPackFormatIDRef>\(bedRefs)</audioObject>
            <audioObject audioObjectID="AO_1002" audioObjectName="Conductor Object"><audioPackFormatIDRef>AP_00031001</audioPackFormatIDRef><audioTrackUIDRef>\(objectUID)</audioTrackUIDRef></audioObject>
            \(trackUIDs)
            \(formats)
            <audioPackFormat audioPackFormatID="AP_00010017">\(bedChannels)</audioPackFormat>
            </audioFormatExtended></format></coreMetadata></ebuCoreMain>
            """
        let xmlBytes = fault == "crosswired_stream"
            ? xml.replacingOccurrences(of: "<audioTrackFormatIDRef>AT_0000000B_01</audioTrackFormatIDRef>",
                                       with: "<audioTrackFormatIDRef>AT_00000001_01</audioTrackFormatIDRef>")
            : xml
        let body = chunk("fmt ", format) + chunk("chna", chna) + chunk("axml", Data(xmlBytes.utf8))
            + chunk("data", Data(repeating: 0, count: 4 * 33))
        return Data("RIFF".utf8) + number(UInt64(body.count + 4), 4) + Data("WAVE".utf8) + body
    }
}
