@preconcurrency import ApplicationServices
import Foundation

extension AccessibilityChannel {
    private struct SidechainUnavailable: Error {
        let stage: String
        var error: HonestContract.FailureError = .readbackUnavailable
    }

    /// Logic 13 keeps the open editor's header stale after some bus picks.
    /// Reacquire the same physical insert and read a new editor before success.
    static func compressorSidechainVerified(
        params: [String: String], writing: Bool, runtime: AXLogicProElements.Runtime
    ) async -> ChannelResult {
        let operation = "logic_plugins.\(writing ? "set" : "get")_sidechain_verified"
        let compressor = "logic.stock.effect.compressor"
        let ax = runtime.ax
        func refuse(_ error: HonestContract.FailureError, _ stage: String) -> ChannelResult {
            .error(HonestContract.encodeStateC(error: error,
                hint: "Show the target track in Logic’s Mixer and close floating plug-in windows. Use Internal or a source from the reported bus choices.",
                extras: ["operation": operation, "readback_stage": stage, "write_attempted": false]))
        }
        func popupSource(_ title: String) -> String? {
            if title == "Internal" { return title }
            let fields = title.components(separatedBy: " ← ")
            guard fields.count == 2, fields[0].hasPrefix("Bus "), !fields[1].isEmpty,
                  let bus = Int(fields[0].dropFirst(4)), (1...256).contains(bus), fields[0] == "Bus \(bus)" else {
                return nil
            }
            return fields[0]
        }

        let requested = params["source"]
        let expected = params["expected_current"]
        guard params["plugin"] == compressor, params["expected_slot_read_status"] == "ok",
              !writing || (requested.flatMap(popupSource) != nil && expected.flatMap(popupSource) != nil),
              let track = params["track"].flatMap(Int.init), track >= 0,
              let insert = params["insert"].flatMap(Int.init), insert >= 0,
              let projectPath = params["project_expected_path"], let trackName = params["expected_track_name"],
              runtime.onScreenWindowList() != nil, let pid = runtime.logicProPID(),
              runtime.observeHost(pid)?.logicVersion?.hasPrefix("13.") == true,
              let app = AXLogicProElements.appRoot(runtime: runtime) else { return refuse(.invalidParams, "compressor_scope") }
        guard case .found(let arrange) = AXLogicProElements.arrangeWindowVerifiedRead(runtime: runtime),
              case .success(let document?) = AXLogicProElements.projectPickerDocumentRead(arrange, runtime: runtime),
              let url = URL(string: document), url.isFileURL,
              AppleScriptChannel.projectPathsMatch(projectPath, url.path),
              ControlBarDisplayMode.foregroundStoppedProject(window: arrange, runtime: runtime, ignoringHelpTags: true),
              let mixer = mixerWithoutRevealForInventory(runtime: runtime, revealRequested: false)?.mixer,
              let binding = AXPluginTrackBinding.resolve(track: track, mixer: mixer, runtime: runtime),
              CFEqual(arrange, binding.window), binding.trackName == trackName,
              let slots = AXLogicProElements.audioPluginInsertSlots(in: binding.strip, runtime: ax),
              slots.indices.contains(insert), !slots.contains(where: { $0.readStatus == .occupiedUnreadable }),
              slots.filter({ $0.name == "Compressor" }).count == 1,
              slots[insert].name == "Compressor" else { return refuse(.readbackUnavailable, "compressor_slot") }
        let slot = slots[insert]
        if let failure = pluginInsertReferenceGuard(params: params, slot: slot, operation: operation) { return failure }

        func context() -> Bool {
            !Task.isCancelled && runtime.focusedApplicationPID() == pid
                && AXLogicProElements.projectPickerDocumentRead(arrange, runtime: runtime) == .success(document)
                && AXPluginTrackBinding.isStable(binding, runtime: runtime)
                && currentChainMatches()
                && (try? AXLogicProElements.observedTransportActivity(in: arrange, runtime: runtime, checking: {}))
                    .map { !$0.isPlaying && !$0.isRecording } == true
        }
        func currentChainMatches() -> Bool {
            guard let live = AXLogicProElements.audioPluginInsertSlots(in: binding.strip, runtime: ax),
                  live.count == slots.count, live.indices.contains(insert), CFEqual(slot.element, live[insert].element)
            else { return false }
            return zip(slots, live).allSatisfy { original, current in
                original.index == current.index && original.name == current.name && original.isBypassed == current.isBypassed
                    && original.readStatus == current.readStatus
            }
        }
        func windows() -> [AXUIElement]? {
            (AXHelpers.getAttribute(app, kAXWindowsAttribute as String, runtime: ax) as [AXUIElement]?)?
                .filter { AXHelpers.getRole($0, runtime: ax) == kAXWindowRole as String }
        }
        func focused(_ window: AXUIElement) -> Bool {
            (AXHelpers.getAttribute(app, kAXFocusedWindowAttribute as String, runtime: ax) as AXUIElement?)
                .map { CFEqual($0, window) } == true
        }
        func children(_ element: AXUIElement) -> [AXUIElement] {
            guard case .success(let result) = AXHelpers.childrenResult(element, runtime: ax) else { return [] }
            return result
        }
        func text(_ element: AXUIElement, _ key: String) -> String? {
            AXHelpers.getAttribute(element, key, runtime: ax)
        }
        func identified(_ editor: AXUIElement) -> Bool {
            AXHelpers.getTitle(editor, runtime: ax) == trackName && children(editor).filter {
                AXHelpers.getRole($0, runtime: ax) == kAXStaticTextRole as String && text($0, kAXValueAttribute) == "Compressor"
            }.count == 1
        }
        func owned(_ editor: AXUIElement) -> Bool {
            guard context(), identified(editor), let current = windows(), current.count == 2 else { return false }
            return current.contains(arrange) && current.contains(editor)
        }
        func noMenu() -> Bool {
            runtime.onScreenWindowList().map { LogicOnScreenWindows.popupMenuCount($0, logicPID: pid) } == 0
        }
        var editor: AXUIElement?
        var menu: (popup: AXUIElement, menu: AXUIElement)?
        var attempted = false
        var before: String?
        var after: String?
        var choices: [String] = []

        func openEditor() async throws -> AXUIElement {
            let open = children(slot.element).filter {
                AXHelpers.getRole($0, runtime: ax) == kAXButtonRole as String && AXHelpers.getDescription($0, runtime: ax) == "open"
            }
            guard context(), windows() == [arrange], focused(arrange), noMenu(), open.count == 1,
                  OperationTraceContext.claimDeadlineEffect("compressor_sidechain_open_editor")
            else { throw SidechainUnavailable(stage: "compressor_open") }
            _ = AXHelpers.performAction(open[0], kAXPressAction, runtime: ax)
            for _ in 0..<6 {
                try await Task.sleep(for: .milliseconds(100))
                guard context() else { break }
                if let current = windows(), current.count == 2, current.contains(arrange),
                   let found = current.first(where: { !CFEqual($0, arrange) }), identified(found) {
                    editor = found
                    if focused(found) { return found }
                }
            }
            throw SidechainUnavailable(stage: "compressor_editor")
        }
        func closeEditor() async -> Bool {
            guard let current = editor, owned(current), focused(current), noMenu(),
                  let close: AXUIElement = AXHelpers.getAttribute(current, kAXCloseButtonAttribute, runtime: ax)
            else { return false }
            _ = AXHelpers.performAction(close, kAXPressAction, runtime: ax)
            for _ in 0..<6 {
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return false }
                if windows() == [arrange], focused(arrange), context() {
                    editor = nil
                    return true
                }
            }
            return false
        }
        func cancelMenu() async -> Bool {
            guard let held = menu, let current = editor, owned(current),
                  children(held.popup).contains(held.menu) else { return false }
            _ = AXHelpers.performAction(held.menu, kAXCancelAction, runtime: ax)
            for _ in 0..<6 {
                do { try await Task.sleep(for: .milliseconds(75)) } catch { return false }
                if noMenu(), owned(current), focused(current) {
                    menu = nil
                    return true
                }
            }
            return false
        }
        func observe(_ current: AXUIElement) async throws -> (String, [String: AXUIElement]) {
            let fields = children(current).filter {
                AXHelpers.getRole($0, runtime: ax) == kAXPopUpButtonRole as String
                    && AXHelpers.getHelp($0, runtime: ax)?.hasPrefix("Side Chain pop-up menu.") == true
            }
            guard owned(current), focused(current), noMenu(), fields.count == 1, let field = fields.first,
                  let shown = text(field, kAXValueAttribute),
                  OperationTraceContext.claimDeadlineEffect("compressor_sidechain_observe_menu")
            else { throw SidechainUnavailable(stage: "compressor_sidechain_popup") }
            _ = AXHelpers.performAction(field, kAXPressAction, runtime: ax)
            try await Task.sleep(for: .milliseconds(280))
            let observedMenus = children(field).filter { AXHelpers.getRole($0, runtime: ax) == kAXMenuRole as String }
            guard owned(current), observedMenus.count == 1, let root = observedMenus.first,
                  slotPopupMenuIsAnchored(root, toSlot: field, runtime: ax)
            else { throw SidechainUnavailable(stage: "compressor_sidechain_menu") }
            menu = (field, root)
            let rootItems = children(root)
            let internalItems = rootItems.filter { AXHelpers.getTitle($0, runtime: ax) == "Internal" }
            let busGroups = rootItems.filter { AXHelpers.getTitle($0, runtime: ax) == "Bus" }
            guard internalItems.count == 1, busGroups.count == 1 else {
                throw SidechainUnavailable(stage: "compressor_sidechain_sources")
            }
            let busMenus = children(busGroups[0]).filter { AXHelpers.getRole($0, runtime: ax) == kAXMenuRole as String }
            guard busMenus.count == 1 else { throw SidechainUnavailable(stage: "compressor_sidechain_bus_menu") }
            let candidates = internalItems + children(busMenus[0])
            var supported: [String: AXUIElement] = [:]
            var checked: [String] = []
            for item in candidates where AXHelpers.getRole(item, runtime: ax) == kAXMenuItemRole as String {
                guard let label = AXHelpers.getTitle(item, runtime: ax), popupSource(label) != nil,
                      (AXHelpers.getAttribute(item, kAXEnabledAttribute as String, runtime: ax) as Bool?) == true else { continue }
                guard supported.updateValue(item, forKey: label) == nil else {
                    throw SidechainUnavailable(stage: "compressor_sidechain_ambiguous_source")
                }
                if text(item, "AXMenuItemMarkChar") == "✓" { checked.append(label) }
            }
            guard checked.count == 1, let source = checked.first, popupSource(source) == shown else {
                throw SidechainUnavailable(stage: "compressor_sidechain_checked_readback")
            }
            return (source, supported)
        }

