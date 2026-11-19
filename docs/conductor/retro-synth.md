# Retro Synth sound design

Conductor 1.16 provides a bounded Analog profile for Retro Synth on English Logic Pro 13.0, build 7801. Alchemy, the other Retro Synth engines and unlisted parameters remain outside this profile.

Open a saved disposable project, load Retro Synth on one uniquely named software instrument track, select that track and leave its Inspector visible. Stop playback and recording. Close other plug-in windows and dialogs. The Retro Synth window must be unlinked if already open. Keep one unlinked Retro Synth window open in **Controls** view throughout your edits. Recreating that window for every request showed rapid host memory growth in qualification. Conductor therefore refuses a closed window by default and does not switch an existing graphical Editor.

First read `logic://project/info` and `logic://tracks` for fresh project and selected track references. Prepare the window once with a state read using `open_editor:true`. This opens it, selects Controls and leaves it visible. Subsequent reads and edits reuse it and preserve its scroll position. The preparation response reports `editor_opened:true`, `editor_retained:true`, `ui_restored:false` and `ui_policy_satisfied:true`: the requested visible window was retained, so the original closed layout was intentionally changed. Reuse reports `editor_opened:false` and `ui_restored:true`. If the window is already open in the graphical Editor, select **Controls** manually first. Avoid closing and recreating it between individual edits.

```json
{
  "command": "get_retro_synth_state",
  "params": {
    "project_ref": "<current project_ref>",
    "target_ref": "<track_ref from the selected row>",
    "open_editor": true
  }
}
```

