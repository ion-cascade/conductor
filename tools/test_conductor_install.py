import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import conductor_install as install


class ReleaseSelectionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def source(self, version):
        path = self.root / f"source-{version}"
        (path / "Scripts").mkdir(parents=True)
        (path / "tools").mkdir()
        (path / "docs").mkdir()
        (path / "docs/SETUP.md").write_text("setup\n")
        (path / "manifest.json").write_text(json.dumps({"name": install.IDENTITY, "version": version}))
        for filename in install.BRIDGE_TOOLS:
            (path / "tools" / filename).touch()
        for filename in install.SHARE_FILES:
            (path / "Scripts" / filename).touch()
        (path / "LogicProMCP").touch()
        return path

    def stage(self, version, binary_version=None):
        source = self.source(version)
        with patch.object(install.subprocess, "run") as build, patch.object(
            install.subprocess, "check_output", side_effect=[str(source), binary_version or version]
        ):
            install.install(self.root, source, None)
        self.assertIn("--disable-automatic-resolution", build.call_args.args[0])

    def test_first_install_update_and_previous_release(self):
        self.stage("0.5.0")
        self.stage("1.0.0")
        state = install.read_state(self.root)
        self.assertEqual({"current": "1.0.0", "previous": "0.5.0"}, state)
        install.select_release(self.root, state["previous"], state)
        self.assertEqual({"current": "0.5.0", "previous": "1.0.0"}, install.read_state(self.root))
        self.assertEqual(0o700, os.stat(self.root / "conductor").st_mode & 0o777)
        self.assertTrue((self.root / "releases/1.0.0/share/SETUP.md").is_file())

    def test_failed_version_check_keeps_previous_selection(self):
        self.stage("0.5.0")
        with self.assertRaisesRegex(install.InstallError, "expected 1.0.0"):
            self.stage("1.0.0", "0.5.0")
        self.assertEqual("0.5.0", install.read_state(self.root)["current"])
        self.assertFalse((self.root / "releases/1.0.0").exists())

    def test_live_broker_lock_blocks_selecting_new_files(self):
        self.stage("0.5.0")
        with install.lock_file(self.root / "bridge.lock", "busy"):
            with self.assertRaisesRegex(install.InstallError, "Stop"):
                self.stage("1.0.0")
        self.assertEqual("0.5.0", install.read_state(self.root)["current"])
        self.assertFalse((self.root / "releases/1.0.0").exists())
