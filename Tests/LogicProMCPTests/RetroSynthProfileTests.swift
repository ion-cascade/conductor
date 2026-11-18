import Foundation
import Testing
@testable import LogicProMCP

struct RetroSynthProfileTests {
    @Test func differentEnvelopeStagesUseTheirMeasuredTimeCurves() throws {
        let attack = try #require(RetroSynthProfile.parameter("amp_attack"))
        let decay = try #require(RetroSynthProfile.parameter("amp_decay"))
        let release = try #require(RetroSynthProfile.parameter("amp_release"))
        #expect(attack.resolve(value: .number(500), unit: "ms")?.position == 60)
        #expect(decay.resolve(value: .number(520), unit: "ms")?.position == 60)
        #expect(release.resolve(value: .number(510), unit: "ms")?.position == 60)
        #expect(attack.resolve(value: .number(10_000), unit: "ms")?.position == 127)
        #expect(release.resolve(value: .number(0), unit: "ms") == nil)
    }

    @Test func normalizedCutoffNeverClaimsFrequencyUnits() throws {
        let cutoff = try #require(RetroSynthProfile.parameter("filter_cutoff"))
        #expect(cutoff.resolve(value: .number(0.4), unit: "normalized")?.position == 200)
        #expect(cutoff.resolve(value: .number(2000), unit: "Hz") == nil)
        #expect(cutoff.resolve(value: .number(0.401), unit: "normalized") == nil)
        #expect(cutoff.resolve(value: .boolean(false), unit: "normalized") == nil)
    }

    @Test func oscillatorWaveformChoicesDoNotBleedBetweenOscillators() throws {
        let first = try #require(RetroSynthProfile.parameter("osc1_waveform"))
        let second = try #require(RetroSynthProfile.parameter("osc2_waveform"))
        #expect(first.resolve(value: .text("Noise"), unit: "waveform") != nil)
        #expect(second.resolve(value: .text("Noise"), unit: "waveform") == nil)
        #expect(second.resolve(value: .text("Triangle"), unit: "waveform") != nil)
        #expect(first.resolve(value: .text("Triangle"), unit: "waveform") == nil)
    }

    @Test func lfoRatesKeepPhysicalAndMusicalUnitsSeparate() throws {
        let rate = try #require(RetroSynthProfile.parameter("lfo_rate"))
        let free = try #require(rate.resolve(value: .number(6.4), unit: "Hz"))
        let synced = try #require(rate.resolve(value: .text("1/8t"), unit: "division"))
        #expect(free.position == 60 && free.sync == false)
        #expect(synced.sync == true && synced.display == "1/8t")
        #expect(rate.resolve(value: .text("6.4"), unit: "Hz") == nil)
        #expect(rate.resolve(value: .number(6), unit: "division") == nil)
    }

    @Test func duplicateDisplayedSustainValuesResolveToOneAdvertisedPosition() throws {
        let sustain = try #require(RetroSynthProfile.parameter("amp_sustain"))
        #expect(sustain.resolve(value: .number(0), unit: "normalized")?.position == 0)
        #expect(sustain.resolve(value: .number(1), unit: "normalized")?.position == 127)
    }

