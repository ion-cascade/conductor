import AppKit
import Foundation
import MCP

/// One fail-closed observation of a relocation candidate. Tests use the explicit token; production
/// observations retain the exact AX track binding so an owned, append-only import can renew the
/// same physical target without reducing identity to an ordinal or display name.
struct RecordSequenceRelocationTrackObservation: @unchecked Sendable {
    let index: Int
    let name: String
    let type: TrackType
    let physicalBinding: AXTrackBinding.Binding?
    let testIdentity: String?
    let selectionReadback: Bool?

    init(index: Int, name: String, type: TrackType, testIdentity: String, selectionReadback: Bool? = nil) {
        self.index = index
        self.name = name
        self.type = type
        physicalBinding = nil
        self.testIdentity = testIdentity
        self.selectionReadback = selectionReadback
    }

    init(track: TrackState) {
        index = track.id
        name = track.name
        type = track.type
        physicalBinding = track.physicalBinding
        testIdentity = nil
        selectionReadback = track.selectionReadback
    }

    /// Proof of a selected, qualified instrument on the original physical track.
    /// The Inspector is only authoritative while this track owns selection.
    func hasSelectedLogic13QualifiedInstrument() -> Bool {
        guard let binding = physicalBinding, selectionReadback == true,
              binding.currentIndex() == index,
              case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(
                in: binding.window, runtime: binding.runtime),
              headers.indices.contains(index), CFEqual(binding.header, headers[index]),
              headers.enumerated().allSatisfy({
                  AXValueExtractors.extractSelectedState($0.element, runtime: binding.runtime.ax)
                      == ($0.offset == index)
              }),
              (AccessibilityChannel.logic13StudioGrandInspector(
                  named: name, in: binding.window, runtime: binding.runtime.ax)
               || RetroSynthSlot.acquire(physical: binding, index: index, name: name) != nil)
        else { return false }
        return binding.currentIndex() == index
    }

    func hasIdentity() -> Bool {
        (physicalBinding != nil) != (testIdentity != nil)
    }

    func hasCurrentIdentityAtIssuedIndex() -> Bool {
        if testIdentity != nil { return physicalBinding == nil }
        guard testIdentity == nil, let physicalBinding else { return false }
        return physicalBinding.currentIndex() == index
    }

    func hasSamePhysicalIdentity(as other: Self) -> Bool {
        if let testIdentity, let otherIdentity = other.testIdentity {
            return testIdentity == otherIdentity
        }
        guard testIdentity == nil, other.testIdentity == nil,
              let physicalBinding, let otherBinding = other.physicalBinding else { return false }
        return physicalBinding.matches(otherBinding)
    }

    /// The import is expected to append one track, which intentionally retires the baseline
    /// population shape. This narrower comparison is only for that owned append transition; later
    /// copy/paste boundaries must use `hasSamePhysicalIdentity` and current-index renewal.
    func hasSameIssuedCarrier(as other: Self) -> Bool {
        if let testIdentity, let otherIdentity = other.testIdentity {
            return testIdentity == otherIdentity
        }
        guard testIdentity == nil, other.testIdentity == nil,
              let physicalBinding, let otherBinding = other.physicalBinding else { return false }
        let sameExposure: Bool
        switch (physicalBinding.exposure, otherBinding.exposure) {
        case (nil, nil): sameExposure = true
        case (let first?, let second?): sameExposure = first === second
        default: sameExposure = false
        }
        return CFEqual(physicalBinding.window, otherBinding.window)
            && CFEqual(physicalBinding.header, otherBinding.header)
            && physicalBinding.document.utf8.elementsEqual(otherBinding.document.utf8)
            && sameExposure
    }
}

/// record_sequence SMF-import implementation, extracted from
/// TrackDispatcher.swift (pure move). handleRecordSequenceSMF generates a
/// Standard MIDI File from the notes spec, imports it via AX menu, and
/// verifies the imported region by AX readback. Helpers stay private to
/// this file; the nested RecordSequenceRegionReadback enum remains in the
/// core TrackDispatcher type.
