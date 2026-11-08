#!/usr/bin/env python3
"""Exercise bootstrap and packaging guards without building or creating any .app."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parent

class CandidateLauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="candidate-launcher-")
        self.root = Path(self.temp.name).resolve()
        self.entry = self.root / "entry"
        shutil.copyfile(TOOLS / "candidate-launcher.sh", self.entry)
        self.entry.chmod(0o755)
        stub = self.root / "entry-bin"
        stub.write_text('#!/bin/bash\nprintf "%s\\n" "$AVPPLAY_HOME" "$TMPDIR" "$1"\n')
        stub.chmod(0o755)

    def tearDown(self):
        self.temp.cleanup()

    def launch(self, home):
        return subprocess.run([str(self.entry), "resume-fixture"], env={**os.environ, "AVPPLAY_HOME": str(home), "TMPDIR": "/wrong-inherited-tmp"}, capture_output=True, text=True)

    def test_both_entry_points_forward_arguments_and_override_inherited_tmp(self):
        for name in ["AVPPlay", "avpplay"]:
            directory = self.root / ("gui" if name == "AVPPlay" else "cli")
            directory.mkdir()
            entry = directory / name
            shutil.copyfile(TOOLS / "candidate-launcher.sh", entry)
            entry.chmod(0o755)
            shutil.copyfile(self.root / "entry-bin", directory / (name + "-bin"))
            (directory / (name + "-bin")).chmod(0o755)
            self.entry = entry
            result = self.launch(self.root / "new data")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), [str(self.root / "new data"), str(self.root / "new data/tmp") + "/", "resume-fixture"])

    def test_rejects_installed_roots_children_parents_and_aliases(self):
        support = Path.home() / "Library/Application Support"
        for name in ["AVPPlay", "AVPPlayModificado", "AVPPlayCandidate", "AVPPlayCandidate185", "AVPPlayCandidate186", "QuestInstaller"]:
            protected = support / name
            alias = self.root / name
            alias.symlink_to(protected, target_is_directory=True)
            for home in [protected, protected / "jobs", support, alias, alias / "build-only"]:
                self.assertNotEqual(self.launch(home).returncode, 0, str(home))

    def test_rejects_shared_jobs_link_before_starting_stub(self):
        home = self.root / "data"
        home.mkdir()
        (home / "jobs").symlink_to(Path.home() / "Library/Application Support/AVPPlayCandidate/jobs")
        result = self.launch(home)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_packager_rejects_185_identity_and_wrong_build_without_compiling(self):
        for key, value in [("AVPPLAY_BUNDLE_ID", "io.github.mymartek.avpplay.modified.candidate"),
                           ("AVPPLAY_APP_BUILD", "185")]:
            result = subprocess.run(["bash", str(TOOLS / "make-app.sh")],
                env={**os.environ, key: value}, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)

    def test_rejects_relative_home_and_redirected_tmp(self):
        self.assertNotEqual(self.launch("relative").returncode, 0)
        home = self.root / "data"
        home.mkdir()
        (home / "tmp").symlink_to(self.root)
        self.assertNotEqual(self.launch(home).returncode, 0)

    def test_packager_refuses_existing_output_before_build(self):
        (self.root / "AVP Play Candidate 187.app").mkdir()
        result = subprocess.run(["bash", str(TOOLS / "make-app.sh")], env={**os.environ, "AVPPLAY_BUNDLE_ID": "io.github.mymartek.avpplay.modified.candidate187", "AVPPLAY_OUTPUT_APP": str(self.root / "AVP Play Candidate 187.app")}, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to replace", result.stderr)

    def test_packager_refuses_179_identity_before_build(self):
        result = subprocess.run(["bash", str(TOOLS / "make-app.sh")], env={**os.environ, "AVPPLAY_BUNDLE_ID": "io.github.mymartek.avpplay.modified"}, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exclusive Bundle ID", result.stderr)

    def test_launcher_rejects_candidate186_app_alias_before_stub(self):
        app = Path.home() / "Applications/AVP Play Candidate 186.app"
        alias = self.root / "previous-app"
        alias.symlink_to(app, target_is_directory=True)
        for path in [app, app / "Contents", alias, alias / "data"]:
            result = self.launch(path)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")

    def test_packager_rejects_candidate186_identity_and_install_destinations(self):
        result = subprocess.run(["bash", str(TOOLS / "make-app.sh")], env={**os.environ,
            "AVPPLAY_BUNDLE_ID": "io.github.mymartek.avpplay.modified.candidate186"}, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        for path in [Path.home() / "Applications/AVP Play Candidate 187.app", Path("/Applications/AVP Play Candidate 187.app")]:
            result = subprocess.run(["bash", str(TOOLS / "make-app.sh")], env={**os.environ,
                "AVPPLAY_OUTPUT_APP": str(path)}, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("overlaps", result.stderr)

if __name__ == "__main__":
    unittest.main(verbosity=2)
