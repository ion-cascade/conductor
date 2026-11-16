@preconcurrency import ApplicationServices
import Foundation

extension AccessibilityChannel {
    func editMIDIRegionExpression(
        parameters: [String: String], eventList: Logic13MIDINoteEventList,
        rows: [Logic13MIDINoteEventList.Row], evidence initialEvidence: [String: Any],
        scopeIsCurrent: () -> Bool
    ) async -> ChannelResult {
        var evidence = initialEvidence
        func refuse(_ error: HonestContract.FailureError, _ hint: String) -> ChannelResult {
            .error(HonestContract.encodeStateC(error: error, hint: hint, extras: evidence))
        }
        guard let position = parameters["position"].flatMap({ Logic13MIDINoteCoordinate($0, length: false) }),
              let channel = parameters["channel"].flatMap(Int.init), (1...16).contains(channel),
              let expected = parameters["expected_current"].flatMap(Int.init), (0...127).contains(expected),
              let target = parameters["value"].flatMap(Int.init), (0...127).contains(target),
              (target - expected).isMultiple(of: 10), target != expected else {
            return refuse(.invalidParams, "Supply an exact position, channel, expected CC11 value and a different value reachable in ten-unit steps.")
        }
        func identity(_ row: Logic13MIDINoteEventList.Row) -> Bool {
            row.expression?.position == position && row.expression?.channel == channel
        }
        let candidates = rows.filter(identity)
        guard candidates.count == 1, let original = candidates.first,
              original.expression?.value == expected else {
            return refuse(.staleSnapshot, "The position and channel must identify one current CC11 event with the expected value.")
        }

        func verifiedRow(_ current: [Logic13MIDINoteEventList.Row], value: Int) -> Logic13MIDINoteEventList.Row? {
            let matches = current.filter(identity)
            guard matches.count == 1, let row = matches.first, row.expression?.value == value,
                  !row.locked, CFEqual(row.element, original.element),
                  current.count == rows.count, eventList.selectionPermits(row.element) else { return nil }
            let stable = zip(rows, current).allSatisfy { before, after in
                guard CFEqual(before.element, after.element) else { return false }
                return before.signature.indices.allSatisfy { index in
                    (CFEqual(before.element, original.element) && index == 6)
                        || before.signature[index] == after.signature[index]
                }
            }
            return stable ? row : nil
        }

        var observed = expected
        var steps = 0
        func uncertain(_ stage: String) -> ChannelResult {
            guard evidence["write_attempted"] as? Bool == true else {
                return refuse(.readbackUnavailable, "The selected region or bound CC11 event changed before the edit.")
            }
            var details = evidence
            details["stage"] = stage
            details["last_verified_value"] = observed
            details["verified_steps"] = steps
            details["safe_to_retry"] = false
            details["effect_unknown"] = true
            return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: details))
        }
        while observed != target {
            guard !Task.isCancelled, scopeIsCurrent(),
                  let fresh = eventList.rows(), let row = verifiedRow(fresh, value: observed) else {
                return uncertain("before_cc11_step")
            }
            let next = observed + (target < observed ? -10 : 10)
            let dispatched = eventList.stepExpression(row, toward: next) {
                guard scopeIsCurrent(), OperationTraceContext.claimDeadlineEffect("midi_region_expression_step") else { return false }
                regionScan = nil
                evidence["write_attempted"] = true
                return true
            }
            guard dispatched else { return uncertain("cc11_action") }
            do { try await Task.sleep(for: .milliseconds(140)) }
            catch { return uncertain("cc11_cancelled") }
            guard scopeIsCurrent(), let after = eventList.rows(), verifiedRow(after, value: next) != nil else {
                return uncertain("cc11_readback")
            }
            observed = next
            steps += 1
        }
        evidence["before"] = Logic13MIDINoteEventList.Expression(position: position, channel: channel, value: expected).evidence
        evidence["observed"] = Logic13MIDINoteEventList.Expression(position: position, channel: channel, value: observed).evidence
        evidence["verified_steps"] = steps
        evidence["peer_events_verified"] = rows.count - 1
        return .success(HonestContract.encodeStateA(extras: evidence))
    }
}
