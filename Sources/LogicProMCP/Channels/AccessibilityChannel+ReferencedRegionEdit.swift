@preconcurrency import ApplicationServices
import Foundation

extension AccessibilityChannel {
    private struct RegionChange {
        let start: String
        let end: String
        let delta: Int
        let edge: Edge

        enum Edge: Equatable { case middle, start, end }

        init?(parameters: [String: String], held: HeldRegion) {
            guard let originalStart = held.info.startPosition, let originalEnd = held.info.endPosition,
                  let first = ArrangeMusicalGrid.ticks(originalStart), let last = ArrangeMusicalGrid.ticks(originalEnd),
                  first < last else { return nil }
            switch parameters["mode"] {
            case "move":
                guard let start = parameters["start"], let target = ArrangeMusicalGrid.ticks(start),
                      let end = ArrangeMusicalGrid.position(target + last - first) else { return nil }
                self.init(start: start, end: end, delta: target - first, edge: .middle)
            case "trim":
                if let start = parameters["start"], let target = ArrangeMusicalGrid.ticks(start),
                   (first..<last).contains(target) {
                    self.init(start: start, end: originalEnd, delta: target - first, edge: .start)
                } else if let end = parameters["end"], let target = ArrangeMusicalGrid.ticks(end),
                          target > first, target <= last {
                    self.init(start: originalStart, end: end, delta: target - last, edge: .end)
                } else { return nil }
            default: return nil
            }
        }

        private init(start: String, end: String, delta: Int, edge: Edge) {
            self.start = start; self.end = end; self.delta = delta; self.edge = edge
        }
    }

