# Connect a client to Conductor

Install and start the [managed bridge](install.md) on the Mac that runs Logic. The broker runs under that Mac’s logged-in GUI account in the Terminal permission context. Multiple clients share one serialized Logic session.

## Local Mac client

Set the client’s stdio command to the absolute installed path, with `relay` as its only argument.

```json
{
  "mcpServers": {
    "conductor": {
      "command": "/Users/your-name/Library/Application Support/Ion Cascade Conductor/conductor",
      "args": ["relay"]
    }
  }
}
```

## Client on another computer

Use an SSH host alias you have already configured and verified for the Mac. The relay runs on the Mac through that connection.

```json
{
  "mcpServers": {
    "conductor": {
      "command": "ssh",
      "args": [
        "-T", "-o", "BatchMode=yes",
        "your-mac-host-alias",
        "exec \"$HOME/Library/Application Support/Ion Cascade Conductor/conductor\" relay"
      ]
    }
  }
}
```

For a non-default prefix, point both Mac Terminal and the relay at the `conductor` command in that prefix.

## Check or reconnect

- Once the bridge reports ready, read `logic://system/health`, `logic://project/info` and `logic://tracks` from the client. Compare the project and track names against Logic before editing.
- If the relay says the bridge is unavailable, check the Mac Terminal tab. Start the selected release again if the broker exited.
- If a write was interrupted, inspect the actual project before retrying and fetch fresh target references. A reconnect never replays a request.

The bridge listens on a per-user Unix socket. SSH authentication and host identity are managed by your SSH client.
