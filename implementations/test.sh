#!/usr/bin/env bash
# Smoke tests for the .worktreeinclude implementations (Python and Bash).
#
# Creates a temporary git repo, populates it with test fixtures, and runs
# both implementations through identical scenarios.
#
# Usage:
#   ./implementations/test.sh              # test both implementations
#   ./implementations/test.sh python       # test only python
#   ./implementations/test.sh bash         # test only bash
#   ./implementations/test.sh --ci         # CI mode: GitHub Actions annotations
#   ./implementations/test.sh --ci python  # CI mode with filter

set -euo pipefail

# ── Paths ────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PY_CMD="python3 $SCRIPT_DIR/python/worktreeinclude.py"
SH_CMD="$SCRIPT_DIR/bash/worktreeinclude.sh"

# ── Test harness ─────────────────────────────────────────────────────────────────

PASS=0
FAIL=0
SKIP=0
CURRENT_IMPL=""
CI_MODE=0

pass() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
fail() {
    FAIL=$((FAIL + 1))
    echo "  FAIL  $1"
    if (( CI_MODE )); then
        echo "::error title=Test Failed::$1"
    fi
}
skip() { SKIP=$((SKIP + 1)); echo "  SKIP  $1"; }

# Run a command, capture exit code + stdout + stderr separately.
# Sets: RC, STDOUT, STDERR
run() {
    local tmpout tmperr
    tmpout=$(mktemp)
    tmperr=$(mktemp)
    RC=0
    "$@" >"$tmpout" 2>"$tmperr" || RC=$?
    STDOUT=$(cat "$tmpout")
    STDERR=$(cat "$tmperr")
    rm -f "$tmpout" "$tmperr"
}

assert_exit() {
    local expected="$1" label="$2"
    if (( RC == expected )); then
        pass "$label"
    else
        fail "$label (expected exit $expected, got $RC)"
        echo "        stderr: ${STDERR:0:200}"
    fi
}

assert_stdout_contains() {
    local pattern="$1" label="$2"
    if echo "$STDOUT" | grep -q "$pattern"; then
        pass "$label"
    else
        fail "$label (stdout missing: '$pattern')"
        echo "        stdout: ${STDOUT:0:200}"
    fi
}

assert_stderr_contains() {
    local pattern="$1" label="$2"
    if echo "$STDERR" | grep -q "$pattern"; then
        pass "$label"
    else
        fail "$label (stderr missing: '$pattern')"
        echo "        stderr: ${STDERR:0:200}"
    fi
}

assert_file_exists() {
    local path="$1" label="$2"
    if [[ -e "$path" ]]; then
        pass "$label"
    else
        fail "$label (file not found: $path)"
    fi
}

assert_file_not_exists() {
    local path="$1" label="$2"
    if [[ ! -e "$path" ]] && [[ ! -L "$path" ]]; then
        pass "$label"
    else
        fail "$label (file unexpectedly exists: $path)"
    fi
}

assert_symlink() {
    local path="$1" label="$2"
    if [[ -L "$path" ]]; then
        pass "$label"
    else
        fail "$label (not a symlink: $path)"
    fi
}

assert_not_symlink() {
    local path="$1" label="$2"
    if [[ -e "$path" ]] && [[ ! -L "$path" ]]; then
        pass "$label"
    else
        fail "$label (expected regular file, got symlink: $path)"
    fi
}

assert_file_content() {
    local path="$1" expected="$2" label="$3"
    if [[ -f "$path" ]] && [[ "$(cat "$path")" == "$expected" ]]; then
        pass "$label"
    else
        fail "$label (content mismatch in $path)"
    fi
}

# ── Fixture setup ────────────────────────────────────────────────────────────────

TMPDIR_ROOT=""
REPO=""