        do {
            let initial = try await openEditor()
            let (observed, available) = try await observe(initial)
            before = observed
            choices = available.keys.sorted()
            if writing {
                guard expected == observed else {
                    throw SidechainUnavailable(stage: "compressor_sidechain_expected_current", error: .staleSnapshot)
                }
                if let requested, requested != observed {
                    guard let leaf = available[requested], owned(initial), let held = menu,
                          children(held.popup).contains(held.menu),
                          OperationTraceContext.claimDeadlineEffect("compressor_sidechain_pick")
                    else { throw SidechainUnavailable(stage: "compressor_sidechain_choice") }
                    attempted = true
                    _ = AXHelpers.performAction(leaf, kAXPressAction, runtime: ax)
                    try await Task.sleep(for: .milliseconds(400))
                    guard noMenu(), owned(initial), focused(initial) else {
                        throw SidechainUnavailable(stage: "compressor_sidechain_menu_after_pick")
                    }
                    menu = nil
                    guard await closeEditor() else { throw SidechainUnavailable(stage: "compressor_sidechain_reopen") }
                    let fresh = try await openEditor()
                    let (reobserved, _) = try await observe(fresh)
                    after = reobserved
                    guard reobserved == requested else { throw SidechainUnavailable(stage: "compressor_sidechain_readback") }
                }
            }
            guard await cancelMenu(), await closeEditor() else { throw SidechainUnavailable(stage: "compressor_sidechain_cleanup") }
            return .success(HonestContract.encodeStateA(extras: [
                "operation": operation, "source": after ?? observed, "before": observed, "choices": choices,
                "changed": after != nil && after != observed, "write_attempted": attempted,
                "editor_restored": true, "verify_source": "ax_compressor_popup_and_checked_menu",
            ]))
        } catch {
            let failure = error as? SidechainUnavailable ?? .init(stage: "compressor_sidechain_interrupted")
            if menu != nil { _ = await cancelMenu() }
            if editor != nil { _ = await closeEditor() }
            if !attempted { return refuse(failure.error, failure.stage) }
            return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: [
                "operation": operation, "readback_stage": failure.stage, "write_attempted": true,
                "before": before as Any? ?? NSNull(), "source": after as Any? ?? NSNull(),
                "editor_restored": editor == nil, "safe_to_retry": false, "effect_unknown": true,
            ]))
        }
    }
}
