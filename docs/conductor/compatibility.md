# Conductor 1.0 compatibility

The support target is the desktop version of Logic Pro on a logged-in Apple silicon Mac. The matrix records the exact combination and workflows tested for this release.

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


## Installation and recovery

| Workflow | Mac mini result |
| --- | --- |
| Clean source install | Built from the extracted source archive in a fresh Swift build directory and installed to an empty prefix. Verified discovery, project identity and native track and MIDI region readback. The logged-in account already had the required macOS permissions. |
| Managed update and rollback | Installed released 0.5.0 source, installed 1.0.0 at the same prefix, rolled back to 0.5.0, then reselected 1.0.0. At each step the same client command reported the selected version and read the disposable Logic session. |
| Bridge recovery | Two simultaneous clients shared the bridge. A duplicate start preserved the running process. During an outage the relay returned before sending a request. Restart and reconnect restored access. |
| Distribution | Versioned source archive and SHA-256 checksums. The tested Swift build used its local ad-hoc signature. |

## Logic workflows

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
