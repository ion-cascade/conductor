<p align="center">
  <img src="docs/assets/conductor-banner.svg" alt="Ion Cascade Conductor — a native bridge between your ideas and Logic Pro" width="1280" />
</p>

<p align="center">
  <strong>An open-source MCP server for Apple Logic Pro, maintained by Ion Cascade.</strong><br />
  Inspect the session. Control the DAW. Check what actually changed.
</p>

<p align="center">
  <a href="#getting-started">Get started</a> ·
  <a href="#what-conductor-does">Capabilities</a> ·
  <a href="#tested-status">Tested status</a> ·
  <a href="docs/conductor/remote-bridge.md">Remote Mac setup</a> ·
  <a href="https://github.com/ion-cascade/conductor/issues">Issues</a>
</p>

## Your Logic session, connected

Conductor connects MCP-compatible assistants and tools to **the real Logic Pro session running on your Mac**. It combines native macOS Accessibility, MIDI, AppleScript and control-surface channels behind structured commands and live project resources.

It is the **complete server maintained by Ion Cascade**: native control channels, command dispatch, project state, verification, MIDI operations and export infrastructure. The optional SSH bridge lets a client on another computer use the same Mac session.

Our focus is practical music work with trustworthy feedback: a command being accepted is different from the intended track changing, a cached reading is different from a fresh observation, and a MIDI region is different from a rendered audio file.

> **Development preview.** Conductor is undergoing live qualification on Logic Pro 13. Use a disposable project for initial tests. See the tested status below before relying on an operation.

## What Conductor does

| Area | Available interfaces |
| --- | --- |
| **Transport** | Playback, stop, tempo, position and control-bar state |
| **Tracks** | Inspect names and exposed controls; select, mute, solo, create and rename tracks |
| **Mixer** | Channel strips, faders, inserts, sends and guarded routing operations |
| **MIDI** | Sequence creation and import, MIDI messages, region-event inspection and guarded MIDI export |
| **Projects** | Open, save, inspect regions, plan exports and verify produced artifacts |
| **Audio analysis** | File format, duration, levels and spectrum measurements |
| **Remote access** | Owner-only Mac socket with an SSH relay for MCP clients on another machine |

These are the server's interfaces, **not a claim that every operation works in every Logic layout**. Native readback, project identity, permissions and command-specific requirements determine what can run.

### A result you can act on

Mutating commands distinguish three outcomes:

| State | Meaning |
| --- | --- |
| **A — verified** | Readback confirmed the requested result. |
| **B — unverified** | An action may have happened, but its outcome could not be established. Inspect the current session before another attempt. |
| **C — refused or failed** | The operation did not satisfy its requirements. Check the error and write-attempt fields. |

Missing, stale and partial observations remain explicit. An incomplete track inventory does not prove there are no hidden tracks.

## Getting started

### Requirements

- A Mac with Logic Pro installed and an open project.
- A Swift toolchain capable of building the pinned package dependencies. Local qualification currently uses Swift 6.4.2 on Apple silicon.
- An MCP client, such as Codex, Claude Desktop or another client supporting stdio servers.
- macOS Accessibility permission for the application responsible for launching Conductor. Other operations can require additional permissions.

### Build from this repository

```bash
git clone https://github.com/ion-cascade/conductor.git
cd conductor
swift build -c release
```

The executable currently remains **`.build/release/LogicProMCP`** for compatibility with the inherited Swift package and tooling. Conductor identifies itself independently in the MCP handshake; tool names such as `logic_tracks` remain compatible.

### Connect a local MCP client

Set the command to the absolute path of the built executable. For clients using a JSON MCP configuration:

```json
{
  "mcpServers": {
    "conductor": {
      "command": "/absolute/path/to/conductor/.build/release/LogicProMCP",
      "env": {
        "LOGIC_PRO_BUNDLE_ID": "com.apple.logic10",
        "LOGIC_MCP_DIRECT_TOOLBAR": "1",
        "LOGIC_MCP_BOUNDED_MIXER_POLL": "1",
        "LOGIC_MCP_DIRECT_MIXER_PANEL": "1",
        "LOGIC_MCP_LOGIC13_TRACKS": "1",
        "LOGIC_MCP_COHERENT_READS": "1"
      }
    }
  }
}
```

The flags select the Logic 13 paths currently being qualified. They are opt-in so the existing compatibility paths remain available.

macOS associates permissions with the launching application. Granting Accessibility to Terminal does not establish that a server launched directly over SSH has the same access. [The remote bridge guide](docs/conductor/remote-bridge.md) explains the Terminal-launched approach.

### Start with a small check

