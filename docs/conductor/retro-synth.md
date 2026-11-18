# Retro Synth sound design

Conductor 1.16 provides a bounded Analog profile for Retro Synth on English Logic Pro 13.0, build 7801. Alchemy, the other Retro Synth engines and unlisted parameters remain outside this profile.

Open a saved disposable project, load Retro Synth on one uniquely named software instrument track, select that track and leave its Inspector visible. Stop playback and recording. Close other plug-in windows and dialogs. The Retro Synth window must be unlinked if already open. Conductor opens and closes an editor it acquires, or restores the view and scroll position of an existing editor.

## Start with a native setting

Read `logic://project/info` and `logic://tracks` for the current `project_ref` and the track's `target_ref`. Both references must belong to this server session and the current saved project.

`logic_plugins.initialize_retro_synth` calls Logic's **Initialize Setting**. It replaces the current sound, so use it deliberately on your test track:

```json
{"command":"initialize_retro_synth","params":{"project_ref":"<current project_ref>","target_ref":"<Retro Synth track target_ref>","confirmed":true}}
```

This verifies the complete initialized Controls table rather than treating the preset name as proof. It does not change your saved default setting.

## Read, then edit

```json
{"command":"get_retro_synth_state","params":{"project_ref":"<current project_ref>","target_ref":"<track target_ref>","options_for":"amp_attack"}}
```

The response includes 21 parameters, their native display and units, an `instrument_ref` and `snapshot_hash`. `options_for` lists exact supported values for one parameter. For example, choose a supported attack time in milliseconds:

```json
{"command":"set_retro_synth_parameter","params":{"project_ref":"<current project_ref>","target_ref":"<track target_ref>","instrument_ref":"<instrument_ref from the read>","expected_snapshot":"<snapshot_hash from the read>","param":"amp_attack","unit":"ms","value":500}}
```

Use the new instrument reference and snapshot hash returned by each successful edit for the next edit. A later state read also replaces the previous reference. References expire on reconnect. If you change the sound manually, read fresh state before another edit.

## Supported controls

| Parameter | Unit or choices |
| --- | --- |
| `osc1_waveform` | `waveform`: Noise, Sawtooth, Square |
| `osc2_waveform` | `waveform`: Triangle, Sawtooth, Square |
| `oscillator_mix` | `normalized`, 0–1 in 0.01 steps |
| `osc2_semitones` | `semitones`, −24–24 in whole steps |
| `osc2_detune` | `cents`, −50–50 in whole steps |
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

The filter type is fixed to **LP 24dB Lush**. Attack, decay and release have different native curves. Some displayed values correspond to several native positions; the setter chooses the first measured position and returns `native_step`. It refuses unsupported values and may offer nearby choices; it never silently rounds the request.

Changing `lfo_sync` converts the rate using Logic's native conversion. Setting `lfo_rate` also selects the corresponding sync mode. Both rows may change together. Read the returned rate instead of assuming the previous value survives conversion.

## Hear the change

On the selected Retro Synth track, use the targeted `logic_tracks.record_sequence` workflow to import a short fixed MIDI phrase. Render the same exact range before and after a parameter edit with identical bounce settings. For a clear first exercise, compare the initialized sound with a 500 ms amplifier attack, or lower normalized filter cutoff with resonance unchanged. Save and reopen the project, obtain fresh project and track references, and read the instrument again.

A state **A** result requires matching native values, matching read bookends, preserved peer controls and successful UI restoration. The bookends are not an atomic Logic transaction. A **C** refusal reports no audio write attempt. A **B** result means an action may have taken effect: inspect the sound and read fresh state before deciding what to do next. Never automatically replay an uncertain edit.
