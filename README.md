# .worktreeinclude

A spec for materializing local development files into fresh Git worktrees.

## The problem

Git worktrees are great for working on multiple branches simultaneously, but they don't carry over your ignored local files. Every new worktree starts without your `.env.local`, database credentials, development keys, or that 200MB GeoIP database you need to run the app.

So you copy things by hand. You forget one. You waste an afternoon.

`.worktreeinclude` is a manifest file that lives at the repository root and declares which ignored or local-only paths should be materialized into new worktrees automatically.

## How it works

Create a `.worktreeinclude` file at your repository root:

```
.env.local
config/credentials/development.key
# @optional
.env.test.local
# @symlink
storage/local/GeoLite2-City.mmdb
```

- **Paths are literal** -- no globs, no patterns, just repository-relative paths.
- **Copy is the default** -- each entry is copied from your source checkout into the new worktree.
- **Missing required paths fail loudly** -- because silent absence is a terrific way to waste an afternoon.

### .worktreeinclude Extra

The spec defines two conformance levels. The **base** level is copy-only: every path is copied, every missing source fails. This makes it trivial to implement and means any tool that reads the manifest gets useful behavior for free.

The **Extra** level adds two directives:

- **`# @symlink`** -- symlinks the next entry instead of copying (good for large, read-mostly assets).
- **`# @optional`** -- skips the next entry without failing if the source path doesn't exist.

Directives apply only to the next path entry and can stack:

```
# @optional
# @symlink
vendor/models/embeddings
```

This entry is symlinked if present, skipped if absent.

A base-only implementation sees the directives as regular comments and copies everything. The same manifest works at both levels -- you just get more control with an Extra implementation.

## Quick examples

**Rails**

```
config/database.yml
config/credentials/development.key
config/credentials/test.key
.env.development.local
# @optional
.env.test.local
# @symlink
storage/local/GeoLite2-City.mmdb
```

**Next.js**

```
.env.local
.env.development.local
# @optional
.env.test.local
.vercel/project.json
# @symlink
public/dev-assets/embeddings
```

**Django**

```
.env
.env.local
config/settings.local.py
# @symlink
data/GeoLite2-City.mmdb
# @optional
# @symlink
data/ml-models
```

## What doesn't belong here

Tracked files. Git already handles those. Listing `package.json` or `Gemfile` in `.worktreeinclude` is either pointless or dangerous.

Large generated caches that are cheap to recreate are better handled by a bootstrap script than by this manifest.

## Key rules

- Entries must be repository-relative paths (no absolute paths, no `..` escapes, no `.git`)
- Tracked paths are rejected -- this is for ignored/local-only files
- Existing destination paths cause failure by default (no silent overwrites)
- Symlinks prefer relative targets, falling back to absolute when necessary
- The manifest itself is the source of truth -- no sidecar metadata files

## Install

Run this from any git repository to set up `.worktreeinclude`:

```sh
curl -fsSL https://raw.githubusercontent.com/bastos/dot-worktreeinclude/main/install.sh | sh
```

This creates three things in your repo:

1. **`scripts/worktreeinclude.sh`** -- the Bash reference implementation (no dependencies)
2. **`.claude/settings.json`** -- `WorktreeCreate`/`WorktreeRemove` hooks so Claude Code automatically materializes files into new worktrees
3. **`.worktreeinclude`** -- a starter template if you don't already have one

The installer is idempotent -- running it again skips anything that already exists.

### Options

```sh
# Use the Python implementation instead of Bash
curl -fsSL ... | sh -s -- --python

# Install the script to a different directory
curl -fsSL ... | sh -s -- --dir bin
```

### Requirements

`curl`, `jq`, and `git`. The `--python` variant also requires `python3`.

If you already have a `.claude/settings.json` with other hooks configured, the installer appends to your existing hook arrays rather than replacing them.

## Gotchas

### Tracked files in `.worktreeinclude` and Claude Code hooks

If your `.worktreeinclude` lists a file that is tracked by Git (e.g. `config/database.yml` that you committed), the entry is redundant -- Git already populates tracked files in new worktrees.

**Before v0.3**, the implementations treated tracked paths as hard errors, which caused `WorktreeCreate` hooks to exit non-zero and left Claude Code without the worktree path. The symptom was the hook appearing to hang, with this in the logs:

```
ERR   path is tracked by Git — .worktreeinclude is for untracked/ignored paths only
```

**Since v0.3 (current default)**, tracked paths are **warned and skipped** instead of failing. A stale manifest with tracked files won't break your hooks. Use `--pedantic` to restore the strict behavior if you want tracked paths to be treated as errors.

```sh
# Default: warn + skip tracked paths
worktreeinclude.sh create --source /repo --target /worktree

# Strict: fail on tracked paths (original behavior)
worktreeinclude.sh create --source /repo --target /worktree --pedantic
```

### Logging

Both implementations log to `worktree.log` in the current directory. Use `--quiet` to suppress stderr output while still writing to the log file. This is useful in hook mode where you only want stdout (the worktree path) and the log file for debugging.

## Implementations

Reference implementations in Python and Bash are in [`implementations/`](implementations/). Both support full spec conformance (Base + Extra), integrate with Claude Code hooks and [agent-worktree](https://github.com/nekocode/agent-worktree), and have no third-party dependencies.

## Spec

The full specification is in [SPEC.md](SPEC.md). It covers the file format, path validation, materialization modes, failure semantics, cross-platform behavior, and two conformance levels (Base and Extra).

**Status:** Draft v0.2

## License

MIT
