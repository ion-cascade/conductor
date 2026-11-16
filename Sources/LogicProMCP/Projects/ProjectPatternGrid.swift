import ApplicationServices
import CryptoKit
import Foundation

struct ProjectPatternGrid {
    struct Entry: Codable, Equatable {
        let row: String
        let step: Int
        let enabled: Bool
        let velocity: Int
        let chance_percent: Int?
        let repeat_count: Int?
        let tied: Bool?

        init(_ read: ProjectPatternStep) {
            row = read.address.row
            step = read.address.step
            enabled = read.enabled
            velocity = read.velocity
            chance_percent = read.chance
            repeat_count = read.repeatCount
            tied = read.tied
        }

        var address: ProjectPatternStep.CellAddress { .init(row: row, step: step) }

        func replacingEnabled(_ value: Bool) -> Self {
            .init(row: row, step: step, enabled: value, velocity: velocity,
                  chance_percent: chance_percent, repeat_count: repeat_count, tied: tied)
        }

        private init(row: String, step: Int, enabled: Bool, velocity: Int, chance_percent: Int?,
                     repeat_count: Int?, tied: Bool?) {
            self.row = row
            self.step = step
            self.enabled = enabled
            self.velocity = velocity
            self.chance_percent = chance_percent
            self.repeat_count = repeat_count
            self.tied = tied
        }
    }

    struct Identity: Codable, Equatable {
        let project_path: String
        let track: String
        let region_name: String
        let region_location: String

        init(_ step: ProjectPatternStep) {
            project_path = step.address.projectPath
            track = step.address.track
            region_name = step.address.regionName
            region_location = step.address.regionLocation
        }

        init?(json: [String: String]) {
            guard json.count == 4, let path = json["project_path"], let track = json["track"],
                  let name = json["region_name"], let location = json["region_location"] else { return nil }
            project_path = path
            self.track = track
            region_name = name
            region_location = location
        }
    }

    let identity: Identity
    let cells: [Entry]

    func data() throws -> Data {
        struct Evidence: Codable {
            let address: Identity
            let cells: [Entry]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Evidence(address: identity, cells: cells))
    }

    func snapshot() throws -> String {
        let digest = SHA256.hash(data: try data()).map { String(format: "%02x", $0) }.joined()
        return "grid_" + digest
    }

    static func capture(from first: ProjectPatternStep) async -> Self? {
        guard let addresses = first.completeGrid else { return nil }
        var current = first
        var cells = [Entry]()
        var allRead = true
        for target in addresses {
            guard !Task.isCancelled, let selected = await select(target, from: current) else {
                allRead = false
                break
            }
            current = selected
            cells.append(Entry(selected))
        }
        guard await select(first.cellAddress, from: current) != nil, allRead,
              cells.count == addresses.count else { return nil }
        return Self(identity: Identity(first), cells: cells)
    }

    static func select(_ target: ProjectPatternStep.CellAddress, from current: ProjectPatternStep) async -> ProjectPatternStep? {
        guard let fresh = ProjectPatternStep.read(), fresh.holdsSameSelection(as: current),
              fresh.visibleRows == current.visibleRows else { return nil }
        if fresh.cellAddress == target { return fresh }
        return await fresh.moveSelection(to: target)
    }
}
