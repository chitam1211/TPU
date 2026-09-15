#!/usr/bin/env python3
"""Local, conservative daily checkpoints for KLTN. Requires Python 3.9+ and Git."""

import argparse
from collections import Counter
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import date, datetime
import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys


EXPECTED_REMOTE = "git@github.com:chitam1211/TPU.git"
BRANCH = "master"


class SafetyError(RuntimeError):
    pass


@dataclass(frozen=True)
class Change:
    status: str  # Added, Modified, Deleted
    path: str
    diff: str = ""


def git(repo, *args, input_data=None, allowed=(0,)):
    # Never inherit index/worktree overrides, invoke a shell, or expand pathspecs.
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0")
    # check-ignore --stdin already takes literal filenames and rejects pathspec magic.
    if args[0] != "check-ignore":
        env["GIT_LITERAL_PATHSPECS"] = "1"
    result = subprocess.run(
        ["git", "-C", str(repo), *args], input=input_data,
        capture_output=True, check=False, env=env,
    )
    if result.returncode not in allowed:
        detail = (result.stderr + result.stdout).decode("utf-8", "replace").strip()
        raise SafetyError(f"git {args[0]} failed ({result.returncode}): {detail}")
    return result.stdout


def decode(raw):
    return os.fsdecode(raw)


def get_repo_root():
    # Resolve from this script, so cron's working directory does not matter.
    expected = Path(__file__).resolve().parents[2]
    root = Path(decode(git(expected, "rev-parse", "--show-toplevel")).strip()).resolve()
    if root != expected or not (root / "kltn").is_dir():
        raise SafetyError("Script must be in <repository>/kltn/scripts/.")
    remote = decode(git(root, "remote", "get-url", "origin")).strip()
    if remote != EXPECTED_REMOTE:
        raise SafetyError(f"Unexpected origin: {remote!r}; expected {EXPECTED_REMOTE!r}.")
    os.chdir(root)
    return root


def get_current_branch(repo):
    return decode(git(repo, "symbolic-ref", "--quiet", "--short", "HEAD", allowed=(0, 1))).strip()


def check_repository_state(repo):
    if git(repo, "diff", "--name-only", "--diff-filter=U", "-z"):
        raise SafetyError("Merge conflicts exist; resolve them manually first.")
    branch = get_current_branch(repo)
    if not branch:
        raise SafetyError("Detached HEAD; no commit created.")
    if branch != BRANCH:
        raise SafetyError(f"Current branch is {branch!r}, not {BRANCH!r}; no branch switch.")
    git(repo, "rev-parse", "--verify", "HEAD")
    for marker in ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD",
                   "rebase-merge", "rebase-apply", "sequencer", "BISECT_LOG", "index.lock"):
        location = Path(decode(git(repo, "rev-parse", "--git-path", marker)).strip())
        if not location.is_absolute():
            location = repo / location
        if location.exists():
            raise SafetyError(f"Repository operation in progress: {marker}.")
    return branch


def excluded_path(path):
    p = PurePosixPath(path)
    parts = tuple(part.lower() for part in p.parts)
    if path not in ("README.md", ".gitignore") and not path.startswith("kltn/"):
        return "outside KLTN scope"
    if p.suffix.lower() in {".log", ".jou", ".vcd", ".wdb", ".wcfg", ".str",
                            ".zip", ".pdf", ".pyc", ".pyo"}:
        return "generated/archive/reference file"
    if any(part in {"__pycache__", ".xil", "build", "cache", ".cache", "ip_user_files"}
           or part.endswith((".cache", ".runs", ".sim", ".hw", ".ip_user_files", ".gen"))
           for part in parts[:-1]):
        return "generated build/cache directory"
    if parts[:2] == ("kltn", "reports") and (
        "before" in parts[2:-1] or any(x.startswith("backup_") for x in parts[2:])
        or parts[-1] == "frozen_before.json"
    ):
        return "report backup/snapshot"
    return ""


