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
  <a href="https://github.com/ion-cascade/conductor/releases/latest">Latest release</a> ·
  <a href="https://github.com/ion-cascade/conductor/issues">Issues</a>
</p>

## Your Logic session, connected

Conductor connects MCP-compatible assistants and tools to **the real Logic Pro session running on your Mac**. It combines native macOS Accessibility, MIDI, AppleScript and control-surface channels behind structured commands and live project resources.

It is the **complete server maintained by Ion Cascade**: native control channels, command dispatch, project state, verification, MIDI operations and export infrastructure. The optional SSH bridge lets a client on another computer use the same Mac session.

Our focus is practical music work with trustworthy feedback: a command being accepted is different from the intended track changing, a cached reading is different from a fresh observation, and a MIDI region is different from a rendered audio file.

> Conductor 1.0 supports the Logic workflows listed in the [compatibility matrix](docs/conductor/compatibility.md). Start with a disposable project.

## What Conductor does

| Area | Available interfaces |
| --- | --- |
| **Transport** | Playback, stop, tempo, position and control-bar state |
| **Tracks** | Inspect and select tracks, adjust track controls, and create and edit Volume automation |
| **Mixer** | Channel strips, faders, stock inserts, Compressor presets, sends and guarded routing operations |
| **MIDI** | Sequence creation and import, MIDI messages, region-event inspection and guarded MIDI export |
| **Projects** | Open, save, inspect exact region boundaries, plan exports and verify produced artifacts |
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

### Install and connect

