# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`.worktreeinclude` is a specification and reference implementation for materializing local development files (`.env.local`, credentials, large assets) into Git worktrees. Git worktrees don't carry over ignored files — this solves that with a manifest at the repo root.

Two reference implementations (Python 3.11+, Bash 4+) implement the full spec (Base + Extra conformance levels). Both have identical CLI interfaces and no third-party dependencies.

## Commands

```bash
# Run all tests (both implementations)
./implementations/test.sh

# Run tests for one implementation
./implementations/test.sh python
./implementations/test.sh bash

# CI mode (GitHub Actions annotations)
./implementations/test.sh --ci
./implementations/test.sh --ci python

# Run an implementation directly
python3 implementations/python/worktreeinclude.py create --source /repo --target /worktree
implementations/bash/worktreeinclude.sh create --source /repo --target /worktree
```

There is no build step or linter configured.

## Architecture

### Spec (SPEC.md)

The `.worktreeinclude` manifest is a line-oriented file of literal repository-relative paths (no globs). Two conformance levels:

- **Base**: Copy-only, comments ignored
- **Extra**: Adds `# @symlink` (symlink instead of copy) and `# @optional` (skip if source missing) directives. Directives apply to the next non-comment line only. Unknown directives (`# @bogus`) must cause parse errors.

### Implementations

Both implementations follow a 9-step execution model: find repo root → find manifest → parse → validate paths → materialize entries. Key behaviors:

- **Path validation**: Rejects absolute paths, `..` escapes, `.git` references, tracked files (`git ls-files --error-unmatch`), device files, pipes, sockets
- **Materialization**: Copy preserves permissions; symlinks prefer relative targets with absolute fallback
- **Failure semantics**: Missing required sources and existing destinations fail (exit 1) unless `--force`
- **Hook mode** (`--hook`): Reads JSON from stdin, creates git worktree, materializes, prints path to stdout. Used for Claude Code `WorktreeCreate`/`WorktreeRemove` hooks.
- **Auto-detection**: Without `--source`/`--target`, detects main worktree and current worktree via git

### Tests (implementations/test.sh)

Custom bash test harness with `pass()`/`fail()`/`skip()` counters and assertion helpers. Creates a temporary git repo with fixtures, runs 14 test suites against each implementation (86 total assertions). Both implementations must produce identical results.

## Manifest Format

```
# Comments and blank lines ignored
.env.local
config/creds/dev.key

# @symlink
data/big.db

# @optional
.env.test.local
```

Entries are literal paths — no patterns, no `.gitignore` semantics.

## Status

Draft v0.2, MIT licensed.
