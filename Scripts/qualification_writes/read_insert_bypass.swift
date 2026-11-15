import AppKit
import ApplicationServices
import Foundation

func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) ?? []
}

func role(_ element: AXUIElement) -> String? {
    attribute(element, kAXRoleAttribute)
}

func description(_ element: AXUIElement) -> String? {
    attribute(element, kAXDescriptionAttribute)
}

let args = CommandLine.arguments
guard args.count == 3, args[1].hasPrefix("/"), args[1].hasSuffix(".logicx") else { exit(1) }
let project = args[1]
let instances = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10")
guard instances.count == 1, let logic = instances.first, logic.isActive else { exit(2) }
let app = AXUIElementCreateApplication(logic.processIdentifier)
let windows: [AXUIElement] = (attribute(app, kAXWindowsAttribute) ?? []).filter { role($0) != kAXHelpTagRole }
guard windows.count == 1, let window = windows.first else { exit(3) }

func ownsWindow() -> Bool {
    guard logic.isActive, let document: String = attribute(window, kAXDocumentAttribute),
          URL(string: document)?.path == project,
          let focused: AXUIElement = attribute(app, kAXFocusedWindowAttribute) else { return false }
    return CFEqual(focused, window)
}

guard ownsWindow() else { exit(4) }
var pending = [(window, 0)]
var mixers: [AXUIElement] = []
var visited = 0
while let (node, depth) = pending.popLast() {
    visited += 1
    guard visited <= 300 else { exit(5) }
    if role(node) == kAXLayoutAreaRole, description(node) == "Mixer",
       children(node).contains(where: { role($0) == kAXLayoutItemRole }) {
        mixers.append(node)
    } else if depth < 7, !["Inspector", "Tracks contents", "Tracks header", "Browser"].contains(description(node) ?? "") {
        pending.append(contentsOf: children(node).reversed().map { ($0, depth + 1) })
    }
}
guard mixers.count == 1 else { exit(6) }
let strips = children(mixers[0]).filter { role($0) == kAXLayoutItemRole && description($0) == args[2] }
guard strips.count == 1 else { exit(7) }

var controlsBySlot: [(name: String, bypassed: Bool, y: CGFloat)] = []
for slot in children(strips[0]) where role(slot) == kAXGroupRole {
    let controls = children(slot).filter { role($0) == kAXCheckBoxRole && description($0) == "bypass" }
    if controls.isEmpty { continue }
    guard controls.count == 1, let name = description(slot),
          let value: Int = attribute(controls[0], kAXValueAttribute), value == 0 || value == 1,
          let position: AXValue = attribute(controls[0], kAXPositionAttribute) else { exit(8) }
    var point = CGPoint.zero
    guard AXValueGetValue(position, .cgPoint, &point), point.y.isFinite else { exit(8) }
    controlsBySlot.append((name, value == 1, point.y))
}

// Accessibility child order differs from the displayed insert order.
let physicalOrder = controlsBySlot.sorted { $0.y < $1.y }
guard ownsWindow(), physicalOrder.map(\.name) == ["Piano", "Channel EQ", "Compressor", "ChromaVerb", "Compressor"],
      Set(physicalOrder.map(\.y)).count == physicalOrder.count,
      physicalOrder[0].bypassed == false else {
    print("UNEXPECTED_INSERTS", controlsBySlot)
    exit(9)
}
let rows: [[Any]] = physicalOrder.dropFirst().enumerated().map { ordinal, slot in
    [ordinal, slot.name, slot.bypassed]
}
guard let output = try? JSONSerialization.data(withJSONObject: rows) else { exit(10) }
print("NATIVE_INSERTS " + String(decoding: output, as: UTF8.self))
