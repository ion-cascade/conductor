import ApplicationServices
import Foundation

extension AXLogicProElements {
    /// Follow the measured primary Tracks pane and count its header rails.
    /// Other windows and editors expose layout rows of their own.
    static func logic13PrimaryTrackRail(in window: AXUIElement, runtime: AXHelpers.Runtime) -> AXUIElement? {
        let path: [(role: String, description: String?)] = [
            (kAXGroupRole as String, "Tracks"), (kAXGroupRole as String, "Tracks"),
            (kAXSplitGroupRole as String, nil), (kAXSplitGroupRole as String, nil),
            (kAXScrollAreaRole as String, nil), (kAXGroupRole as String, "Tracks header")
        ]
        var level = [window]
        for step in path {
            var next: [AXUIElement] = []
            for parent in level {
                guard !Task.isCancelled, case .success(let children) = AXHelpers.childrenResult(parent, runtime: runtime)
                else { return nil }
                for child in children {
                    guard let role = AXHelpers.getRole(child, runtime: runtime) else { return nil }
                    guard role == step.role else { continue }
                    if let expected = step.description {
                        switch AXHelpers.getAttributeResult(child, kAXDescriptionAttribute as String, runtime: runtime)
                            as Result<String?, AXHelpers.AXStatusError> {
                        case .success(let actual) where actual == expected: break
                        case .success: continue
                        case .failure(let error) where error.isDefinitiveAbsence: continue
                        case .failure: return nil
                        }
                    }
                    guard let owner: AXUIElement = AXHelpers.getAttribute(child, kAXParentAttribute as String, runtime: runtime),
                          CFEqual(owner, parent), !next.contains(where: { CFEqual($0, child) }) else { return nil }
                    next.append(child)
                }
            }
            guard !next.isEmpty, next.count <= 16 else { return nil }
            level = next
        }
        return level.count == 1 ? level[0] : nil
    }

    /// The region workspace is the sibling of the held header scroll area.
    /// Do not enumerate the Library/Inspector to find this known Arrange path.
    static func logic13TrackContent(in window: AXUIElement, runtime: Runtime) -> AXUIElement? {
        let ax = runtime.ax
        guard !Task.isCancelled,
              let rail = logic13PrimaryTrackRail(in: window, runtime: ax),
              let scroll: AXUIElement = AXHelpers.getAttribute(rail, kAXParentAttribute as String, runtime: ax),
              AXHelpers.getRole(scroll, runtime: ax) == kAXScrollAreaRole as String,
              let split: AXUIElement = AXHelpers.getAttribute(scroll, kAXParentAttribute as String, runtime: ax),
              AXHelpers.getRole(split, runtime: ax) == kAXSplitGroupRole as String,
              case .success(let siblings) = AXHelpers.childrenResult(split, runtime: ax),
              siblings.filter({ CFEqual($0, scroll) }).count == 1 else { return nil }
        var ancestor = split
        var visited = [split]
        while !CFEqual(ancestor, window) {
            guard !Task.isCancelled, visited.count < 16,
                  let parent: AXUIElement = AXHelpers.getAttribute(ancestor, kAXParentAttribute as String, runtime: ax),
                  !visited.contains(where: { CFEqual($0, parent) }),
                  case .success(let children) = AXHelpers.childrenResult(parent, runtime: ax),
                  children.filter({ CFEqual($0, ancestor) }).count == 1 else { return nil }
            ancestor = parent; visited.append(parent)
        }
        var contents: [AXUIElement] = []
        for sibling in siblings where !CFEqual(sibling, scroll) {
            guard !Task.isCancelled, let role = AXHelpers.getRole(sibling, runtime: ax) else { return nil }
            guard role == kAXScrollAreaRole as String else { continue }
            guard case .success(let children) = AXHelpers.childrenResult(sibling, runtime: ax) else { return nil }
            for child in children {
                guard let role = AXHelpers.getRole(child, runtime: ax) else { return nil }
                if role == kAXGroupRole as String,
                   AXLocalePolicy.trackContentExplicit.containsNormalized(AXHelpers.getDescription(child, runtime: ax)) {
                    guard let parent: AXUIElement = AXHelpers.getAttribute(child, kAXParentAttribute as String, runtime: ax),
                          CFEqual(parent, sibling) else { return nil }
                    contents.append(child)
                }
            }
        }
        return contents.count == 1 ? contents[0] : nil
    }

