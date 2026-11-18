# Developing Conductor

Conductor is the full Swift server. The Python broker is an optional transport for reaching the same running Logic session from several clients.

| Path | Responsibility |
| --- | --- |
| `Sources/LogicProMCP/Server` | MCP lifecycle, command handling, deadlines and mutation ownership |
| `Sources/LogicProMCP/Channels` | Native control and observation channels |
| `Sources/LogicProMCP/Instruments` | Qualified instrument profiles, native readback and guarded sound-design edits |
| `Sources/LogicProMCP/Accessibility` | Bound macOS Accessibility selectors and controls |
| `Sources/LogicProMCP/State` | Cache, refresh coordination and target references |
| `Sources/LogicProMCP/Projects` | Project export planning, execution and artifact verification |
| `Tests/LogicProMCPTests` | Swift unit and behavioral tests |
| `tools/logic_bridge_server.py` | Shared, serialized Mac broker |
| `tools/logic_bridge_relay.py` | SSH stdio-to-socket relay |

## Validation

Run the Python transport suite with:

```bash
python3 -m unittest discover -s tools -p 'test_*.py' -v
```

Build the native server with `swift build -c release`. Swift dependencies and native frameworks require a suitable macOS toolchain.

The inherited Swift suite includes a mixture of deterministic, source-contract, environment-dependent and live tests. Some test helpers exist only in debug builds. A filtered release test invocation is not a claim that the entire upstream suite passed.

After preparing the debug tests with `swift test list`, run `bash Scripts/release-preflight.sh` for the operation registry, parameter/schema, workflow, invariant and qualification censuses before the longer suites. Retain the complete test inventory and prove that any sharded run covers its union exactly and preserves the previous release's test identities and parameter cases. Keep live GUI qualification separate from suites that may activate Logic. Record actual counts, opt-in skips and results in that release's qualification receipt.

Native checks use disposable projects, exact source/binary identity and independent readback. Verify saved values after project reopening and bridge restart. Inspect resulting audio files and measure the intended changes with matched controls.

## Distribution

Conductor publishes a verified source archive and checksums. The [managed Mac installer](install.md) builds from that archive. Historical distribution workflows remain under `docs/upstream/` for reference.

Verify installed delivery through the MCP client’s configured launcher or SSH relay. Check the reported version, selected installation and executable checksum, then repeat the native read/edit/render workflow through that connection. Stop owned candidate bridges before starting the selected installation, retain its rollback release and confirm that only the intended server owns the MIDI endpoints. Close owned Terminal helpers after verification.

The Swift module and executable retain `LogicProMCP` names for compatibility. The runtime MCP identity and repository branding are Ion Cascade Conductor.

## Source lineage

The adoption baseline is `dc80ca7329b35a7cc1749823209aa6cb7ffb3cd8` from MongLong0214/logic-pro-mcp. Original history and the MIT licence are retained. See the root NOTICE for attribution.
