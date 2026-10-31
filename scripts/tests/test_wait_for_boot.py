"""Exercise the simulator boot wait against scripted bootstatus output."""
import contextlib
import io
import runpy
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
MODULE = runpy.run_path(str(SCRIPTS / "wait-for-boot"))

PHASE = "[2026-10-31 02:35:24 +0000] Status=2, isTerminal=NO, Elapsed=00:{:02d}."
MIGRATION = "\tWaiting on Data Migration\n\t\tReason:{}\n\t\tMigration Elapsed:00:{:02d} seconds"


def scripted(*steps):
    """Build a command that prints each (delay, text) step, then exits with the last value."""
    *lines, status = steps
    source = "import sys, time\n"
    for delay, text in lines:
        source += "time.sleep(" + repr(delay) + "); print(" + repr(text) + ", flush=True)\n"
    source += "sys.exit(" + repr(status) + ")\n"
    return [sys.executable, "-c", source]


class WaitForBootTests(unittest.TestCase):
    def wait(self, command, stall_seconds, deadline_seconds=60):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            MODULE["wait_for_boot"]("device", stall_seconds, deadline_seconds, command=command)
        return output.getvalue()

    def test_treats_only_phase_changes_as_progress(self):
        normalize = MODULE["normalize"]
        self.assertEqual(normalize(PHASE.format(5)), normalize(PHASE.format(59)))
        self.assertEqual(normalize(MIGRATION.format("Siri.migrator", 1)),
                         normalize(MIGRATION.format("Siri.migrator", 40)))
        self.assertNotEqual(normalize(MIGRATION.format("Siri.migrator", 1)),
                            normalize(MIGRATION.format("MCProfile.migrator", 1)))
        self.assertNotEqual(normalize(PHASE.format(5)),
                            normalize("[x] Status=4, isTerminal=NO, Elapsed=00:05."))

    def test_outlives_a_slow_boot_that_keeps_changing_phase(self):
        command = scripted((0.2, PHASE.format(1)), (0.2, "\tBooting"),
                           (0.2, MIGRATION.format("Siri.migrator", 1)),
                           (0.2, "\tWaiting on System App"), (0.2, "\tFinished"), 0)
        output = self.wait(command, stall_seconds=3)
        self.assertIn("Waiting for simulator boot: device", output)
        self.assertIn("Finished", output)

    def test_fails_when_the_same_phase_repeats_past_the_stall_limit(self):
        command = scripted((0.1, "\tWaiting on System App"), (0.1, "\tWaiting on System App"),
                           (0.1, "\tWaiting on System App"), (2, "\tFinished"), 0)
        with self.assertRaisesRegex(RuntimeError, "no progress for 0.5 seconds: device"):
            self.wait(command, stall_seconds=0.5)

    def test_fails_when_bootstatus_prints_nothing_for_too_long(self):
        with self.assertRaisesRegex(RuntimeError, "no progress for 0.5 seconds"):
            self.wait(scripted((2, "\tFinished"), 0), stall_seconds=0.5)

    def test_fails_at_the_overall_deadline_despite_progress(self):
        steps = [(0.2, PHASE.format(index)[:-1] + " phase " + str(index)) for index in range(20)]
        with self.assertRaisesRegex(RuntimeError, "did not finish within the 1 seconds left"):
            self.wait(scripted(*steps, 0), stall_seconds=5, deadline_seconds=1)

    def test_repeated_multiline_phase_does_not_reset_stall_deadline(self):
        blocks = [(0.1, PHASE.format(i) + "\n" + MIGRATION.format("Siri.migrator", i))
                  for i in range(10)]
        with self.assertRaisesRegex(RuntimeError, "no progress"):
            self.wait(scripted(*blocks, 0), stall_seconds=0.3)

    def test_closed_output_does_not_disable_deadlines(self):
        command = [sys.executable, "-c", "import os,time; os.close(1); os.close(2); time.sleep(1)"]
        with self.assertRaisesRegex(RuntimeError, "no progress"):
            self.wait(command, stall_seconds=0.2, deadline_seconds=0.5)

    def test_partial_output_does_not_block_deadline_check(self):
        command = [sys.executable, "-c", "import sys,time; sys.stdout.write('Boot'); sys.stdout.flush(); time.sleep(1)"]
        with self.assertRaisesRegex(RuntimeError, "no progress"):
            self.wait(command, stall_seconds=0.2, deadline_seconds=0.5)

    def test_entry_point_shares_one_budget_across_devices(self):
        calls = []

        def boot(udid, stall_seconds, deadline_seconds):
            calls.append((udid, stall_seconds, round(deadline_seconds)))
            if udid == "watch":
                raise RuntimeError("Simulator boot made no progress for 1 seconds: watch")

        with self.assertRaises(SystemExit) as raised:
            MODULE["main"](["--stall-seconds", "1", "--deadline-seconds", "60", "phone", "watch"],
                           boot=boot)
        self.assertEqual(calls, [("phone", 1, 60), ("watch", 1, 60)])
        self.assertIn("no progress for 1 seconds: watch", str(raised.exception.code))

    def test_entry_point_retries_a_failed_boot_once_after_shutdown(self):
        events = []

        def boot(udid, stall_seconds, deadline_seconds):
            events.append("boot " + udid)
            if events.count("boot watch") == 1:
                raise RuntimeError("Simulator boot failed with status 60: watch")

        MODULE["main"](["phone", "watch"], boot=boot, shutdown=lambda udid: events.append("shutdown " + udid))
        self.assertEqual(events, ["boot phone", "boot watch", "shutdown watch", "boot watch"])

    def test_entry_point_does_not_retry_a_stalled_boot(self):
        events = []

        def boot(udid, stall_seconds, deadline_seconds):
            events.append("boot " + udid)
            raise RuntimeError("Simulator boot made no progress for 300 seconds: " + udid)

        with self.assertRaises(SystemExit):
            MODULE["main"](["watch"], boot=boot, shutdown=lambda udid: events.append("shutdown " + udid))
        self.assertEqual(events, ["boot watch"])

    def test_reports_a_failed_boot(self):
        with self.assertRaisesRegex(RuntimeError, "failed with status 3: device"):
            self.wait(scripted((0, "\tBooting"), 3), stall_seconds=5)


if __name__ == "__main__":
    unittest.main()
