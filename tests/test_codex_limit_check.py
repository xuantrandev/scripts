"""Offline tests for codex_limit_check.sh with a stub `codex` binary."""

import json
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "codex_limit_check.sh"

MOCK_CODEX = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path

root = Path(os.environ["MOCK_ROOT"])
args = sys.argv[1:]

def log_exec(argv):
    with (root / "exec_calls").open("a") as stream:
        stream.write(json.dumps(argv) + "\n")

if "app-server" in args:
    cursor_path = root / "cursor"
    cursor = int(cursor_path.read_text()) if cursor_path.exists() else 0
    responses = json.loads((root / "responses").read_text())
    if cursor >= len(responses):
        sys.exit(98)
    cursor_path.write_text(str(cursor + 1))
    payload = responses[cursor]
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if msg.get("method") == "account/rateLimits/read":
            sys.stdout.write(json.dumps({"id": msg.get("id", 2), "result": payload}) + "\n")
            sys.stdout.flush()
            break
        if msg.get("method") == "initialize":
            sys.stdout.write(json.dumps({"id": msg.get("id", 1), "result": {}}) + "\n")
            sys.stdout.flush()
    sys.exit(0)
elif "exec" in args:
    # Emulate current CLIs: --ask-for-approval AFTER exec is rejected.
    if "--ask-for-approval" in args[args.index("exec"):]:
        print("error: unexpected argument '--ask-for-approval' found", file=sys.stderr)
        sys.exit(2)
    log_exec(args)
    if (root / "exec_fail").exists():
        sys.exit(3)
    print("mock exec ok")
    sys.exit(0)
else:
    sys.exit(99)
