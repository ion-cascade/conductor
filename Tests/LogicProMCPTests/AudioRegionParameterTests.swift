import Testing
@testable import LogicProMCP

struct AudioRegionParameterTests {
    @Test func gainReadsOnlyTheExactRegionInspectorFormat() {
        let gain = AudioRegionParameter.gain
        #expect(gain.observed(description: "Gain, -6.3 dB", value: "") == -6.3)
        #expect(gain.observed(description: "Gain, +12.0 dB", value: "") == 12)
        #expect(gain.observed(description: "Gain", value: "-6.3") == nil)
        #expect(gain.observed(description: "input gain", value: "-6.3") == nil)
        #expect(gain.observed(description: "Gain, nan dB", value: "") == nil)
    }

    @Test func gainEntryUsesBoundedFiniteTenths() {
        let gain = AudioRegionParameter.gain
        #expect(gain.accepts(-24))
        #expect(gain.accepts(12))
        #expect(gain.accepts(-6.3))
        #expect(gain.entryText(-6.3) == "-6.3")
        #expect(!gain.accepts(-24.1))
        #expect(!gain.accepts(12.1))
        #expect(!gain.accepts(-6.31))
        #expect(!gain.accepts(.infinity))
    }

    @Test func fadeReadsOnlyCommittedTimeForTheRequestedEdge() {
        let fade = AudioRegionParameter.fadeOut
        #expect(fade.observed(description: "Fade-Out Time", value: "500 milliseconds") == 500)
        #expect(fade.observed(description: "Fade-Out Time", value: "1 millisecond") == 1)
        #expect(fade.observed(description: "Fade-Out Time", value: "500") == nil)
        #expect(fade.observed(description: "Fade-In Time", value: "500 milliseconds") == nil)
        #expect(fade.observed(description: "Fade-Out Time", value: "0 milliseconds") == 0)
        #expect(fade.accepts(0))
        #expect(fade.accepts(1000))
        #expect(!fade.accepts(1001))
        #expect(!fade.accepts(1.5))
        #expect(fade.entryText(650) == "650")
    }
}