setup_repo() {
    TMPDIR_ROOT=$(mktemp -d)
    REPO="$TMPDIR_ROOT/repo"

    # Create a git repo with an initial commit.
    mkdir -p "$REPO"
    git -C "$REPO" init -b main --quiet
    git -C "$REPO" config user.email "test@test.com"
    git -C "$REPO" config user.name "Test"
    echo "tracked" > "$REPO/tracked.txt"
    git -C "$REPO" add tracked.txt
    git -C "$REPO" commit -m "initial" --quiet

    # Create untracked source files for the manifest.
    echo "secret=abc123"         > "$REPO/.env.local"
    mkdir -p "$REPO/config/creds"
    echo "dev-key-data"          > "$REPO/config/creds/dev.key"
    mkdir -p "$REPO/data"
    echo "large-asset-content"   > "$REPO/data/big.db"

    # Create the .worktreeinclude manifest.
    cat > "$REPO/.worktreeinclude" <<'MANIFEST'
# Environment files
.env.local
config/creds/dev.key

# @symlink
data/big.db

# @optional
.env.test.local
MANIFEST

    # Create the target worktree directory (simulates a linked worktree).
    mkdir -p "$TMPDIR_ROOT/target"
}

cleanup() {
    if [[ -n "$TMPDIR_ROOT" ]] && [[ -d "$TMPDIR_ROOT" ]]; then
        # Clean up any git worktrees we created via --hook.
        local wt_dir="$REPO/.worktrees"
        if [[ -d "$wt_dir" ]]; then
            for wt in "$wt_dir"/*/; do
                [[ -d "$wt" ]] || continue
                git -C "$REPO" worktree remove "$wt" --force 2>/dev/null || true
            done
        fi
        # Delete leftover branches.
        git -C "$REPO" for-each-ref --format='%(refname:short)' refs/heads/worktree/ 2>/dev/null | while read -r b; do
            git -C "$REPO" branch -D "$b" 2>/dev/null || true
        done
        rm -rf "$TMPDIR_ROOT"
    fi
}
trap cleanup EXIT

# Reset target to empty state between tests.
reset_target() {
    rm -rf "$TMPDIR_ROOT/target"
    mkdir -p "$TMPDIR_ROOT/target"
}

# ── Test suites ──────────────────────────────────────────────────────────────────

test_help() {
    local cmd="$1" impl="$2"

    echo ""
    echo "--- $impl: help ---"

    run $cmd create --help
    assert_exit 0 "$impl: create --help exits 0"
    # Python writes help to stdout, Bash writes to stderr.
    if echo "$STDOUT$STDERR" | grep -q "hook"; then
        pass "$impl: create --help mentions --hook"
    else
        fail "$impl: create --help mentions --hook"
    fi

    run $cmd remove --help
    assert_exit 0 "$impl: remove --help exits 0"
}

test_create_basic() {
    local cmd="$1" impl="$2"

    echo ""
    echo "--- $impl: create (basic copy + symlink + optional skip) ---"
    reset_target

    run $cmd create --source "$REPO" --target "$TMPDIR_ROOT/target"
    assert_exit 0 "$impl: create exits 0"
    assert_file_exists "$TMPDIR_ROOT/target/.env.local"      "$impl: .env.local copied"
    assert_file_content "$TMPDIR_ROOT/target/.env.local" "secret=abc123" "$impl: .env.local content matches"
    assert_file_exists "$TMPDIR_ROOT/target/config/creds/dev.key" "$impl: nested file copied"
    assert_not_symlink "$TMPDIR_ROOT/target/.env.local"           "$impl: .env.local is a copy, not a symlink"
    assert_not_symlink "$TMPDIR_ROOT/target/config/creds/dev.key" "$impl: nested file is a copy, not a symlink"
    assert_symlink "$TMPDIR_ROOT/target/data/big.db"          "$impl: data/big.db is a symlink"
    assert_file_not_exists "$TMPDIR_ROOT/target/.env.test.local" "$impl: optional missing file skipped"
    assert_stderr_contains "SKIP" "$impl: stderr reports SKIP for optional entry"
}

test_create_dry_run() {
    local cmd="$1" impl="$2"

    echo ""
    echo "--- $impl: create --dry-run ---"
    reset_target

    run $cmd create --source "$REPO" --target "$TMPDIR_ROOT/target" --dry-run
    assert_exit 0 "$impl: create --dry-run exits 0"
    assert_file_not_exists "$TMPDIR_ROOT/target/.env.local" "$impl: dry-run does not create files"
    assert_stderr_contains "DRY" "$impl: stderr reports DRY"
}

test_create_existing_destination_fails() {
    local cmd="$1" impl="$2"

    echo ""
    echo "--- $impl: create fails on existing destination ---"
    reset_target
    mkdir -p "$TMPDIR_ROOT/target"
    echo "existing" > "$TMPDIR_ROOT/target/.env.local"

    run $cmd create --source "$REPO" --target "$TMPDIR_ROOT/target"
    assert_exit 1 "$impl: create exits 1 when destination exists"
    assert_stderr_contains "already exists" "$impl: stderr mentions existing destination"
}

test_create_force() {
    local cmd="$1" impl="$2"

    echo ""
    echo "--- $impl: create --force overwrites ---"
    reset_target
    echo "old" > "$TMPDIR_ROOT/target/.env.local"

    run $cmd create --source "$REPO" --target "$TMPDIR_ROOT/target" --force
    assert_exit 0 "$impl: create --force exits 0"
    assert_file_content "$TMPDIR_ROOT/target/.env.local" "secret=abc123" "$impl: file overwritten with source content"
}

test_create_missing_required_fails() {
    local cmd="$1" impl="$2"

    echo ""
    echo "--- $impl: create fails on missing required source ---"
    reset_target

    # Use a manifest with a non-existent required path.
    local saved
    saved=$(cat "$REPO/.worktreeinclude")
    echo "nonexistent/file.txt" > "$REPO/.worktreeinclude"

    run $cmd create --source "$REPO" --target "$TMPDIR_ROOT/target"
    assert_exit 1 "$impl: create exits 1 for missing required source"
    assert_stderr_contains "required source path not found" "$impl: stderr mentions missing source"

    # Restore manifest.
    echo "$saved" > "$REPO/.worktreeinclude"
}

test_create_tracked_path_warns() {
    local cmd="$1" impl="$2"

    echo ""
    echo "--- $impl: create warns on tracked paths (default) ---"
    reset_target

    local saved
    saved=$(cat "$REPO/.worktreeinclude")
    echo "tracked.txt" > "$REPO/.worktreeinclude"

    run $cmd create --source "$REPO" --target "$TMPDIR_ROOT/target"
    assert_exit 0 "$impl: create exits 0 for tracked path (default: warn + skip)"
    assert_stderr_contains "tracked by Git" "$impl: stderr mentions tracked path"
    assert_stderr_contains "WARN" "$impl: stderr shows WARN for tracked path"

    echo "$saved" > "$REPO/.worktreeinclude"
}

test_create_tracked_path_pedantic_fails() {
    local cmd="$1" impl="$2"

    echo ""
    echo "--- $impl: create --pedantic rejects tracked paths ---"
    reset_target

    local saved
    saved=$(cat "$REPO/.worktreeinclude")
    echo "tracked.txt" > "$REPO/.worktreeinclude"

    run $cmd create --source "$REPO" --target "$TMPDIR_ROOT/target" --pedantic
    assert_exit 1 "$impl: create exits 1 for tracked path with --pedantic"
    assert_stderr_contains "tracked by Git" "$impl: stderr mentions tracked path"

    echo "$saved" > "$REPO/.worktreeinclude"
}

test_create_quiet() {
    local cmd="$1" impl="$2"

    echo ""
    echo "--- $impl: create --quiet ---"
    reset_target

    # Run from a dedicated temp directory so worktree.log lands there.
    local quiet_cwd="$TMPDIR_ROOT/quiet_cwd_$$"
    mkdir -p "$quiet_cwd"

    run bash -c "cd '$quiet_cwd' && $cmd create --source '$REPO' --target '$TMPDIR_ROOT/target' --quiet"
    assert_exit 0 "$impl: create --quiet exits 0"
    if [[ -z "$STDERR" ]]; then
        pass "$impl: --quiet silences stderr"
    else
        fail "$impl: --quiet should silence stderr but got output"
        echo "        stderr: ${STDERR:0:200}"
    fi
    assert_file_exists "$TMPDIR_ROOT/target/.env.local" "$impl: --quiet still creates files"
    assert_file_exists "$quiet_cwd/worktree.log" "$impl: --quiet writes to worktree.log"

    # Verify the log file has content.
    if [[ -s "$quiet_cwd/worktree.log" ]]; then
        pass "$impl: worktree.log contains log lines"
    else
        fail "$impl: worktree.log is empty"
    fi

    rm -rf "$quiet_cwd"
}

test_create_invalid_path_fails() {
    local cmd="$1" impl="$2"

    echo ""
    echo "--- $impl: create rejects invalid paths ---"
    reset_target

    local saved
    saved=$(cat "$REPO/.worktreeinclude")

    # Absolute path.
    echo "/etc/passwd" > "$REPO/.worktreeinclude"
    run $cmd create --source "$REPO" --target "$TMPDIR_ROOT/target"
    assert_exit 1 "$impl: create exits 1 for absolute path"

    # Path escaping root.
    echo "../../etc/passwd" > "$REPO/.worktreeinclude"
    run $cmd create --source "$REPO" --target "$TMPDIR_ROOT/target"
    assert_exit 1 "$impl: create exits 1 for path escaping root"

    # .git path.
    echo ".git/config" > "$REPO/.worktreeinclude"
    run $cmd create --source "$REPO" --target "$TMPDIR_ROOT/target"
    assert_exit 1 "$impl: create exits 1 for .git path"

    echo "$saved" > "$REPO/.worktreeinclude"
}

test_remove() {
    local cmd="$1" impl="$2"

    echo ""
    echo "--- $impl: remove ---"
    reset_target

    # First create, then remove.
    run $cmd create --source "$REPO" --target "$TMPDIR_ROOT/target"
    assert_exit 0 "$impl: create before remove exits 0"

    run $cmd remove --source "$REPO" --target "$TMPDIR_ROOT/target"
    assert_exit 0 "$impl: remove exits 0"
    assert_file_not_exists "$TMPDIR_ROOT/target/.env.local"      "$impl: .env.local removed"
    assert_file_not_exists "$TMPDIR_ROOT/target/config/creds/dev.key" "$impl: nested file removed"
    assert_file_not_exists "$TMPDIR_ROOT/target/data/big.db"     "$impl: symlink removed"
}

test_remove_dry_run() {
    local cmd="$1" impl="$2"

    echo ""
    echo "--- $impl: remove --dry-run ---"
    reset_target

    # Create first.
    run $cmd create --source "$REPO" --target "$TMPDIR_ROOT/target"

    run $cmd remove --source "$REPO" --target "$TMPDIR_ROOT/target" --dry-run
    assert_exit 0 "$impl: remove --dry-run exits 0"
    assert_file_exists "$TMPDIR_ROOT/target/.env.local" "$impl: dry-run does not remove files"
    assert_stderr_contains "DRY" "$impl: stderr reports DRY"
}

test_no_manifest() {
    local cmd="$1" impl="$2"

    echo ""
    echo "--- $impl: no manifest ---"
    reset_target

    local saved
    saved=$(cat "$REPO/.worktreeinclude")
    rm "$REPO/.worktreeinclude"

    run $cmd create --source "$REPO" --target "$TMPDIR_ROOT/target"
    assert_exit 0 "$impl: create with no manifest exits 0"
    assert_stderr_contains "nothing to do" "$impl: stderr says nothing to do"

    echo "$saved" > "$REPO/.worktreeinclude"
}

test_unknown_directive_fails() {
    local cmd="$1" impl="$2"

    echo ""
    echo "--- $impl: unknown directive fails ---"
    reset_target

    local saved
    saved=$(cat "$REPO/.worktreeinclude")
    printf '# @bogus\n.env.local\n' > "$REPO/.worktreeinclude"

    run $cmd create --source "$REPO" --target "$TMPDIR_ROOT/target"
    assert_exit 1 "$impl: create exits 1 for unknown directive"
    assert_stderr_contains "unknown directive" "$impl: stderr mentions unknown directive"

    echo "$saved" > "$REPO/.worktreeinclude"
}

test_hook_create() {
    local cmd="$1" impl="$2"

    echo ""
    echo "--- $impl: create --hook ---"

    local hook_name="smoke-${impl}-$$"
    run bash -c "cd '$REPO' && echo '{\"name\":\"$hook_name\",\"cwd\":\"/tmp\"}' | $cmd create --hook"
    assert_exit 0 "$impl: create --hook exits 0"
    assert_stdout_contains ".worktrees/$hook_name" "$impl: stdout prints worktree path"

    local wt_path="$REPO/.worktrees/$hook_name"
    assert_file_exists "$wt_path" "$impl: worktree directory created"

    # Verify the git worktree is registered.
    if git -C "$REPO" worktree list --porcelain | grep -q "$hook_name"; then
        pass "$impl: worktree registered in git"
    else
        fail "$impl: worktree not registered in git"
    fi

    # Clean up this worktree.
    git -C "$REPO" worktree remove "$wt_path" --force 2>/dev/null || true
    git -C "$REPO" branch -D "worktree/$hook_name" 2>/dev/null || true
}

test_hook_remove() {
    local cmd="$1" impl="$2"

    echo ""
    echo "--- $impl: remove --hook ---"

    run bash -c "cd '$REPO' && echo '{\"worktree_path\":\"/tmp/nonexistent\"}' | $cmd remove --hook"
    assert_exit 0 "$impl: remove --hook exits 0 (no manifest = nothing to do)"
}

# ── Run all tests for one implementation ─────────────────────────────────────────

run_suite() {
    local cmd="$1" impl="$2"
    CURRENT_IMPL="$impl"

    if (( CI_MODE )); then echo "::group::Testing: $impl"; fi
    echo ""
    echo "=============================="
    echo "  Testing: $impl"
    echo "=============================="

    test_help              "$cmd" "$impl"
    test_create_basic      "$cmd" "$impl"
    test_create_dry_run    "$cmd" "$impl"
    test_create_existing_destination_fails "$cmd" "$impl"
    test_create_force      "$cmd" "$impl"
    test_create_missing_required_fails     "$cmd" "$impl"
    test_create_tracked_path_warns         "$cmd" "$impl"
    test_create_tracked_path_pedantic_fails "$cmd" "$impl"
    test_create_quiet                      "$cmd" "$impl"
    test_create_invalid_path_fails         "$cmd" "$impl"
    test_remove            "$cmd" "$impl"
    test_remove_dry_run    "$cmd" "$impl"
    test_no_manifest       "$cmd" "$impl"
    test_unknown_directive_fails           "$cmd" "$impl"
    test_hook_create       "$cmd" "$impl"
    test_hook_remove       "$cmd" "$impl"

    if (( CI_MODE )); then echo "::endgroup::"; fi
}

# ── Main ─────────────────────────────────────────────────────────────────────────

main() {
    # Parse --ci flag from any position; remaining args become the filter.
    local filter="all"
    for arg in "$@"; do
        case "$arg" in
            --ci) CI_MODE=1 ;;
            *)    filter="$arg" ;;
        esac
    done

    echo "Setting up test fixtures..."
    setup_repo
    echo "Repo: $REPO"

    case "$filter" in
        python) run_suite "$PY_CMD" "python" ;;
        bash)   run_suite "$SH_CMD" "bash" ;;
        all)
            run_suite "$PY_CMD" "python"
            run_suite "$SH_CMD" "bash"
            ;;
        *)
            echo "Usage: $0 [--ci] [python|bash|all]" >&2
            exit 1
            ;;
    esac

    echo ""
    echo "=============================="
    echo "  Results: $PASS passed, $FAIL failed, $SKIP skipped"
    echo "=============================="

    # Write GitHub Actions job summary when in CI mode.
    if (( CI_MODE )) && [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        cat >> "$GITHUB_STEP_SUMMARY" <<EOF
| Result | Count |
|--------|-------|
| Passed | $PASS |
| Failed | $FAIL |
| Skipped| $SKIP |
EOF
    fi

    if (( FAIL > 0 )); then
        exit 1
    fi
    exit 0
}

main "$@"