    /// Logic 13 exposes each region under its numbered Arrange lane. Match the
    /// full native lane label to one retained header, including its ordinal.
    /// Logic drops AXParent from some lane proxies. Prove direct membership with
    /// the held content's child list and validate the region's reciprocal link.
    static func logic13RegionTrackIndex(_ region: AXUIElement, in content: AXUIElement,
                                        headers: [AXUIElement], runtime: AXHelpers.Runtime) -> Int? {
        guard let lane: AXUIElement = AXHelpers.getAttribute(region, kAXParentAttribute as String, runtime: runtime),
              AXHelpers.getRole(lane, runtime: runtime) == kAXLayoutAreaRole as String,
              case .success(let lanes) = AXHelpers.childrenResult(content, runtime: runtime),
              lanes.filter({ CFEqual($0, lane) }).count == 1,
              case .success(let regions) = AXHelpers.childrenResult(lane, runtime: runtime),
              regions.filter({ CFEqual($0, region) }).count == 1,
              let numberedName = AXHelpers.getDescription(lane, runtime: runtime), !numberedName.isEmpty else { return nil }
        var matches: [Int] = []
        for (index, header) in headers.enumerated() {
            guard let description = AXHelpers.getDescription(header, runtime: runtime) else { return nil }
            if description.utf8.elementsEqual(numberedName.utf8) { matches.append(index) }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Individual Arrange items carry selection even when the split editor
    /// reports an empty selected-children array at the group level.
    static func logic13SelectedRegion(in content: AXUIElement, runtime: AXHelpers.Runtime) -> AXUIElement? {
        guard let items = logic13RegionItems(in: content, runtime: runtime) else { return nil }
        var selection: AXUIElement?
        for item in items where (AXHelpers.getAttribute(item, kAXRoleDescriptionAttribute, runtime: runtime) as String?) == "Region" {
            guard case .success(let selected?) = AXHelpers.getAttributeResult(item, kAXSelectedAttribute, runtime: runtime)
                as Result<NSNumber?, AXHelpers.AXStatusError> else { return nil }
            if selected.boolValue {
                guard selection == nil else { return nil }
                selection = item
            }
        }
        return selection
    }

    /// An unreadable, cyclic or truncated tree is not an empty region set.
    static func logic13RegionItems(in content: AXUIElement, runtime: AXHelpers.Runtime) -> [AXUIElement]? {
        var pending: [(AXUIElement, Int)] = [(content, 0)]
        var visited: [AXUIElement] = []
        var result: [AXUIElement] = []
        let leaves = Set([kAXStaticTextRole, kAXTextFieldRole, kAXImageRole,
            kAXButtonRole, kAXCheckBoxRole, kAXSliderRole, kAXValueIndicatorRole].map { $0 as String })
        while let (element, depth) = pending.popLast() {
            guard !Task.isCancelled, depth <= 10, visited.count < 4096,
                  !visited.contains(where: { CFEqual($0, element) }),
                  let role = AXHelpers.getRole(element, runtime: runtime) else { return nil }
            visited.append(element)
            if role == kAXLayoutItemRole as String { result.append(element); continue }
            if leaves.contains(role) { continue }
            switch AXHelpers.childrenResult(element, runtime: runtime) {
            case .success(let children):
                pending.append(contentsOf: children.reversed().map { ($0, depth + 1) })
            case .failure(let error) where role == kAXLayoutAreaRole as String && error.isDefinitiveAbsence:
                // Empty Logic 13 track lanes return AXError.noValue for AXChildren.
                continue
            case .failure:
                return nil
            }
        }
        return result
    }
}