1. Open a disposable Logic project and bring Logic to the foreground.
2. Read `logic://system/health`, `logic://project/info`, `logic://tracks` and `logic://transport/state`.
3. Confirm the returned project and track names match your session.
4. Test Play and Stop, then a reversible operation on one known track. Inspect the verification result and fresh state after each change.

Keep recordings and projects on your own machines. Conductor's bridge uses your existing SSH connection; this repository contains no credentials or personal client configuration.

## Tested status

Qualification is specific to the build, host and workflow. Current local work uses **Logic Pro 13.0 build 7801 on an Apple M2 Pro running macOS 27.2.1**.

| Check | Current evidence |
| --- | --- |
| Shared bridge and recovery | The configured SSH launcher supported simultaneous clients and a fresh connection after the upstream exited. Conductor started automatically after signing out of macOS and signing back in, then read the saved MIDI through the same launcher. Duplicate startup preserved the active socket and PID. After Logic quit and relaunched, the same client reopened the saved fixture and verified its notes. |
| Target selection | Numbered search results were checked against the intended track name, with independent selection readback. |
| Stable track references | Track selection and mute on/off succeeded through issued references. |
| Read-after-write state | Explicit core refreshes replace stale track data; unread transport defaults are omitted. |
| Playback and mixer panel | Play/Stop and mixer hide/show were verified in a disposable session. |
| MIDI-to-audio workflow | The Mac mini tests loaded Studio Grand through MCP, imported four-note fixtures at bars one and three, and read them back from Logic’s MIDI export. Pitch, onset, duration, velocity and channel matched at 480 PPQ before and after reopening. Independent checks verified both native stereo AIFF renders, including the 3.715-second render through the configured SSH launcher after a bridge restart. |
| Automated checks | The 0.2 candidate passed 254 focused Swift tests and 16 Python tests. The bridge tests cover concurrent clients, reconnects, cancellation, disconnects and duplicate startup. |

### Import onto an existing instrument

On the Logic 13 candidate, select the Studio Grand track and keep its Inspector visible. Pass its current zero-based index as `target_track` and its unique current name as `target_expected_name` to `logic_tracks.record_sequence`. The note string contains pitch, offset in milliseconds, duration in milliseconds, velocity and a one-based MIDI channel.

Logic creates a staging track when it imports the Standard MIDI File. Conductor verifies Arrange keyboard focus before copying and pasting the new region onto the selected instrument track. It then checks the result against the previous arrangement. When Conductor closes the Library to transfer the region, the receipt reports whether it verified that the Library reopened. The receipt identifies the retained staging track. Reacquire track references before reading the notes or deleting the staging track, especially when both tracks have the same name. After an interrupted or unverified write, inspect the arrangement before another import.

### Current limits

- The qualified track-selection adapter currently expects English UI labels and an exposed, contiguous track rail in a single project window.
- Track and routing inventories can be partial. Hidden tracks and collapsed stacks require their own evidence.
- Pan controls depend on the visible layout; missing controls are not verified centre pan.
- Short per-track exports can finish between progress observations. The 0.2 candidate verifies a stable, decodable WAV or AIFF in its own run directory with one independently bound subject. General multi-track file attribution remains unverified.
- MIDI note readback uses the native Standard MIDI File export and reports ticks from the SMF origin. The bar-three fixture keeps its leading space. Its region spans bars one through four, and the first note falls at tick 3840 at 480 PPQ.
- Factory patch qualification covers Studio Grand. Arbitrary instruments and effects, Stem Splitter and general export workflows remain outside this qualification.
- Screenshots were unavailable in the current remote Mac environment. Live qualification used MCP responses and separate native Accessibility probes; no visual or listening approval is implied.

See [development notes](docs/conductor/development.md) for the source layout and validation approach. The inherited [technical API reference](docs/API.md) describes the broader command surface; its operation-specific requirements still apply.

## Contributing

Bug reports are most useful with the Logic/macOS versions, command, verification response and a minimal disposable-project reproduction. Remove private paths and personal material before posting logs.

For code changes, explain the intended behavior and show both the successful path and refusal behavior. A command returning success is insufficient when the UI or exported artifact can disagree.

```bash
python3 -m unittest discover -s tools -p 'test_*.py' -v
swift build -c release
```

Swift tests and native workflows have different requirements. Consult the development notes before running the inherited full suite.

## Maintained by Ion Cascade

[Ion Cascade](https://github.com/ion-cascade) owns the ongoing direction, maintenance and releases of **Conductor**.

Conductor builds on [MongLong0214/logic-pro-mcp](https://github.com/MongLong0214/logic-pro-mcp) and the earlier work of **Kolton Jacobs**. We retain the upstream Git history, original MIT licence and contributor credit. See [NOTICE.md](NOTICE.md) for provenance and attribution.

**[MIT licensed](LICENSE)** · **[Report an issue](https://github.com/ion-cascade/conductor/issues)**