    func editArrangeRegion(parameters: [String: String], runtime: AXLogicProElements.Runtime) async -> ChannelResult {
        let operation = "project.edit_region"
        let reference = parameters["target_ref"] ?? ""
        func refuse(_ error: HonestContract.FailureError, _ hint: String,
                    restored: Bool = true) -> ChannelResult {
            .error(HonestContract.encodeStateC(error: error, hint: hint, extras: [
                "operation": operation, "target_ref": reference, "write_attempted": false,
                "viewport_restored": restored,
            ]))
        }
        guard let snapshot = regionScan, ContinuousClock.now < snapshot.expires,
              let held = snapshot.targets[reference],
              parameters["expected_start"] == held.info.startPosition,
              parameters["expected_end"] == held.info.endPosition else {
            return refuse(.staleTargetReference, "Scan the project again and use the region's current reference and boundaries.")
        }
        guard let change = RegionChange(parameters: parameters, held: held) else {
            return refuse(.invalidParams, "Use the observed musical grid. A trim must stay within the original region.")
        }
        guard let scope = ArrangeRegionScope(runtime: runtime),
              scope.document == snapshot.document, CFEqual(scope.window, snapshot.window), scope.holdsHeaders(),
              scope.headers.indices.contains(held.info.trackIndex),
              CFEqual(scope.headers[held.info.trackIndex], held.header),
              AXTrackBinding.presentation(of: held.header, runtime: runtime.ax) == held.headerPresentation,
              let initial = Self.regionEditCensus(scope: scope),
              initial.filter({ Self.sameRegionObservation(held, item: $0.item, info: $0.info) }).count == 1
        else { return refuse(.staleTargetReference, "The exact region and its parent track could not be corroborated.") }

        if change.delta == 0 {
            return .success(HonestContract.encodeStateA(extras: [
                "operation": operation, "target_ref": reference, "start": change.start, "end": change.end,
                "write_attempted": false, "unchanged": true,
            ]))
        }
        guard initial.allSatisfy({ $0.info.isSelected != nil && ($0.info.isSelected == false || CFEqual($0.item, held.item)) }),
              let selected = ArrangeRegionScope.regionSelection(scope.content, runtime: runtime.ax),
              selected.allSatisfy({ CFEqual($0, held.item) }) else {
            return refuse(.unsupportedState, "Deselect other regions before editing this target.")
        }
        let presentation = await scope.transition(to: held.page, replacing: scope.originalPage)
        if !presentation.reached {
            let restored: Bool
            if let owned = presentation.ownedPage {
                restored = await scope.show(scope.originalPage, replacing: owned)
            } else { restored = false }
            return refuse(.readbackUnavailable, "The saved region viewport could not be reacquired.", restored: restored)
        }

        let ax = runtime.ax
        guard let before = Self.regionEditCensus(scope: scope),
              before.count == initial.count,
              before.filter({ Self.sameRegionObservation(held, item: $0.item, info: $0.info) }).count == 1,
              Self.sameRegionPeers(initial, before, ignoring: held.item),
              scope.selectionIsOriginal(),
              Self.safeDragMode(scope: scope, held: held, change: change, census: before),
              let drag = Self.regionDragPoints(held, change: change, scope: scope),
              let hitTest = ax.elementAtPosition,
              case .success(.some(let hit)) = hitTest(scope.app, drag.start),
              Self.ownsRegionGesture(hit, held: held, edge: change.edge, runtime: ax),
              scope.holdsArrange(), scope.page()?.matches(held.page) == true,
              OperationTraceContext.claimDeadlineEffect("region_drag")
        else {
            let restored = await scope.show(scope.originalPage, replacing: held.page)
            return refuse(.readbackUnavailable,
                "The region and requested boundary must fit a writable Arrange viewport. The current edit mode and neighbors must allow the gesture without changing other regions.",
                restored: restored)
        }

        regionScan = nil
        let mouse = AXMouseHelper.Runtime.production
        let priorPointer = CGEvent(source: nil)?.location
        _ = mouse.postMouseEvent(.mouseMoved, drag.start, 0)
        mouse.sleepMicros(70_000)
        guard scope.holdsArrange(), scope.page()?.matches(held.page) == true, scope.selectionIsOriginal(),
              case .success(.some(let ready)) = hitTest(scope.app, drag.start),
              Self.ownsRegionGesture(ready, held: held, edge: change.edge, runtime: ax),
              mouse.postMouseEvent(.leftMouseDown, drag.start, 1) else {
            let restored = await scope.show(scope.originalPage, replacing: held.page)
            return refuse(.axWriteFailed, "The exact region could not be actuated.", restored: restored)
        }
        // The matching release belongs to the exact down event even if the
        // client cancels. The intermediate drag steps stay in the held lane.
        mouse.sleepMicros(100_000)
        var posted = true
        for index in 1...8 {
            let fraction = CGFloat(index) / 8
            let point = CGPoint(x: drag.start.x + (drag.end.x - drag.start.x) * fraction, y: drag.start.y)
            posted = mouse.postMouseEvent(.leftMouseDragged, point, 1) && posted
            mouse.sleepMicros(25_000)
        }
        posted = mouse.postMouseEvent(.leftMouseUp, drag.end, 1) && posted
        // A hovered resize handle replaces the region's ordinary AXHelp.
        // Move off the region before reading its actual post-edit evidence.
        if let pid = runtime.logicProPID(), runtime.focusedApplicationPID() == pid,
           let current: AXUIElement = AXHelpers.getAttribute(scope.app, kAXMainWindowAttribute, runtime: ax),
           CFEqual(current, scope.window), let frame = scope.frame(scope.window) {
            let resting = priorPointer.flatMap { frame.contains($0) && abs($0.y - drag.end.y) > 24 ? $0 : nil }
                ?? CGPoint(x: frame.minX + 180, y: frame.minY + 10)
            _ = mouse.postMouseEvent(.mouseMoved, resting, 0)
        }

        var observed: RegionInfo?
        var peersVerified = false
        for _ in 0..<6 {
            try? await Task.sleep(for: .milliseconds(150))
            guard let after = Self.regionEditCensus(scope: scope) else { continue }
            let matches = after.filter {
                CFEqual($0.item, held.item) && $0.info.trackIndex == held.info.trackIndex
                    && $0.info.name.utf8.elementsEqual(held.info.name.utf8) && $0.info.kind == held.info.kind
            }
            if matches.count == 1 { observed = matches[0].info }
            peersVerified = Self.sameRegionPeers(before, after, ignoring: held.item)
            if observed?.startPosition == change.start && observed?.endPosition == change.end && peersVerified { break }
        }
        let restored = await scope.show(scope.originalPage, replacing: held.page)
        let fields: [String: Any] = [
            "operation": operation, "target_ref": reference, "write_attempted": true,
            "requested_start": change.start, "requested_end": change.end,
            "observed_start": observed?.startPosition.map { $0 as Any } ?? NSNull(),
            "observed_end": observed?.endPosition.map { $0 as Any } ?? NSNull(),
            "neighboring_regions_verified": peersVerified, "viewport_restored": restored,
            "reference_reread_required": true,
        ]
        guard posted, restored, peersVerified, observed?.startPosition == change.start,
              observed?.endPosition == change.end else {
            return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: fields))
        }
        return .success(HonestContract.encodeStateA(extras: fields))
    }

    private typealias EditRegionRow = (item: AXUIElement, info: RegionInfo)

    private static func regionEditCensus(scope: ArrangeRegionScope) -> [EditRegionRow]? {
        guard scope.holdsArrange(), scope.holdsHeaders(),
              case .success(let result) = enumerateRegionItems(runtime: scope.runtime, includeOffscreen: true),
              scope.holdsArrange(), scope.holdsHeaders() else { return nil }
        return result.regions
    }

    private static func sameRegionPeers(_ before: [EditRegionRow], _ after: [EditRegionRow], ignoring item: AXUIElement) -> Bool {
        guard before.count == after.count else { return false }
        return before.filter { !CFEqual($0.item, item) }.allSatisfy { previous in
            after.filter {
                CFEqual(previous.item, $0.item) && previous.info.trackIndex == $0.info.trackIndex
                    && previous.info.name.utf8.elementsEqual($0.info.name.utf8)
                    && previous.info.kind == $0.info.kind
                    && previous.info.startPosition == $0.info.startPosition
                    && previous.info.endPosition == $0.info.endPosition
            }.count == 1
        }
    }

    private static func ownsRegionGesture(_ hit: AXUIElement, held: HeldRegion, edge: RegionChange.Edge,
                                          runtime: AXHelpers.Runtime) -> Bool {
        if edge == .middle { return CFEqual(hit, held.item) }
        let name = edge == .start ? "move left border" : "move right border"
        guard AXHelpers.getRole(hit, runtime: runtime) == "AXHandle",
              AXHelpers.getDescription(hit, runtime: runtime) == name,
              let parent: AXUIElement = AXHelpers.getAttribute(hit, kAXParentAttribute, runtime: runtime)
        else { return false }
        return CFEqual(parent, held.item)
    }

    private static func safeDragMode(scope: ArrangeRegionScope, held: HeldRegion, change: RegionChange,
                                     census: [EditRegionRow]) -> Bool {
        let ax = scope.runtime.ax
        let controls = AXHelpers.findAllDescendants(of: scope.window, role: kAXPopUpButtonRole, maxDepth: 12, runtime: ax)
            .filter { AXHelpers.getDescription($0, runtime: ax) == "Drag Mode" }
        guard controls.count == 1, let control = controls.first,
              let mode: String = AXHelpers.getAttribute(control, kAXValueAttribute, runtime: ax),
              ["Overlap", "No Overlap"].contains(mode),
              let originalStart = held.info.startPosition.flatMap(ArrangeMusicalGrid.ticks),
              let originalEnd = held.info.endPosition.flatMap(ArrangeMusicalGrid.ticks),
              let newStart = ArrangeMusicalGrid.ticks(change.start),
              let newEnd = ArrangeMusicalGrid.ticks(change.end) else { return false }
        if mode == "Overlap" { return true }
        // Allow the native default No Overlap when no neighbor lies near the
        // swept region. The extra bar covers snapping near either boundary.
        let earliest = min(originalStart, newStart) - 3840
        let latest = max(originalEnd, newEnd) + 3840
        return census.filter { !CFEqual($0.item, held.item) && $0.info.trackIndex == held.info.trackIndex }
            .allSatisfy { peer in
                guard let start = peer.info.startPosition.flatMap(ArrangeMusicalGrid.ticks),
                      let end = peer.info.endPosition.flatMap(ArrangeMusicalGrid.ticks) else { return false }
                return end <= earliest || start >= latest
            }
    }

    private static func regionDragPoints(_ held: HeldRegion, change: RegionChange, scope: ArrangeRegionScope)
        -> (start: CGPoint, end: CGPoint)? {
        guard let viewport = scope.frame(scope.pane), let region = scope.frame(held.item), viewport.contains(region),
              region.width > 12, region.height > 12,
              let start = held.info.startPosition.flatMap(ArrangeMusicalGrid.ticks),
              let end = held.info.endPosition.flatMap(ArrangeMusicalGrid.ticks),
              end > start else { return nil }
        let pixels = region.width * CGFloat(change.delta) / CGFloat(end - start)
        guard abs(pixels) >= 3 else { return nil }
        let origin: CGPoint
        switch change.edge {
        case .middle: origin = .init(x: region.midX, y: region.midY)
        case .start: origin = .init(x: region.minX + 2, y: region.maxY - 3)
        case .end: origin = .init(x: region.maxX - 2, y: region.maxY - 3)
        }
        let destination = CGPoint(x: origin.x + pixels, y: origin.y)
        let envelope = change.edge == .middle ? region.offsetBy(dx: pixels, dy: 0) : region
        guard viewport.insetBy(dx: 8, dy: 0).contains(destination),
              viewport.contains(envelope) else { return nil }
        return (origin, destination)
    }
}
