# Developing Conductor

Conductor is the full Swift server. The Python broker is an optional transport for reaching the same running Logic session from several clients.

| Path | Responsibility |
| --- | --- |
| `Sources/LogicProMCP/Server` | MCP lifecycle, command handling, deadlines and mutation ownership |
| `Sources/LogicProMCP/Channels` | Native control and observation channels |
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

The 0.2 candidate passed 245 focused Swift tests covering track selection, MIDI import verification, transport readback, project population, and per-track export completion. Native checks remain separate: use a disposable project, exact build identity and independent readback. Export qualification must inspect the actual resulting audio file.

## Distribution

Conductor publishes a verified source archive and checksums. The [managed Mac installer](install.md) builds from that archive. Historical distribution workflows remain under `docs/upstream/` for reference.

The Swift module and executable retain `LogicProMCP` names for compatibility. The runtime MCP identity and repository branding are Ion Cascade Conductor.

## Source lineage

The adoption baseline is `dc80ca7329b35a7cc1749823209aa6cb7ffb3cd8` from MongLong0214/logic-pro-mcp. Original history and the MIT licence are retained. See the root NOTICE for attribution.
