#!/usr/bin/env python3
"""Reference implementation of the .worktreeinclude specification (v0.1).

This script materializes local development files (environment configs,
credentials, large assets) into newly created Git worktrees, as defined
by a .worktreeinclude manifest at the repository root.

It supports two subcommands:

    create  -- read the manifest from the source checkout and materialize
               each entry into the target worktree via copy or symlink.
    remove  -- read the manifest and remove previously materialized entries
               from the target worktree.

Auto-detection:
    When --source or --target are not provided, the script infers them
    from the current Git state:

        source  = main (first) worktree   ('git worktree list --porcelain')
        target  = worktree root of CWD    ('git rev-parse --show-toplevel')

    This means the script "just works" when called from inside a linked
    worktree, which is the typical hook context for both Claude Code and
    agent-worktree.

Spec conformance (section 22):
    - Reads .worktreeinclude from the source checkout root.
    - Treats entries as literal repository-relative paths.
    - Supports # @symlink and # @optional directives.
    - Applies directives only to the next valid path entry.
    - Fails for missing required paths.
    - Warns and skips tracked paths by default; with --pedantic, treats them as errors.
    - Fails for existing destination conflicts by default.
    - Allows file and directory symlinks.
    - Prefers relative symlink targets; falls back to absolute.
    - Uses the manifest itself as the source of truth (no sidecar state).

See SPEC.md for the full specification.

Requires: Python 3.11+, Git
"""

from __future__ import annotations

import argparse
import datetime
import enum
import os
import posixpath
import shutil
import stat
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import TextIO


# ── Constants ───────────────────────────────────────────────────────────────────

MANIFEST_NAME = ".worktreeinclude"
"""The manifest file name, per spec section 5."""


# ── Data model ──────────────────────────────────────────────────────────────────


class Mode(enum.StrEnum):
    """Materialization mode for a manifest entry.

    Spec section 9:
        COPY    -- default; the entry is copied from source to target.
        SYMLINK -- enabled by '# @symlink'; a symbolic link is created instead.
    """

    COPY = "copy"
    SYMLINK = "symlink"


@dataclass(frozen=True, slots=True)
class Entry:
    """A single parsed entry from the .worktreeinclude manifest.

    Attributes:
        path:     Repository-relative path using forward slashes.
                  Spec section 6.1: paths are literal, no globbing.
        mode:     How the entry is materialized. Spec section 9.
        optional: When True, a missing source is silently skipped
                  instead of causing a failure. Spec section 10.
    """

    path: str
    mode: Mode = Mode.COPY
    optional: bool = False


# ── Exceptions ──────────────────────────────────────────────────────────────────


class WorktreeIncludeError(Exception):
    """Base exception for all worktreeinclude errors."""


class ParseError(WorktreeIncludeError):
    """Raised when the manifest contains a syntax error.

    Attributes:
        line_number: The 1-based line number where the error occurred.
    """

    def __init__(self, line_number: int, message: str) -> None:
        self.line_number = line_number
        super().__init__(f"line {line_number}: {message}")


class ValidationError(WorktreeIncludeError):
    """Raised when an entry fails path, eligibility, or safety validation."""


class MaterializeError(WorktreeIncludeError):
    """Raised when a copy or symlink operation fails."""


# ── Manifest parser ────────────────────────────────────────────────────────────
#
# Implements the parsing model from spec section 16 line-by-line:
#
#   1. Empty lines are ignored.
#   2. '# @symlink'  sets pending_mode = symlink.
#   3. '# @optional' sets pending_optional = True.
#   4. '# @<other>'  raises a parse error (spec section 6.3).
#   5. '#...'         is a regular comment — ignored.
#   6. Anything else  is a path entry; it consumes and resets pending state.
#


