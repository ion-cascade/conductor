import Foundation
import FoundationXML

/// A bounded ADM BWF inspection. Channel attribution follows CHNA track UIDs
/// and their AXML object membership, independently of the output filename.
struct ProjectADMArtifact: Codable, Sendable {
    struct Object: Codable, Sendable {
        let id: String
        let name: String
        let packReferences: [String]
        let channels: [Int]
    }

    let sampleRate: Int
    let bitDepth: Int
    let channels: Int
    let frames: UInt64
    let objects: [Object]

    static func read(_ url: URL) throws -> Self {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        guard size >= 44 else { throw Failure.invalid }
        try file.seek(toOffset: 0)
        let header = try bytes(file, count: 12)
        let container = String(decoding: header.prefix(4), as: UTF8.self)
        guard ["RIFF", "RF64", "BW64"].contains(container),
              String(decoding: header[8..<12], as: UTF8.self) == "WAVE" else { throw Failure.invalid }
        var offset: UInt64 = 12
        var riffSize = UInt64(integer(header, 4, 4)) + 8
        var extendedDataSize: UInt64?
        var chunks: [String: Data] = [:]
        var dataSize: UInt64?
        while offset < size {
            guard offset + 8 <= size else { throw Failure.invalid }
            try file.seek(toOffset: offset)
            let chunkHeader = try bytes(file, count: 8)
            let tag = String(decoding: chunkHeader.prefix(4), as: UTF8.self)
            var length = integer(chunkHeader, 4, 4)
            if tag == "data", length == UInt64(UInt32.max) {
                guard let extendedDataSize else { throw Failure.invalid }
                length = extendedDataSize
            }
            guard length <= size - offset - 8 else { throw Failure.invalid }
            if tag == "ds64" {
                guard container != "RIFF", chunks[tag] == nil, length >= 28, length <= 1_048_576 else { throw Failure.invalid }
                let body = try bytes(file, count: Int(length))
                riffSize = integer(body, 0, 8) + 8
                extendedDataSize = integer(body, 8, 8)
                chunks[tag] = body
            } else if ["fmt ", "axml", "chna"].contains(tag) {
                guard chunks[tag] == nil, length > 0, length <= 1_048_576 else { throw Failure.invalid }
                chunks[tag] = try bytes(file, count: Int(length))
            } else if tag == "data" {
                guard dataSize == nil, length > 0 else { throw Failure.invalid }
                dataSize = length
            }
            offset += 8 + length + length % 2
        }
        guard offset == size, riffSize == size,
              let format = chunks["fmt "], format.count >= 16,
              let chna = chunks["chna"], let axml = chunks["axml"], let dataSize else { throw Failure.invalid }
        let encoding = integer(format, 0, 2)
        let channels = Int(integer(format, 2, 2))
        let rate = Int(integer(format, 4, 4))
        let align = Int(integer(format, 12, 2))
        let depth = Int(integer(format, 14, 2))
        guard (1...128).contains(channels), rate == 48_000, depth == 24,
              align == channels * 3, dataSize % UInt64(align) == 0,
              integer(format, 8, 4) == UInt64(rate * align) else { throw Failure.invalid }
        if encoding == 0xfffe {
            guard format.count >= 40, integer(format, 16, 2) >= 22,
                  integer(format, 18, 2) == 24,
                  Array(format[24..<40]) == [1, 0, 0, 0, 0, 0, 16, 0, 128, 0, 0, 170, 0, 56, 155, 113]
            else { throw Failure.invalid }
        } else {
            guard encoding == 1 else { throw Failure.invalid }
        }
        let uids = try trackUIDs(chna, channels: channels)
        let xml = try ADMXML.read(axml)
        let objectNodes = xml.nodes(named: "audioObject")
        var seenChannels = Set<Int>()
        let objects = try objectNodes.map { node -> Object in
            guard let id = node.attributes["audioObjectID"], !id.isEmpty,
                  let name = node.attributes["audioObjectName"], !name.isEmpty else { throw Failure.invalid }
            let references = node.children.filter { $0.name == "audioTrackUIDRef" }.map(\.text)
            let packs = node.children.filter { $0.name == "audioPackFormatIDRef" }.map(\.text)
            guard !references.isEmpty, !packs.isEmpty else { throw Failure.invalid }
            let indices = try references.map { uid -> Int in
                guard let index = uids[uid], seenChannels.insert(index).inserted else { throw Failure.invalid }
                return index
            }
            return Object(id: id, name: name, packReferences: packs, channels: indices)
        }
        guard !objects.isEmpty, seenChannels == Set(1...channels),
              Set(objects.map(\.id)).count == objects.count,
              Set(xml.nodes(named: "audioTrackUID").compactMap { $0.attributes["UID"] }) == Set(uids.keys)
        else { throw Failure.invalid }
        return Self(sampleRate: rate, bitDepth: depth, channels: channels, frames: dataSize / UInt64(align), objects: objects)
    }

    enum Failure: Error { case invalid }

    private static func bytes(_ file: FileHandle, count: Int) throws -> Data {
        guard let data = try file.read(upToCount: count), data.count == count else { throw Failure.invalid }
        return data
    }

    private static func integer(_ bytes: Data, _ offset: Int, _ count: Int) -> UInt64 {
        bytes[offset..<(offset + count)].enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
    }

    private static func trackUIDs(_ data: Data, channels: Int) throws -> [String: Int] {
        guard data.count >= 4, integer(data, 0, 2) == channels,
              integer(data, 2, 2) == channels, data.count == 4 + channels * 40 else { throw Failure.invalid }
        var result: [String: Int] = [:]
        for row in 0..<channels {
            let start = 4 + row * 40
            let index = Int(integer(data, start, 2))
            let uid = String(decoding: data[(start + 2)..<(start + 14)], as: UTF8.self)
            guard (1...channels).contains(index), uid.hasPrefix("ATU_"), result[uid] == nil else { throw Failure.invalid }
            result[uid] = index
        }
        guard Set(result.values).count == channels else { throw Failure.invalid }
        return result
    }
}

private final class ADMXML: NSObject, XMLParserDelegate {
    final class Node {
        let name: String
        let attributes: [String: String]
        var text = ""
        var children: [Node] = []
        init(_ name: String, _ attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }
    }

    private var stack: [Node] = []
    private var all: [Node] = []

    static func read(_ data: Data) throws -> ADMXML {
        guard let text = String(data: data, encoding: .utf8),
              !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else { throw ProjectADMArtifact.Failure.invalid }
        let document = ADMXML()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = true
        parser.delegate = document
        guard parser.parse(), document.stack.isEmpty,
              document.nodes(named: "audioFormatExtended").count == 1 else { throw ProjectADMArtifact.Failure.invalid }
        return document
    }

    func nodes(named name: String) -> [Node] { all.filter { $0.name == name } }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        let node = Node(name, attributes)
        stack.last?.children.append(node)
        stack.append(node)
        all.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        stack.last?.text = stack.last?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        _ = stack.popLast()
    }
}