'''


def payload(used, resets_at, window=300):
    return {"rateLimits": {
        "primary": {"usedPercent": used, "windowDurationMins": window,
                    "resetsAt": resets_at},
        "secondary": {"usedPercent": 10, "windowDurationMins": 10080,
                      "resetsAt": (resets_at or 0) + 100000},
    }}


class CodexLimitCheckTests(unittest.TestCase):
    def run_script(self, responses, args=(), extra_env=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            codex = root / "codex"
            codex.write_text(MOCK_CODEX)
            codex.chmod(0o755)
            (root / "responses").write_text(json.dumps(responses))
            state = root / "state"
            state.mkdir()
            env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}",
                       MOCK_ROOT=str(root))
            if extra_env:
                env.update(extra_env)
            cmd = [str(SCRIPT), "--state-dir", str(state), "--wait", "0"] + list(args)
            result = subprocess.run(cmd, text=True, capture_output=True,
                                    env=env, timeout=60)
            calls_path = root / "exec_calls"
            calls = ([json.loads(line) for line in calls_path.read_text().splitlines()]
                     if calls_path.exists() else [])
            history = ((state / "history.log").read_text()
                       if (state / "history.log").exists() else "")
        return result, calls, history

    def future(self, secs=7200):
        return int(time.time()) + secs

    def test_help_makes_no_codex_calls(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state"
            env = dict(os.environ)
            env.pop("MOCK_ROOT", None)
            result = subprocess.run(
                [str(SCRIPT), "--help"], text=True, capture_output=True,
                env=dict(env, PATH="/usr/bin:/bin"), timeout=15)
        self.assertEqual(result.returncode, 0)
        self.assertIn("Usage:", result.stdout)

    def test_missing_reset_triggers_kick(self):
        result, calls, history = self.run_script(
            [payload(40, None), payload(40, None), payload(40, None)])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("reset time unavailable", result.stdout)
        self.assertIn("Kick sent", result.stdout)
        self.assertEqual(len(calls), 1)
        self.assertIn("gpt-5-mini", " ".join(calls[0]))
        # --ask-for-approval must never be placed after exec (current CLIs
        # reject it); it may only appear before the subcommand.
        argv = calls[0]
        if "--ask-for-approval" in argv:
            self.assertLess(argv.index("--ask-for-approval"), argv.index("exec"))
        self.assertIn("unscheduled", history)

    def test_valid_reset_never_kicks_even_when_unchanged(self):
        # Regression: identical future resetsAt across polls is NORMAL
        # (window expiry, not a ticking clock) — e.g. 100% used, resets in
        # 29m. Must wait for reset, never kick.
        reset = self.future(29 * 60)
        result, calls, history = self.run_script(
            [payload(100, reset), payload(100, reset)])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("resets in", result.stdout)
        self.assertNotIn("Kick sent", result.stdout)
        self.assertIn("no kick", result.stdout.lower())
        self.assertEqual(calls, [])

    def test_reset_beyond_5h_triggers_kick(self):
        # A live 5h window can never reset >= 5h away -> stuck -> kick.
        now = int(time.time())
        reset = now + 5 * 3600 + 60
        result, calls, history = self.run_script(
            [payload(40, reset), payload(40, reset), payload(40, reset)])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Stuck", result.stdout)
        self.assertIn("Kick sent", result.stdout)
        self.assertEqual(len(calls), 1)
        self.assertIn("stuck", history)

    def test_zero_percent_with_far_reset_triggers_kick(self):
        # 0% used but reset a full 5h away is equally stuck -> kick.
        now = int(time.time())
        reset = now + 5 * 3600 + 60
        result, calls, _ = self.run_script(
            [payload(0, reset), payload(0, reset), payload(0, reset)])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Stuck", result.stdout)
        self.assertIn("Kick sent", result.stdout)
        self.assertEqual(len(calls), 1)

    def test_reset_just_under_5h_never_kicks(self):
        now = int(time.time())
        reset = now + 5 * 3600 - 120
        result, calls, _ = self.run_script(
            [payload(40, reset), payload(40, reset)])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("Kick sent", result.stdout)
        self.assertEqual(calls, [])

    def test_far_reset_in_single_poll_is_transient(self):
        now = int(time.time())
        result, calls, _ = self.run_script(
            [payload(40, now + 3600), payload(40, now + 6 * 3600)])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("Kick sent", result.stdout)
        self.assertIn("transient", result.stdout.lower())
        self.assertEqual(calls, [])

    def test_far_reset_jitter_between_polls_still_kicks(self):
        # ResetsAt jitters seconds between polls; snapshots 11s apart must
        # still agree and kick, not count as transient.
        now = int(time.time())
        reset2 = now + 5 * 3600 + 120
        reset1 = reset2 - 11
        result, calls, _ = self.run_script(
            [payload(0, reset1), payload(0, reset2), payload(0, reset2)])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Stuck", result.stdout)
        self.assertIn("Kick sent", result.stdout)
        self.assertEqual(len(calls), 1)

    def test_transient_missing_reset_does_not_kick(self):
        reset = self.future()
        result, calls, _ = self.run_script(
            [payload(40, reset), payload(40, None)])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("Kick sent", result.stdout)
        self.assertEqual(calls, [])

    def test_active_countdown_needs_no_kick(self):
        now = self.future()
        result, calls, _ = self.run_script(
            [payload(40, now), payload(40, now + 60)])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Countdown active", result.stdout)
        self.assertEqual(calls, [])

    def test_idle_window_needs_no_kick(self):
        reset = self.future()
        result, calls, _ = self.run_script(
            [payload(0, reset), payload(0, reset)])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("idle", result.stdout.lower())
        self.assertEqual(calls, [])

    def test_weekly_only_account_skips(self):
        reset = self.future()
        weekly = {"rateLimits": {
            "primary": {"usedPercent": 20, "windowDurationMins": 10080,
                        "resetsAt": reset}}}
        result, calls, _ = self.run_script([weekly, weekly])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("No 5h window", result.stdout)
        self.assertEqual(calls, [])

    def test_dry_run_never_kicks(self):
        result, calls, _ = self.run_script(
            [payload(40, None), payload(40, None)], args=["--dry-run"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Dry run", result.stdout)
        self.assertEqual(calls, [])

    def test_kick_failure_exits_nonzero(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            codex = root / "codex"
            codex.write_text(MOCK_CODEX)
            codex.chmod(0o755)
            (root / "responses").write_text(json.dumps(
                [payload(40, None), payload(40, None)]))
            (root / "exec_fail").write_text("1")
            state = root / "state"
            state.mkdir()
            env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}",
                       MOCK_ROOT=str(root))
            result = subprocess.run(
                [str(SCRIPT), "--state-dir", str(state), "--wait", "0"],
                text=True, capture_output=True, env=env, timeout=60)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("kick request failed", result.stderr.lower())

    def test_missing_codex_binary_exits_2(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state"
            env = dict(os.environ, PATH="/usr/bin:/bin",
                       CODEX_BIN="codex-definitely-missing-xyz")
            result = subprocess.run(
                [str(SCRIPT), "--state-dir", str(state), "--wait", "0"],
                text=True, capture_output=True, env=env, timeout=15)
        self.assertEqual(result.returncode, 2)
        self.assertIn("codex", (result.stdout + result.stderr).lower())


if __name__ == "__main__":
    unittest.main()
