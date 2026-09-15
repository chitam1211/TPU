"""Run: python3 -m unittest discover -s kltn/scripts -p test_auto_daily_commit.py -v"""

import argparse
from datetime import datetime, timedelta
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import auto_daily_commit as daily


class SummaryTests(unittest.TestCase):
    def test_requested_example(self):
        changes = [
            daily.Change("Modified", "kltn/rtl/core_if/fp32_addsub.v"),
            daily.Change("Added", "kltn/tb/core_if/tb_fp32_addsub.v"),
            daily.Change("Modified", "kltn/rtl/core_if/fp_csr.v"),
        ]
        self.assertEqual(daily.generate_change_summary(changes), [
            "Update FP32 add/sub execution unit", "Add FP32 add/sub testbench",
            "Update floating-point CSR logic",
        ])
        self.assertTrue(daily.build_commit_message(changes, datetime(2026, 9, 15, 17, 30)).startswith(
            "KLTN checkpoint 2026-09-15 17:30\n\n- Update"))

    def test_timestamp_title_format(self):
        changes = [daily.Change("Modified", "kltn/rtl/core_if/fp_csr.v")]
        self.assertRegex(daily.build_commit_message(changes).splitlines()[0],
                         r"^KLTN checkpoint \d{4}-\d{2}-\d{2} \d{2}:\d{2}$")
        self.assertEqual(daily.build_commit_message(changes, datetime(2026, 1, 2, 3, 4)).splitlines()[0],
                         "KLTN checkpoint 2026-01-02 03:04")

    def test_groups_keep_added_modified_deleted_distinct(self):
        changes = [daily.Change("Modified", f"kltn/rtl/core_if/unit{i}.v") for i in range(30)]
        changes += [daily.Change("Deleted", "kltn/tb/old.v"), daily.Change("Added", "kltn/tb/new.v")]
        self.assertEqual(daily.generate_change_summary(changes), [
            "Update RV32IF core implementation (30 files)",
            "Remove RTL verification tests", "Add RTL verification tests",
        ])

    def test_diff_patterns_and_limit(self):
        change = daily.Change("Modified", "kltn/rtl/core_if/decoder.v", "- old\n+ FMUL_S = 1;\n")
        self.assertIn("floating-point instruction decoding", daily.describe_change(change))
        changes = [daily.Change("Added", f"kltn/file{i}.txt") for i in range(30)]
        self.assertEqual(len(daily.generate_change_summary(changes)), 10)

    def test_generated_filters(self):
        for path in ("kltn/a.LOG", "kltn/sim/build/a.out", "kltn/proj.runs/a.v",
                     "kltn/.Xil/data", "kltn/docs/reference.pdf", "kltn/reports/x/y/before/a.v",
                     "kltn/__pycache__/a.pyc", "outside.txt"):
            with self.subTest(path=path):
                self.assertTrue(daily.excluded_path(path))
        self.assertFalse(daily.excluded_path("kltn/rtl/core_if/fp_csr.v"))


class RepositoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="kltn daily tests ")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.repo = self.base / "repo with spaces"
        self.repo.mkdir()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        self.env.update(XDG_STATE_HOME=str(self.base / "state"), AUTO_PUSH="false",
                        GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        self.g("init", "-b", "master")
        self.g("config", "user.name", "Checkpoint Test")
        self.g("config", "user.email", "checkpoint@example.invalid")
        self.g("config", "core.autocrlf", "false")
        self.g("config", "core.whitespace", "blank-at-eol,blank-at-eof,space-before-tab")
        self.g("config", "commit.gpgsign", "false")
        self.g("config", "core.hooksPath", str(self.base / "no-hooks"))
        self.g("remote", "add", "origin", daily.EXPECTED_REMOTE)
        script = self.repo / "kltn/scripts/auto_daily_commit.py"
        script.parent.mkdir(parents=True)
        shutil.copyfile(Path(daily.__file__), script)
        self.write("README.md", "Initial README\n")
        self.write(".gitignore", "*.ignored\n*.log\n")
        self.write("kltn/rtl/core_if/fp32_addsub.v", "module old;\nendmodule\n")
        self.write("kltn/tb/old.v", "old test\n")
        self.write("outside.txt", "outside\n")
        self.write("kltn/tracked.log", "generated\n")
        self.g("add", "--all")
        self.g("add", "--force", "kltn/tracked.log")
        self.g("commit", "-m", "Initial fixture")
        self.head = self.g("rev-parse", "HEAD").strip()

    def g(self, *args, check=True):
        result = subprocess.run(["git", "-C", str(self.repo), *args], env=self.env,
                                capture_output=True, check=check)
        return result.stdout.decode("utf-8", "replace")

    def write(self, path, text):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(text.encode("utf-8"))

    def cli(self, *args, code=0, extra_env=None):
        result = subprocess.run([sys.executable, str(self.repo / "kltn/scripts/auto_daily_commit.py"), *args],
                                cwd=self.base, env={**self.env, **(extra_env or {})},
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def logs(self):
        path = self.base / "state/kltn-auto-commit/auto_commit.log"
        return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]

    def test_dry_run_and_summary_leave_index_head_and_source_untouched(self):
        self.write("kltn/tb/new test [1].v", "test\n")
        index = (self.repo / ".git/index").read_bytes()
        status = self.g("status", "--porcelain")
        for flag in ("--dry-run", "--show-summary"):
            output = self.cli(flag, "--push", extra_env={"AUTO_PUSH": "true"})
            self.assertIn("Added", output)
            self.assertIn("Add RTL verification tests", output)
            self.assertEqual((self.repo / ".git/index").read_bytes(), index)
            self.assertEqual(self.g("status", "--porcelain"), status)
            self.assertEqual(self.g("rev-parse", "HEAD").strip(), self.head)
            self.assertFalse(list((self.base / "state/kltn-auto-commit").glob("*.lock")))
            self.assertEqual(self.logs()[-1]["result"], "PREVIEW")

    def test_real_commit_scopes_paths_and_tracks_deletions(self):
        self.write("kltn/rtl/core_if/fp32_addsub.v", "module updated;\nendmodule\n")
        self.write("kltn/tb/new test [1].v", "new test\n")
        (self.repo / "kltn/tb/old.v").unlink()
        self.write("README.md", "Changed README\n")
        self.write("outside.txt", "changed outside\n")
        self.write("kltn/tracked.log", "changed generated\n")
        self.write("kltn/sim/build/output.v", "generated\n")
        self.write("kltn/reports/a/b/before/snapshot.v", "snapshot\n")
        self.write("kltn/docs/reference.pdf", "reference\n")
        self.write("kltn/private.ignored", "ignored\n")
        self.cli()
        committed = set(self.g("diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD").splitlines())
        self.assertEqual(committed, {"README.md", "kltn/rtl/core_if/fp32_addsub.v",
                                     "kltn/tb/new test [1].v", "kltn/tb/old.v"})
        message = self.g("log", "-1", "--format=%B")
        self.assertIn("Remove RTL verification tests", message)
        self.assertIn("Update FP32 add/sub execution unit", message)
        self.assertRegex(message.splitlines()[0], r"^KLTN checkpoint \d{4}-\d{2}-\d{2} \d{2}:\d{2}$")
        log = (self.base / "state/kltn-auto-commit/auto_commit.log").read_text(encoding="utf-8")
        self.assertIn("COMMIT", log)
        self.assertIn("changed outside", (self.repo / "outside.txt").read_text())
        self.assertIn("No KLTN changes to commit.", self.cli())

    def test_clean_and_only_generated_are_noops(self):
        self.assertIn("No KLTN changes to commit.", self.cli())
        self.write("kltn/tracked.log", "updated\n")
        self.write("kltn/new.log", "generated\n")
        self.write("kltn/new.zip", "archive\n")
        self.assertIn("No KLTN changes to commit.", self.cli())
        self.assertEqual(self.g("rev-parse", "HEAD").strip(), self.head)
        self.assertEqual(self.logs()[-1]["result"], "NO_CHANGES")
        self.assertEqual(self.logs()[-1]["files_changed"], 0)

    def test_no_changes_does_not_add_commit_or_push(self):
        state = self.base / "state/kltn-auto-commit"
        state.mkdir(parents=True)
        args = argparse.Namespace(dry_run=False, show_summary=False, push=True)
        with patch.object(daily, "stage_changes") as stage, patch.object(daily, "create_commit") as commit, \
                patch.object(daily, "push_changes") as push:
            daily.run(self.repo, state, args)
            stage.assert_not_called()
            commit.assert_not_called()
            push.assert_not_called()
        self.assertEqual(self.logs()[-1]["result"], "NO_CHANGES")

    def test_two_runs_without_new_changes_create_only_one_checkpoint(self):
        self.write("kltn/new.py", "print('checkpoint')\n")
        self.cli()
        checkpoint = self.g("rev-parse", "HEAD").strip()
        index = (self.repo / ".git/index").read_bytes()
        self.assertEqual(self.cli("--push").strip(), "No KLTN changes to commit.")
        self.assertEqual(self.g("rev-parse", "HEAD").strip(), checkpoint)
        self.assertEqual((self.repo / ".git/index").read_bytes(), index)
        self.assertEqual(self.g("rev-list", "--count", f"{self.head}..HEAD").strip(), "1")
        self.assertEqual([r["result"] for r in self.logs()], ["COMMITTED", "NO_CHANGES"])

    def test_new_changes_allow_two_checkpoints_on_same_day(self):
        state = self.base / "state/kltn-auto-commit"
        state.mkdir(parents=True)
        args = argparse.Namespace(dry_run=False, show_summary=False, push=False)
        first_time = datetime(2026, 9, 15, 13, 30).astimezone()
        with patch.object(daily, "print_preview"):
            for run_time, source in ((first_time, "first"), (first_time + timedelta(hours=4), "second")):
                self.write("kltn/new.py", f"print('{source}')\n")
                daily.run(self.repo, state, args, daily.RunInfo(started_at=run_time))
        self.assertEqual(self.g("rev-list", "--count", f"{self.head}..HEAD").strip(), "2")
        self.assertEqual(self.g("log", "-2", "--format=%s").splitlines(), [
            "KLTN checkpoint 2026-09-15 17:30", "KLTN checkpoint 2026-09-15 13:30"])
        for record in self.logs():
            self.assertEqual(record["result"], "COMMITTED")
            self.assertEqual(record["branch"], "master")
            self.assertEqual(record["files_changed"], 1)
            self.assertRegex(record["commit_hash"], r"^[0-9a-f]{40,64}$")
            datetime.fromisoformat(record["timestamp"])

    def test_staged_changes_block_without_modifying_index(self):
        self.write("outside.txt", "staged outside\n")
        self.g("add", "outside.txt")
        self.write("kltn/new.py", "print('new')\n")
        index = (self.repo / ".git/index").read_bytes()
        self.assertIn("already has staged", self.cli(code=1))
        self.assertEqual((self.repo / ".git/index").read_bytes(), index)
        self.assertEqual(self.logs()[-1]["result"], "BLOCKED_STAGED_CHANGES")
        self.assertIn("Existing staged changes", self.cli("--dry-run"))

    def test_only_outside_staged_changes_are_still_protected(self):
        self.write("outside.txt", "staged\n")
        self.g("add", "outside.txt")
        index = (self.repo / ".git/index").read_bytes()
        self.cli(code=1)
        self.assertEqual(self.logs()[-1]["result"], "BLOCKED_STAGED_CHANGES")
        self.assertEqual((self.repo / ".git/index").read_bytes(), index)

    def test_wrong_branch_detached_and_wrong_remote(self):
        self.g("switch", "-c", "feature")
        self.assertIn("not 'master'", self.cli(code=1))
        self.assertEqual(self.logs()[-1]["result"], "BLOCKED_WRONG_BRANCH")
        self.assertEqual(self.logs()[-1]["branch"], "feature")
        self.g("checkout", "--detach")
        self.assertIn("Detached HEAD", self.cli(code=1))
        self.assertEqual(self.logs()[-1]["result"], "BLOCKED_WRONG_BRANCH")
        self.g("switch", "master")
        self.g("remote", "set-url", "origin", "git@example.invalid:wrong/repo.git")
        self.assertIn("Unexpected origin", self.cli(code=1))
        self.assertEqual(self.logs()[-1]["result"], "ERROR")
        self.assertEqual(self.g("rev-parse", "HEAD").strip(), self.head)

    def test_conflict_blocks(self):
        self.g("switch", "-c", "feature")
        self.write("README.md", "feature\n")
        self.g("add", "README.md")
        self.g("commit", "-m", "Feature")
        self.g("switch", "master")
        self.write("README.md", "master\n")
        self.g("add", "README.md")
        self.g("commit", "-m", "Master")
        self.g("merge", "feature", check=False)
        index = (self.repo / ".git/index").read_bytes()
        self.assertIn("Merge conflicts", self.cli(code=1))
        self.assertEqual(self.logs()[-1]["result"], "BLOCKED_CONFLICT")
        self.assertEqual((self.repo / ".git/index").read_bytes(), index)

    def test_whitespace_blocks_tracked_and_new_files(self):
        self.write("README.md", "bad whitespace  \n")
        self.assertIn("failed", self.cli(code=1))
        self.assertEqual(self.g("rev-parse", "HEAD").strip(), self.head)
        self.assertFalse(self.g("diff", "--cached", "--name-only"))
        self.write("README.md", "Initial README\n")
        self.write("kltn/new.py", "bad whitespace  \n")
        self.cli(code=1)
        self.assertEqual(self.g("rev-parse", "HEAD").strip(), self.head)
        self.assertIn("kltn/new.py", self.g("diff", "--cached", "--name-only"))

    def test_rename_is_added_and_deleted(self):
        (self.repo / "kltn/tb/old.v").rename(self.repo / "kltn/tb/renamed.v")
        output = self.cli("--dry-run")
        self.assertIn("Deleted", output)
        self.assertIn("Added", output)
        self.cli()
        self.assertFalse(self.g("status", "--porcelain"))

    def test_gitignored_tracked_source_is_excluded(self):
        self.write(".gitignore", "*.ignored\n*.log\nkltn/tb/old.v\n")
        self.write("kltn/tb/old.v", "changed ignored source\n")
        self.cli()
        self.assertEqual(self.g("diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD").strip(), ".gitignore")

    def test_failed_push_retains_commit(self):
        self.write("kltn/new.py", "print('checkpoint')\n")
        # Local pushurl mismatch fails after commit, without accessing a network.
        self.g("remote", "set-url", "--push", "origin", str(self.base / "missing-remote"))
        self.assertIn("local commit retained", self.cli("--push", code=1))
        self.assertNotEqual(self.g("rev-parse", "HEAD").strip(), self.head)
        self.assertFalse(self.g("diff", "--cached", "--name-only"))

    def test_push_command_failure_retains_commit(self):
        self.write("kltn/new.py", "print('checkpoint')\n")
        state = self.base / "direct-state"
        state.mkdir()
        args = argparse.Namespace(dry_run=False, show_summary=False, push=True)
        with patch.object(daily, "push_changes", side_effect=daily.SafetyError("push failed")):
            with self.assertRaisesRegex(daily.SafetyError, "push failed"):
                daily.run(self.repo, state, args)
        self.assertNotEqual(self.g("rev-parse", "HEAD").strip(), self.head)

    def test_log_cannot_be_in_repository(self):
        self.assertIn("outside the repository", self.cli(code=1, extra_env={"XDG_STATE_HOME": str(self.repo / "logs")}))
        self.assertFalse((self.repo / "logs").exists())

    def test_concurrent_index_change_blocks_commit(self):
        self.write("kltn/new.py", "print('checkpoint')\n")
        state = self.base / "direct-state"
        state.mkdir()
        args = argparse.Namespace(dry_run=False, show_summary=False, push=False)
        calls = []

        def concurrent_stage(*unused):
            calls.append(1)
            if len(calls) == 2:
                self.write("outside.txt", "concurrently staged\n")
                self.g("add", "outside.txt")

        with patch.object(daily, "print_preview", side_effect=concurrent_stage):
            with self.assertRaisesRegex(daily.SafetyError, "HEAD/index changed"):
                daily.run(self.repo, state, args)
        self.assertEqual(self.g("rev-parse", "HEAD").strip(), self.head)
        self.assertIn("outside.txt", self.g("diff", "--cached", "--name-only"))

    def test_overlapping_runs_are_blocked(self):
        state = self.base / "state/kltn-auto-commit"
        state.mkdir(parents=True)
        index = (self.repo / ".git/index").read_bytes()
        self.write("kltn/new.py", "print('new')\n")
        with daily.run_lock(state):
            self.assertIn("WARNING: Another KLTN checkpoint", self.cli())
            self.assertEqual(self.logs()[-1]["result"], "SKIPPED_LOCK")
            self.assertEqual(self.g("rev-parse", "HEAD").strip(), self.head)
            self.assertEqual((self.repo / ".git/index").read_bytes(), index)
            # Preview neither takes nor removes the active instance's lock.
            self.cli("--dry-run")
            self.assertIn("WARNING: Another KLTN checkpoint", self.cli())
        # A persistent but unlocked file must not block the next normal run.
        self.assertTrue((state / "auto_commit.lock").exists())
        self.cli()
        self.assertNotEqual(self.g("rev-parse", "HEAD").strip(), self.head)

    def test_lock_is_released_after_process_termination(self):
        state = self.base / "state/kltn-auto-commit"
        state.mkdir(parents=True)
        helper = (
            "import sys, time; from pathlib import Path; "
            "sys.path.insert(0, sys.argv[1]); import auto_daily_commit as daily; "
            "lock = daily.run_lock(Path(sys.argv[2])); lock.__enter__(); "
            "print('locked', flush=True); time.sleep(30)"
        )
        process = subprocess.Popen([sys.executable, "-c", helper, str(Path(daily.__file__).parent), str(state)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertEqual(process.stdout.readline().strip(), "locked")
            self.assertIn("WARNING: Another KLTN checkpoint", self.cli())
        finally:
            process.terminate()
            process.communicate(timeout=10)
        self.assertEqual(self.cli().strip(), "No KLTN changes to commit.")


if __name__ == "__main__":
    unittest.main()
