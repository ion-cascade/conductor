# Connect to a remote Mac

The bridge runs on the Mac in an application context that has macOS Accessibility permission. MCP clients connect through an existing SSH configuration. Multiple clients share one Logic session and one serialized upstream server; they do not get separate projects.

## Mac: start from Terminal

Build Conductor and open a disposable Logic project. In the Mac's Terminal, with Accessibility enabled for Terminal:

```bash
export LOGIC_MCP_EXECUTABLE="$HOME/Projects/conductor/.build/release/LogicProMCP"
export LOGIC_PRO_BUNDLE_ID=com.apple.logic10
export LOGIC_MCP_DIRECT_TOOLBAR=1
export LOGIC_MCP_BOUNDED_MIXER_POLL=1
export LOGIC_MCP_DIRECT_MIXER_PANEL=1
export LOGIC_MCP_LOGIC13_TRACKS=1
export LOGIC_MCP_COHERENT_READS=1
/usr/bin/python3 "$HOME/Projects/conductor/tools/logic_bridge_server.py"
```

Adjust the checkout path to your installation. The broker uses an owner-only directory and Unix socket under `~/Library/Application Support/Logic MCP Bridge`. It keeps one server process alive across client disconnects. Stop the broker deliberately when no operation is in flight.

For persistent use, run that same Terminal-context bootstrap at login. A direct SSH launch has a different macOS permission context; an SSH connection alone does not prove GUI access. This repository does not grant permissions or install a login item automatically.

## Client computer: use the SSH relay

Use an SSH host alias you have already verified and configured for your Mac. A generic MCP configuration is:

```json
{
  "mcpServers": {
    "conductor": {
      "command": "ssh",
      "args": [
        "-T", "-o", "BatchMode=yes",
        "your-mac-host-alias",
        "/usr/bin/python3 $HOME/Projects/conductor/tools/logic_bridge_relay.py"
      ]
    }
  }
}
```

The relay waits up to eight seconds for startup before sending protocol bytes. It never reconnects and replays an attempted action. If the upstream server exits, reconnect and reacquire target references.

The broker bounds client and queue counts, serializes requests, translates request IDs, negotiates initialization, forwards notifications and handles cancellation. A disconnected client's already-dispatched operation is allowed to reach a terminal response; its writes are not repeated for another client.

Launch the broker before connecting. For a custom socket directory, set `LOGIC_MCP_BRIDGE_DIR` identically on the Mac broker and relay.
