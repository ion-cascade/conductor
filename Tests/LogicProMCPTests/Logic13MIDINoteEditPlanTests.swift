import Testing
@testable import LogicProMCP

@Suite("Logic 13 MIDI note edit plan")
struct Logic13MIDINoteEditPlanTests {
    private func note(pitch: Int = 60, velocity: Int = 94,
                      start: String = "1.1.1.1", length: String = "0.0.3.0") throws -> Logic13MIDINoteValue {
        try Logic13MIDINoteValue(
            channel: 1, pitch: pitch, velocity: velocity,
            position: #require(Logic13MIDINoteCoordinate(start, length: false)),
            length: #require(Logic13MIDINoteCoordinate(length, length: true))
        )
    }

    @Test func plansEveryObservedGestureWithoutRoundingTimingOrVelocity() throws {
        let before = try note()
        let after = try note(pitch: 65, velocity: 88, start: "1.1.1.7", length: "0.0.3.6")
        let plan = try #require(Logic13MIDINoteEditPlan(before: before, after: after, peers: []))
        #expect(plan.steps.count == 23)
        #expect(plan.steps.first?.current == before)
        #expect(plan.steps.last?.expected == after)
        for (previous, following) in zip(plan.steps, plan.steps.dropFirst()) {
            #expect(previous.expected == following.current)
        }
    }

    @Test func refusesAmbiguousCurrentAndIntermediateNotes() throws {
        let before = try note()
        let after = try note(pitch: 65)
        let exactDuplicate = try note(velocity: 42, length: "0.0.1.0")
        let intermediate = try note(pitch: 63)
        #expect(Logic13MIDINoteEditPlan(before: before, after: after, peers: [exactDuplicate]) == nil)
        #expect(Logic13MIDINoteEditPlan(before: before, after: after, peers: [intermediate]) == nil)
    }

    @Test func capsWorkBeforeAnyActuation() throws {
        let before = try note()
        let after = try note(start: "1.1.1.50")
        #expect(Logic13MIDINoteEditPlan(before: before, after: after, peers: []) == nil)
        #expect(Logic13MIDINoteCoordinate("0.0.0.0", length: true) == nil)
        #expect(Logic13MIDINoteCoordinate("0.1.1.1", length: false) == nil)
    }
}