If the project is reopened, obtain fresh project and track references and prepare its window again. Closing the window deliberately ends the editing session; a later read without `open_editor:true` refuses safely. The retained workflow passed bounded native qualification. Earlier Logic aborts and editor-recreation memory growth remain documented; avoid recreating the window between edits. See the [compatibility limits](compatibility.md#116-retro-synth-analog).

## Start with a native setting

Read `logic://project/info` and `logic://tracks` for the current `project_ref` and the selected row's `track_ref`. Pass that `track_ref` value as `target_ref` in the commands below. Both references must belong to this server session and the current saved project.

`logic_plugins.initialize_retro_synth` calls Logic's **Initialize Setting**. It replaces the current sound, so use it deliberately on your test track:

```json
{
  "command": "initialize_retro_synth",
  "params": {
    "project_ref": "<current project_ref>",
    "target_ref": "<track_ref from the selected row>",
    "confirmed": true
  }
}
```

This verifies the complete initialized Controls table rather than treating the preset name as proof. It does not change your saved default setting. Logic’s initialized setting has the filter bypassed. Set `filter_enabled` to JSON `true` with unit `bool` before testing cutoff, resonance, filter envelopes or LFO modulation. This is an explicit edit; initialization preserves the actual factory setting. For a filter LFO exercise, set `lfo_via_amount` to `0` with unit `normalized` to remove dependence on the modulation wheel, then compare a fixed phrase with identical controller events.

## Read, then edit

```json
{
  "command": "get_retro_synth_state",
  "params": {
    "project_ref": "<current project_ref>",
    "target_ref": "<track_ref from the selected row>",
    "options_for": "amp_attack"
  }
}
```

The response includes 22 parameters, their native display and units, an `instrument_ref` and `snapshot_hash`. `options_for` lists exact supported values for one parameter. For example, choose a supported attack time in milliseconds:

```json
{
  "command": "set_retro_synth_parameter",
  "params": {
    "project_ref": "<current project_ref>",
    "target_ref": "<track_ref from the selected row>",
    "instrument_ref": "<instrument_ref from the read>",
    "expected_snapshot": "<snapshot_hash from the read>",
    "param": "amp_attack",
    "unit": "ms",
    "value": 500
  }
}
```

Use the new instrument reference and snapshot hash returned by each successful edit for the next edit. A later state read also replaces the previous reference. References belong to the running server session; obtain fresh state after reconnecting or reopening. If you change the sound manually, read fresh state before another edit.

## Supported controls

| Parameter | Unit or choices |
| --- | --- |
| `osc1_waveform` | `waveform`: Noise, Sawtooth, Square |
| `osc2_waveform` | `waveform`: Triangle, Sawtooth, Square |
| `oscillator_mix` | `normalized`, 0–1 in 0.01 steps |
| `osc2_semitones` | `semitones`, −24–24 in whole steps |
| `osc2_detune` | `cents`, −50–50 in whole steps |
| `filter_enabled` | `bool`, JSON `true` for Active or `false` for Bypass |
| `filter_cutoff` | `normalized`, 0–1 in 0.002 steps; no Hz conversion |
| `filter_resonance` | `normalized`, 0–1 in 0.01 steps |
| `filter_envelope_depth` | `normalized`, −1–1 in 0.01 steps |
| `filter_lfo_depth` | `normalized`, 0–1 in 0.01 steps |
| `lfo_waveform` | `waveform`: Sawtooth Down, Sawtooth Up, Triangle, Rectangle Bipolar, Rectangle Unipolar |
| `lfo_rate` | `Hz` with a numeric value, or `division` with the exact native string |
| `lfo_sync` | `bool`, JSON `true` or `false` |
| `lfo_via_amount` | `normalized`, 0–1 in 0.01 steps |
| `amp_attack`, `amp_decay`, `amp_release` | `ms`, exact native choices |
| `filter_attack`, `filter_decay`, `filter_release` | `ms`, exact native choices |
| `amp_sustain`, `filter_sustain` | `normalized`, exact native choices |

Choosing Square enables that oscillator’s native pulse-width controls. Conductor verifies that the pulse-width value and display stay unchanged through this presentation change; pulse-width editing is not exposed.

The filter type is fixed to **LP 24dB Lush**. Attack, decay and release have different native curves. Some displayed values correspond to several native positions; the setter chooses the first measured position and returns `native_step`. It refuses unsupported values and may offer nearby choices; it never silently rounds the request.

Changing `lfo_sync` converts the rate using Logic's native conversion. Setting `lfo_rate` also selects the corresponding sync mode. Both rows may change together. Read the returned rate instead of assuming the previous value survives conversion.

## Hear the change

On the selected Retro Synth track, use the targeted `logic_tracks.record_sequence` workflow to import a short fixed MIDI phrase. The operation keeps its original imported GM lane as a safety copy and reports that lane separately. Once the target paste is verified, mute or remove the reported source lane using a fresh corroborated track reference before rendering. Use this reproducible phrase at **120 BPM in 4/4**, on MIDI channel 1 with velocity 80:

| MIDI note | Start from bar 1 | Duration |
| --- | --- | --- |
| 48 | 0 ms | 4,000 ms |
| 52 | 4,500 ms | 1,000 ms |
| 55 | 6,000 ms | 1,000 ms |

For a bounce, finish the edits, then use the state read below to close the bound Controls window and return to the project before export. It verifies the final native state and reports `editor_closed:true`, `editor_retained:false` and `ui_restored:false` for that requested layout change. Do not combine `open_editor:true` and `close_editor:true`.

```json
{
  "command": "get_retro_synth_state",
  "params": {
    "project_ref": "<current project_ref>",
    "target_ref": "<track_ref from the selected row>",
    "close_editor": true
  }
}
```

Bounce **1.1.1.1 through 5.1.1.1** as stereo WAV at 48 kHz / 24-bit, with audio tail disabled. This produces an eight-second comparison. Render the same range before and after a parameter edit with identical bounce settings. For a clear first exercise, compare the initialized sound with a 500 ms amplifier attack, or enable the filter in both comparison renders and lower normalized filter cutoff with resonance unchanged. Save and reopen the project, obtain fresh project and track references, and read the instrument again.

A state **A** result requires matching native values, matching read bookends, preserved peer controls and the reported UI policy being satisfied. Preparation intentionally retains a newly opened Controls window; subsequent calls restore the existing viewport. The bookends are not an atomic Logic transaction. A **C** refusal reports no audio write attempt. A **B** result means an action may have taken effect: inspect the sound and read fresh state before deciding what to do next. Never automatically replay an uncertain edit.

For synthesis concepts, see Apple’s [Retro Synth modulation guide](https://support.apple.com/en-ca/guide/logicpro/lgsicb606bce/mac). The supported MCP controls and their native units are listed above.
