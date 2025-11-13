#!/usr/bin/env python3
"""
Script to check if local code matches remote repository.

Usage:
    python check_sync.py
"""

import subprocess
import sys

def run_command(cmd):
    """Run shell command and return output"""
    try:
        result = subprocess.run(
            cmd,
            shell=True,
            capture_output=True,
            text=True,
            encoding='utf-8',
            errors='replace'
        )
        return result.returncode, result.stdout, result.stderr
    except Exception as e:
        return 1, "", str(e)

def check_git_status():
    """Check git status"""
    print("="*70)
    print("CHECKING GIT SYNC STATUS")
    print("="*70)
    
    # 1. Check if we're in a git repo
    code, _, _ = run_command("git rev-parse --git-dir")
    if code != 0:
        print("❌ Not a git repository!")
        return False
    
    # 2. Get current branch
    code, branch, _ = run_command("git branch --show-current")
    if code != 0:
        print("❌ Cannot determine current branch")
        return False
    
    branch = branch.strip()
    print(f"\n[1] Current branch: {branch}")
    
    # 3. Fetch from remote
    print(f"\n[2] Fetching from remote...")
    code, _, _ = run_command("git fetch origin")
    if code != 0:
        print("    ⚠️  Cannot fetch from remote (no internet?)")
    else:
        print("    ✅ Fetched successfully")
    
    # 4. Check if branch is up to date with remote
    print(f"\n[3] Comparing with remote (origin/{branch})...")
    code, output, _ = run_command(f"git rev-list --left-right --count origin/{branch}...HEAD")
    if code == 0 and output:
        behind, ahead = output.strip().split()
        behind = int(behind)
        ahead = int(ahead)
        
        if behind == 0 and ahead == 0:
            print(f"    ✅ Up to date with origin/{branch}")
        elif behind > 0 and ahead == 0:
            print(f"    ⚠️  Your branch is BEHIND origin/{branch} by {behind} commit(s)")
            print(f"       Run: git pull origin {branch}")
        elif behind == 0 and ahead > 0:
            print(f"    ⚠️  Your branch is AHEAD of origin/{branch} by {ahead} commit(s)")
            print(f"       Run: git push origin {branch}")
        else:
            print(f"    ⚠️  Your branch has DIVERGED from origin/{branch}")
            print(f"       Behind: {behind} commit(s), Ahead: {ahead} commit(s)")
    else:
        print(f"    ⚠️  Cannot compare with origin/{branch}")
    
    # 5. Check uncommitted changes
    print(f"\n[4] Checking uncommitted changes...")
    code, output, _ = run_command("git status --porcelain")
    if code == 0:
        if not output.strip():
            print("    ✅ No uncommitted changes")
        else:
            lines = output.strip().split('\n')
            modified = [l for l in lines if l.startswith(' M') or l.startswith('M ')]
            untracked = [l for l in lines if l.startswith('??')]
            deleted = [l for l in lines if l.startswith(' D') or l.startswith('D ')]
            added = [l for l in lines if l.startswith('A ')]
            
            if modified:
                print(f"    ⚠️  Modified files: {len(modified)}")
                for m in modified[:5]:
                    print(f"       - {m[3:]}")
                if len(modified) > 5:
                    print(f"       ... and {len(modified) - 5} more")
            
            if untracked:
                print(f"    ℹ️  Untracked files: {len(untracked)}")
                for u in untracked[:5]:
                    print(f"       - {u[3:]}")
                if len(untracked) > 5:
                    print(f"       ... and {len(untracked) - 5} more")
            
            if deleted:
                print(f"    ⚠️  Deleted files: {len(deleted)}")
                for d in deleted:
                    print(f"       - {d[3:]}")
            
            if added:
                print(f"    ✅ New files staged: {len(added)}")
    
    # 6. Check differences with remote
    print(f"\n[5] Checking code differences with origin/{branch}...")
    code, output, _ = run_command(f"git diff origin/{branch} --stat")
    if code == 0:
        if not output.strip():
            print("    ✅ Code matches remote repository")
        else:
            print("    ⚠️  Code differs from remote:")
            print("    " + output.replace("\n", "\n    "))
    
    # 7. Summary
    print("\n" + "="*70)
    print("SUMMARY")
    print("="*70)
    
    code1, output1, _ = run_command(f"git rev-list --left-right --count origin/{branch}...HEAD")
    code2, output2, _ = run_command("git status --porcelain")
    
    is_synced = True
    
    if code1 == 0 and output1:
        behind, ahead = output1.strip().split()
        if int(behind) > 0 or int(ahead) > 0:
            is_synced = False
            print(f"⚠️  Branch not synced with remote")
    
    if code2 == 0 and output2.strip():
        is_synced = False
        print(f"⚠️  You have uncommitted changes")
    
    if is_synced:
        print("✅ Your code is fully synced with remote repository!")
        print("\nYou can safely share your code with teammates.")
        return True
    else:
        print("\n📝 To sync your code:")
        print("   1. Commit changes: git add . && git commit -m 'message'")
        print("   2. Pull updates: git pull origin " + branch)
        print("   3. Push changes: git push origin " + branch)
        return False

def main():
    try:
        is_synced = check_git_status()
        return 0 if is_synced else 1
    except Exception as e:
        print(f"\n❌ Error: {e}")
        return 1

if __name__ == '__main__':
    sys.exit(main())
