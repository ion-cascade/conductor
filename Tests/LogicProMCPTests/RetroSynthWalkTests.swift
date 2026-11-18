import Testing
@testable import LogicProMCP

@MainActor
struct RetroSynthWalkTests {
    @Test func mixedCoarseAndFineWalkRequiresEveryObservedStep() async {
        var current = 50
        var requests: [(Int, Bool)] = []
        var boundaries = 0
        let result = await RetroSynthWalk.apply(destination: 25, read: { current }, permitted: { true },
            actuate: { next, coarse in requests.append((next, coarse)); current = next },
            afterFirstEffect: { boundaries += 1 }, pause: {})
        #expect(result == .verified(steps: 7))
        #expect(requests.map(\.0) == [40, 30, 29, 28, 27, 26, 25])
        #expect(requests.map(\.1) == [true, true, false, false, false, false, false])
        #expect(boundaries == 1)
    }

    @Test func acceptedActionWithoutReadbackNeverSucceedsOrReplays() async {
        let current = 50
        var effects = 0
        let result = await RetroSynthWalk.apply(destination: 25, read: { current }, permitted: { true },
            actuate: { _, _ in effects += 1 }, afterFirstEffect: {}, pause: {})
        #expect(result == .uncertain)
        #expect(effects == 1)
    }

    @Test func unexpectedIntermediateValueStopsTheWalk() async {
        var current = 50
        var effects = 0
        let result = await RetroSynthWalk.apply(destination: 25, read: { current }, permitted: { true },
            actuate: { _, _ in current = 49; effects += 1 }, afterFirstEffect: {}, pause: {})
        #expect(result == .uncertain)
        #expect(effects == 1)
    }

    @Test func lostAuthorityBeforeTheFirstEffectIsAZeroWriteRefusal() async {
        var effects = 0
        let result = await RetroSynthWalk.apply(destination: 25, read: { 50 }, permitted: { false },
            actuate: { _, _ in effects += 1 }, afterFirstEffect: {}, pause: {})
        #expect(result == .refused)
        #expect(effects == 0)
    }

    @Test func lossAfterAWriteDoesNotReacquireOrCompensateBlindly() async {
        var current = 50
        var owned = true
        var effects = 0
        let result = await RetroSynthWalk.apply(destination: 25, read: { current }, permitted: { owned },
            actuate: { next, _ in current = next; effects += 1; owned = false }, afterFirstEffect: {}, pause: {})
        #expect(result == .uncertain)
        #expect(effects == 1)
    }
    @Test func taskCancellationAfterTheFirstEffectStopsWithoutReplay() async {
        var current = 0
        var effects = 0
        let worker = Task { @MainActor in
            await RetroSynthWalk.apply(destination: 100, read: { current }, permitted: { true },
                actuate: { next, _ in current = next; effects += 1 },
                afterFirstEffect: { withUnsafeCurrentTask { $0?.cancel() } },
                pause: { try Task.checkCancellation() })
        }
        #expect(await worker.value == .uncertain)
        #expect(effects == 1 && current == 10)
        #expect(!Task.isCancelled)
    }

}
