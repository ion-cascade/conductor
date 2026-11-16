<p align="center">
  <img src="docs/assets/conductor-banner.svg" alt="Ion Cascade Conductor" width="1280" />
</p>

<p align="center">
  <strong>A native MCP server for Apple Logic Pro, maintained by Ion Cascade.</strong>
</p>

<p align="center">
  <a href="https://github.com/ion-cascade/conductor/releases/latest"><img src="https://img.shields.io/github/v/release/ion-cascade/conductor?label=latest%20release" alt="Latest Conductor release" /></a>
</p>

<p align="center">
  <a href="https://github.com/ion-cascade/conductor/releases/latest">Download latest release</a> ·
  <a href="#get-started">Get started</a> ·
  <a href="docs/conductor/compatibility.md">Compatibility</a> ·
  <a href="docs/API.md">API reference</a>
</p>

Conductor connects an MCP client to your live Logic Pro session on a Mac. It reads tracks, regions, Mixer strips and inserts, applies supported edits, and verifies the results against Logic or the resulting files. The optional SSH relay lets a client on another computer control the same Mac session.

## Get started

1. Download the versioned source archive and `SHA256SUMS` from the [latest GitHub release](https://github.com/ion-cascade/conductor/releases/latest).
2. Verify and extract the archive, then run `./Scripts/install.sh` on the Mac that runs Logic. The installer builds Conductor with Apple’s Swift toolchain and keeps the previous installed release available for rollback. [Install, update and roll back](docs/conductor/install.md)
3. Start the bridge in Mac Terminal and connect your MCP client locally or over SSH. [Connect an MCP client](docs/conductor/remote-bridge.md)
4. Open a disposable Logic project in the foreground. Read `logic://system/health`, `logic://project/info` and `logic://tracks` to check that the server sees the project and tracks you expect.

Use the [compatibility matrix](docs/conductor/compatibility.md) to check the tested setup and the requirements for each workflow. The [latest release notes](https://github.com/ion-cascade/conductor/releases/latest) link to the source archive, checksums and native qualification receipt.

## Workflows

| Area | What you can do |
| --- | --- |
| Transport and session | Read the open project and visible tracks. Play, stop and locate an exact musical position. |
| Arrangement | Scan Arrange viewports for offscreen audio or MIDI regions, then move or trim a bound region. Set audio-region gain and standard linear fades. |
| Track automation | Create and edit supported Volume and absolute Pan points, move a Volume point, or shape a flat segment by inserting one control point. |
| MIDI | Import and export track MIDI. Edit an existing note’s pitch, start, length and velocity, or change an existing Expression (CC11) event. |
| Mixer and inserts | Adjust a referenced strip. Read Channel EQ, apply supported Compressor presets and sidechains, bypass occupied inserts, and edit qualified mono Gain levels and Gain automation. |
| Render and delivery | Bounce an exact stereo PCM range, export selected aligned stems, verify a delivery receipt and resume unfinished outputs after reconnecting. |
| Stem Splitter and Step Sequencer | Separate audio into stems or individual drum kit pieces, or inspect and toggle a selected Drum Machine Designer step. |
| Audio analysis | Read an audio file’s format, levels and spectral measurements. |

[Workflow examples and command requirements](docs/API.md) · [Command parameters](docs/COMMAND-PARAMETERS.md)

## Read back your changes

| Result | What it means |
| --- | --- |
| **A — verified** | Logic or an independent file check confirmed the requested result. |
| **B — unverified** | An action may have taken effect. Inspect the current project before sending it again. |
| **C — refused or failed** | A requirement failed. Check the returned error and whether a write was attempted. |

Acquire a fresh reference after reopening or changing the project. For track and insert operations, use the reference returned by the current inventory. Track lists can report partial coverage when tracks are hidden, stacks are collapsed or the Arrange viewport is incomplete.

## Development

Build the source with `swift build -c release`. Run bridge tests with `python3 -m unittest discover -s tools -p 'test_*.py' -v`. Native acceptance uses a disposable Logic project and independent state or file readback. [Development notes](docs/conductor/development.md) · [Report an issue](https://github.com/ion-cascade/conductor/issues)

## Maintained by Ion Cascade

Ion Cascade maintains the full Conductor server, including native controls, project state, verification, export and the remote bridge. Conductor builds on the work of MongLong0214 and Kolton Jacobs and retains the upstream history and MIT licence. [Ion Cascade](https://github.com/ion-cascade) · [Attribution](NOTICE.md) · [MIT licence](LICENSE)
