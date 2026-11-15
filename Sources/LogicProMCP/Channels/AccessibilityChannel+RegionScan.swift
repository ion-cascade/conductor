@preconcurrency import ApplicationServices
import Foundation

extension AccessibilityChannel {
    struct RegionPage: Codable, Equatable, Sendable {
        let horizontal: Double
        let vertical: Double

        // Native layout rounds normalized scroll values as the other axis redraws.
        func matches(_ other: Self) -> Bool {
            abs(horizontal - other.horizontal) <= 0.0012 && abs(vertical - other.vertical) <= 0.0012
        }
    }

    struct HeldRegion: @unchecked Sendable {
        let item: AXUIElement
        let header: AXUIElement
        let headerPresentation: Data
        let info: RegionInfo
        let page: RegionPage
        let viewportClearance: CGFloat
    }

    struct RegionScanSnapshot: @unchecked Sendable {
        let document: String
        let window: AXUIElement
        let expires: ContinuousClock.Instant
        let targets: [String: HeldRegion]
    }

    struct ArrangeRegionScope: @unchecked Sendable {
        let runtime: AXLogicProElements.Runtime
        let app: AXUIElement
        let window: AXUIElement
        let document: String
        let content: AXUIElement
        let pane: AXUIElement
        let horizontal: AXUIElement
        let vertical: AXUIElement
        let headers: [AXUIElement]
        let originalPage: RegionPage
        let originalSelection: [AXUIElement]

        init?(runtime: AXLogicProElements.Runtime) {
            _ = runtime.onScreenWindowList()
            guard ProcessInfo.processInfo.environment["LOGIC_MCP_LOGIC13_TRACKS"] == "1",
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else {
                Log.debug("Arrange region acquisition environment or gate unavailable", subsystem: "ax")
                return nil
            }
            guard let app = AXLogicProElements.appRoot(runtime: runtime),
                  case .found(let window) = AXLogicProElements.arrangeWindowVerifiedRead(runtime: runtime),
                  case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime),
                  URL(string: document)?.isFileURL == true else {
                Log.debug("Arrange region document unavailable", subsystem: "ax")
                return nil
            }
            guard ControlBarDisplayMode.foregroundStoppedProject(window: window, runtime: runtime, ignoringHelpTags: true) else {
                Log.debug("Arrange region foreground or stopped transport unavailable", subsystem: "ax")
                return nil
            }
            guard let content = AXLogicProElements.logic13TrackContent(in: window, runtime: runtime),
                  let pane: AXUIElement = AXHelpers.getAttribute(content, kAXParentAttribute, runtime: runtime.ax),
                  AXHelpers.getRole(pane, runtime: runtime.ax) == kAXScrollAreaRole,
                  case .success(let children) = AXHelpers.childrenResult(pane, runtime: runtime.ax),
                  children.filter({ CFEqual($0, content) }).count == 1,
                  let x = Self.scrollbar(kAXHorizontalOrientationValue, in: children, runtime: runtime.ax),
                  let y = Self.scrollbar(kAXVerticalOrientationValue, in: children, runtime: runtime.ax),
                  let h = Self.value(x, runtime: runtime.ax), let v = Self.value(y, runtime: runtime.ax) else {
                Log.debug("Arrange region pane or scroll values unavailable", subsystem: "ax")
                return nil
            }
            guard case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(in: window, runtime: runtime),
                  !headers.isEmpty, headers.count <= 256,
                  let selection = Self.regionSelection(content, runtime: runtime.ax) else {
                Log.debug("Arrange region track headers or selection unavailable", subsystem: "ax")
                return nil
            }
            self.runtime = runtime
            self.app = app
            self.window = window
            self.document = document
            self.content = content
            self.pane = pane
            self.horizontal = x
            self.vertical = y
            self.headers = headers
            originalPage = .init(horizontal: h, vertical: v)
            originalSelection = selection
            guard holdsArrange() else {
                Log.debug("Arrange region scope changed during acquisition", subsystem: "ax")
                return nil
            }
        }

        private static func scrollbar(_ axis: String, in children: [AXUIElement],
                                      runtime: AXHelpers.Runtime) -> AXUIElement? {
            let matches = children.filter {
                AXHelpers.getRole($0, runtime: runtime) == kAXScrollBarRole
                    && (AXHelpers.getAttribute($0, kAXOrientationAttribute, runtime: runtime) as String?) == axis
            }
            return matches.count == 1 ? matches.first : nil
        }

        private static func value(_ element: AXUIElement, runtime: AXHelpers.Runtime) -> Double? {
            guard let number: NSNumber = AXHelpers.getAttribute(element, kAXValueAttribute, runtime: runtime),
                  (0...1).contains(number.doubleValue) else { return nil }
            return number.doubleValue
        }

