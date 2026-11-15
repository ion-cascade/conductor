import Foundation
import MCP

struct ProjectAlignedStemSettings: Codable, Equatable, Sendable {
    let includeAudioTail: Bool
    let includeVolumePanAutomation: Bool
    let range: ProjectBounceRange?

    init(includeAudioTail: Bool, includeVolumePanAutomation: Bool, range: ProjectBounceRange? = nil) {
        self.includeAudioTail = includeAudioTail
        self.includeVolumePanAutomation = includeVolumePanAutomation
        self.range = range
    }

    enum CodingKeys: String, CodingKey {
        case range
        case includeAudioTail = "include_audio_tail"
        case includeVolumePanAutomation = "include_volume_pan_automation"
    }

    static func parse(_ raw: Value?, artifacts: [String]) throws -> Self? {
        guard let raw else { return nil }
        guard artifacts.contains("stem"), case .object(let values) = raw,
              Set(values.keys).isSubset(of: ["include_audio_tail", "include_volume_pan_automation"]) else {
            throw ExportPlanError.invalid("stem_settings requires a stem artifact and accepts include_audio_tail and include_volume_pan_automation")
        }
        func option(_ name: String) throws -> Bool {
            guard let value = values[name] else { return false }
            guard case .bool(let active) = value else { throw ExportPlanError.invalid("stem_settings.\(name) must be a Boolean") }
            return active
        }
        return try Self(includeAudioTail: option("include_audio_tail"),
                        includeVolumePanAutomation: option("include_volume_pan_automation"))
    }

    /// The native Track Name attachment was qualified with unique, portable names.
    static func namesQualify(_ subjects: [ProjectExportStemSubject]) -> Bool {
        let names = subjects.map(\.name)
        return !names.isEmpty && Set(names.map { $0.lowercased() }).count == names.count
            && names.allSatisfy { name in
                !name.isEmpty && name == name.trimmingCharacters(in: .whitespaces)
                    && name.unicodeScalars.allSatisfy { scalar in
                        (97...122).contains(scalar.value) || (65...90).contains(scalar.value) || (48...57).contains(scalar.value)
                            || scalar == " " || scalar == "-" || scalar == "_"
                    }
            }
    }
}
