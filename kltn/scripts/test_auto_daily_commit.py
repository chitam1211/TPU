"""Run: python3 -m unittest discover -s kltn/scripts -p test_auto_daily_commit.py -v"""

import argparse
from datetime import date
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import sys
from pathlib import Path

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
        self.assertTrue(daily.build_commit_message(changes, "2026-09-15").startswith(
            "Daily KLTN update 2026-09-15\n\n- Update"))

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
        self.assertTrue(message.startswith(f"Daily KLTN update {date.today().isoformat()}"))
        log = (self.base / "state/kltn-auto-commit/auto_commit.log").read_text(encoding="utf-8")
        self.assertIn("COMMIT", log)
        self.assertIn("changed outside", (self.repo / "outside.txt").read_text())
        self.assertIn("No eligible", self.cli())

    def test_clean_and_only_generated_are_noops(self):
        self.assertIn("No eligible", self.cli())
        self.write("kltn/tracked.log", "updated\n")
        self.write("kltn/new.log", "generated\n")
        self.write("kltn/new.zip", "archive\n")
        self.assertIn("No eligible", self.cli())
        self.assertEqual(self.g("rev-parse", "HEAD").strip(), self.head)

    def test_staged_changes_block_without_modifying_index(self):
        self.write("outside.txt", "staged outside\n")
        self.g("add", "outside.txt")
        self.write("kltn/new.py", "print('new')\n")
        index = (self.repo / ".git/index").read_bytes()
        self.assertIn("already has staged", self.cli(code=1))
        self.assertEqual((self.repo / ".git/index").read_bytes(), index)
        self.assertIn("Existing staged changes", self.cli("--dry-run"))

    def test_wrong_branch_detached_and_wrong_remote(self):
        self.g("switch", "-c", "feature")
        self.assertIn("not 'master'", self.cli(code=1))
        self.g("checkout", "--detach")
        self.assertIn("Detached HEAD", self.cli(code=1))
        self.g("switch", "master")
        self.g("remote", "set-url", "origin", "git@example.invalid:wrong/repo.git")
        self.assertIn("Unexpected origin", self.cli(code=1))
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
        with daily.run_lock(state, self.repo):
            self.assertIn("Another daily checkpoint", self.cli(code=1))


if __name__ == "__main__":
    unittest.main()
