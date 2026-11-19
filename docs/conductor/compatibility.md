# Conductor compatibility

The support target is the desktop version of Logic Pro on a logged-in Apple silicon Mac. The matrix records the qualification host and the workflows verified for each release.

| Layer | Qualification target |
| --- | --- |
| Mac | Apple M2 Pro Mac mini, arm64 |
| macOS | 27.2.1 |
| Logic Pro | Desktop 13.0, build 7801, bundle ID `com.apple.logic10` |
| UI | English Logic controls, visible foreground Arrange, Mixer where required |
| Toolchain | Apple Swift 6.4.2 and system Python 3.9.6 |
| Bridge | Managed per-user install, Terminal GUI launcher, local Unix socket and SSH stdio relay |
| Permissions | Accessibility and keyboard event access in the Terminal context. macOS Automation approval for project commands when requested. |

Intel Macs, other Logic and macOS versions, Creator Studio, other UI languages, and operation without a GUI session are outside this qualification.


## 1.16 Retro Synth Analog

The explicit retained Controls workflow passes native parameter, refusal, interruption, reopened/reconnected MIDI and controlled render checks on the recorded host. Keep Controls open between sound-design operations and close it deliberately before export.

| Workflow | Bounded profile |
| --- | --- |
| Instrument state | Retro Synth on one selected, uniquely named software instrument track, Inspector visible, saved project stopped in the foreground. Existing editor must be unlinked. |
| Initialization | Native Initialize Setting, checked against all 83 observed Controls rows. The user's saved default is unchanged; the initialized filter is bypassed. Enable it explicitly for filter sound shaping. |
| Sound design | 22 controls for oscillator waveforms/mix/tuning, explicit filter Active/Bypass, normalized cutoff/resonance/depths, amplifier and filter ADSR, and LFO waveform/rate/sync/via amount. |
| Targeting | Current project and physical track references, plus an issued instrument reference and expected snapshot for each parameter edit. Bare indices are refused. |

The synthesis engine is **Analog** and the filter is **LP 24dB Lush**. Other engines, filter-type changes, global/FX parameters, preset loading and Alchemy sound-design controls are outside this profile. Native ADSR and LFO displays are quantized; request one advertised native choice. Cutoff is normalized, with no claimed Hz conversion. LFO Sync and Rate can change together through Logic's native conversion. Read bookends and preserved peers provide bounded verification, not an atomic host transaction.

Logic can normalize the synchronized 1/8 rate from raw position 88 to 90 when reopening while retaining the displayed division. That measured transition is recorded explicitly. Obtain fresh state after reopening; do not reuse the previous snapshot. Render comparisons measure each stereo channel’s power independently before averaging, so channel phase cannot cancel the measured energy. PCM identity is not promised.

