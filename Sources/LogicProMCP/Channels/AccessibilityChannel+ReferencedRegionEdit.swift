@preconcurrency import ApplicationServices
import Foundation

extension AccessibilityChannel {
    func editArrangeRegion(parameters: [String: String], runtime: AXLogicProElements.Runtime) async -> ChannelResult {
        .error(HonestContract.encodeStateC(error: .readbackUnavailable,
            hint: "The exact native region editor could not be acquired.", extras: ["write_attempted": false]))
    }
}
