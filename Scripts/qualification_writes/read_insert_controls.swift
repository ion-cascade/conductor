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
guard (args.count == 3 || (args.count == 4 && args[3] == "preset")),
      args[1].hasPrefix("/"), args[1].hasSuffix(".logicx") else { exit(1) }
let observePreset = args.count == 4
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

var controlsBySlot: [(name: String, bypassed: Bool, y: CGFloat, group: AXUIElement)] = []
for slot in children(strips[0]) where role(slot) == kAXGroupRole {
    let controls = children(slot).filter { role($0) == kAXCheckBoxRole && description($0) == "bypass" }
    if controls.isEmpty { continue }
    guard controls.count == 1, let name = description(slot),
          let value: Int = attribute(controls[0], kAXValueAttribute), value == 0 || value == 1,
          let position: AXValue = attribute(controls[0], kAXPositionAttribute) else { exit(8) }
    var point = CGPoint.zero
    guard AXValueGetValue(position, .cgPoint, &point), point.y.isFinite else { exit(8) }
    controlsBySlot.append((name, value == 1, point.y, slot))
}

// Accessibility child order differs from the displayed insert order.
let physicalOrder = controlsBySlot.sorted { $0.y < $1.y }
let expectedOrder = observePreset
    ? ["Piano", "Channel EQ", "Compressor", "ChromaVerb"]
    : ["Piano", "Channel EQ", "Compressor", "ChromaVerb", "Compressor"]
guard ownsWindow(), physicalOrder.map(\.name) == expectedOrder,
      Set(physicalOrder.map(\.y)).count == physicalOrder.count,
      physicalOrder[0].bypassed == false else {
    print("UNEXPECTED_INSERTS", controlsBySlot.map(\.name))
    exit(9)
}
let insertRows = Array(physicalOrder.dropFirst())
if observePreset {
    let index = 1
    let plugin = insertRows[index].group
    let controls = children(plugin).filter { role($0) == kAXButtonRole && description($0) == "open" }
    guard controls.count == 1, ownsWindow(),
          AXUIElementPerformAction(controls[0], kAXPressAction as CFString) == .success else { exit(11) }
    Thread.sleep(forTimeInterval: 0.5)

    func currentWindows() -> [AXUIElement] {
        (attribute(app, kAXWindowsAttribute) ?? []).filter { role($0) != kAXHelpTagRole }
    }
    let opened = currentWindows()
    let added = opened.filter { !CFEqual($0, window) }
    guard opened.count == 2, added.count == 1, let editor = added.first,
          (attribute(editor, kAXTitleAttribute) as String?) == args[2],
          children(editor).filter({
              role($0) == kAXStaticTextRole && (attribute($0, kAXValueAttribute) as String?) == "Compressor"
          }).count == 1,
          let close: AXUIElement = attribute(editor, kAXCloseButtonAttribute) else { exit(12) }

    func ownsEditor() -> Bool {
        let current = currentWindows()
        guard logic.isActive, current.count == 2,
              current.contains(where: { CFEqual($0, window) }),
              current.contains(where: { CFEqual($0, editor) }),
              let document: String = attribute(window, kAXDocumentAttribute),
              URL(string: document)?.path == project,
              let focus: AXUIElement = attribute(app, kAXFocusedWindowAttribute) else { return false }
        return CFEqual(editor, focus)
    }

    guard ownsEditor() else { exit(13) }
    let settings = children(editor).compactMap { child -> String? in
        guard role(child) == kAXPopUpButtonRole,
              let value: String = attribute(child, kAXValueAttribute),
              ["Custom", "Piano"].contains(value) else { return nil }
        return value
    }
    guard ownsEditor(),
          AXUIElementPerformAction(close, kAXPressAction as CFString) == .success else { exit(14) }
    Thread.sleep(forTimeInterval: 0.35)
    guard currentWindows().count == 1, ownsWindow(), settings.count == 1,
          let output = try? JSONSerialization.data(withJSONObject: ["insert": index, "preset": settings[0]])
    else { exit(15) }
    print("NATIVE_PRESET " + String(decoding: output, as: UTF8.self))
} else {
    let rows: [[Any]] = insertRows.enumerated().map { ordinal, slot in
        [ordinal, slot.name, slot.bypassed]
    }
    guard let output = try? JSONSerialization.data(withJSONObject: rows) else { exit(10) }
    print("NATIVE_INSERTS " + String(decoding: output, as: UTF8.self))
}