Two Logic processes aborted during qualification, after 30 hours 40 minutes and 2 hours 34 minutes respectively. Both reports end in AttributeGraph table growth through SwiftUICore/AppKit; their cause is undetermined. Repeated automatic editor recreation showed memory growth and is excluded from ordinary reads and edits. The explicit retained workflow passed 30 edits and 10 reads with preserved native values, followed by the complete native sequence. The longer audio sequence used a controlled process handoff near the test memory cap, with the exact saved state and all 83 native rows verified afterward. This is a bounded mitigation for [#65](https://github.com/ion-cascade/conductor/issues/65), not a root-cause fix or long-session stability guarantee. The [qualification observation](../observations/2026-11-19-retro-synth-retained-controls-qualified.json) preserves those limits.

If Logic does not expose positive native folder selection during a MIDI read, Conductor refuses before Save and closes only its owned panel. The shared Save-panel adapter now reads the browser’s canonical columns. After the fix, MIDI reads and exports passed after closing Controls, after a stereo bounce, and after project reopening and bridge restart. Earlier refusals remain retained; no automatic export replay is added.

[Control matrix and beginner workflow](retro-synth.md)

## 1.15 Surround and spatial delivery

| Workflow | Qualified Logic Pro 13.0 profile |
| --- | --- |
| Surround bounce | Saved, stopped foreground project with native Spatial Audio Off, Surround Format 5.1 (ITU 775), and 48 kHz. Explicit `channel_layout:"5.1"` selects Surround Bounce, interleaved 24-bit WAVE, Normalize Off and no dither. |
| Dolby Atmos ADM BWF | Saved, stopped foreground project with Dolby Atmos, a 7.1.2 bed and 48 kHz. Export the native whole Project as 24-bit ADM BWF with one named ten-channel bed and one named mono object. Supply the exact expected frame count, including Logic's export padding or tail. |
| Artifact attribution | The six-channel bounce uses WAVE order L, R, C, LFE, Ls, Rs. ADM readback checks the CHNA → track → stream → channel graph against AXML pack and object membership and reports each channel's native name. |
| Destination protection | ADM publishes only a verified staged file to a new filename. Unverified exports retain their private staging directory. Existing destinations are preserved. |

Qualification uses separate synthetic channel-identification signals and an independent mono object. The four-second surround fixture produces 192,000 frames, with all six channels matching the input samples. The ADM fixture produces 196,608 frames. Its six active bed channels and mono object match the source signals within two 24-bit quantization steps; unused bed channels and the 4,608-frame padding are silent. Both workflows are checked after project reopening and bridge restart.

Other layouts, sample rates, bit depths, multiple objects, selected-range ADM exports and spatial project configuration are outside this profile. Configure the project in Logic before exporting. Omitting `channel_layout` retains the stereo bounce profile. Typed PCM bounce resume continues to refuse reuse when original settings provenance is unavailable and preserves existing bytes. Selected-stem delivery retains its separately qualified resume behavior.

[Surround and ADM parameters](../API.md#spatial-delivery)

## 1.14 Live Loops and notation

| Workflow | Scope on Logic Pro 13.0 |
| --- | --- |
| Live Loops | Read a bounded grid with numbered scenes and unique track names. Start or stop the selected looping Start/Stop cell with 1 Bar grid quantization and the transport already running. |
| Score | Read visible pitches, positions and rests for one selected MIDI region on one staff. Export one part as MusicXML to a new filename and read back the written measures. |

Capture to Arrange, scene writes and Score Editor mutations are separate qualification work.

## 1.13 Composition, Browser and drum patterns

| Workflow | Verified scope on Logic Pro 13.0 |
| --- | --- |
| Chord Track | Read up to 32 whole-bar events. In a three-event progression, changed C major to C minor at bars 3–4, preserved the first and last events, refused a stale chord identity and verified the saved progression after reopening. Writes are limited to standalone natural-root major or minor chords. |
| Keyboard Player | Read the selected region, track, Complexity and Intensity and verified the native Pitch Source switch between region chords and the Chord Track. The region-source bounce was PCM-identical across the global edit. The Chord Track source reflected the edit and its reopened bounce matched the saved result. |
| Unified Browser | Searched the native Instruments list view. Applied Hi-Hat Open 2 - Topaz to one selected track, checked the Inspector, retained the other three tracks and region layout, and verified the saved patch after reopening. |
| Drum Machine Designer | Read three complete 16-step rows. Edited two cells, checked all 46 peers, refused a stale snapshot and verified the saved grid after reopening. The edited and reopened exact-range bounces had identical PCM. |

The Browser commands use Logic's ranked search and local instrument patch replacement. Patch merging, Find Similar, content downloads, Apple Loop and sample placement, and plug-in presets are outside the verified Browser workflow. Velocity, Chance, repeat count and tie state are read-only. Session Player types other than Keyboard Player and direct performance-parameter writes are outside this qualification.

## 1.12.1 Native Flex and take-comp qualification

These checks use disposable Logic Pro 13.0 build 7801 projects and compare the saved project with a fresh native read and an independent stem render after reopening.

| Workflow | Verified on the Mac mini |
| --- | --- |
| Flex Time | In Automatic (Polyphonic) mode, the marker for source sample 44,113 moved from 1,920 to 2,880 ticks relative to the region start. The first onset moved from 1.00 to 1.49 seconds and the two later onsets stayed within 10 ms of the control. The source WAV checksum and the other regions’ identities and bounds matched. |
| Flex Pitch | Logic's MIDI projection identified three notes. The selected note at exported tick 1,440 (480 PPQ) moved from MIDI 57 to 60. The other notes and event timing matched. The rendered note changed from 220 Hz to approximately 261.6 Hz and the source WAV checksum matched the control. |
| Take comp | Switched a saved 0.5–1.0 second section from the 731 Hz take to the 967 Hz take. Saved readback retained the other four segment ranges and take assignments, and the reopened stem matched those assignments. The qualification refused a changed saved snapshot, a different project identity and an ambiguous take in a synthetic negative case. |

The marker and comp snapshot checks use build-specific saved data. The Flex Pitch check uses Logic's native MIDI projection. These are qualification procedures for disposable projects. General live Flex and take-comp editing through MCP remains outside the qualified command set.

## 1.12 Smart Tempo analysis readback

On the qualified desktop Logic 13 host, analyze an ordinary audio region in Logic, close the Smart Tempo Editor, then select only that region in Arrange. Use a fresh region reference with `logic_project.get_region_smart_tempo`. Conductor briefly opens the bound editor, reads the tempo in BPM and the first downbeat in source samples, then verifies that the editor closed and the original selection is intact.

The read requires the first downbeat to be exposed in the native editor. Tempo analysis, corrections and time-map changes remain manual.

## 1.11.1 Airwindows PurestGain

PurestGain 1.0.0 is qualified for parameter readback on the Mac mini as a mono Audio Unit. Get the occupied insert's current reference from `logic_plugins.get_inventory` and pass it to `get_host_parameter_manifest`. The Controls view reports Gain in dB and Slow Fade as a unitless value. Read `value_description` for the formatted value. The raw AX slider integer has separate units.

Conductor checks both native views of a slider before reporting its value. A mismatched or unrecognized layout returns a refused row. PurestGain's parameter writes remain unsupported.

## 1.11 Bounded automation and mono Gain

| Workflow | Mac mini scope |
| --- | --- |
| Track Volume envelope | Add one control point inside a matched flat segment and edit its value in the native Event List. The workflow exposes piecewise envelope editing. Logic's canvas curve handles remain outside this adapter. |
| MIDI region Expression | Change the value of one identified existing CC11 event in an ordinary MIDI region. Match the native region, channel, controller and position, and verify peer events and saved readback. |
| Stock Gain automation | Read and edit an existing Gain automation point for the qualified fourth audio insert. Bind the insert, selected lane and native event address. |
| Stock mono Gain | Write −6.0 to 0.0 dB in 0.1 dB steps with the exact Controls editor manually opened and focused. Phase Invert stays read-only. |
| Third-party Audio Units | The registered Mac mini catalogue contained Apple units only. |

[Automation and plug-in commands](../API.md)

## 1.10 Track automation and stock plug-ins

| Workflow | Mac mini qualification |
| --- | --- |
| Move one Volume point | An exact 120-tick move preserved the point value and three other Volume points. The new position survived save, close and reopen with a fresh MCP connection. Stale references and stale neighbor values refused. |
| Volume envelope | The 48 kHz stereo control and edited renders differed by about +2.05 dB at the beginning. They were sample-identical from frame 3360 onward. The edited render used the owned native Save panel after Conductor's bounce guard refused submission. |
| Curve shapes and region automation | The tested curve canvas exposed a single Accessibility control. The region Event List exposed converted points as generic Fader events. Both need independent readback before edits can be supported. |
| Plug-in parameter automation | Logic exposed the specific Gain lane in the automation menu and showed two new Gain events after native creation. Verification of a sweep, exact insert binding at write time and saved readback remains open. |
| Stock inserts | The existing Channel EQ adapter reads eight bands and qualifies the bound Peak 1 gain write. Mono Gain retains level and phase readback. The native Gain control changed and persisted in a scratch probe, but the MCP setter failed its editor custody checks. |
| Third-party Audio Units | The Mac mini's registered Audio Unit catalogue contained Apple manufacturers only. Third-party read or write compatibility requires qualification against a specific installed unit. |

[Track automation commands](../API.md#move-a-track-volume-point)

## 1.9 Drum kit pieces and MIDI note editing

| Workflow | Supported desktop Logic 13 scope |
| --- | --- |
| Individual kit pieces | Use one selected ordinary audio region with a uniquely named source in the saved project package. The adapter selects the native kit-pieces preset and verifies six named AIFF files and their arrangement below the Drums stack. Keep the project saved for persistence. |
| In-place MIDI notes | Use one selected visible ordinary region and its unfiltered Event List with absolute start and elapsed length. One uniquely addressed note can change pitch, onset, length and velocity. The first adapter covers 24 materialized events and a maximum of 48 verified native actions per request. |
| Refusals | The workflows require fresh references. Expected MIDI note fields must agree, and ambiguous note identities refuse before an edit. Unsupported layouts remain explicit. |

[Stem Splitter and MIDI command requirements](../API.md)

## 1.8.1 Native write qualification

The operation-bound write matrix covers 14 writes across ten disposable fixture cases. On the supported Mac mini setup it checks named targets and neighboring state, including stale expectations and references where supported. Persistence checks acquire fresh references after closing and reopening the project. The region parameter and sidechain cases include measured bounces.

The release artifact records results individually. The matrix uses the fixtures and preconditions described in the [qualification runner](../../Scripts/qualification_writes/README.md). Support for each write is bounded by its documented native control, selection and project requirements.

## 1.8 Audio-region gain and fades

| Workflow | Mac mini qualification |
| --- | --- |
| Exact gain | Verified native Inspector values at +12.0, −24.0 and −6.0 dB on a referenced audio region. The 48 kHz stereo bounce measured the −6.0 dB change against a control. |
| Fade times | Verified standard zero-curve fade-in and fade-out settings by reading the Inspector immediately and after reopening. A 500 ms fade-in and a 1000 ms fade-out matched their linear envelopes against the gain-only bounce. |
| Selection and persistence | Tested with two audio tracks named `Twin`. Refused the unselected region, a two-region selection, stale values and stale references. Compared the neighboring tone, all four region boundaries and two source WAV checksums. |

The workflow uses a saved project in stopped foreground Arrange with a single ordinary audio region selected and the required Inspector section expanded. [Audio-region commands](../API.md#set-audio-region-gain-and-fades)

## 1.7 Compressor sidechain

| Workflow | Mac mini qualification |
| --- | --- |
| Immediate native readback | Changed a referenced stock Compressor between Internal and `Bus 2 ← Audio 1`. The original editor popup could remain stale. A fresh editor on the same insert agreed with the native checked menu before any save or project reopen. |
| Keyed and control renders | In matched 44.1 kHz stereo WAV bounces of a dedicated key and piano fixture, the piano’s measured low-band level fell by about 2.7 dB during the key. The independently measured 2351 Hz key tone stayed steady. |
| Persistence | Saved, closed and reopened the project through a fresh connection, then verified the same insert’s bus selection using a fresh reference. |

The tested route uses an English Logic 13 Mixer with one stock Compressor on the target strip, a stopped transport, and one labelled bus source. [Compressor sidechain commands](../API.md#set-a-stock-compressor-sidechain-source)

## 1.6 Verified mix delivery

| Workflow | Mac mini qualification |
| --- | --- |
| Mix and selected stems | On a 12-track Logic project with four populated tracks, exported the stereo mix, two distinct tracks named `Twin`, and the piano. Independent PCM analysis matched the stem signals to their selected tracks. A separate stem export verified that the omitted track was audible, and its tone was present in the stereo mix. |
| Musical range and alignment | The native cycle ran from `1.1.1.1` to `3.1.1.1`, with 120 BPM at bar 1 and 60 BPM at bar 2. The four 24-bit WAVs each had 264,600 frames at 44.1 kHz. A signal beginning at one second matched in the corresponding stem and mix on a 20 ms measurement grid. |
| Read-only status | Verified a 1.4 receipt and the partial 1.6 receipt with the project closed. Detected changed and missing WAVs, a changed bundled source, changed expected settings, and an invalid receipt. Status preserved the valid receipt bytes. |
| Resume after interruption | Stopped the test bridge after the first stem committed. Reopened the same project, obtained fresh references, and confirmed that resume retained the first file’s checksum and rendered the two remaining stems and stereo mix. The configured bridge repeated the complete workflow. |

The combined delivery qualifies 24-bit WAVE at the native project sample rate, with a shared exact range and both tail options off. The Mac mini qualification used 44.1 kHz. The stereo mix follows the main output, including its routing and processing. [Mix delivery and recovery](../API.md#deliver-a-stereo-mix-with-selected-stems)

## 1.5 Production editors

| Workflow | Mac mini qualification |
| --- | --- |
| Step Sequencer | On a saved Drum Machine Designer pattern, read the native grid addresses and selected step values. Toggled Kick 1 step 2, verified velocity 64, checked Kick 1 step 1 and Snare 1 step 2, then read the saved step again after reopening. |
| Velocity | The Step inspector exposed the selected velocity. The tested native grid increment, inspector numeric entry and inspector drag did not produce the requested value. Velocity remains read-only. |
| Flex Time | With Automatic (Polyphonic), a native marker gesture shifted a synthetic transient from 1.00 to 1.49 seconds in a 44.1 kHz render. The timing persisted after reopening. The source WAVE checksum and three neighboring region identities and bounds matched. The tested Accessibility paths exposed the region and algorithm without a readable marker position, so Flex Time editing is outside the MCP API. |

The Step Sequencer adapter covers the split editor’s visible 16-step grid with one pattern region and one step selected, the Step inspector open, and preview, recording and Mono Mode off. [Step Sequencer commands](../API.md#inspect-and-toggle-one-pattern-step)


## 1.4 Selective stem delivery

| Workflow | Mac mini qualification |
| --- | --- |
| Selective attribution | Exported two tracks named `Twin` and one piano track by their fresh Arrange references. Independent PCM analysis matched each file to its track. A separate export confirmed the omitted track was audible. |
| Exact musical range | Native Cycle locators read `1.1.1.1`–`3.1.1.1`, with 120 BPM at bar 1 and 60 BPM at bar 2. Each selected 24-bit WAVE file measured 264,600 frames at 44.1 kHz, or six seconds. |
| Audio tails | Logic accepted Include Audio Tail with Cycle Range Only. This fixture still produced 264,600 frames for each track. Tail length depends on Logic’s native export behavior. |
| Inserts and automation | With Channel EQ, Compressor and ChromaVerb enabled, the native Volume/Pan Automation option changed the rendered stereo balance while preserving the exact two-second range. Native inventory confirmed all three inserts remained enabled. |
| Interrupted resume | Stopped the test bridge after the first stem was recorded, reopened the saved project, and connected again. Conductor verified and reused the original WAV and exported only the two missing stems. Stale references, a changed range, changed automation settings and an altered WAV were refused. |
| Compressor sidechain feasibility | A separate key track exposed `Bus 2 ← Audio 1` in the stock Compressor. The immediate read still showed `Internal`. The saved project showed `Bus 2` after reopening. [Issue #28](https://github.com/ion-cascade/conductor/issues/28) remains open. |

The range adapter requires active Cycle and the Custom control-bar display with exact native locator readback. Resume requires the same saved project, selected track order, output root and export settings. [Selective stem parameters](../API.md#selective-stem-delivery)

## 1.3 Pan automation and insert bypass

| Workflow | Mac mini qualification |
| --- | --- |
| Absolute track Pan | With Logic’s Beats display at `2.1.1.1`, seeded Pan at the initial anchor `1.1.1.1` and at the playhead. Logic’s Event List read back `74` at `1.1.1.1` after editing and `64` at `2.1.1.1`. The existing Volume events and the adjacent track’s empty automation list were preserved. Reopened the project through a fresh connection and checked both the positions and displayed values. |
| Stock insert bypass | Bypassed and re-enabled each of two Compressors on the same strip by its occupied slot reference. Channel EQ and ChromaVerb stayed active. The already-correct request returned without pressing a control. Reopened through a fresh connection, saw the saved bypass state and verified that the retired reference was rejected before writing. |
| Compressor sidechain | The control continued to read `Internal` immediately after the Input 1 press, then showed `Input 1` after reopening. The tested Bus 1 send and return were visible in the Mixer, while the exact Compressor menu offered the physical inputs. A keyed/control render is pending. Sidechain writes are outside the 1.3 surface. |
| Managed connection | Installed the source build and reconnected through the configured SSH stdio launcher. |

The Pan adapter requires Logic’s visible absolute track Pan lane in Read mode. Creation uses a single selected track, an empty Pan lane and the full Beats playhead display. The bypass adapter requires a readable Mixer insert chain and stopped transport. [API reference](../API.md)


## 1.2 arrangement and bounce

| Workflow | Mac mini qualification |
| --- | --- |
| Arrange discovery | Sampled 25 viewport positions across both axes on a 21-track project with repeated region names, a hidden track and a collapsed six-track stack. The scan reported partial coverage and restored the starting view. Collapsed lanes remained undisclosed. |
| Reference-bound edit | Moved and trimmed an offscreen MIDI region and a lower audio region. Native readback checked the target, other observed regions and the restored viewport. Reopened both saved edits through a fresh connection. Stale references refused before editing. |
| Constant-tempo bounce | Bounced the edited audio at `55.3.1.1`–`57.1.1.1`. Independent decoding counted 144,000 stereo frames at 48 kHz. The sampled waveform matched the portion of the synthetic source remaining after the left trim. |
| Tempo-change bounce | Logic’s Tempo List showed 120 BPM at bar 1 and 60 BPM at bar 2 after reopening. Bounced `1.2.1.1`–`2.3.1.1`. Independent decoding counted 168,000 stereo frames at 48 kHz and identified the expected pitches on each side of the change. |
| Delivery guards | A native Open dialog and descending positions produced zero files. An occupied destination was preserved byte for byte. The Swift executor test separately exercised a wrong-document identity readback. |
| Managed connection | Installed 1.2.0 from the versioned source and repeated the workflow through the configured SSH stdio launcher. |

The verified edit and explicit-range path uses the English Logic 13 interface and a 4/4, 1/16 position grid. To edit an ordinary audio or MIDI region, the scan must obtain a writable position in Arrange that fits the region and its requested edit. Snap and zoom affect how precisely Logic can apply a gesture. [Arrange and bounce parameters](../API.md#sample-arrange-viewports-and-edit-one-region)

## 1.1 Logic workflows

| Workflow | Qualification on a 21-track project |
| --- | --- |
| Hidden tracks and collapsed stacks | With the Arrange header rail focused, inspection observed 14 → 21 → 14 rows across Hide View and a six-child summing stack. It preserved the original selection and restored both controls. The scrollable rail remained partial despite matching the project’s track count. With Arrange workspace focus, inspection exposed the hidden row, restored Hide View and left the stack collapsed. |
| Exact track targeting | Two tracks shared a name and one had its Hide flag set. A fresh reference changed and restored only that track’s volume. The visible duplicate stayed at its original value. Name-only selection and retired references refused before editing. |
| Mixer routing and scalars | Verified Stereo Out → No Output after replacement of the selected native strip. The neighboring strip stayed on Stereo Out and the retired reference refused. Volume, pan, mute and solo each changed and restored on the fresh strip. Other layouts and redraws without native continuity evidence can return an unverified result. |
| Explicit PCM bounce | Verified two 48 kHz, 16-bit stereo WAVE exports of the 256-second range shown in Logic, with 12,288,000 frames each. Covered a Mixer-to-Arrange transition, reconnect through the configured SSH launcher, a real Open dialog refusal and no overwrite on collisions. The wrong-document refusal was also exercised in the Swift executor tests. |
| Managed install | Built the source distribution in the Mac mini’s Swift toolchain, selected 1.1.0 with the managed launcher and reconnected through the existing SSH client command. |

## 1.0 installation and recovery

| Workflow | Mac mini result |
| --- | --- |
| Clean source install | Built from the extracted source archive in a fresh Swift build directory and installed to an empty prefix. Verified discovery, project identity and native track and MIDI region readback. The logged-in account already had the required macOS permissions. |
| Managed update and rollback | Installed released 0.5.0 source, installed 1.0.0 at the same prefix, rolled back to 0.5.0, then reselected 1.0.0. At each step the same client command reported the selected version and read the disposable Logic session. |
| Bridge recovery | Two simultaneous clients shared the bridge. A duplicate start preserved the running process. During an outage the relay returned before sending a request. Restart and reconnect restored access. |
| Distribution | Versioned source archive and SHA-256 checksums. The tested Swift build used its local ad-hoc signature. |

## 1.0 Logic workflows

| Workflow | Verified case and scope |
| --- | --- |
| Project and MIDI | Created, saved, reopened and read a native Logic project. Imported four Studio Grand notes at bar three, checked onset, duration, pitch, velocity and channel from Logic, and reproduced the previous release’s stereo PCM sample for sample. |
| Stock Compressor | Applied the factory Piano preset to the intended insert and checked its name after saving and reopening. |
| Track Volume | Read exact region-border positions, updated both selected points, and verified the four point values after reopen. The create path needs an enabled empty Volume lane in Read mode. |
| Mixer routing | Read the occupied Bus 1 send and Aux return, changed the send level and restored it. Logic can redraw a strip after an output change. The direct output in this run needed independent readback after the setter returned an unverified result. |
| Stereo bounce | Verified 48 kHz/16-bit WAVE, 44.1 kHz/24-bit AIFF, and 96 kHz/24-bit WAVE. The two-second range extended to 3.715 seconds with tail capture. A collision preserved the original file, and a read-only destination was refused. |
| Aligned per-track export | Two named 44.1 kHz/24-bit WAVE files had a common frame count and identical PCM across repeated exports. Their summed six-second range matched the directly routed Stereo Out reference to −131.8 dB relative RMS. The piano stem retained its decay after the MIDI region. Shared returns and output processing can change the mix independently of these track files. |
| Native Stem Splitter | Applied Separate All Stems to one referenced audio region in a saved project. Six stereo assets and regions, their common bounds, and the muted source persisted after save and reopen. These assets are separation estimates. |

See the [delivery API](../API.md#explicit-stereo-pcm-bounce) for the exact parameter shapes and prerequisites.
