import Foundation

/// Read the written score produced by Logic for one pitched part.
struct ProjectMusicXML: Encodable, Equatable {
    struct Meter: Encodable, Equatable {
        let beats: Int
        let beat_type: Int
    }

    struct Event: Encodable, Equatable {
        let offset: Int
        let duration: Int
        let voice: String?
        let staff: Int?
        let is_rest: Bool
        let step: String?
        let octave: Int?
        let alter: Int?
    }

    struct Measure: Encodable, Equatable {
        let number: String
        let meter: Meter
        let divisions: Int
        let events: [Event]
    }

    let part_name: String
    let measures: [Measure]

    static let maximumBytes = 1_048_576

    func matchesNative(_ readback: ProjectScore.Readback) -> Bool {
        guard part_name == readback.track_name, let meter = measures.first?.meter,
              readback.time_signature == "\(meter.beats)/\(meter.beat_type)" else { return false }
        let events = measures.flatMap(\.events)
        guard events.filter(\.is_rest).count == readback.rest_count else { return false }
        let pitchClass = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        let written = events.compactMap { event -> Int? in
            guard let step = event.step, let base = pitchClass[step], let octave = event.octave else { return nil }
            return (octave + 1) * 12 + base + (event.alter ?? 0)
        }
        let native = readback.notes.compactMap { note -> Int? in
            guard let step = note.pitch.first, let base = pitchClass[String(step)] else { return nil }
            var tail = note.pitch.dropFirst()
            var alter = 0
            if let accidental = tail.first, "#♯b♭".contains(accidental) {
                alter = "#♯".contains(accidental) ? 1 : -1
                tail = tail.dropFirst()
            }
            guard let octave = Int(tail) else { return nil }
            return (octave + 1) * 12 + base + alter
        }
        guard native.count == readback.notes.count, native.count == written.count else { return false }
        // Logic's middle-C display convention can be C3 or C4. One
        // convention must account for all pitches in a score.
        return native.sorted() == written.sorted() || native.map { $0 + 12 }.sorted() == written.sorted()
    }

    static func parse(_ data: Data) -> Self? {
        guard (1...maximumBytes).contains(data.count),
              let document = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]),
              let root = document.rootElement(), root.name == "score-partwise",
              let partList = only(root.elements(forName: "part-list")),
              let definition = only(partList.elements(forName: "score-part")),
              let part = only(root.elements(forName: "part")),
              let identity = part.attribute(forName: "id")?.stringValue, !identity.isEmpty,
              definition.attribute(forName: "id")?.stringValue == identity,
              let name = text("part-name", in: definition), !name.isEmpty, name.utf8.count <= 256
        else { return nil }

        let source = part.elements(forName: "measure")
        guard (1...32).contains(source.count) else { return nil }
        var result = [Measure]()
        var divisions: Int?
        var meter: Meter?
        var eventCount = 0
        var pitched = false
        for item in source {
            guard let number = item.attribute(forName: "number")?.stringValue,
                  !number.isEmpty, number.utf8.count <= 16 else { return nil }
            var position = 0
            var onset: Int?
            var events = [Event]()
            for child in item.children ?? [] {
                guard let element = child as? XMLElement else { continue }
                switch element.name {
                case "attributes":
                    if let value = text("divisions", in: element) {
                        guard events.isEmpty, let units = Int(value), (1...32768).contains(units) else { return nil }
                        divisions = units
                    }
                    if let time = only(element.elements(forName: "time")) {
                        guard events.isEmpty, let beats = integer("beats", in: time), (1...32).contains(beats),
                              let unit = integer("beat-type", in: time), [1, 2, 4, 8, 16, 32].contains(unit)
                        else { return nil }
                        meter = Meter(beats: beats, beat_type: unit)
                    }
                case "backup", "forward":
                    guard let duration = integer("duration", in: element), (1...1_048_576).contains(duration) else { return nil }
                    position += element.name == "backup" ? -duration : duration
                    guard (0...1_048_576).contains(position) else { return nil }
                    onset = nil
                case "note":
                    guard eventCount < 256, element.elements(forName: "grace").isEmpty,
                          let duration = integer("duration", in: element), (1...1_048_576).contains(duration)
                    else { return nil }
                    let chord = !element.elements(forName: "chord").isEmpty
                    guard let offset = chord ? onset : position,
                          let event = readEvent(element, offset: offset, duration: duration) else { return nil }
                    if !chord {
                        onset = position
                        position += duration
                        guard position <= 1_048_576 else { return nil }
                    }
                    events.append(event)
                    eventCount += 1
                    pitched = pitched || !event.is_rest
                default:
                    break
                }
            }
            guard let divisions, let meter else { return nil }
            result.append(Measure(number: number, meter: meter, divisions: divisions, events: events))
        }
        guard pitched else { return nil }
        return .init(part_name: name, measures: result)
    }

    private static func readEvent(_ item: XMLElement, offset: Int, duration: Int) -> Event? {
        let voice = text("voice", in: item)
        let staff = integer("staff", in: item)
        guard (voice?.utf8.count ?? 0) <= 16, staff.map({ (1...16).contains($0) }) ?? true else { return nil }
        if only(item.elements(forName: "rest")) != nil, item.elements(forName: "pitch").isEmpty {
            return .init(offset: offset, duration: duration, voice: voice, staff: staff, is_rest: true,
                         step: nil, octave: nil, alter: nil)
        }
        guard item.elements(forName: "rest").isEmpty, let pitch = only(item.elements(forName: "pitch")),
              let step = text("step", in: pitch), ["A", "B", "C", "D", "E", "F", "G"].contains(step),
              let octave = integer("octave", in: pitch), (0...9).contains(octave),
              let alter = Int(text("alter", in: pitch) ?? "0"), (-2...2).contains(alter) else { return nil }
        return .init(offset: offset, duration: duration, voice: voice, staff: staff, is_rest: false,
                     step: step, octave: octave, alter: alter)
    }

    private static func only<T>(_ values: [T]) -> T? { values.count == 1 ? values.first : nil }

    private static func text(_ name: String, in parent: XMLElement) -> String? {
        only(parent.elements(forName: name))?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func integer(_ name: String, in parent: XMLElement) -> Int? {
        text(name, in: parent).flatMap { Int($0) }
    }
}