Download the versioned source archive and checksums from the [GitHub release](https://github.com/ion-cascade/conductor/releases/latest). Verify the archive, extract it, then run `./Scripts/install.sh` on the Mac that runs Logic. The installer builds Conductor with your Swift toolchain, keeps each installed release separate, and installs the stable `conductor` command in your account.

- [Install, update and roll back](docs/conductor/install.md)
- [Connect a local or SSH MCP client](docs/conductor/remote-bridge.md)
- [Compatibility and verified workflows](docs/conductor/compatibility.md)

To work on the source directly:

```bash
git clone https://github.com/ion-cascade/conductor.git
cd conductor
swift build -c release
```

The package executable is `.build/release/LogicProMCP`.

### Start with a small check

1. Open a disposable Logic project and bring Logic to the foreground.
2. Read `logic://system/health`, `logic://project/info`, `logic://tracks` and `logic://transport/state`.
3. Confirm the returned project and track names match your session.
4. Test Play and Stop, then a reversible operation on one known track. Inspect the verification result and fresh state after each change.

Keep recordings and projects on your own machines. Conductor's bridge uses your existing SSH connection; this repository contains no credentials or personal client configuration.

## Tested status

Conductor 1.0 was verified on an Apple M2 Pro Mac mini running macOS 27.2.1 and desktop Logic Pro 13.0 build 7801. The [compatibility matrix](docs/conductor/compatibility.md) lists the clean-install workflow, measured release checks, and the scope of Logic support.

The release passed 404 focused Swift tests and 19 Python tests covering the installer and shared bridge.

### Render and export from Logic 13

Use the same `logic_project` parameters for the read-only `export_plan` and the confirmed `export_run`. Set `artifacts` to `["bounce"]` and supply `bounce_settings` for explicit stereo PCM delivery. For aligned per-track WAVE files, use `artifacts: ["stem"]` and provide `stem_settings`. Conductor returns the verified Mac paths, including the private output directory used for stems.

Logic’s Stem Splitter is a separate workflow. Select an audio region in a saved project and use `logic_tracks.split_selected_audio` with the project, track and exact region bounds. Conductor checks the six resulting files and the arrangement edit. [Delivery parameters and supported scope](docs/API.md#explicit-stereo-pcm-bounce)

### Import onto an existing instrument

In Logic 13, select the Studio Grand track and keep its Inspector visible. Pass its current zero-based index as `target_track` and its unique current name as `target_expected_name` to `logic_tracks.record_sequence`. The note string contains pitch, offset in milliseconds, duration in milliseconds, velocity and a one-based MIDI channel.

Logic creates a staging track when it imports the Standard MIDI File. Conductor verifies Arrange keyboard focus before copying and pasting the new region onto the selected instrument track. It then checks the result against the previous arrangement. When Conductor closes the Library to transfer the region, the receipt reports whether it verified that the Library reopened. The receipt identifies the retained staging track. Reacquire track references before reading the notes or deleting the staging track, especially when both tracks have the same name. After an interrupted or unverified write, inspect the arrangement before another import.

### Place and move a MIDI region

1. Open a saved project, stop playback, and show hidden tracks with `logic_navigate.toggle_view` using `view: "hidden_tracks"` and `visible: true`.
2. Select one MIDI region in Arrange. Read `logic_project.get_regions` and check its selection and exact boundaries.
3. Call `logic_transport.goto_position` with a position such as `3.2.3.17` for bar, beat, division and tick. Confirm the tool observed that exact position.
4. Call `logic_edit.move_to_playhead` and check its verified start and end positions. Save and reopen to check persistence. Use `logic_midi.read_track_notes` if you also need the underlying MIDI events.

### Adjust a specific mixer strip

With the Mixer open, read `logic://mixer` and take the `mixer_strip_ref` from the intended strip. Use it as `target_ref` with `logic_mixer` and the `set_volume`, `set_pan`, `set_mute` or `set_solo` command. A mute or solo request also takes a Boolean `enabled`. Read the strip again to check its new state.

For Arrange controls, use a track reference from `logic_project.inspect_session`. Review coverage before deciding which tracks exist and reacquire references when opening a different project or exposing a different set of tracks. A control listed in `unavailable_fields` needs fresh native evidence before use.

### Apply a Compressor preset

With the Mixer open and the intended track selected, call `logic_plugins.get_inventory` with its current zero-based Arrange index. Take the Compressor’s `plugin_insert_ref` and use it as `target_ref` for `get_preset_verified`. To load the factory Piano preset, call `set_preset_verified` with the same reference, `path: "02 Keyboards/Piano"` and the just-observed setting as `expected_current`. Reacquire the reference after reopening the project.

For the Compressor threshold, `get_param_verified` and `set_param_verified` use the plug-in’s normalized percentage. A setting of 82 represents 82% on that control.

### Automate track volume

1. Stop playback and select one region on the intended track. Show track automation and leave the enabled Volume lane in Read mode.
2. Take the track reference from `logic://tracks` and read the selected region’s exact start and end with `logic_project.get_regions`. Call `logic_tracks.create_volume_automation_at_region_borders` with the reference, `start`, and `end`. Creation requires an empty track automation event list.
3. Open Logic’s Track Automation Event List for the track. Call `get_volume_automation` with the same track reference and verify its `points` and `selected_positions`.
4. Call `set_volume_automation_point` with a reported `position`, `expected_current` and the target `value`. If Logic selected two points together, send the other position as `linked_position`. The adapter changes values in 10-unit steps in Logic’s 0–127 fader scale.

### Current limits

- The track-selection adapter uses English UI labels and an exposed, contiguous track rail in one Arrange window. Logic's track search can omit tracks marked hidden even while their headers are shown.
- Track inventories can be partial when tracks are concealed, stacks are collapsed or the viewport cannot prove the end of the rail. Routing completeness has separate requirements.
- Mixer readback depends on the visible layout. For example, Master has no observed pan control and Stereo Out has no observed solo switch in the tested Mixer.
- Short per-track exports can finish between progress observations. The 0.2 candidate verifies a stable, decodable WAV or AIFF in its own run directory with one independently bound subject. General multi-track file attribution remains unverified.
- MIDI note readback uses the native Standard MIDI File export and reports ticks from the SMF origin. The bar-three fixture keeps its leading space. Its region spans bars one through four, and the first note falls at tick 3840 at 480 PPQ.
- Factory patch qualification covers Studio Grand. Other factory patches and arbitrary effects need their own native qualification.
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