        static func regionSelection(_ content: AXUIElement, runtime: AXHelpers.Runtime) -> [AXUIElement]? {
            guard case .success(.elements(let items)) = AXHelpers.getAXUIElementArrayRead(
                content, kAXSelectedChildrenAttribute, runtime: runtime) else { return nil }
            return items
        }

        static func same(_ lhs: [AXUIElement], _ rhs: [AXUIElement]) -> Bool {
            lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { CFEqual($0, $1) }
        }

        func holdsArrange() -> Bool {
            guard OperationTraceContext.current?.ownsGate() == true,
                  case .found(let current) = AXLogicProElements.arrangeWindowVerifiedRead(runtime: runtime),
                  CFEqual(current, window),
                  ControlBarDisplayMode.foregroundStoppedProject(window: window, runtime: runtime, ignoringHelpTags: true),
                  AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime) == .success(document),
                  AXLogicProElements.logic13TrackContent(in: window, runtime: runtime).map({ CFEqual($0, content) }) == true,
                  case .success(let nodes) = AXHelpers.childrenResult(pane, runtime: runtime.ax),
                  Self.scrollbar(kAXHorizontalOrientationValue, in: nodes, runtime: runtime.ax).map({ CFEqual($0, horizontal) }) == true,
                  Self.scrollbar(kAXVerticalOrientationValue, in: nodes, runtime: runtime.ax).map({ CFEqual($0, vertical) }) == true
            else { return false }
            return true
        }

        func holdsHeaders() -> Bool {
            guard case .read(let current) = AXLogicProElements.allTrackHeadersVerifiedRead(in: window, runtime: runtime)
            else { return false }
            return Self.same(headers, current)
        }

        func page() -> RegionPage? {
            guard let x = Self.value(horizontal, runtime: runtime.ax), let y = Self.value(vertical, runtime: runtime.ax)
            else { return nil }
            return .init(horizontal: x, vertical: y)
        }

        func selectionIsOriginal() -> Bool {
            Self.regionSelection(content, runtime: runtime.ax).map { Self.same($0, originalSelection) } == true
        }

        func frame(_ element: AXUIElement) -> CGRect? {
            let ax = runtime.ax
            guard let p = AXHelpers.getPosition(element, runtime: ax),
                  let s = AXHelpers.getSize(element, runtime: ax),
                  p.x.isFinite, p.y.isFinite, s.width.isFinite, s.height.isFinite,
                  s.width > 0, s.height > 0 else { return nil }
            return CGRect(origin: p, size: s)
        }

        struct ViewportTransition {
            let reached: Bool
            /// Exact observed page after an owned, verified setter. Missing if
            /// the last write or an intervening change could not be determined.
            let ownedPage: RegionPage?
        }

        func transition(to requested: RegionPage, replacing owned: RegionPage) async -> ViewportTransition {
            var before = owned
            for (index, bar) in [horizontal, vertical].enumerated() {
                guard holdsArrange(), let current = page(), current.matches(before) else {
                    return .init(reached: false, ownedPage: nil)
                }
                before = current
                let value = index == 0 ? requested.horizontal : requested.vertical
                let expected = index == 0
                    ? RegionPage(horizontal: value, vertical: before.vertical)
                    : RegionPage(horizontal: before.horizontal, vertical: value)
                if before.matches(expected) { continue }
                guard AXHelpers.setAttribute(bar, kAXValueAttribute, NSNumber(value: value), runtime: runtime.ax)
                else { return .init(reached: false, ownedPage: page()?.matches(before) == true ? before : nil) }
                try? await Task.sleep(for: .milliseconds(125))
                guard holdsArrange(), let after = page() else { return .init(reached: false, ownedPage: nil) }
                guard after.matches(expected) else {
                    Log.debug("Arrange viewport after setting axis \(index): expected \(expected), observed \(after)", subsystem: "ax")
                    return .init(reached: false, ownedPage: after.matches(before) ? after : nil)
                }
                before = after
            }
            return .init(reached: before.matches(requested), ownedPage: before)
        }

        func show(_ page: RegionPage, replacing owned: RegionPage) async -> Bool {
            await transition(to: page, replacing: owned).reached
        }
    }

    struct RegionScanReport: Encodable {
        struct Row: Encodable {
            let region: RegionInfo
            let reference: String?
            enum CodingKeys: String, CodingKey { case region; case reference = "target_ref" }
        }

        let regions: [Row]
        let sampledPages: [RegionPage]
        let complete = false
        let scope = "sampled_arrange_viewports"
        let reasons: [String]
        let restoration: String
        enum CodingKeys: String, CodingKey {
            case regions, complete, scope, reasons, restoration
            case sampledPages = "sampled_pages"
        }
    }

    func inspectArrangeRegions(runtime: AXLogicProElements.Runtime) async -> ChannelResult {
        regionScan = nil
        guard let scope = ArrangeRegionScope(runtime: runtime) else {
            return .error(HonestContract.encodeStateC(error: .readbackUnavailable,
                hint: "A saved, stopped Logic 13 Arrange window with readable scrollbars is required."))
        }
        let grid = [0.0, 0.25, 0.5, 0.75, 1.0]
        var page = scope.originalPage
        var sampled: [RegionPage] = []
        var custodyLost = false
        var observed: [HeldRegion] = []
        var reasons = ["sampled_viewports"]
        var stackGap = false
        // Record actual scrollbar values and exact native owners for every sample.
        // Page spacing does not certify an unbroken path through every track/time lane.
        let pages = [scope.originalPage] + grid.flatMap { y in
            grid.map { x in RegionPage(horizontal: x, vertical: y) }
        }
        for requested in pages {
            guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil, scope.selectionIsOriginal() else {
                reasons.append("viewport_navigation_unverified")
                break
            }
            let navigation = await scope.transition(to: requested, replacing: page)
            if let owned = navigation.ownedPage { page = owned }
            else { custodyLost = true }
            guard navigation.reached else {
                reasons.append("viewport_navigation_unverified")
                if custodyLost { break }
                continue
            }
            if sampled.contains(where: { $0.matches(page) }) { continue }
            guard scope.holdsHeaders(), scope.selectionIsOriginal(),
                  case .success(let inventory) = Self.enumerateRegionItems(runtime: runtime),
                  scope.holdsArrange(), scope.page()?.matches(page) == true else {
                reasons.append("viewport_readback_unverified")
                break
            }
            sampled.append(page)
            stackGap = stackGap || inventory.trackHeadersWithStackVisibilityGaps > 0
            let viewport = scope.frame(scope.pane)
            for row in inventory.regions {
                let index = row.info.trackIndex
                guard scope.headers.indices.contains(index),
                      let presentation = AXTrackBinding.presentation(of: scope.headers[index], runtime: runtime.ax)
                else { continue }
                let clearance: CGFloat
                if let viewport, let frame = scope.frame(row.item), viewport.contains(frame) {
                    clearance = min(frame.minX - viewport.minX, viewport.maxX - frame.maxX,
                                    frame.minY - viewport.minY, viewport.maxY - frame.maxY)
                } else { clearance = -1 }
                let candidate = HeldRegion(item: row.item, header: scope.headers[index],
                    headerPresentation: presentation, info: row.info, page: page, viewportClearance: clearance)
                if let existing = observed.firstIndex(where: { Self.sameRegionObservation($0, item: row.item, info: row.info) }) {
                    if clearance > observed[existing].viewportClearance { observed[existing] = candidate }
                } else {
                    observed.append(candidate)
                }
                if observed.count >= 512 { break }
            }
            if observed.count >= 512 {
                reasons.append("region_limit_reached")
                break
            }
        }
        if stackGap { reasons.append("collapsed_or_unreadable_stack") }
        let restored: Bool
        if !custodyLost, scope.selectionIsOriginal() {
            restored = await scope.show(scope.originalPage, replacing: page) && scope.holdsHeaders()
        } else { restored = false }
        var targets: [String: HeldRegion] = [:]
        let rows = observed.map { held -> RegionScanReport.Row in
            guard restored, held.viewportClearance >= 8, held.info.startPosition != nil, held.info.endPosition != nil,
                  Self.isOrdinaryRegion(held.info),
                  observed.filter({ CFEqual($0.item, held.item) }).count == 1 else {
                return .init(region: held.info, reference: nil)
            }
            let ref = "reg_" + UUID().uuidString
            targets[ref] = held
            return .init(region: held.info, reference: ref)
        }
        if restored {
            regionScan = .init(document: scope.document, window: scope.window,
                expires: .now.advanced(by: .seconds(180)), targets: targets)
        } else {
            reasons.append("presentation_restoration_unverified")
        }
        return Self.encodeResult(RegionScanReport(regions: rows, sampledPages: sampled, reasons: reasons.reduce(into: []) { if !$0.contains($1) { $0.append($1) } },
                                                  restoration: restored ? "restored" : "unverified"))
    }

    private static func isOrdinaryRegion(_ info: RegionInfo) -> Bool {
        guard let help = info.rawHelp?.lowercased() else { return false }
        let markers = ["looped region", "alias region", "take folder"]
        guard !markers.contains(where: { help.contains($0) }) else { return false }
        return (info.kind == "audio" && help.contains("audio region."))
            || (info.kind == "midi" && help.contains("midi region."))
    }

    static func sameRegionObservation(_ held: HeldRegion, item: AXUIElement, info: RegionInfo) -> Bool {
        CFEqual(held.item, item) && held.info.trackIndex == info.trackIndex
            && held.info.name.utf8.elementsEqual(info.name.utf8) && held.info.kind == info.kind
            && held.info.startPosition == info.startPosition && held.info.endPosition == info.endPosition
    }
}
