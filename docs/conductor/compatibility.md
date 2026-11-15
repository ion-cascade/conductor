# Conductor 1.7 compatibility

The support target is the desktop version of Logic Pro on a logged-in Apple silicon Mac. The matrix records the Mac mini used to qualify Conductor 1.7 and the checks from earlier releases.

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
