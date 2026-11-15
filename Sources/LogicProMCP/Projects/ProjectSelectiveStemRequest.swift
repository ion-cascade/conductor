import Foundation
import MCP

struct ProjectSelectiveStemRequest {
    let projectPath: String
    let outputRoot: String
    let deliveryID: UUID
    let references: [TargetReference]
    let settings: ProjectAlignedStemSettings

    static func requested(_ params: [String: Value]) -> Bool {
        guard case .object(let settings) = params["stem_settings"] else { return false }
        return settings["track_refs"] != nil || settings["delivery_id"] != nil || settings["range"] != nil
    }

    init(_ params: [String: Value]) throws {
        let projects = try ProjectExportPlanner.projectPaths(from: params)
        let kinds = try ProjectExportPlanner.artifactKinds(from: params)
        guard projects.count == 1, let project = projects.first,
              AppleScriptSafety.isValidProjectPath(project, requireExisting: true),
              kinds == ["stem"], params["bounce_settings"] == nil, params["naming_policy"] == nil,
              params["collision_policy"] == nil || params["collision_policy"]?.stringValue == "fail_if_exists",
              case .object(var fields) = params["stem_settings"],
              case .array(let tracks) = fields.removeValue(forKey: "track_refs"),
              (1...16).contains(tracks.count),
              case .string(let id) = fields.removeValue(forKey: "delivery_id"),
              let deliveryID = UUID(uuidString: id) else {
            throw ExportPlanError.invalid("Selective stems require one saved .logicx, artifacts [stem], an existing output_root, and stem_settings with 1–16 track_refs and a delivery_id UUID.")
        }
        let references = tracks.compactMap { value -> TargetReference? in
            guard case .string(let raw) = value, raw.hasPrefix("trk_") else { return nil }
            return TargetReference(rawValue: raw)
        }
        guard references.count == tracks.count, Set(references).count == tracks.count else {
            throw ExportPlanError.invalid("Use distinct current track references from the open project.")
        }
        let range = try ProjectBounceRange.parse(fields.removeValue(forKey: "range"))
        guard let profile = try ProjectAlignedStemSettings.parse(.object(fields), artifacts: kinds) else {
            throw ExportPlanError.invalid("Selective stems require native WAVE settings.")
        }
        let root = try ProjectExportPlanner.outputRoot(from: params)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue,
              URL(fileURLWithPath: root).resolvingSymlinksInPath().path == root else {
            throw ExportPlanError.invalid("The selective stem output root must be an existing directory at its canonical path.")
        }
        self.projectPath = URL(fileURLWithPath: project).standardizedFileURL.path
        self.outputRoot = root
        self.deliveryID = deliveryID
        self.references = references
        self.settings = .init(includeAudioTail: profile.includeAudioTail,
                              includeVolumePanAutomation: profile.includeVolumePanAutomation, range: range)
    }

    var directory: URL {
        URL(fileURLWithPath: outputRoot).appendingPathComponent("Conductor Stems \(deliveryID.uuidString)", isDirectory: true)
    }
}