def get_changed_files(repo):
    # NUL records support spaces, tabs, newlines and non-ASCII filenames.
    # Disabling rename detection represents renames as Deleted + Added.
    status = git(repo, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames")
    changes = {}
    raw = git(repo, "diff", "--name-status", "--no-renames", "-z", "HEAD", "--").split(b"\0")
    for i in range(0, len(raw) - 1, 2):
        kind, path = decode(raw[i]), decode(raw[i + 1])
        changes[path] = Change({"A": "Added", "D": "Deleted"}.get(kind, "Modified"), path)
    for record in status.split(b"\0"):
        if record.startswith(b"?? "):
            path = decode(record[3:])
            changes[path] = Change("Added", path)
    return sorted(changes.values(), key=lambda change: change.path)


def classify_changes(repo, changes):
    if not changes:
        return [], []
    ignored = set(decode(p) for p in git(
        repo, "check-ignore", "--no-index", "--stdin", "-z",
        input_data=b"".join(os.fsencode(c.path) + b"\0" for c in changes), allowed=(0, 1),
    ).split(b"\0") if p)
    selected, excluded = [], []
    for change in changes:
        reason = excluded_path(change.path)
        if change.path in ignored:
            reason = "ignored by Git (including already tracked files)"
        if (repo / change.path).is_dir():
            reason = "directory/submodule; requires manual review"
        if reason:
            excluded.append((change, reason))
        else:
            selected.append(change)
    return selected, excluded


def collect_diffs(repo, changes):
    result = []
    for change in changes:
        patch = git(repo, "diff", "--no-ext-diff", "--no-textconv", "--no-renames",
                    "--unified=2", "HEAD", "--", change.path).decode("utf-8", "replace")
        if change.status == "Added" and not patch:
            path = repo / change.path
            if path.is_symlink():
                patch = "+" + os.readlink(path)
            else:
                with path.open("rb") as source:
                    sample = source.read(65536)
                if b"\0" not in sample:
                    patch = "\n".join("+" + line for line in sample.decode("utf-8", "replace").splitlines())
        result.append(Change(change.status, change.path, patch))
    return result


def describe_change(change):
    path = change.path.lower()
    name = PurePosixPath(path).stem
    changed_lines = "\n".join(line[1:] for line in change.diff.splitlines()
                             if line[:1] in ("+", "-") and not line.startswith(("+++", "---")))
    if "fp32_addsub" in name:
        return "FP32 add/sub testbench" if "/tb/" in path or name.startswith("tb_") else "FP32 add/sub execution unit"
    if "fp_csr" in name:
        return "floating-point CSR logic"
    if "/rtl/core_if/" in path:
        if "decode" in name and re.search(r"FMUL|FADD|FSUB|F[LS]W|7'b1010011", changed_lines, re.I):
            return "RV32IF floating-point instruction decoding"
        if "pipeline" in name or "hazard" in name or "forward" in name:
            return "RV32IF pipeline control"
        if "fmul" in name or "fp32_mul" in name:
            return "FP32 multiply execution unit"
        return "RV32IF core implementation"
    for fragment, description in (
        ("/rtl/matrix/", "matrix coprocessor RTL"),
        ("/assembler/", "instruction assembler"),
        ("/iss/", "ISA reference model"),
        ("/tb/", "RTL verification tests"),
        ("/sim/", "simulation configuration and tools"),
    ):
        if fragment in path:
            return description
    if "auto_daily_commit" in path:
        if name.startswith("test_"):
            return "daily Git checkpoint tests"
        return "daily Git checkpoint setup guide" if path.endswith(".md") else "daily Git checkpoint automation"
    for fragment, description in (("/scripts/", "project scripts"), ("/rtl/", "RTL implementation"),
                                  ("/docs/", "project documentation"), ("/reports/", "project reports"),
                                  ("/constraints/", "implementation constraints")):
        if fragment in path:
            return description
    if path == ".gitignore":
        return "Git ignore rules"
    if path == "readme.md":
        return "repository README"
    return f"project file {change.path!r}"


def generate_change_summary(changes, max_lines=10):
    actions = {"Added": "Add", "Modified": "Update", "Deleted": "Remove"}
    groups = Counter((change.status, describe_change(change)) for change in changes)
    lines = [f"{actions[status]} {description}" + (f" ({count} files)" if count > 1 else "")
             for (status, description), count in groups.items()]
    if len(lines) > max_lines:
        omitted = len(lines) - max_lines + 1
        lines = lines[:max_lines - 1] + [f"Include {omitted} other grouped project changes"]
    return lines


def build_commit_message(changes, today=None):
    return f"Daily KLTN update {today or date.today().isoformat()}\n\n" + "\n".join(
        "- " + line for line in generate_change_summary(changes)
    ) + "\n"


def stage_changes(repo, changes):
    # Explicit literal paths only; stdin avoids command-line length limits.
    git(repo, "add", "--all", "--pathspec-from-file=-", "--pathspec-file-nul",
        input_data=b"".join(os.fsencode(c.path) + b"\0" for c in changes))


def index_fingerprint(repo):
    return git(repo, "diff", "--cached", "--raw", "--no-abbrev", "--no-renames", "-z")


def tracked_diff_stat(repo, changes):
    # Small batches also work with Windows' command-line size limit.
    return "".join(git(repo, "diff", "--stat", "HEAD", "--", *[
        c.path for c in changes[start:start + 32]
    ]).decode("utf-8", "replace") for start in range(0, len(changes), 32))


def create_commit(repo, message):
    output = git(repo, "commit", "--file=-", input_data=message.encode("utf-8"))
    print(output.decode("utf-8", "replace"), end="", flush=True)
    return decode(git(repo, "rev-parse", "HEAD")).strip()


def push_changes(repo):
    check_repository_state(repo)
    urls = decode(git(repo, "remote", "get-url", "--push", "--all", "origin")).splitlines()
    if urls != [EXPECTED_REMOTE]:
        raise SafetyError(f"Unexpected push destination(s): {urls!r}; local commit retained.")
    output = git(repo, "push", "origin", BRANCH)
    print(output.decode("utf-8", "replace"), end="", flush=True)


def state_directory(repo):
    state = (Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state")))
             / "kltn-auto-commit").resolve()
    if state == repo or repo in state.parents:
        raise SafetyError("Log/state directory must be outside the repository.")
    state.mkdir(parents=True, exist_ok=True)
    return state


def write_log(state, message):
    with (state / "auto_commit.log").open("a", encoding="utf-8") as log:
        log.write(f"[{datetime.now().astimezone().isoformat(timespec='seconds')}] {message}\n")


@contextmanager
def run_lock(state, repo):
    key = hashlib.sha256(os.fsencode(os.path.normcase(str(repo.resolve())))).hexdigest()[:16]
    with (state / f"{key}.lock").open("a+b") as handle:
        if os.name == "nt":
            import msvcrt
            if handle.tell() == 0:
                handle.write(b"0")
                handle.flush()
            handle.seek(0)
            try:
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            except OSError as error:
                raise SafetyError("Another daily checkpoint is running.") from error
        else:
            import fcntl
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as error:
                raise SafetyError("Another daily checkpoint is running.") from error
        try:
            yield
        finally:
            if os.name == "nt":
                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(handle, fcntl.LOCK_UN)


def print_preview(repo, branch, changes, message, stat):
    print("=" * 40)
    print("KLTN DAILY COMMIT")
    print(f"Date: {date.today().isoformat()}\nBranch: {branch}\nRepository: {repo}")
    print(f"Files changed: {len(changes)}")
    for change in changes:
        print(f"  {change.status:8} {change.path!r}")
    if stat:
        print("Diff stat (tracked files):\n" + stat.rstrip())
    print("Generated commit message:\n" + message)
    print("=" * 40, flush=True)


def run(repo, state, args):
    with run_lock(state, repo):
        branch = check_repository_state(repo)
        head = git(repo, "rev-parse", "HEAD")
        selected, excluded = classify_changes(repo, get_changed_files(repo))
        for change, reason in excluded:
            print(f"Skip {change.path!r}: {reason}")
        if not selected:
            print("No eligible KLTN changes; nothing to commit.")
            write_log(state, "No eligible changes.")
            return
        preview = args.dry_run or args.show_summary
        cached_before = git(repo, "diff", "--cached", "--no-ext-diff", "--no-textconv", "--binary")
        if cached_before and not preview:
            raise SafetyError("Index already has staged changes. Commit or unstage them manually first.")
        changes = collect_diffs(repo, selected)
        # Run the requested worktree check and also check existing staged changes.
        git(repo, "diff", "--check")
        git(repo, "diff", "--cached", "--check")
        stat = tracked_diff_stat(repo, changes)
        message = build_commit_message(changes)
        print_preview(repo, branch, changes, message, stat)
        if preview:
            if cached_before:
                print("NOTE: Existing staged changes will block a normal run.")
            print("Preview only: no git add, commit or push. Untracked whitespace is checked after staging in a normal run.")
            write_log(state, "Preview only.\n" + message)
            return
        check_repository_state(repo)
        if git(repo, "rev-parse", "HEAD") != head or git(repo, "diff", "--cached", "--name-only", "-z"):
            raise SafetyError("HEAD/index changed during analysis; retry when Git is idle.")
        # Keep the user's files and index intact on failure; never reset/clean.
        stage_changes(repo, changes)
        staged_fingerprint = index_fingerprint(repo)
        staged = git(repo, "diff", "--cached", "--name-status", "--no-renames", "-z").split(b"\0")
        staged_paths = {decode(staged[i]) for i in range(1, len(staged) - 1, 2)}
        expected = {c.path for c in changes}
        if staged_paths != expected:
            raise SafetyError("Staged paths changed unexpectedly; inspect the index manually.")
        git(repo, "diff", "--check")
        git(repo, "diff", "--cached", "--check")
        staged_changes = []
        for i in range(0, len(staged) - 1, 2):
            path = decode(staged[i + 1])
            patch = git(repo, "diff", "--cached", "--no-ext-diff", "--no-textconv", "--", path)
            staged_changes.append(Change({b"A": "Added", b"D": "Deleted"}.get(staged[i], "Modified"),
                                         path, patch.decode("utf-8", "replace")))
        approved, rejected = classify_changes(repo, staged_changes)
        if rejected or len(approved) != len(changes):
            raise SafetyError("File eligibility changed during staging; inspect the index manually.")
        message = build_commit_message(staged_changes)
        stat = git(repo, "diff", "--cached", "--stat").decode("utf-8", "replace")
        print_preview(repo, branch, staged_changes, message, stat)
        check_repository_state(repo)
        if git(repo, "rev-parse", "HEAD") != head or index_fingerprint(repo) != staged_fingerprint:
            raise SafetyError("HEAD/index changed during staging; inspect the index manually.")
        commit = create_commit(repo, message)
        write_log(state, f"COMMIT {commit}\n{message}")
        if args.push or os.environ.get("AUTO_PUSH", "false").lower() == "true":
            write_log(state, f"PUSH requested for local commit {commit}.")
            push_changes(repo)
            write_log(state, f"PUSH succeeded: {commit}")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="Preview without staging, committing or pushing")
    parser.add_argument("--show-summary", action="store_true", help="Read-only change summary (same safety as dry-run)")
    parser.add_argument("--push", action="store_true", help="Push origin master after a successful new local commit")
    args = parser.parse_args(argv)
    state = None
    try:
        # Establish external logging before repository validation so failures are logged.
        state = state_directory(Path(__file__).resolve().parents[2])
        repo = get_repo_root()
        run(repo, state, args)
        return 0
    except (SafetyError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr, flush=True)
        if state is not None:
            try:
                write_log(state, f"ERROR: {error}")
            except OSError as log_error:
                print(f"ERROR writing log: {log_error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
