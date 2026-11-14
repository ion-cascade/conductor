import ApplicationServices
import Foundation

extension AccessibilityChannel {
    private typealias ObservedRegion = (item: AXUIElement, info: RegionInfo)

    /// Bind the selection and all observed regions to one saved Arrange window.
    /// Selection, coordinates and project identity are renewed at the write boundary.
    static func moveChosenRegionToExactPlayhead(
        runtime: AXLogicProElements.Runtime,
        move: () async -> ChannelResult,
        settle: () async -> Void
    ) async -> ChannelResult {
        let operation = "region.move_to_playhead"
        func refusal(_ hint: String) -> ChannelResult {
            .error(HonestContract.encodeStateC(error: .readbackUnavailable, hint: hint,
                extras: ["operation": operation, "write_attempted": false, "fallback_unsafe": true]))
        }
        guard case .found(let window) = AXLogicProElements.arrangeWindowRead(runtime: runtime),
              case .success(let document?) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime),
              URL(string: document)?.isFileURL == true,
              ControlBarDisplayMode.foregroundStoppedProject(window: window, runtime: runtime),
              case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(in: window, runtime: runtime),
              AXLogicProElements.hiddenTrackViewRead(headers: headers, in: window, runtime: runtime)?.shown == true
        else { return refusal("The saved foreground Arrange window, stopped transport and shown hidden-track view are required.") }

        func sameProject() -> Bool {
            guard case .found(let current) = AXLogicProElements.arrangeWindowRead(runtime: runtime),
                  CFEqual(window, current),
                  AXLogicProElements.projectPickerDocumentRead(current, runtime: runtime) == .success(document)
            else { return false }
            return ControlBarDisplayMode.foregroundStoppedProject(window: window, runtime: runtime)
        }

        func capture() -> (selected: ObservedRegion, regions: [ObservedRegion])? {
            guard sameProject(),
                  case .read(let currentHeaders) = AXLogicProElements.allTrackHeadersVerifiedRead(in: window, runtime: runtime),
                  headers.count == currentHeaders.count, zip(headers, currentHeaders).allSatisfy({ CFEqual($0, $1) }),
                  AXLogicProElements.hiddenTrackViewRead(headers: currentHeaders, in: window, runtime: runtime)?.shown == true,
                  case .success(let inventory) = enumerateRegionItems(runtime: runtime),
                  inventory.coversWholeArrangement,
                  inventory.regions.allSatisfy({ $0.info.isSelected != nil && $0.info.startPosition != nil
                      && $0.info.endPosition != nil }),
                  sameProject()
            else { return nil }
            let selected = inventory.regions.filter { $0.info.isSelected == true }
            guard selected.count == 1, let region = selected.first, region.info.trackIndex >= 0
            else { return nil }
            return (region, inventory.regions)
        }

        func observedPlayhead() -> String? {
            guard sameProject(), let bar = AXLogicProElements.directLogic13Toolbar(in: window, runtime: runtime.ax)
            else { return nil }
            let transport = AXValueExtractors.extractTransportState(from: bar, runtime: runtime.ax)
            return TransportDispatcher.completeObservedMusicalPosition(transport)?.value
        }

        guard let before = capture() else {
            return refusal("The exact boundaries and exclusive selection of one Arrange region could not be verified.")
        }
        var playhead = observedPlayhead()
        var lease: ControlBarDisplayMode.Lease?
        var fields: [String: Any] = ["operation": operation, "write_attempted": false, "move_write_attempted": false]
        func finish(_ error: HonestContract.UncertainReason? = nil) -> ChannelResult {
            var result = fields
            var uncertainty = error
            if let lease {
                let restoration = OperationTraceContext.claimDeadlineEffect("region_move_display_restore")
                    ? ControlBarDisplayMode.restore(lease, runtime: runtime)
                    : .refused("region_move_display_restore_not_permitted")
                result["display_mode_restored"] = restoration == .restored
                if case .refused(let reason) = restoration {
                    result["display_mode_restore_refused"] = reason
                    result["position_verified"] = uncertainty == nil
                    uncertainty = .readbackUnavailable
                }
            }
            if let uncertainty {
                result["safe_to_retry"] = result["write_attempted"] as? Bool == false
                return .success(HonestContract.encodeStateB(reason: uncertainty, extras: result))
            }
            return .success(HonestContract.encodeStateA(extras: result))
        }

