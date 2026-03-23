#!/usr/bin/env bash
# Reference implementation of the .worktreeinclude specification (v0.1).
#
# Materializes local development files (environment configs, credentials,
# large assets) into newly created Git worktrees, as defined by a
# .worktreeinclude manifest at the repository root.
#
# Supports two subcommands:
#
#   create  -- read the manifest from the source checkout and materialize
#              each entry into the target worktree via copy or symlink.
#   remove  -- read the manifest and remove previously materialized entries
#              from the target worktree.
#
# Requires: Bash 4+, Git, standard coreutils (cp, ln, rm, mkdir)
#
# See SPEC.md for the full specification.

set -euo pipefail

readonly MANIFEST_NAME=".worktreeinclude"

# ── Logging state ────────────────────────────────────────────────────────────────

QUIET="false"
LOG_FILE="worktree.log"

# ── Output helpers ───────────────────────────────────────────────────────────────

_validate_log_file() {
    # When --quiet is set, the log file is mandatory — otherwise there
    # would be no output at all.  In non-quiet mode, log file failures
    # are best-effort (stderr still works).
    if [[ "$QUIET" == "true" ]]; then
        if ! echo "" >> "$LOG_FILE" 2>/dev/null; then
            echo "  ERR   --quiet requires a writable log file, but $LOG_FILE could not be opened" >&2
            exit 1
        fi
    fi
}

_write_log() {
    local level="$1" message="$2"
    local ts
    ts=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')
    echo "$ts [$level] $message" >> "$LOG_FILE" 2>/dev/null || true
}

_log()      { _write_log "INFO" "$1"; [[ "$QUIET" == "true" ]] || echo "  $1" >&2; }
_log_ok()   { _write_log "INFO" "OK    $1"; [[ "$QUIET" == "true" ]] || echo "  OK    $1" >&2; }
_log_skip() { _write_log "INFO" "SKIP  $1"; [[ "$QUIET" == "true" ]] || echo "  SKIP  $1" >&2; }
_log_warn() { _write_log "WARN" "$1"; [[ "$QUIET" == "true" ]] || echo "  WARN  $1" >&2; }
_log_err()  { _write_log "ERR"  "$1"; [[ "$QUIET" == "true" ]] || echo "  ERR   $1" >&2; }
_log_dry()  { _write_log "INFO" "DRY   $1"; [[ "$QUIET" == "true" ]] || echo "  DRY   $1" >&2; }

# ── Git helpers ──────────────────────────────────────────────────────────────────

find_repo_root() {
    local from_dir="${1:-.}"
    git -C "$from_dir" rev-parse --show-toplevel 2>/dev/null \
        || { _log_err "not inside a Git repository: $from_dir"; return 1; }
}

find_main_worktree() {
    local from_dir="${1:-.}"
    local output
    output=$(git -C "$from_dir" worktree list --porcelain 2>/dev/null) \
        || { _log_err "failed to list worktrees"; return 1; }

    local path
    path=$(echo "$output" | grep -m1 '^worktree ' | sed 's/^worktree //')
    if [[ -z "$path" ]]; then
        _log_err "could not determine main worktree from git output"
        return 1
    fi
    echo "$path"
}

is_tracked() {
    # Returns 0 if the path IS tracked, 1 otherwise.
    local entry_path="$1" source_root="$2"
    git -C "$source_root" ls-files --error-unmatch "$entry_path" &>/dev/null
}

# ── Path validation ──────────────────────────────────────────────────────────────

