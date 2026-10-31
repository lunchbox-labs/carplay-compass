"""Exercise the Watch app warm-up against a scripted simctl."""
import contextlib
import io
import runpy
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
MODULE = runpy.run_path(str(SCRIPTS / "warm-watch-app"))

# A stand-in for `xcrun simctl` that behaves per subcommand: the script receives the
# subcommand as its first argument and reads its behavior from the BEHAVIOR mapping.
FAKE = '''
import sys, time
behavior = {BEHAVIOR}
action = behavior.get(sys.argv[1], "ok")
if action == "hang":
    time.sleep(5)
sys.exit(int(action) if action.isdigit() else 0)
'''


def simctl(**behavior):
    return [sys.executable, "-c", FAKE.replace("{BEHAVIOR}", repr(behavior))]


class WarmWatchAppTests(unittest.TestCase):
    def warm(self, command, timeout=5):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            MODULE["warm"]("watch", "/tmp/App.app", "dev.example.watchkitapp", timeout, simctl=command)
        return output.getvalue()

    def test_installs_launches_and_stops_the_app(self):
        output = self.warm(simctl())
        self.assertIn("Installing the Watch app", output)
        self.assertIn("Launching the Watch app", output)
        self.assertIn("Stopping the Watch app", output)

    def test_fails_when_the_install_fails(self):
        with self.assertRaisesRegex(RuntimeError, "Installing the Watch app failed with status 2"):
            self.warm(simctl(install="2"))

    def test_reports_a_hung_launch_and_carries_on(self):
        output = self.warm(simctl(launch="hang"), timeout=0.5)
        self.assertIn("Launching the Watch app did not finish within 0.5 seconds", output)
        self.assertIn("Stopping the Watch app", output)

    def test_tolerates_an_app_that_already_exited(self):
        output = self.warm(simctl(terminate="3"))
        self.assertIn("Stopping the Watch app failed with status 3", output)

    def test_entry_point_reports_failures_as_exit_status(self):
        with self.assertRaises(SystemExit) as raised, contextlib.redirect_stdout(io.StringIO()):
            MODULE["main"](["watch", "/tmp/App.app", "dev.example.watchkitapp", "--timeout-seconds", "0.5"],
                           simctl=simctl(install="hang"))
        self.assertIn("did not finish within 0.5 seconds", str(raised.exception.code))


if __name__ == "__main__":
    unittest.main()
