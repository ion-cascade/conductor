# Native write qualification

The write matrix runs against an owned desktop Logic session with a managed Conductor bridge. It holds the expected release version and the SHA-256 of the bridge executable throughout the run and writes an operation receipt only after successful document and helper cleanup. It requires the case selection to match the operation set in the receipt. The Swift census records these fixtures separately from the generic protocol and write/restore sweep.

From the repository root, with a trusted local fixture driver and a running isolated release profile:

```sh
python3 -m Scripts.qualification_writes.runner \
  --driver /path/to/write-fixtures.py \
  --version 1.8.1 --sha256 "$CANDIDATE_BINARY_SHA256" \
  --receipt /path/to/new-write-qualification.jsonl
```

Use `--case` for fixture development. A release receipt needs the complete matrix and the final `completed` event. The runner fails at the first unexpected result so a possibly unfinished native edit can be inspected in the owned clone. Operation receipts carry both acceptance evidence and the underlying refusal data. The release workflow verifies the isolated bridge stops after the matrix closes all of its projects.

## Fixture driver contract

The driver exports `make_driver()`. Its `binary_identity()` checks the active bridge worker and its child process against the installed executable. Return the canonical binary path in `binary`, the server `version`, and `sha256`. Its `open_fixture(case)` context manager clones and selects a disposable project and yields the case adapter. `verify_fixture_cleanup(case)` must independently confirm that the bound document closed and owned helper windows were retired. Execute cases serially under one desktop session.

Each case adapter supplies a `client` with `call`, `verified` and `request` methods. A refusal must be an MCP error with the expected error code and `write_attempted: false`. A verified tool reply must be State A. Use genuine native observations for the other adapter methods. Never use the write reply as the independent witness. Fixtures that need product persistence close and reopen the same saved clone and reacquire the project and target references.

| Case | Fixture |
| --- | --- |
| `mixer` | Two same-name strips in the embedded native Mixer. Provide `project_path` and `project_ref`. |
| `preset`, `bypass` | One stock Compressor initially at Custom for preset. For bypass use the fixture with two occupied stock Compressor positions and distinct surrounding inserts. `read_insert_controls.swift` reads the native editor or physical strip for these checks. |
| `region_edit` | Offscreen named audio region with exact bounds and peer regions in the Arrange lanes. |
| `region_parameters` | The 1.8 gain and fade fixture with a separate target and adjacent tone. Provide a direct native Inspector observer able to select, peek and check multiple selection without editing the setting. |
| `volume`, `pan` | An empty target lane at the exact region or playhead coordinates and an independently readable native Automation Event List. `native_lanes` returns ordered target events and peer-lane evidence. `with_event_list` runs a callback while the verified editor is held. |
| `splitter` | A selected region backed by a uniquely named bundled audio file. Inspect the generated AIFFs independently of the split reply, including their geometry. |
| `pattern` | A copy of the Logic Step Sequencer tutorial with the bounded Kick 1 step and native Inspector read. On reopen, peek at the selection without clicking the disabled cell. |
| `sidechain` | Stock Compressor initially keyed by Bus 2, with a separate audible key tone and piano. Record both exact-range bounces and observe a freshly opened native editor. |

Keep project copies, audio, native probe transcripts and machine-specific paths in the local evidence directory. Record the fixture and driver revision used alongside the release receipt.