    @Test func booleansAreNotNumbersOrText() throws {
        let sync = try #require(RetroSynthProfile.parameter("lfo_sync"))
        #expect(sync.resolve(value: .boolean(true), unit: "bool")?.boolean == true)
        #expect(sync.resolve(value: .number(1), unit: "bool") == nil)
        #expect(sync.resolve(value: .text("true"), unit: "bool") == nil)
    }

    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity])
    func nonFiniteNumbersNeverResolve(_ number: Double) throws {
        let mix = try #require(RetroSynthProfile.parameter("oscillator_mix"))
        #expect(mix.resolve(value: .number(number), unit: "normalized") == nil)
    }

    @Test func everyQualifiedFactoryParameterAgreesWithItsIndependentNativeDisplay() throws {
        let snapshot = factory()
        try snapshot.validateLayout()
        for parameter in RetroSynthProfile.parameters {
            _ = try snapshot.observation(parameter)
        }
        #expect(snapshot.isFactoryInitialized)
        #expect(RetroSynthProfile.parameters.count == 21)
    }

    @Test func mismatchedRawAndDisplayedSliderValuesRefuse() throws {
        let mix = try #require(RetroSynthProfile.parameter("oscillator_mix"))
        var rows = factory().rows
        let index = try #require(rows.firstIndex { $0.label == mix.label })
        var controls = rows[index].controls
        controls[0] = .init(role: "AXSlider", value: .number(25), display: "")
        rows[index] = .init(label: mix.label, controls: controls)
        let snapshot = RetroSynthSnapshot(preset: "Manual", rows: rows)
        #expect(throws: (any Error).self) { try snapshot.observation(mix) }
    }

    @Test func alteredPeerCannotBeHiddenByARequestedParameterChange() throws {
        let before = factory()
        var rows = before.rows
        let peer = try #require(rows.firstIndex { $0.label == "Oscillator 2 Waveform:" })
        rows[peer] = .init(label: "Oscillator 2 Waveform:", controls: [
            .init(role: "AXPopUpButton", value: .text("Square"), display: ""),
        ])
        let after = RetroSynthSnapshot(preset: "Manual", rows: rows)
        #expect(!after.preservesPeers(of: before, changing: ["Cutoff:"]))
        #expect(after.preservesPeers(of: before, changing: ["Oscillator 2 Waveform:"]))
        #expect(try before.fingerprint != after.fingerprint)
        #expect(!after.isFactoryInitialized)
    }

    @Test func missingOrDuplicatedRowsNeverBecomePartialSuccess() throws {
        var rows = factory().rows
        rows.removeLast()
        #expect(throws: (any Error).self) { try RetroSynthSnapshot(preset: "Manual", rows: rows).validateLayout() }
        rows = factory().rows
        rows[35] = rows[33]
        #expect(throws: (any Error).self) { try RetroSynthSnapshot(preset: "Manual", rows: rows).validateLayout() }
    }

    @Test(arguments: [1, 2])
    func squareEnablesPulseWidthPresentationWithoutAuthorizingAValueChange(_ oscillator: Int) throws {
        let before = factory()
        let waveform = "Oscillator \(oscillator) Waveform:"
        let width = "Oscillator \(oscillator)  Pulse Width:"
        var rows = before.rows
        let waveIndex = try #require(rows.firstIndex { $0.label == waveform })
        let widthIndex = try #require(rows.firstIndex { $0.label == width })
        rows[waveIndex] = .init(label: waveform, controls: [.init(role: "AXPopUpButton", value: .text("Square"), display: "")])
        let native = try #require(rows[widthIndex].controls.first)
        rows[widthIndex] = .init(label: width, controls: [
            .init(role: "AXSlider", value: native.value, display: ""), native,
            .init(role: "AXValueIndicator", value: native.value, display: ""),
        ])
        let after = RetroSynthSnapshot(preset: "Manual", rows: rows)
        try after.validateLayout()
        #expect(after.preservesPeers(of: before, changing: [waveform]))
        rows[widthIndex] = .init(label: width, controls: [
            .init(role: "AXSlider", value: native.value, display: ""),
            .init(role: "AXSlider", value: native.value, display: "51.0 %"),
            .init(role: "AXValueIndicator", value: native.value, display: ""),
        ])
        #expect(!RetroSynthSnapshot(preset: "Manual", rows: rows).preservesPeers(of: before, changing: [waveform]))
    }

    private func factory() -> RetroSynthSnapshot {
        .init(preset: "Manual", rows: RetroSynthFactoryBaseline.labels.map { label in
            .init(label: label, controls: label.flatMap { RetroSynthFactoryBaseline.values[$0] } ?? [])
        })
    }
}