        if playhead == nil {
            guard OperationTraceContext.claimDeadlineEffect("region_move_display_switch")
            else { return refusal("The request deadline prevented preparing the exact playhead display.") }
            switch ControlBarDisplayMode.selectBeatsForSeek(runtime: runtime) {
            case .unavailable(let reason):
                return refusal(reason)
            case .unsettled(let possibleLease, let reason):
                lease = possibleLease
                fields["write_attempted"] = true
                fields["detail"] = reason
                return finish(.readbackUnavailable)
            case .switched(let acquired):
                lease = acquired
                fields["display_mode_switched_from"] = acquired.original
                fields["write_attempted"] = true
            }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(ControlBarDisplayMode.positionComponentsTimeout))
            repeat {
                playhead = observedPlayhead()
                if playhead != nil { break }
                try? await clock.sleep(for: .seconds(ControlBarDisplayMode.positionComponentsPollInterval))
            } while clock.now < deadline && !Task.isCancelled
        }

        guard let playhead, let prior = capture(),
              sameRegion(prior.selected, before.selected), matchesBounds(prior.selected.info, before.selected.info),
              sameOtherRegions(before.regions, prior.regions, excluding: before.selected.item),
              observedPlayhead() == playhead
        else {
            fields["detail"] = "The exact playhead or the held Arrange selection changed before the move."
            if lease == nil { return refusal("The exact playhead or the held Arrange selection changed before the move.") }
            return finish(.readbackUnavailable)
        }

        fields["requested"] = playhead
        fields["previous_start_position"] = before.selected.info.startPosition
        fields["previous_end_position"] = before.selected.info.endPosition
        if before.selected.info.startPosition == playhead {
            fields["unchanged"] = true
            fields["observed"] = playhead
            fields["end_position"] = before.selected.info.endPosition
            return finish()
        }
        guard OperationTraceContext.claimDeadlineEffect("region_exact_move") else {
            fields["detail"] = "The request deadline prevented the region move."
            if lease == nil { return refusal("The request deadline prevented the region move.") }
            return finish(.readbackUnavailable)
        }
        fields["write_attempted"] = true
        fields["move_write_attempted"] = true
        let attempted = await move()
        guard attempted.isSuccess, !attempted.message.hasPrefix("MENU_ERROR") else {
            fields["detail"] = attempted.message
            return finish(.readbackUnavailable)
        }
        await settle()
        guard let after = capture(), sameRegion(after.selected, before.selected),
              sameOtherRegions(before.regions, after.regions, excluding: before.selected.item),
              observedPlayhead() == playhead
        else { return finish(.readbackUnavailable) }
        fields["observed"] = after.selected.info.startPosition
        fields["end_position"] = after.selected.info.endPosition
        fields["track_index"] = after.selected.info.trackIndex
        fields["region_name"] = after.selected.info.name
        fields["verify_source"] = "bound_arrange_region_and_playhead"
        return finish(after.selected.info.startPosition == playhead ? nil : .readbackMismatch)
    }

    private static func sameRegion(_ lhs: ObservedRegion, _ rhs: ObservedRegion) -> Bool {
        CFEqual(lhs.item, rhs.item) && lhs.info.trackIndex == rhs.info.trackIndex
            && lhs.info.name == rhs.info.name && lhs.info.kind == rhs.info.kind
    }

    private static func matchesBounds(_ lhs: RegionInfo, _ rhs: RegionInfo) -> Bool {
        lhs.startPosition == rhs.startPosition && lhs.endPosition == rhs.endPosition
    }

    private static func sameOtherRegions(
        _ before: [ObservedRegion], _ after: [ObservedRegion], excluding item: AXUIElement
    ) -> Bool {
        guard before.count == after.count else { return false }
        return before.filter { !CFEqual($0.item, item) }.allSatisfy { held in
            after.filter { sameRegion(held, $0) && matchesBounds(held.info, $0.info) }.count == 1
        }
    }
}