validate_path() {
    local entry_path="$1"

    # Reject absolute paths (POSIX).
    if [[ "$entry_path" == /* ]]; then
        _log_err "absolute path not allowed: '$entry_path'"
        return 1
    fi

    # Reject paths that escape the repository root via ..
    # Normalize: split on /, resolve . and .., check we stay inside.
    local -a segments
    IFS='/' read -ra segments <<< "$entry_path"
    local depth=0
    for seg in "${segments[@]}"; do
        case "$seg" in
            ""|".") continue ;;
            "..")
                depth=$((depth - 1))
                if (( depth < 0 )); then
                    _log_err "path escapes repository root: '$entry_path'"
                    return 1
                fi
                ;;
            *)
                depth=$((depth + 1))
                ;;
        esac
    done

    # Reject paths referring to .git.
    for seg in "${segments[@]}"; do
        if [[ "$seg" == ".git" ]]; then
            _log_err "path refers to Git internals: '$entry_path'"
            return 1
        fi
    done

    return 0
}

check_safe_source() {
    local source_path="$1"
    [[ -e "$source_path" ]] || return 0

    if [[ -b "$source_path" ]] || [[ -c "$source_path" ]]; then
        _log_err "device file not allowed: $source_path"
        return 1
    fi
    if [[ -p "$source_path" ]]; then
        _log_err "named pipe not allowed: $source_path"
        return 1
    fi
    # Bash doesn't have a direct socket test; use find.
    if [[ -S "$source_path" ]]; then
        _log_err "socket not allowed: $source_path"
        return 1
    fi
    return 0
}

# ── Manifest parser ──────────────────────────────────────────────────────────────

# Parses the manifest and calls a callback for each entry.
# Callback signature: callback <path> <mode> <optional>
#   mode: "copy" or "symlink"
#   optional: "true" or "false"
parse_manifest() {
    local manifest_path="$1"
    local callback="$2"

    local pending_mode="copy"
    local pending_optional="false"
    local line_number=0

    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        line_number=$((line_number + 1))
        local trimmed
        trimmed=$(echo "$raw_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        # Empty lines.
        [[ -z "$trimmed" ]] && continue

        # Recognized directive: # @symlink
        if [[ "$trimmed" == "# @symlink" ]]; then
            pending_mode="symlink"
            continue
        fi

        # Recognized directive: # @optional
        if [[ "$trimmed" == "# @optional" ]]; then
            pending_optional="true"
            continue
        fi

        # Unknown directive — parse error.
        if [[ "$trimmed" == "# @"* ]]; then
            _log_err "line $line_number: unknown directive: '$trimmed'"
            return 1
        fi

        # Regular comment.
        if [[ "$trimmed" == "#"* ]]; then
            continue
        fi

        # Path entry — consume pending state.
        "$callback" "$trimmed" "$pending_mode" "$pending_optional"
        local rc=$?
        if (( rc != 0 )); then
            return "$rc"
        fi

        # Reset pending state.
        pending_mode="copy"
        pending_optional="false"

    done < "$manifest_path"
}

# ── Hook helpers ─────────────────────────────────────────────────────────────────

read_hook_input() {
    # Read JSON from stdin.  Uses jq if available, falls back to
    # simple grep/sed extraction for {"key":"value"} objects.
    local input
    input=$(cat)

    if command -v jq &>/dev/null; then
        echo "$input"
    else
        echo "$input"
    fi
}

json_get() {
    # Extract a string value from JSON.  Uses jq if available,
    # falls back to sed for simple flat objects.
    local json="$1" key="$2"

    if command -v jq &>/dev/null; then
        echo "$json" | jq -r ".$key"
    else
        # Fallback: simple extraction for flat JSON.
        echo "$json" | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
    fi
}

create_git_worktree() {
    local name="$1" path="$2" cwd="$3"
    local stderr
    stderr=$(git -C "$cwd" worktree add -b "worktree/$name" "$path" HEAD 2>&1) \
        || { _log_err "failed to create git worktree: $stderr"; return 1; }
}

# ── Commands ─────────────────────────────────────────────────────────────────────

cmd_create() {
    local source="$1" target="$2" force="${3:-false}" dry_run="${4:-false}" pedantic="${5:-false}"
    local manifest_path="$source/$MANIFEST_NAME"

    if [[ ! -f "$manifest_path" ]]; then
        _log "no $MANIFEST_NAME found in $source — nothing to do"
        return 0
    fi

    # Count entries for the header message.
    local entry_count=0
    local errors=0

    _log "source: $source"
    _log "target: $target"

    _materialize_entry() {
        local entry_path="$1" mode="$2" optional="$3"
        local source_path="$source/$entry_path"
        local dest_path="$target/$entry_path"
        local label="$entry_path ($mode${optional:+|optional})"
        [[ "$optional" == "false" ]] && label="$entry_path ($mode)"

        entry_count=$((entry_count + 1))

        # Validate path syntax.
        if ! validate_path "$entry_path"; then
            errors=$((errors + 1))
            return 0  # continue processing
        fi

        # Tracked paths (spec section 8).
        if is_tracked "$entry_path" "$source"; then
            if [[ "$pedantic" == "true" ]]; then
                _log_err "$label: path is tracked by Git — .worktreeinclude is for untracked/ignored paths only (spec section 8): '$entry_path'"
                errors=$((errors + 1))
                return 0
            else
                _log_warn "$label: path is tracked by Git — skipping (already in worktree via Git)"
                return 0
            fi
        fi

        # Missing source.
        if [[ ! -e "$source_path" ]]; then
            if [[ "$optional" == "true" ]]; then
                _log_skip "$label — source not found (optional)"
                return 0
            else
                _log_err "$label: required source path not found: '$entry_path'"
                errors=$((errors + 1))
                return 0
            fi
        fi

        # Safety check on source.
        if ! check_safe_source "$source_path"; then
            errors=$((errors + 1))
            return 0
        fi

        # Existing destination.
        if [[ -e "$dest_path" ]] || [[ -L "$dest_path" ]]; then
            if [[ "$force" == "true" ]]; then
                if [[ "$dry_run" != "true" ]]; then
                    if [[ -d "$dest_path" ]] && [[ ! -L "$dest_path" ]]; then
                        rm -rf "$dest_path"
                    else
                        rm -f "$dest_path"
                    fi
                fi
            else
                _log_err "$label: destination already exists: '$entry_path'"
                errors=$((errors + 1))
                return 0
            fi
        fi

        # Dry run.
        if [[ "$dry_run" == "true" ]]; then
            _log_dry "$label: $source_path -> $dest_path"
            return 0
        fi

        # Materialize.
        mkdir -p "$(dirname "$dest_path")"

        case "$mode" in
            copy)
                if [[ -d "$source_path" ]]; then
                    cp -a "$source_path" "$dest_path" 2>&1 \
                        || { _log_err "$label: failed to copy $source_path -> $dest_path"; errors=$((errors + 1)); return 0; }
                else
                    cp -p "$source_path" "$dest_path" 2>&1 \
                        || { _log_err "$label: failed to copy $source_path -> $dest_path"; errors=$((errors + 1)); return 0; }
                fi
                ;;
            symlink)
                # Prefer relative symlink targets.
                local rel_target
                rel_target=$(python3 -c "import os.path; print(os.path.relpath('$source_path', '$(dirname "$dest_path")'))" 2>/dev/null) \
                    || rel_target=""

                if [[ -n "$rel_target" ]]; then
                    ln -s "$rel_target" "$dest_path" 2>/dev/null \
                        || ln -s "$source_path" "$dest_path" 2>/dev/null \
                        || { _log_err "$label: failed to create symlink $dest_path -> $source_path"; errors=$((errors + 1)); return 0; }
                else
                    ln -s "$source_path" "$dest_path" 2>/dev/null \
                        || { _log_err "$label: failed to create symlink $dest_path -> $source_path"; errors=$((errors + 1)); return 0; }
                fi
                ;;
        esac

        _log_ok "$label"
        return 0
    }

    parse_manifest "$manifest_path" _materialize_entry || return 1

    _log "processed $entry_count entries from $manifest_path"

    if (( errors > 0 )); then
        _log_err "$errors error(s) during materialization"
        return 1
    fi

    return 0
}

cmd_remove() {
    local source="$1" target="$2" dry_run="${3:-false}"
    local manifest_path="$source/$MANIFEST_NAME"

    if [[ ! -f "$manifest_path" ]]; then
        _log "no $MANIFEST_NAME found in $source — nothing to do"
        return 0
    fi

    local errors=0

    _remove_entry() {
        local entry_path="$1" mode="$2" optional="$3"
        local dest_path="$target/$entry_path"

        # Nothing to remove if not present.
        if [[ ! -e "$dest_path" ]] && [[ ! -L "$dest_path" ]]; then
            _log_skip "$entry_path — not present"
            return 0
        fi

        if [[ "$dry_run" == "true" ]]; then
            _log_dry "would remove: $dest_path"
            return 0
        fi

        if [[ -L "$dest_path" ]]; then
            rm -f "$dest_path"
        elif [[ -d "$dest_path" ]]; then
            rm -rf "$dest_path"
        else
            rm -f "$dest_path"
        fi

        if [[ $? -eq 0 ]]; then
            _log_ok "removed $entry_path"
        else
            _log_err "failed to remove $entry_path"
            errors=$((errors + 1))
        fi

        return 0
    }

    _log "removing entries from $target"
    parse_manifest "$manifest_path" _remove_entry || return 1

    if (( errors > 0 )); then
        _log_err "$errors error(s) during removal"
        return 1
    fi

    return 0
}

# ── Auto-detection ───────────────────────────────────────────────────────────────

resolve_source_and_target() {
    local source_arg="$1" target_arg="$2"

    if [[ -n "$source_arg" ]]; then
        SOURCE=$(cd "$source_arg" && pwd)
    else
        SOURCE=$(find_main_worktree) || return 1
    fi

    if [[ -n "$target_arg" ]]; then
        TARGET=$(cd "$target_arg" && pwd)
    else
        TARGET=$(find_repo_root) || return 1
    fi

    # Guard: source == target with no explicit target.
    if [[ "$SOURCE" == "$TARGET" ]] && [[ -z "$target_arg" ]]; then
        _log_err "current directory is the main worktree. Use --target to specify the target worktree, or run this script from inside a linked worktree."
        return 1
    fi

    if [[ ! -d "$SOURCE" ]]; then
        _log_err "source directory does not exist: $SOURCE"
        return 1
    fi
    if [[ ! -d "$TARGET" ]]; then
        _log_err "target directory does not exist: $TARGET"
        return 1
    fi
}

# ── CLI ──────────────────────────────────────────────────────────────────────────

usage() {
    cat >&2 <<'EOF'
Usage: worktreeinclude.sh <command> [options]

Commands:
  create    Materialize .worktreeinclude entries into the target worktree
  remove    Remove materialized entries from the target worktree

Run 'worktreeinclude.sh <command> --help' for command-specific help.
EOF
}

usage_create() {
    cat >&2 <<'EOF'
Usage: worktreeinclude.sh create [--source DIR] [--target DIR] [--force] [--dry-run] [--pedantic] [--quiet] [--hook]

Materialize .worktreeinclude entries into the target worktree.

Options:
  --source DIR  Source checkout root. Default: main worktree (auto-detected).
  --target DIR  Target worktree root. Default: current worktree (auto-detected).
  --force       Overwrite existing destination paths.
  --dry-run     Show what would be done without making changes.
  --pedantic    Fail on tracked paths (strict spec compliance). Default
                behavior is to warn and skip tracked paths.
  --quiet       Suppress non-error stderr log output. Usage/errors may still be printed. Logs are still written to worktree.log.
  --hook        Run as a Claude Code WorktreeCreate hook. Reads JSON from
                stdin, creates the git worktree, materializes entries, and
                prints the worktree path to stdout.
  --help        Show this help message.
EOF
}

usage_remove() {
    cat >&2 <<'EOF'
Usage: worktreeinclude.sh remove [--source DIR] [--target DIR] [--dry-run] [--quiet] [--hook]

Remove materialized entries from the target worktree.

Options:
  --source DIR  Source checkout root. Default: main worktree (auto-detected).
  --target DIR  Target worktree root. Default: current worktree (auto-detected).
  --dry-run     Show what would be done without making changes.
  --quiet       Suppress stderr output. Logs are still written to worktree.log.
  --hook        Run as a Claude Code WorktreeRemove hook. Reads JSON from
                stdin with worktree_path, and removes materialized entries.
  --help        Show this help message.
EOF
}

main() {
    if (( $# < 1 )); then
        usage
        return 1
    fi

    local command="$1"
    shift

    case "$command" in
        create)
            local source_arg="" target_arg="" force="false" dry_run="false" hook="false" pedantic="false"
            while (( $# > 0 )); do
                case "$1" in
                    --source)    source_arg="$2"; shift 2 ;;
                    --target)    target_arg="$2"; shift 2 ;;
                    --force)     force="true"; shift ;;
                    --dry-run)   dry_run="true"; shift ;;
                    --pedantic)  pedantic="true"; shift ;;
                    --quiet)     QUIET="true"; shift ;;
                    --hook)      hook="true"; shift ;;
                    --help)      usage_create; return 0 ;;
                    *)           _log_err "unknown option: $1"; usage_create; return 1 ;;
                esac
            done

            _validate_log_file

            if [[ "$hook" == "true" ]]; then
                local hook_json
                hook_json=$(cat) || { _log_err "failed to read hook input from stdin"; return 1; }

                local name
                name=$(json_get "$hook_json" "name")
                if [[ -z "$name" ]]; then
                    _log_err "missing 'name' in hook input"
                    return 1
                fi

                local source
                source=$(find_main_worktree) || return 1
                local target="$source/.worktrees/$name"

                create_git_worktree "$name" "$target" "$source" || return 1

                local rc=0
                cmd_create "$source" "$target" "$force" "$dry_run" "$pedantic" || rc=$?

                if (( rc == 0 )); then
                    echo "$target"  # stdout — Claude Code reads this
                fi
                return "$rc"
            fi

            resolve_source_and_target "$source_arg" "$target_arg" || return 1
            cmd_create "$SOURCE" "$TARGET" "$force" "$dry_run" "$pedantic"
            ;;

        remove)
            local source_arg="" target_arg="" dry_run="false" hook="false"
            while (( $# > 0 )); do
                case "$1" in
                    --source)  source_arg="$2"; shift 2 ;;
                    --target)  target_arg="$2"; shift 2 ;;
                    --dry-run) dry_run="true"; shift ;;
                    --quiet)   QUIET="true"; shift ;;
                    --hook)    hook="true"; shift ;;
                    --help)    usage_remove; return 0 ;;
                    *)         _log_err "unknown option: $1"; usage_remove; return 1 ;;
                esac
            done

            _validate_log_file

            if [[ "$hook" == "true" ]]; then
                local hook_json
                hook_json=$(cat) || { _log_err "failed to read hook input from stdin"; return 1; }

                local worktree_path
                worktree_path=$(json_get "$hook_json" "worktree_path")
                if [[ -z "$worktree_path" ]]; then
                    _log_err "missing 'worktree_path' in hook input"
                    return 1
                fi

                local source
                source=$(find_main_worktree) || return 1
                cmd_remove "$source" "$worktree_path" "$dry_run"
                return $?
            fi

            resolve_source_and_target "$source_arg" "$target_arg" || return 1
            cmd_remove "$SOURCE" "$TARGET" "$dry_run"
            ;;

        --help|-h)
            usage
            return 0
            ;;

        *)
            _log_err "unknown command: $command"
            usage
            return 1
            ;;
    esac
}

main "$@"
