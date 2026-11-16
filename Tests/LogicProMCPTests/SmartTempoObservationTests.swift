import ApplicationServices
import Testing
@testable import LogicProMCP

struct SmartTempoObservationTests {
    @Test(arguments: ["8820 samples", "8821 samples", ""])
    func readsTempoFromTheControlTreeBesideTheContentGroup(_ sampleDescription: String) {
        let ax = FakeAXRuntimeBuilder()
        let window = ax.element(0)
        let pane = ax.element(1)
        let contents = ax.element(2)
        let controls = ax.element(3)
        let inspector = ax.element(4)
        let tempo = ax.element(5)
        let scroll = ax.element(6)
        let display = ax.element(7)
        let grid = ax.element(8)
        let barOne = ax.element(9)
        let marker = ax.element(10)

        let groups = [
            (pane, "Smart Tempo"), (contents, "Smart Tempo contents"), (controls, ""),
            (display, "Smart Tempo editor"), (grid, "Editor"), (barOne, "Downbeat, Bar 1"),
        ]
        for (group, description) in groups {
            ax.setAttribute(group, kAXRoleAttribute, kAXGroupRole)
            ax.setAttribute(group, kAXDescriptionAttribute, description)
        }
        ax.setAttribute(tempo, kAXRoleAttribute, kAXTextFieldRole)
        ax.setAttribute(tempo, kAXHelpAttribute, "Shows the tempo of the audio file.")
        ax.setAttribute(tempo, kAXValueAttribute, "120.0")
        ax.setAttribute(marker, kAXRoleAttribute, kAXValueIndicatorRole)
        ax.setAttribute(marker, kAXDescriptionAttribute, "Move Marker")
        ax.setAttribute(marker, kAXValueAttribute, 8820)
        ax.setAttribute(marker, kAXValueDescriptionAttribute, sampleDescription)
        ax.setChildren(window, [pane])
        ax.setChildren(pane, [contents, controls])
        ax.setChildren(controls, [inspector, scroll])
        ax.setChildren(inspector, [tempo])
        ax.setChildren(scroll, [display])
        ax.setChildren(display, [grid])
        ax.setChildren(grid, [barOne])
        ax.setChildren(barOne, [marker])

        let observed = AccessibilityChannel.smartTempoObservation(window, runtime: ax.makeAXRuntime())
        let expected: AccessibilityChannel.SmartTempoObservation? = sampleDescription == "8820 samples"
            ? .init(tempo: 120, firstDownbeat: 8820) : nil
        #expect(observed == expected)
    }
}
