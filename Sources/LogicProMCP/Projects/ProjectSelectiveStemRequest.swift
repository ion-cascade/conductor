import Foundation
import MCP

struct ProjectSelectiveStemRequest {
    let projectPath: String
    let outputRoot: String
    let deliveryID: UUID
    let references: [TargetReference]
    let settings: ProjectAlignedStemSettings
    let mix: ProjectPCMBounceSettings?

    static func requested(_ params: [String: Value]) -> Bool {
        guard case .object(let settings) = params["stem_settings"] else { return false }
        return settings["track_refs"] != nil || settings["delivery_id"] != nil || settings["range"] != nil
    }

    init(_ params: [String: Value]) throws {
        let projects = try ProjectExportPlanner.projectPaths(from: params)
        let kinds = try ProjectExportPlanner.artifactKinds(from: params)
        guard projects.count == 1, let project = projects.first,
              AppleScriptSafety.isValidProjectPath(project, requireExisting: true),
              (kinds == ["stem"] || Set(kinds) == ["stem", "bounce"]),
              params["naming_policy"] == nil,
              params["collision_policy"] == nil || params["collision_policy"]?.stringValue == "fail_if_exists",
              case .object(var fields) = params["stem_settings"],
              case .array(let tracks) = fields.removeValue(forKey: "track_refs"),
              (1...16).contains(tracks.count),
              case .string(let id) = fields.removeValue(forKey: "delivery_id"),
              let deliveryID = UUID(uuidString: id) else {
            throw ExportPlanError.invalid("Selective delivery requires one saved .logicx, stem or stem and bounce artifacts, an existing output_root, and stem_settings with 1–16 track_refs and a delivery_id UUID.")
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
        var mix = try ProjectPCMBounceSettings.parse(params["bounce_settings"], artifacts: kinds)
        if kinds.contains("bounce") {
            guard let range, let requested = mix, requested.format == .wav, requested.bitDepth == 24,
                  !requested.includeAudioTail, !profile.includeAudioTail,
                  requested.range == nil || requested.range == range else {
                throw ExportPlanError.invalid("A mix and stem delivery needs an exact stem range and 24-bit WAVE bounce settings at the project sample rate, with both tail options off.")
            }
            mix?.range = range
        }
        let root = try Self.existingRoot(from: params)
        self.projectPath = URL(fileURLWithPath: project).standardizedFileURL.path
        self.outputRoot = root
        self.deliveryID = deliveryID
        self.references = references
        self.settings = .init(includeAudioTail: profile.includeAudioTail,
                              includeVolumePanAutomation: profile.includeVolumePanAutomation, range: range)
        self.mix = mix
    }

    static func existingRoot(from params: [String: Value]) throws -> String {
        let root = try ProjectExportPlanner.outputRoot(from: params)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue,
              URL(fileURLWithPath: root).resolvingSymlinksInPath().path == root else {
            throw ExportPlanError.invalid("The delivery output root must be an existing directory at its canonical path.")
        }
        return root
    }

    static func directory(root: String, id: UUID) -> URL {
        URL(fileURLWithPath: root).appendingPathComponent("Conductor Stems \(id.uuidString)", isDirectory: true)
    }

    var directory: URL { Self.directory(root: outputRoot, id: deliveryID) }
}
