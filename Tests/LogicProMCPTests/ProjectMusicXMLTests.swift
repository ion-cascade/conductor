import Foundation
import Testing
@testable import LogicProMCP

struct ProjectMusicXMLTests {
    private let fixture = """
        <?xml version="1.0"?>
        <!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN"
          "http://www.musicxml.org/dtds/partwise.dtd">
        <score-partwise version="4.0">
          <part-list><score-part id="P1"><part-name>Grand Piano</part-name></score-part></part-list>
          <part id="P1">
            <measure number="1">
              <attributes><divisions>4</divisions><time><beats>3</beats><beat-type>4</beat-type></time></attributes>
              <note><pitch><step>F</step><alter>1</alter><octave>4</octave></pitch><duration>4</duration></note>
              <note><rest/><duration>2</duration></note>
              <note><pitch><step>C</step><octave>5</octave></pitch><duration>6</duration></note>
            </measure>
            <measure number="2">
              <note><pitch><step>D</step><octave>5</octave></pitch><duration>12</duration></note>
            </measure>
          </part>
        </score-partwise>
        """

    @Test func writtenNotationRetainsPitchRestTimingAndInheritedMeter() throws {
        let score = try #require(ProjectMusicXML.parse(Data(fixture.utf8)))
        #expect(score.part_name == "Grand Piano")
        #expect(score.measures.map(\.meter) == Array(repeating: .init(beats: 3, beat_type: 4), count: 2))
        #expect(score.measures.map(\.divisions) == [4, 4])
        let events = score.measures.flatMap(\.events)
        #expect(events.map(\.offset) == [0, 4, 6, 0])
        #expect(events.map(\.duration) == [4, 2, 6, 12])
        #expect(events.map(\.is_rest) == [false, true, false, false])
        #expect(events.map(\.step) == ["F", nil, "C", "D"])
        #expect(events.map(\.octave) == [4, nil, 5, 5])
        #expect(events.map(\.alter) == [1, nil, 0, 0])
    }

    @Test func refusesWrongPartIdentityAndMissingNoteTiming() {
        for modified in [
            fixture.replacingOccurrences(of: "<part id=\"P1\">", with: "<part id=\"wrong\">"),
            fixture.replacingOccurrences(of: "<duration>4</duration>", with: ""),
            fixture.replacingOccurrences(of: "<beat-type>4</beat-type>", with: "<beat-type>5</beat-type>"),
        ] {
            #expect(ProjectMusicXML.parse(Data(modified.utf8)) == nil)
        }
    }
}
