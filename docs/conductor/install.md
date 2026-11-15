# Install Conductor on the Mac that runs Logic Pro

The GitHub release provides source code and checksums. The installer builds the release on your Mac and stores the executable and its helpers together. It uses your account and keeps the previous release for rollback.

## Install from a release

1. Install the Apple command-line tools or select your Swift toolchain. Open Terminal and check `swift --version`.
2. Download the **versioned source archive** and **SHA256SUMS** from the same [Conductor release](https://github.com/ion-cascade/conductor/releases/latest). From that download directory, verify the source before extracting it.

   ```bash
   grep 'source.tar.gz$' SHA256SUMS | shasum -a 256 -c -
   ```

3. Extract the verified archive. From the extracted directory run:

   ```bash
   ./Scripts/install.sh
   ```

4. In Mac Terminal, start the bridge in its own tab and wait for `shared bridge ready`.

   ```bash
   conductor="$HOME/Library/Application Support/Ion Cascade Conductor/conductor"
   "$conductor" status
   "$conductor" start
   ```

The install path is configurable with `--prefix /absolute/path`. Run the `conductor` command from that same prefix in subsequent steps. The GUI session and permissions are prerequisites for live Logic control.

## Connect and check permissions

Keep the bridge running in Mac Terminal. Open a disposable Logic project and connect a client over [the local or SSH relay](remote-bridge.md). Read `logic://project/info` and `logic://tracks` and compare them with the open project. A successful handshake proves connectivity. Project and track readback checks whether the launch context can see Logic.

If macOS reports an Accessibility problem, check **System Settings → Privacy & Security → Accessibility** for the application that starts Conductor. In this setup it is Terminal on the Mac that runs Logic. Run `"$conductor" doctor` in that same Terminal context. Project lifecycle operations can also need Automation access to Logic Pro and System Events. Check the app named by the macOS prompt under **Privacy & Security → Automation**. [Apple’s Accessibility permissions guide](https://support.apple.com/guide/mac-help/allow-accessibility-apps-to-access-your-mac-mh43185/mac)

## Update or roll back

Finish any running operation and disconnect clients. Stop the bridge in its Terminal tab with Control-C. Verify and extract the new source release, run its `./Scripts/install.sh` with the same prefix, then use `status` and `start`. The client command stays the same.

To return to the immediately previous managed release:

```bash
"$conductor" rollback
"$conductor" status
"$conductor" start
```

Use `"$conductor" use 1.0.0` to return to that retained version after stopping the bridge. If a build fails, the previously selected release is still available through `status` and `start`.

For a one-time migration from a 0.5 source checkout, you can install that version into a new managed prefix using the 1.0 installer, then install 1.0 into the same prefix:

```bash
/usr/bin/python3 ./tools/conductor_install.py install --source "/path/to/extracted-conductor-0.5.0"
./Scripts/install.sh
```

Stop the older bridge before reusing its socket directory. Older manual launchers stay under your control. If you keep a separate login launcher, configure it to run the managed `conductor start` command.

## Recover a connection

If a connection drops while a write is in flight, inspect the project in Logic before sending another write. The relay does not replay a request. If the broker stopped, restart it from the Mac Terminal context, reconnect, and reacquire project and track references. Refer to the [compatibility matrix](compatibility.md) for the measured setup and workflow limits.
