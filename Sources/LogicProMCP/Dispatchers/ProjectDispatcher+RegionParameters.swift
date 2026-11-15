import Foundation
import MCP

extension ProjectDispatcher {
    static func regionParameter(command: String, params: [String: Value], router: ChannelRouter) async -> CallTool.Result {
        let write = command.hasPrefix("set_")
        let fade = command.hasSuffix("_fade")
        func invalid(_ hint: String) -> CallTool.Result {
            toolTextResult(.error(HonestContract.encodeStateC(error: .invalidParams, hint: hint,
                extras: ["operation": "project.\(command)", "write_attempted": false])))
        }
        let parameter: AudioRegionParameter
        if fade {
            guard let edge = params["edge"]?.stringValue, let parsed = AudioRegionParameter(rawValue: edge),
                  parsed != .gain else { return invalid("Use edge in or out.") }
            parameter = parsed
        } else {
            parameter = .gain
        }
        var keys: Set<String> = ["target_ref"]
        if fade { keys.insert("edge") }
        if write { keys.formUnion([parameter.receiptKey, "expected_\(parameter.receiptKey)"]) }
        guard Set(params.keys) == keys, let reference = params["target_ref"]?.stringValue,
              reference.hasPrefix("reg_") else {
            return invalid("Pass a current target_ref and the values required by \(command).")
        }
        let operation = "region.\(write ? "set" : "get")_\(fade ? "fade" : "gain")"
        var args = ["target_ref": reference]
        if fade { args["edge"] = parameter.rawValue }
        guard write else { return toolTextResult(await router.route(operation: operation, params: args)) }
        func numeric(_ key: String) -> Double? {
            switch params[key] {
            case .int(let value): Double(value)
            case .double(let value): value.isFinite ? value : nil
            default: nil
            }
        }
        let expectedKey = "expected_\(parameter.receiptKey)"
        guard let expected = numeric(expectedKey), let desired = numeric(parameter.receiptKey),
              parameter.accepts(desired) else {
            return invalid(fade ? "Use the observed time and a new whole-millisecond value from 0 to 1000."
                                : "Use the observed gain and a new value from -24.0 to +12.0 dB in 0.1 dB steps.")
        }
        args[expectedKey] = String(expected)
        args[parameter.receiptKey] = String(desired)
        let request = args
        let traceID = await startTraceIfEnabled(command: command)
        let result = await withWriteBoundaryArmed(traceID) {
            await router.route(operation: operation, params: request)
        }
        return await finalizeTrace(toolTextResult(result), traceID: traceID)
    }
}
