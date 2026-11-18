import ApplicationServices
import Foundation

extension RetroSynthNative {
    /// All callbacks that record a write run after the synchronous native effect.
    /// The first-effect precondition is renewed immediately before that effect.
    func set(parameter: RetroSynthProfile.Parameter, choice: RetroSynthProfile.Choice,
             firstEffectPermitted: () throws -> Void,
             didWrite: () async -> Void) async throws {
        var effects = 0
        func authorize(_ stage: String) throws {
            guard holdsTarget() else { throw Failure.unavailable("write_context_lost") }
            if effects == 0 { try firstEffectPermitted() }
            guard holdsTarget(), OperationTraceContext.claimDeadlineEffect(stage, rejectTaskCancellationWithoutContext: true) else {
                throw Failure.unavailable("write_authority_lost")
            }
            effects += 1
        }
        // Sync changes replace the checkbox and convert the active rate. Both
        // values are intentional coupled state; no prior control is reused.
        if parameter.id == "lfo_rate", let desired = choice.sync {
            let before = try snapshot()
            if try before.boolean("LFO Sync:") != desired {
                try await setSync(desired, authorize: authorize, didWrite: didWrite)
            }
        }
        switch parameter.kind {
        case .sync:
            guard let desired = choice.boolean else { throw Failure.unavailable("sync_choice") }
            try await setSync(desired, authorize: authorize, didWrite: didWrite)
        case .choices:
            guard let text = choice.text else { throw Failure.unavailable("popup_choice") }
            if try snapshot().text(parameter.label) == text { return }
            try await selectPopup(parameter.label, value: text, authorize: authorize, didWrite: didWrite)
        default:
            guard let destination = choice.position else { throw Failure.unavailable("scalar_destination") }
            let result = await RetroSynthWalk.apply(destination: destination,
                read: { try self.scalar(parameter.label).position },
                permitted: { self.holdsTarget() },
                actuate: { next, coarse in
                    let current = try self.scalar(parameter.label)
                    let action = next > current.position ? kAXIncrementAction : kAXDecrementAction
                    if coarse {
                        guard AXHelpers.getActionNames(current.control, runtime: self.runtime.ax).contains(action) else {
                            throw Failure.unavailable("coarse_step_unavailable")
                        }
                    } else {
                        guard AXHelpers.isAttributeSettable(current.control, kAXValueAttribute, runtime: self.runtime.ax) == true else {
                            throw Failure.unavailable("fine_step_unavailable")
                        }
                    }
                    try authorize("retro_scalar_step")
                    if coarse { _ = AXHelpers.performAction(current.control, action, runtime: self.runtime.ax) }
                    else { _ = AXHelpers.setAttribute(current.control, kAXValueAttribute, NSNumber(value: next), runtime: self.runtime.ax) }
                }, afterFirstEffect: didWrite, pause: { try await self.pause() })
            guard case .verified = result else { throw Failure.unavailable("scalar_walk_unverified") }
        }
    }

    private func setSync(_ desired: Bool, authorize: (String) throws -> Void,
                         didWrite: () async -> Void) async throws {
        if try snapshot().boolean("LFO Sync:") == desired { return }
        let row = try row("LFO Sync:")
        try await reveal(row)
        let controls = try controls(row)
        guard controls.count == 1, AXHelpers.getRole(controls[0], runtime: runtime.ax) == kAXCheckBoxRole else {
            throw Failure.unavailable("sync_control")
        }
        try authorize("retro_sync_toggle")
        _ = AXHelpers.performAction(controls[0], kAXPressAction, runtime: runtime.ax)
        await didWrite()
        for _ in 0..<20 {
            try await pause()
            guard holdsTarget() else { throw Failure.unavailable("sync_context_changed") }
            if let fresh = try? snapshot(), try fresh.boolean("LFO Sync:") == desired { return }
        }
        throw Failure.unavailable("sync_readback_timeout")
    }