def parse_manifest(manifest_path: Path) -> list[Entry]:
    """Parse a .worktreeinclude manifest file into a list of entries.

    Args:
        manifest_path: Absolute path to the .worktreeinclude file.

    Returns:
        A list of Entry objects in manifest order.

    Raises:
        ParseError:         On unknown directives (spec section 6.3).
        FileNotFoundError:  If the manifest file does not exist.
    """
    entries: list[Entry] = []
    pending_mode = Mode.COPY
    pending_optional = False

    text = manifest_path.read_text(encoding="utf-8")

    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        trimmed = raw_line.strip()

        # Rule 1: empty lines are ignored.
        if not trimmed:
            continue

        # Rule 2: recognized directive '# @symlink'.
        if trimmed == "# @symlink":
            pending_mode = Mode.SYMLINK
            continue

        # Rule 3: recognized directive '# @optional'.
        if trimmed == "# @optional":
            pending_optional = True
            continue

        # Rule 4: unknown directive — parse error (spec section 6.3).
        if trimmed.startswith("# @"):
            raise ParseError(line_number, f"unknown directive: {trimmed!r}")

        # Rule 5: regular comment.
        if trimmed.startswith("#"):
            continue

        # Rule 6: path entry — consume pending directives.
        entries.append(
            Entry(
                path=trimmed,
                mode=pending_mode,
                optional=pending_optional,
            )
        )

        # Reset pending state after each path entry (spec section 16).
        pending_mode = Mode.COPY
        pending_optional = False

    return entries


# ── Path validation ─────────────────────────────────────────────────────────────
#
# Implements spec sections 7, 8, and 13.
#


def validate_path(entry_path: str) -> None:
    """Validate a manifest entry path per spec section 7.

    Rejects:
        - Absolute paths.
        - Paths that normalize outside the repository root (.. escapes).
        - Paths that refer to Git internals (.git as a path segment).

    Args:
        entry_path: The repository-relative path string from the manifest.

    Raises:
        ValidationError: If the path violates any rule from spec section 7.
    """
    # ── Reject absolute paths ───────────────────────────────────────────
    # POSIX absolute: starts with /
    # Windows absolute: starts with X: (drive letter)
    if entry_path.startswith("/") or (
        len(entry_path) >= 2 and entry_path[1] == ":"
    ):
        raise ValidationError(f"absolute path not allowed: {entry_path!r}")

    # ── Reject paths that escape the repository root ────────────────────
    # Normalize against a synthetic /repo root using POSIX path rules so
    # the check is platform-independent (the manifest always uses /).
    normalized = posixpath.normpath(posixpath.join("/repo", entry_path))
    if normalized != "/repo" and not normalized.startswith("/repo/"):
        raise ValidationError(
            f"path escapes repository root: {entry_path!r}"
        )

    # ── Reject paths referring to .git ──────────────────────────────────
    # Split on '/' and check each segment.  This correctly rejects:
    #   .git          (the directory itself)
    #   .git/config   (inside .git)
    #   foo/.git/bar  (nested .git)
    # but allows:
    #   .gitignore    (not a segment match)
    #   .github/...   (different name)
    segments = entry_path.replace("\\", "/").split("/")
    if ".git" in segments:
        raise ValidationError(
            f"path refers to Git internals: {entry_path!r}"
        )


