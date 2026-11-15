# Conductor 1.0 compatibility

The support target is the desktop version of Logic Pro on a logged-in Apple silicon Mac. The matrix records the exact combination and workflows tested for this release.

| Layer | Qualification target |
| --- | --- |
| Mac | Apple M2 Pro Mac mini, arm64 |
| macOS | 27.2.1 |
| Logic Pro | Desktop 13.0, build 7801, bundle ID `com.apple.logic10` |
| UI | English Logic controls, visible foreground Arrange, Mixer where required |
| Toolchain | Apple Swift 6.4.2 and system Python 3 |
| Bridge | Managed per-user install, Terminal GUI launcher, local Unix socket and SSH stdio relay |
| Permissions | Accessibility and keyboard event access in the Terminal context. macOS Automation approval for project commands when requested. |

Intel Macs, other Logic and macOS versions, Creator Studio, other UI languages, and operation without a GUI session are outside this qualification.
