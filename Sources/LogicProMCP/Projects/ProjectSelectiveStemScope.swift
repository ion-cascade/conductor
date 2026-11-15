@preconcurrency import ApplicationServices
import Foundation

/// Keeps the issued physical track headers through selection and the native Export panel.
final class ProjectSelectiveStemScope: @unchecked Sendable {
    let runtime: AXLogicProElements.Runtime
    let window: AXUIElement
    let headers: [AXUIElement]
    let originalIndex: Int
    private let document: String

    init?(
        bindings: [AXTrackBinding.Binding], subjects: [ProjectExportStemSubject], runtime: AXLogicProElements.Runtime = .production
    ) {
        _ = runtime.onScreenWindowList()
        guard let first = bindings.first, bindings.count == subjects.count,
              let pid = runtime.logicProPID(), runtime.observeHost(pid)?.logicVersion?.hasPrefix("13.") == true,
              ControlBarDisplayMode.foregroundStoppedProject(window: first.window, runtime: runtime, ignoringHelpTags: true),
              case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(in: first.window, runtime: runtime),
              zip(bindings, subjects).allSatisfy({ binding, subject in
                  CFEqual(first.window, binding.window) && binding.document == first.document &&
                      headers.indices.contains(subject.index) && CFEqual(headers[subject.index], binding.header) &&
                      binding.currentIndex() == subject.index &&
                      AXValueExtractors.extractTrackNameResult(from: binding.header, runtime: runtime.ax)
                          == .success(subject.name)
              }), let originalIndex = Self.exclusiveIndex(in: headers, runtime: runtime.ax) else { return nil }
        self.runtime = runtime
        self.window = first.window
        self.headers = headers
        self.originalIndex = originalIndex
        self.document = first.document
    }

    private static func exclusiveIndex(in headers: [AXUIElement], runtime: AXHelpers.Runtime) -> Int? {
        let states = headers.compactMap { AXValueExtractors.extractSelectedState($0, runtime: runtime) }
        guard states.count == headers.count else { return nil }
        let indices = states.indices.filter { states[$0] }
        return indices.count == 1 ? indices[0] : nil
    }

    private func currentDocument() -> Bool {
        !Task.isCancelled && runtime.focusedApplicationPID() == runtime.logicProPID()
            && AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime) == .success(document)
            && (AXHelpers.getAttribute(window, "AXDocumentEdited", runtime: runtime.ax) as Bool?) != true
    }

    func selected(_ index: Int, range: ProjectBounceRange?) -> Bool {
        guard currentDocument(),
              case .read(let live) = AXLogicProElements.allTrackHeadersVerifiedRead(in: window, runtime: runtime),
              live.count == headers.count, zip(live, headers).allSatisfy({ CFEqual($0, $1) }),
              Self.exclusiveIndex(in: live, runtime: runtime.ax) == index else { return false }
        return range == nil || cycleRange() == range
    }

    func select(_ index: Int, replacing original: Int) async -> Bool {
        guard headers.indices.contains(index),
              ControlBarDisplayMode.foregroundStoppedProject(window: window, runtime: runtime, ignoringHelpTags: true),
              selected(original, range: nil) else { return false }
        if index == original { return true }
        let header = headers[index]
        let ax = runtime.ax
        guard CGPreflightPostEventAccess(),
              case .success(let children) = AXHelpers.childrenResult(header, runtime: ax),
              case .success(.some(let name)) = AXValueExtractors.extractTrackNameResult(from: header, runtime: ax)
        else { return false }
        let fields = children.filter {
            AXHelpers.getRole($0, runtime: ax) == kAXTextFieldRole
                && AXHelpers.getDescription($0, runtime: ax) == name
        }
        guard fields.count == 1, let field = fields.first,
              let origin = AXHelpers.getPosition(field, runtime: ax),
              let size = AXHelpers.getSize(field, runtime: ax),
              origin.x.isFinite, origin.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 4, size.height > 4, let probe = ax.elementAtPosition else { return false }
        let point = CGPoint(x: origin.x + min(size.width / 2, 40), y: origin.y + size.height / 2)
        guard case .success(.some(let hit)) = probe(AXUIElementCreateSystemWide(), point),
              CFEqual(hit, field) || CFEqual(hit, header),
              selected(original, range: nil),
              OperationTraceContext.claimDeadlineEffect("selective_stem_track_select") else { return false }
        _ = AXMouseHelper.click(at: point)
        for _ in 0..<8 {
            do { try await Task.sleep(for: .milliseconds(65)) } catch { return false }
            guard currentDocument() else { return false }
            if selected(index, range: nil) { return true }
        }
        return false
    }

    /// The Custom LCD exposes two distinct locator groups and four raw fields per side.
    func cycleRange() -> ProjectBounceRange? {
        let ax = runtime.ax
        guard currentDocument(),
              let bar = AXLogicProElements.logic13ControlBarContainer(in: window, runtime: ax),
              let cycle = AXLogicProElements.directToolbarControl(AXLocalePolicy.transportCycleControl, in: bar, runtime: ax),
              AXValueExtractors.extractButtonState(cycle, runtime: ax) == true else { return nil }
        let displays = AXHelpers.findAllDescendants(of: bar, role: kAXGroupRole, maxDepth: 4, runtime: ax)
            .filter { AXHelpers.getDescription($0, runtime: ax) == "Transport Display" }
        guard displays.count == 1, let display = displays.first,
              case .success(let children) = AXHelpers.childrenResult(display, runtime: ax) else { return nil }
        func locator(_ side: String) -> String? {
            let groups = children.filter {
                AXHelpers.getRole($0, runtime: ax) == kAXGroupRole &&
                    AXHelpers.getHelp($0, runtime: ax)?.hasPrefix("\(side) Locator, \(side) Locator display.") == true
            }
            guard groups.count == 1, let group = groups.first,
                  case .success(let fields) = AXHelpers.childrenResult(group, runtime: ax),
                  fields.count == 4 else { return nil }
            var values: [String] = []
            for label in ["bar", "beat", "division", "tick"] {
                let matches = fields.filter {
                    AXHelpers.getRole($0, runtime: ax) == kAXSliderRole &&
                        AXHelpers.getDescription($0, runtime: ax) == label
                }
                guard matches.count == 1, let field = matches.first,
                      let value: Int = AXHelpers.getAttribute(field, kAXValueAttribute, runtime: ax), value > 0
                else { return nil }
                values.append(String(value))
            }
            return values.joined(separator: ".")
        }
        guard let start = locator("Left"), let end = locator("Right"),
              let first = ProjectBounceRange.position(start), let last = ProjectBounceRange.position(end),
              first.lexicographicallyPrecedes(last), currentDocument() else { return nil }
        return .init(start: start, end: end)
    }
}