def check_not_tracked(entry_path: str, source_root: Path) -> None:
    """Verify that a path is NOT tracked by Git.  Spec section 8.

    .worktreeinclude is intended for paths that Git does not populate
    in a new worktree.  Tracked files are already present through normal
    Git checkout behavior; listing them in the manifest is invalid.

    Args:
        entry_path:  Repository-relative path to check.
        source_root: Root of the source checkout.

    Raises:
        ValidationError: If the path is tracked by Git.
    """
    result = subprocess.run(
        ["git", "ls-files", "--error-unmatch", entry_path],
        cwd=source_root,
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        raise ValidationError(
            f"path is tracked by Git — .worktreeinclude is for "
            f"untracked/ignored paths only (spec section 8): {entry_path!r}"
        )


def check_safe_source(source_path: Path) -> None:
    """Verify that a source path is a safe filesystem object.  Spec section 13.

    Rejects device files, named pipes, and sockets.  Missing paths are
    handled separately by the caller (spec section 10).

    Args:
        source_path: Absolute path to the source file or directory.

    Raises:
        ValidationError: If the source is an unsafe filesystem object type.
    """
    if not source_path.exists():
        return

    st = source_path.lstat()
    mode = st.st_mode

    if stat.S_ISBLK(mode) or stat.S_ISCHR(mode):
        raise ValidationError(f"device file not allowed: {source_path}")

    if stat.S_ISFIFO(mode):
        raise ValidationError(f"named pipe not allowed: {source_path}")

    if stat.S_ISSOCK(mode):
        raise ValidationError(f"socket not allowed: {source_path}")


# ── Materialization ─────────────────────────────────────────────────────────────
#
# Implements spec sections 9.1 (copy), 9.2 (symlink), 9.3 (relative targets),
# 10 (missing sources), and 11 (existing destinations).
#


def _ensure_parent(destination: Path) -> None:
    """Create parent directories for a destination path.

    Per spec sections 9.1 and 9.2:
        "parent directories in the target MUST be created as needed."
    """
    destination.parent.mkdir(parents=True, exist_ok=True)


def materialize_copy(source: Path, destination: Path) -> None:
    """Copy a file or directory from source to destination.  Spec section 9.1.

    Behavior:
        - If source is a file, the destination is a file.
        - If source is a directory, the destination is a recursively
          copied directory.
        - File permissions are preserved when practical (SHOULD).
        - Parent directories in the target are created as needed.

    Args:
        source:      Absolute path to the source file or directory.
        destination: Absolute path in the target worktree.

    Raises:
        MaterializeError: If the copy operation fails.
    """
    _ensure_parent(destination)

    try:
        if source.is_dir():
            # Recursive directory copy.  Preserve internal symlinks and
            # file metadata (timestamps, permissions) via copy2.
            shutil.copytree(
                source,
                destination,
                symlinks=True,
                copy_function=shutil.copy2,
            )
        else:
            # Single file copy preserving permissions and timestamps.
            shutil.copy2(source, destination)
    except OSError as exc:
        raise MaterializeError(
            f"failed to copy {source} -> {destination}: {exc}"
        ) from exc


def materialize_symlink(source: Path, destination: Path) -> None:
    """Create a symbolic link from destination pointing to source.

    Spec section 9.2 (symlink mode) and 9.3 (relative vs absolute targets):

        - Prefers a relative symlink target when it can be represented
          correctly on the current platform.
        - Falls back to an absolute target when a relative path cannot
          be computed (e.g. different Windows drive roots).
        - On platforms that distinguish file and directory symlinks
          (Windows), passes target_is_directory accordingly.
        - Parent directories in the target are created as needed.

    Args:
        source:      Absolute path to the source file or directory.
        destination: Absolute path for the symlink in the target worktree.

    Raises:
        MaterializeError: If symlink creation fails.
    """
    _ensure_parent(destination)

    is_dir = source.is_dir()

    # ── Prefer relative symlink targets (spec section 9.3) ──────────────
    try:
        relative_target = os.path.relpath(source, destination.parent)
    except ValueError:
        # os.path.relpath raises ValueError on Windows when source and
        # destination are on different drives.  Fall back to absolute.
        relative_target = None

    # Try relative first, then absolute as fallback.
    targets_to_try = []
    if relative_target is not None:
        targets_to_try.append(relative_target)
    targets_to_try.append(str(source))  # absolute fallback

    last_error: OSError | None = None
    for target_str in targets_to_try:
        try:
            os.symlink(
                target_str,
                destination,
                target_is_directory=is_dir,
            )
            return  # Success.
        except OSError as exc:
            last_error = exc
            # Clean up the failed attempt before retrying.
            if destination.is_symlink() or destination.exists():
                destination.unlink()

    raise MaterializeError(
        f"failed to create symlink {destination} -> {source}: {last_error}"
    )


# ── Git helpers ─────────────────────────────────────────────────────────────────


def _run_git(
    *args: str,
    cwd: Path | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run a git command and return the CompletedProcess.

    Args:
        *args: Git subcommand and arguments.
        cwd:   Working directory for the command.

    Returns:
        The CompletedProcess with captured stdout/stderr.

    Raises:
        WorktreeIncludeError: If git is not installed.
    """
    try:
        return subprocess.run(
            ["git", *args],
            cwd=cwd,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        raise WorktreeIncludeError(
            "git is not installed or not in PATH"
        )


def find_repo_root(from_dir: Path | None = None) -> Path:
    """Find the repository root of the given (or current) directory.

    Uses 'git rev-parse --show-toplevel'.

    Args:
        from_dir: Directory to start from.  Defaults to CWD.

    Returns:
        Absolute path to the repository root.

    Raises:
        WorktreeIncludeError: If the directory is not inside a Git repo.
    """
    result = _run_git("rev-parse", "--show-toplevel", cwd=from_dir)
    if result.returncode != 0:
        raise WorktreeIncludeError(
            f"not inside a Git repository: {from_dir or Path.cwd()}"
        )
    return Path(result.stdout.strip())


def find_main_worktree(from_dir: Path | None = None) -> Path:
    """Find the main (source) worktree for this repository.

    The main worktree is always listed first in the output of
    'git worktree list --porcelain'.  This serves as the source
    checkout per spec section 3.1.

    Args:
        from_dir: Any directory inside the repository.

    Returns:
        Absolute path to the main worktree root.

    Raises:
        WorktreeIncludeError: If the main worktree cannot be determined.
    """
    result = _run_git("worktree", "list", "--porcelain", cwd=from_dir)
    if result.returncode != 0:
        raise WorktreeIncludeError(
            f"failed to list worktrees: {result.stderr.strip()}"
        )

    for line in result.stdout.splitlines():
        if line.startswith("worktree "):
            return Path(line.removeprefix("worktree "))

    raise WorktreeIncludeError(
        "could not determine main worktree from git output"
    )


# ── Hook helpers ─────────────────────────────────────────────────────────────────


def _read_hook_input() -> dict:
    """Read Claude Code hook JSON from stdin."""
    import json

    return json.loads(sys.stdin.read())


def create_git_worktree(name: str, path: Path, cwd: Path) -> None:
    """Create a git worktree at the given path.

    Args:
        name: Branch-friendly name for the worktree (used as worktree/<name>).
        path: Absolute path where the worktree will be created.
        cwd:  Directory to run git from (must be inside a git repo).

    Raises:
        WorktreeIncludeError: If the git worktree command fails.
    """
    result = _run_git(
        "worktree", "add", "-b", f"worktree/{name}", str(path), "HEAD",
        cwd=cwd,
    )
    if result.returncode != 0:
        raise WorktreeIncludeError(
            f"failed to create git worktree: {result.stderr.strip()}"
        )


# ── Output helpers ──────────────────────────────────────────────────────────────

_quiet: bool = False
_log_fh: TextIO | None = None


def _init_logging(quiet: bool = False) -> None:
    """Initialize logging: set quiet mode and open worktree.log for appending.

    When quiet=True, the log file is mandatory — if it cannot be opened,
    the script exits with an error because there would be no output at all.
    When quiet=False, a log file failure is non-fatal (stderr still works).
    """
    global _quiet, _log_fh
    _quiet = quiet
    try:
        _log_fh = open("worktree.log", "a", encoding="utf-8")
    except OSError as exc:
        if quiet:
            print(
                f"  ERR   --quiet requires a writable log file, "
                f"but worktree.log could not be opened: {exc}",
                file=sys.stderr,
            )
            sys.exit(1)
        # Non-quiet mode: log file is best-effort, stderr still works.


def _write_log(level: str, message: str) -> None:
    """Write a timestamped line to the log file."""
    if _log_fh:
        ts = datetime.datetime.now().isoformat(timespec="seconds")
        _log_fh.write(f"{ts} [{level}] {message}\n")
        _log_fh.flush()


def _log(message: str) -> None:
    """Print a status message to stderr and log file."""
    _write_log("INFO", message)
    if not _quiet:
        print(f"  {message}", file=sys.stderr)


def _log_ok(message: str) -> None:
    """Print a success message to stderr and log file."""
    _write_log("INFO", f"OK    {message}")
    if not _quiet:
        print(f"  OK    {message}", file=sys.stderr)


def _log_skip(message: str) -> None:
    """Print a skip message to stderr and log file."""
    _write_log("INFO", f"SKIP  {message}")
    if not _quiet:
        print(f"  SKIP  {message}", file=sys.stderr)


def _log_warn(message: str) -> None:
    """Print a warning message to stderr and log file."""
    _write_log("WARN", message)
    if not _quiet:
        print(f"  WARN  {message}", file=sys.stderr)


def _log_err(message: str) -> None:
    """Print an error message to stderr and log file."""
    _write_log("ERR", message)
    if not _quiet:
        print(f"  ERR   {message}", file=sys.stderr)


def _log_dry(message: str) -> None:
    """Print a dry-run message to stderr and log file."""
    _write_log("INFO", f"DRY   {message}")
    if not _quiet:
        print(f"  DRY   {message}", file=sys.stderr)


# ── Commands ────────────────────────────────────────────────────────────────────


def cmd_create(
    source: Path,
    target: Path,
    *,
    force: bool = False,
    dry_run: bool = False,
    pedantic: bool = False,
) -> int:
    """Materialize .worktreeinclude entries into the target worktree.

    Implements the execution model from spec section 17:

        1. Read .worktreeinclude from the source checkout root.
        2. Parse the manifest.
        3. Validate each entry (path rules, tracked check, safety check).
        4. Resolve source and destination paths.
        5. Enforce failure rules (missing required, existing destination).
        6. Materialize the entry as copy or symlink.

    Args:
        source:  Root of the source checkout (main worktree).
        target:  Root of the target worktree.
        force:   If True, overwrite existing destinations.  The spec
                 default is to fail (section 11), but implementations
                 MAY offer a force mode.
        dry_run: If True, report actions without performing them.

    Returns:
        Exit code: 0 on success, 1 if any entry failed.
    """
    manifest_path = source / MANIFEST_NAME

    # Step 1: read .worktreeinclude.  No manifest = no-op (spec section 17
    # step 3: "if present").
    if not manifest_path.is_file():
        _log(f"no {MANIFEST_NAME} found in {source} — nothing to do")
        return 0

    # Step 2: parse the manifest.
    try:
        entries = parse_manifest(manifest_path)
    except ParseError as exc:
        _log_err(f"parse error in {MANIFEST_NAME}: {exc}")
        return 1

    if not entries:
        _log(f"{MANIFEST_NAME} is empty — nothing to do")
        return 0

    _log(f"processing {len(entries)} entries from {manifest_path}")
    _log(f"source: {source}")
    _log(f"target: {target}")

    errors: list[str] = []

    for entry in entries:
        source_path = source / entry.path
        dest_path = target / entry.path
        label = (
            f"{entry.path} "
            f"({entry.mode.value}"
            f"{'|optional' if entry.optional else ''})"
        )

        # Step 3a: validate path syntax (spec section 7).
        try:
            validate_path(entry.path)
        except ValidationError as exc:
            _log_err(f"{label}: {exc}")
            errors.append(str(exc))
            continue

        # Step 3b: tracked paths (spec section 8).
        try:
            check_not_tracked(entry.path, source)
        except ValidationError as exc:
            if pedantic:
                _log_err(f"{label}: {exc}")
                errors.append(str(exc))
                continue
            else:
                _log_warn(
                    f"{label}: {exc} — skipping "
                    f"(already in worktree via Git)"
                )
                continue

        # Step 5a: missing source paths (spec section 10).
        if not source_path.exists():
            if entry.optional:
                _log_skip(f"{label} — source not found (optional)")
                continue
            else:
                msg = f"required source path not found: {entry.path!r}"
                _log_err(f"{label}: {msg}")
                errors.append(msg)
                continue

        # Step 3c: safety check on source (spec section 13).
        try:
            check_safe_source(source_path)
        except ValidationError as exc:
            _log_err(f"{label}: {exc}")
            errors.append(str(exc))
            continue

        # Step 5b: existing destination (spec section 11).
        if dest_path.exists() or dest_path.is_symlink():
            if force:
                if not dry_run:
                    if dest_path.is_dir() and not dest_path.is_symlink():
                        shutil.rmtree(dest_path)
                    else:
                        dest_path.unlink()
            else:
                msg = f"destination already exists: {entry.path!r}"
                _log_err(f"{label}: {msg}")
                errors.append(msg)
                continue

        # Step 6: materialize the entry.
        if dry_run:
            _log_dry(f"{label}: {source_path} -> {dest_path}")
            continue

        try:
            match entry.mode:
                case Mode.COPY:
                    materialize_copy(source_path, dest_path)
                case Mode.SYMLINK:
                    materialize_symlink(source_path, dest_path)
            _log_ok(label)
        except MaterializeError as exc:
            _log_err(f"{label}: {exc}")
            errors.append(str(exc))

    if errors:
        _log_err(f"{len(errors)} error(s) during materialization")
        return 1

    return 0


def cmd_remove(
    source: Path,
    target: Path,
    *,
    dry_run: bool = False,
) -> int:
    """Remove materialized .worktreeinclude entries from the target worktree.

    Reads the manifest from the source checkout and removes corresponding
    entries from the target.  Uses the manifest itself as the source of
    truth — no sidecar metadata (spec section 12).

    This is useful as a pre-removal cleanup step so that 'git worktree remove'
    does not complain about untracked files, and so that symlinks pointing
    back to the source checkout are cleaned up explicitly.

    Args:
        source:  Root of the source checkout (main worktree).
        target:  Root of the target worktree.
        dry_run: If True, report actions without performing them.

    Returns:
        Exit code: 0 on success, 1 if any removal failed.
    """
    manifest_path = source / MANIFEST_NAME

    if not manifest_path.is_file():
        _log(f"no {MANIFEST_NAME} found in {source} — nothing to do")
        return 0

    try:
        entries = parse_manifest(manifest_path)
    except ParseError as exc:
        _log_err(f"parse error in {MANIFEST_NAME}: {exc}")
        return 1

    if not entries:
        return 0

    _log(f"removing {len(entries)} entries from {target}")

    errors: list[str] = []

    for entry in entries:
        dest_path = target / entry.path

        # Nothing to remove if the path is not present.
        if not dest_path.exists() and not dest_path.is_symlink():
            _log_skip(f"{entry.path} — not present")
            continue

        if dry_run:
            _log_dry(f"would remove: {dest_path}")
            continue

        try:
            if dest_path.is_symlink():
                # Remove symlinks directly (do not follow).
                dest_path.unlink()
            elif dest_path.is_dir():
                shutil.rmtree(dest_path)
            else:
                dest_path.unlink()
            _log_ok(f"removed {entry.path}")
        except OSError as exc:
            msg = f"failed to remove {entry.path}: {exc}"
            _log_err(msg)
            errors.append(msg)

    if errors:
        _log_err(f"{len(errors)} error(s) during removal")
        return 1

    return 0


# ── Auto-detection ──────────────────────────────────────────────────────────────


def resolve_source_and_target(
    source_arg: str | None,
    target_arg: str | None,
) -> tuple[Path, Path]:
    """Resolve the source checkout and target worktree paths.

    Auto-detection (when arguments are omitted):

        source  →  main (first) worktree from 'git worktree list --porcelain'
        target  →  repo root of CWD from 'git rev-parse --show-toplevel'

    If the CWD is the main worktree and --target is not provided, this
    function raises an error.  Materializing from main into main is not
    a useful operation.

    Args:
        source_arg: Explicit --source value, or None.
        target_arg: Explicit --target value, or None.

    Returns:
        (source_root, target_root) as resolved absolute paths.

    Raises:
        WorktreeIncludeError: On detection failure or invalid combination.
    """
    source = Path(source_arg).resolve() if source_arg else find_main_worktree()
    target = Path(target_arg).resolve() if target_arg else find_repo_root()

    # Guard: source == target means the script is running in the main
    # worktree without an explicit --target.  This is almost certainly
    # a mistake.
    if source.resolve() == target.resolve() and not target_arg:
        raise WorktreeIncludeError(
            "current directory is the main worktree. "
            "Use --target to specify the target worktree, or run this "
            "script from inside a linked worktree."
        )

    if not source.is_dir():
        raise WorktreeIncludeError(
            f"source directory does not exist: {source}"
        )
    if not target.is_dir():
        raise WorktreeIncludeError(
            f"target directory does not exist: {target}"
        )

    return source, target


# ── CLI ─────────────────────────────────────────────────────────────────────────


def build_parser() -> argparse.ArgumentParser:
    """Build the argument parser for the worktreeinclude CLI."""
    parser = argparse.ArgumentParser(
        prog="worktreeinclude",
        description=(
            "Reference implementation of the .worktreeinclude spec. "
            "Materializes local development files into Git worktrees."
        ),
        epilog="See SPEC.md for the full specification.",
    )

    subparsers = parser.add_subparsers(dest="command", required=True)

    # ── create ──────────────────────────────────────────────────────────
    create_parser = subparsers.add_parser(
        "create",
        help="Materialize .worktreeinclude entries into the target worktree.",
        description=(
            "Read .worktreeinclude from the source checkout and materialize "
            "each entry (copy or symlink) into the target worktree."
        ),
    )
    create_parser.add_argument(
        "--source",
        metavar="DIR",
        help=(
            "Root of the source checkout.  "
            "Default: main worktree (auto-detected)."
        ),
    )
    create_parser.add_argument(
        "--target",
        metavar="DIR",
        help=(
            "Root of the target worktree.  "
            "Default: repo root of current directory (auto-detected)."
        ),
    )
    create_parser.add_argument(
        "--force",
        action="store_true",
        help=(
            "Overwrite existing destination paths.  "
            "Default behavior is to fail (spec section 11)."
        ),
    )
    create_parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be done without making changes.",
    )
    create_parser.add_argument(
        "--pedantic",
        action="store_true",
        help=(
            "Fail on tracked paths (strict spec compliance). "
            "Default behavior is to warn and skip tracked paths."
        ),
    )
    create_parser.add_argument(
        "--quiet",
        action="store_true",
        help="Suppress stderr output. Logs are still written to worktree.log.",
    )
    create_parser.add_argument(
        "--hook",
        action="store_true",
        help=(
            "Run as a Claude Code WorktreeCreate hook. "
            "Reads JSON from stdin, creates the git worktree, "
            "materializes entries, and prints the worktree path to stdout."
        ),
    )

    # ── remove ──────────────────────────────────────────────────────────
    remove_parser = subparsers.add_parser(
        "remove",
        help="Remove materialized entries from the target worktree.",
        description=(
            "Read .worktreeinclude from the source checkout and remove "
            "each materialized entry from the target worktree."
        ),
    )
    remove_parser.add_argument(
        "--source",
        metavar="DIR",
        help="Root of the source checkout.  Default: main worktree.",
    )
    remove_parser.add_argument(
        "--target",
        metavar="DIR",
        help="Root of the target worktree.  Default: current worktree.",
    )
    remove_parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be done without making changes.",
    )
    remove_parser.add_argument(
        "--quiet",
        action="store_true",
        help="Suppress stderr output. Logs are still written to worktree.log.",
    )
    remove_parser.add_argument(
        "--hook",
        action="store_true",
        help=(
            "Run as a Claude Code WorktreeRemove hook. "
            "Reads JSON from stdin with worktree_path, "
            "and removes materialized entries."
        ),
    )

    return parser


def main() -> int:
    """Entry point for the worktreeinclude CLI.

    Returns:
        Exit code: 0 on success, 1 on error.
    """
    parser = build_parser()
    args = parser.parse_args()

    # Initialize logging early so all output is captured.
    _init_logging(quiet=args.quiet)

    # ── Hook mode ────────────────────────────────────────────────────────
    # When --hook is passed, the script acts as a Claude Code lifecycle
    # hook.  It reads JSON from stdin instead of using --source/--target,
    # and (for create) handles the git worktree creation itself.
    if args.hook:
        try:
            hook_input = _read_hook_input()
        except Exception as exc:
            _log_err(f"failed to read hook input from stdin: {exc}")
            return 1

        try:
            if args.command == "create":
                source = find_main_worktree()
                name = hook_input["name"]
                target = source / ".worktrees" / name
                create_git_worktree(name, target, source)
                rc = cmd_create(
                    source,
                    target,
                    pedantic=getattr(args, "pedantic", False),
                )
                if rc == 0:
                    print(target)  # stdout — Claude Code reads this
                return rc
            elif args.command == "remove":
                source = find_main_worktree()
                target = Path(hook_input["worktree_path"])
                return cmd_remove(source, target)
        except WorktreeIncludeError as exc:
            _log_err(str(exc))
            return 1
        except KeyError as exc:
            _log_err(f"missing key in hook input: {exc}")
            return 1

    try:
        source, target = resolve_source_and_target(args.source, args.target)
    except WorktreeIncludeError as exc:
        _log_err(str(exc))
        return 1

    match args.command:
        case "create":
            return cmd_create(
                source,
                target,
                force=args.force,
                dry_run=args.dry_run,
                pedantic=args.pedantic,
            )
        case "remove":
            return cmd_remove(
                source,
                target,
                dry_run=args.dry_run,
            )
        case _:
            parser.print_help()
            return 1


if __name__ == "__main__":
    sys.exit(main())