    private func selectPopup(_ label: String, value: String,
                             authorize: (String) throws -> Void,
                             didWrite: () async -> Void) async throws {
        let row = try row(label)
        try await reveal(row)
        let controls = try controls(row)
        guard controls.count == 1, AXHelpers.getRole(controls[0], runtime: runtime.ax) == kAXPopUpButtonRole,
              try children(controls[0]).allSatisfy({ AXHelpers.getRole($0, runtime: runtime.ax) != kAXMenuRole }),
              holdsTarget(), OperationTraceContext.claimDeadlineEffect("retro_parameter_menu", rejectTaskCancellationWithoutContext: true) else {
            throw Failure.unavailable("popup_control")
        }
        _ = AXHelpers.performAction(controls[0], kAXPressAction, runtime: runtime.ax)
        var owned: AXUIElement?
        do {
            let menu = try await waitForMenu(under: controls[0], permitted: holdsTarget)
            owned = menu
            let matches = try children(menu).filter {
                AXHelpers.getRole($0, runtime: runtime.ax) == kAXMenuItemRole
                    && AXHelpers.getTitle($0, runtime: runtime.ax) == value
            }
            guard matches.count == 1,
                  (AXHelpers.getAttribute(matches[0], kAXEnabledAttribute, runtime: runtime.ax) as Bool?) == true else {
                throw Failure.unavailable("popup_value_not_addressable")
            }
            try authorize("retro_popup_selection")
            _ = AXHelpers.performAction(matches[0], kAXPressAction, runtime: runtime.ax)
            await didWrite()
            for _ in 0..<20 {
                try await pause()
                guard holdsTarget() else { throw Failure.unavailable("popup_context_changed") }
                if (try? parameterText(label)) == value { return }
            }
            throw Failure.unavailable("popup_readback_timeout")
        } catch {
            if let owned, cleanupPermitted() { _ = AXHelpers.performAction(owned, kAXCancelAction, runtime: runtime.ax) }
            throw error
        }
    }

    func initialize(didWrite: () async -> Void) async throws {
        let settings = try children(editor).filter { AXHelpers.getRole($0, runtime: runtime.ax) == kAXPopUpButtonRole }
        guard settings.count == 1, holdsTarget(),
              OperationTraceContext.claimDeadlineEffect("retro_initialize_menu", rejectTaskCancellationWithoutContext: true) else {
            throw Failure.unavailable("initialize_context")
        }
        _ = AXHelpers.performAction(settings[0], kAXPressAction, runtime: runtime.ax)
        var owned: AXUIElement?
        do {
            let menu = try await waitForMenu(under: editor, permitted: holdsTarget)
            owned = menu
            let commands = try children(menu).filter {
                AXHelpers.getRole($0, runtime: runtime.ax) == kAXMenuItemRole
                    && AXHelpers.getTitle($0, runtime: runtime.ax) == "Initialize Setting"
            }
            guard commands.count == 1,
                  (AXHelpers.getAttribute(commands[0], kAXEnabledAttribute, runtime: runtime.ax) as Bool?) == true,
                  holdsTarget(), OperationTraceContext.claimDeadlineEffect("retro_initialize_setting", rejectTaskCancellationWithoutContext: true) else {
                throw Failure.unavailable("initialize_command")
            }
            _ = AXHelpers.performAction(commands[0], kAXPressAction, runtime: runtime.ax)
            await didWrite()
            for _ in 0..<25 {
                try await pause()
                guard holdsTarget() else { throw Failure.unavailable("initialize_context_changed") }
                if let current = try? snapshot(), current.isFactoryInitialized { return }
            }
            throw Failure.unavailable("initialize_readback")
        } catch {
            if let owned, cleanupPermitted() { _ = AXHelpers.performAction(owned, kAXCancelAction, runtime: runtime.ax) }
            throw error
        }
    }
}
