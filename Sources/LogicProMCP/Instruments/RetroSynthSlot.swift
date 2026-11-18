import ApplicationServices
import Foundation

/// A selected physical Arrange header corroborates its Inspector. The native
/// instrument group and its Open button are retained independently of any editor.
struct RetroSynthSlot {
    let physical: AXTrackBinding.Binding
    let index: Int
    let name: String
    let strip: AXUIElement
    let group: AXUIElement
    let openButton: AXUIElement

    static func acquire(physical: AXTrackBinding.Binding, index: Int, name: String) -> Self? {
        let runtime = physical.runtime.ax
        guard physical.currentIndex() == index,
              case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(
                in: physical.window, runtime: physical.runtime),
              headers.indices.contains(index), CFEqual(headers[index], physical.header),
              headers.enumerated().allSatisfy({
                  AXValueExtractors.extractSelectedState($0.element, runtime: runtime) == ($0.offset == index)
              }),
              headers.enumerated().filter({
                  AXValueExtractors.extractTrackState(from: $0.element, index: $0.offset, runtime: runtime).name == name
              }).count == 1,
              case .success(let rootChildren) = AXHelpers.childrenResult(physical.window, runtime: runtime) else { return nil }
        let inspectors = rootChildren.filter {
            AXHelpers.getRole($0, runtime: runtime) == kAXGroupRole
                && AXHelpers.getDescription($0, runtime: runtime) == "Inspector"
        }
        guard inspectors.count == 1,
              let nodes = try? descendants(inspectors[0], runtime: runtime, maximumDepth: 5, capacity: 300) else { return nil }
        let strips = nodes.filter {
            AXHelpers.getRole($0, runtime: runtime) == "AXLayoutItem"
                && AXHelpers.getDescription($0, runtime: runtime) == name
                && (AXHelpers.getAttribute($0, kAXHelpAttribute, runtime: runtime) as String?)?.hasPrefix("Left inspector channel strip.") == true
        }
        guard strips.count == 1, case .success(let controls) = AXHelpers.childrenResult(strips[0], runtime: runtime) else { return nil }
        let groups = controls.filter {
            AXHelpers.getRole($0, runtime: runtime) == kAXGroupRole
                && AXHelpers.getDescription($0, runtime: runtime) == "RetroSyn"
        }
        guard groups.count == 1, case .success(let buttons) = AXHelpers.childrenResult(groups[0], runtime: runtime) else { return nil }
        let open = buttons.filter {
            AXHelpers.getRole($0, runtime: runtime) == kAXButtonRole
                && AXHelpers.getDescription($0, runtime: runtime) == "open"
        }
        guard open.count == 1, physical.currentIndex() == index else { return nil }
        return Self(physical: physical, index: index, name: name, strip: strips[0], group: groups[0], openButton: open[0])
    }

    func isCurrent() -> Bool {
        guard let renewed = Self.acquire(physical: physical, index: index, name: name) else { return false }
        return CFEqual(strip, renewed.strip) && CFEqual(group, renewed.group) && CFEqual(openButton, renewed.openButton)
    }

    static func descendants(_ root: AXUIElement, runtime: AXHelpers.Runtime,
                            maximumDepth: Int, capacity: Int) throws -> [AXUIElement] {
        var pending = [(root, 0)]
        var result: [AXUIElement] = []
        var cursor = 0
        while cursor < pending.count {
            let (node, depth) = pending[cursor]
            cursor += 1
            if result.contains(where: { CFEqual($0, node) }) { continue }
            guard result.count < capacity else { throw RetroSynthSnapshot.Failure.unavailable("control_census_limit") }
            result.append(node)
            if depth == maximumDepth { continue }
            switch AXHelpers.childrenResult(node, runtime: runtime) {
            case .success(let children):
                guard pending.count + children.count <= capacity * 2 else {
                    throw RetroSynthSnapshot.Failure.unavailable("control_population_limit")
                }
                pending += children.map { ($0, depth + 1) }
            case .failure(let error) where error.isDefinitiveAbsence: break
            case .failure: throw RetroSynthSnapshot.Failure.unavailable("control_census_unreadable")
            }
        }
        return result
    }
}
