"""Exercise the Watch test entry point with a simulated CoreSimulator service."""
import itertools
import json
import os
import runpy
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]


class WatchSimulatorTests(unittest.TestCase):
    HOST_NEVER_CONNECTED = ("CompassWatch (1) encountered an error (Early unexpected exit, operation never"
                            " finished bootstrapping - no restart will be attempted.)")

    def run_watch(self, snapshots, test_status=0, xcodebuild=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scripts").symlink_to(SCRIPTS)
            (root / "snapshots.json").write_text(json.dumps(snapshots))
            (root / "xcrun").write_text('''#!/usr/bin/env python3
import json, pathlib, sys
root = pathlib.Path(__file__).parent
with (root / "calls").open("a") as log:
    log.write(" ".join(sys.argv[1:]) + "\\n")
if sys.argv[1:3] == ["simctl", "list"]:
    counter = root / "counter"
    index = int(counter.read_text()) if counter.exists() else 0
    snapshots = json.loads((root / "snapshots.json").read_text())
    print(json.dumps(snapshots[min(index, len(snapshots)-1)]))
    counter.write_text(str(index+1))
elif sys.argv[1:4] == ["simctl", "runtime", "list"]:
    print(json.dumps({"watch": {"runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.watchOS-27-0", "state": "Ready", "mountPath": "/"}, "phone": {"runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "state": "Ready", "mountPath": "/"}}))
''')
            (root / "xcodebuild").write_text(
                xcodebuild or f"#!/bin/sh\necho test >> '{root}/calls'\nexit {test_status}\n")
            for name in ("xcrun", "xcodebuild"):
                (root / name).chmod(0o755)
            result = subprocess.run(["bash", str(SCRIPTS / "test-watch")], cwd=root,
                                    env={**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"]},
                                    capture_output=True, text=True, timeout=20)
            return result, (root / "calls").read_text()

    def failing_host_then(self, status):
        """An xcodebuild stand-in whose first run reports the host handshake failure."""
        return ("#!/bin/sh\n"
                "echo test >> calls\n"
                "if [ \"$(grep -c '^test$' calls)\" -eq 1 ]; then\n"
                f"  echo '{self.HOST_NEVER_CONNECTED}'; exit 65\n"
                "fi\n"
                f"exit {status}\n")

    def snapshot(self, available=True):
        return {"devices": {
            "com.apple.CoreSimulator.SimRuntime.watchOS-27-0": [{"udid": "watch", "name": "Apple Watch", "isAvailable": available}],
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [{"udid": "phone", "name": "iPhone", "isAvailable": True}]},
            "pairs": {"pair": {"watch": {"udid": "watch"}, "phone": {"udid": "phone"}}}}

    def test_waits_for_watch_to_reappear_after_runtime_transition(self):
        result, calls = self.run_watch([self.snapshot(False), self.snapshot()])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("simctl bootstatus phone -b", calls)
        self.assertIn("simctl bootstatus watch -b", calls)
        self.assertIn("simctl install watch .build/watch/Build/Products/Debug-watchsimulator/CompassWatch.app", calls)
        self.assertIn("simctl launch watch dev.lunchbox-labs.carplay-compass.watchkitapp", calls)
        self.assertIn("simctl terminate watch dev.lunchbox-labs.carplay-compass.watchkitapp", calls)
        self.assertTrue(calls.endswith("test\n"))
        self.assertEqual(calls.count("test\n"), 1)

    def test_preserves_a_host_connection_failure(self):
        result, calls = self.run_watch([self.snapshot()], xcodebuild=self.failing_host_then(0))
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertEqual(calls.count("test\n"), 1)

    def test_does_not_hide_test_failure_alongside_host_connection_error(self):
        command = self.failing_host_then(0).replace(
            f"  echo '{self.HOST_NEVER_CONNECTED}'",
            f"  echo 'Test Case testHeading failed (0.01 seconds).'; echo '{self.HOST_NEVER_CONNECTED}'")
        result, calls = self.run_watch([self.snapshot()], xcodebuild=command)
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertEqual(calls.count("test\n"), 1)

    def test_rejects_unmounted_or_transitioning_watch_runtime(self):
        select_pair = runpy.run_path(str(SCRIPTS / "select-watch-pair"))["select_pair"]
        runtimes = {
            "watch": {"runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.watchOS-27-0", "state": "Copying", "mountPath": "/"},
            "phone": {"runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "state": "Ready", "mountPath": "/"},
        }
        self.assertIsNone(select_pair(self.snapshot(), runtimes))
        runtimes["watch"]["state"] = "Ready"
        runtimes["watch"]["mountPath"] = "/missing-watch-mount"
        self.assertIsNone(select_pair(self.snapshot(), runtimes))
        runtimes["watch"]["mountPath"] = "/"
        self.assertIsNotNone(select_pair(self.snapshot(), runtimes))

    def test_missing_pair_fails_at_deadline(self):
        wait = runpy.run_path(str(SCRIPTS / "select-watch-pair"))["wait_for_pair"]
        clock = itertools.count(0, 2).__next__  # the deadline passes before the first poll
        with self.assertRaisesRegex(RuntimeError, "within 1 seconds"):
            wait(timeout=1, clock=clock)

    def test_summarizes_state_when_no_pair_appears(self):
        summarize = runpy.run_path(str(SCRIPTS / "select-watch-pair"))["summarize"]
        runtimes = {"watch": {"runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.watchOS-27-0",
                              "state": "Copying", "mountPath": None}}
        summary = summarize(self.snapshot(False), runtimes)
        self.assertIn("Watch runtimes: Copying at None", summary)
        self.assertIn("watchOS-27-0: Apple Watch unavailable", summary)
        self.assertIn("iOS-27-0: iPhone available", summary)
        self.assertIn("Pairs: 1", summary)
        empty = summarize({"devices": {"com.apple.CoreSimulator.SimRuntime.watchOS-27-0": []}}, {})
        self.assertIn("Watch runtimes: none", empty)
        self.assertIn("watchOS-27-0: no devices", empty)
        self.assertIn("Pairs: 0", empty)

    def test_preserves_native_test_failure(self):
        result, calls = self.run_watch([self.snapshot()], test_status=7)
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertTrue(calls.endswith("test\n"))
        self.assertEqual(calls.count("test\n"), 1, "a failing test must not be retried")


if __name__ == "__main__":
    unittest.main()
