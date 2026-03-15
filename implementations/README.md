# .worktreeinclude -- Implementations

Two reference implementations of the [.worktreeinclude spec](../SPEC.md):

| Implementation | Path | Requirements |
|----------------|------|--------------|
| **Python** | [`python/worktreeinclude.py`](python/worktreeinclude.py) | Python 3.11+, Git |
| **Bash** | [`bash/worktreeinclude.sh`](bash/worktreeinclude.sh) | Bash 4+, Git, coreutils |

Both implementations cover full spec conformance (Base + Extra), including `# @symlink`, `# @optional`, path validation, tracked-path rejection, and `--hook` mode for Claude Code integration.

Neither implementation requires third-party dependencies.

## Quick start

```bash
# Python — from inside a linked worktree (auto-detects source/target):
python3 implementations/python/worktreeinclude.py create

# Bash — same:
implementations/bash/worktreeinclude.sh create

# Explicit paths:
python3 implementations/python/worktreeinclude.py create --source /path/to/main --target /path/to/worktree
implementations/bash/worktreeinclude.sh create --source /path/to/main --target /path/to/worktree

# Dry run:
python3 implementations/python/worktreeinclude.py create --dry-run
implementations/bash/worktreeinclude.sh create --dry-run

# Remove materialized entries before deleting a worktree:
python3 implementations/python/worktreeinclude.py remove
implementations/bash/worktreeinclude.sh remove
```

## How auto-detection works

When `--source` and `--target` are omitted, both implementations infer them from Git:

| Argument   | Default                                                         |
|------------|-----------------------------------------------------------------|
| `--source` | Main (first) worktree from `git worktree list --porcelain`      |
| `--target` | Repository root of the current directory (`git rev-parse`)       |

This means the script works out of the box when called from inside a linked worktree, which is the standard context for both Claude Code hooks and agent-worktree hooks.

If you run it from the main worktree without `--target`, it errors out -- materializing from main into main is not useful.

## Integration with Claude Code

Claude Code fires lifecycle hooks when worktrees are created or removed. Add this to your project's `.claude/settings.json`:

### Using Python

```json
{
  "hooks": {
    "WorktreeCreate": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "python3 implementations/python/worktreeinclude.py create --hook"
          }
        ]
      }
    ],
    "WorktreeRemove": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "python3 implementations/python/worktreeinclude.py remove --hook"
          }
        ]
      }
    ]
  }
}
```

### Using Bash

```json
{
  "hooks": {
    "WorktreeCreate": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "implementations/bash/worktreeinclude.sh create --hook"
          }
        ]
      }
    ],
    "WorktreeRemove": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "implementations/bash/worktreeinclude.sh remove --hook"
          }
        ]
      }
    ]
  }
}
```

### What happens

1. You (or Claude) request a worktree via `/worktree` or the Agent tool.
2. Claude Code fires `WorktreeCreate` **before** the worktree exists -- the hook **replaces** the default `git worktree add` behavior.
3. The hook reads JSON from stdin (containing the worktree `name`), creates the git worktree at `<source>/.worktrees/<name>`, materializes `.worktreeinclude` entries, and prints the worktree path to stdout.
4. Claude Code uses the printed path as the new worktree location.
5. When the worktree is removed, `WorktreeRemove` fires **before** deletion. The hook reads the `worktree_path` from stdin and cleans up materialized entries.

## Integration with agent-worktree (Pi)

[agent-worktree](https://github.com/nekocode/agent-worktree) (`wt`) is a Rust-based worktree manager designed for AI coding agents. It supports lifecycle hooks via its config file.

### Option A: post_create hook

Add a `post_create` hook in your project config or `~/.agent-worktree/config.toml`:

```toml
# Python
post_create = ["python3 /path/to/worktreeinclude.py create"]

# Bash
post_create = ["/path/to/worktreeinclude.sh create"]
```

The `post_create` hook runs after the worktree is created, with the CWD set to the new worktree. Auto-detection handles the rest.

### Option B: snap mode

When using snap mode to launch an agent in a fresh worktree:

```bash
wt new feature-branch -s claude
```

The `post_create` hook fires before the agent starts, so your `.env.local`, credentials, and large assets are already in place when Claude begins working.

### Replacing copy_files

agent-worktree has a built-in `copy_files` config that supports gitignore-style patterns:

```toml
copy_files = [".env", ".env.*"]
```

`.worktreeinclude` offers more control:

| Feature                | `copy_files`           | `.worktreeinclude`       |
|------------------------|------------------------|--------------------------|
| Pattern matching       | gitignore-style globs  | Literal paths only       |
| Symlinks               | No                     | Yes (`# @symlink`)       |
| Optional entries       | No                     | Yes (`# @optional`)      |
| Per-entry control      | No                     | Yes (directives stack)   |
| Committed to repo      | No (user config)       | Yes (repo root file)     |

You can use both. `copy_files` handles the simple cases; `.worktreeinclude` handles entries that need symlinks or optional behavior.

## CLI reference

Both implementations share the same CLI interface.

### `create`

Materialize entries from the manifest into the target worktree.

```
worktreeinclude.{py,sh} create [--source DIR] [--target DIR] [--force] [--dry-run] [--hook]
```

| Flag         | Description                                                |
|--------------|------------------------------------------------------------|
| `--source`   | Source checkout root. Default: main worktree.              |
| `--target`   | Target worktree root. Default: current worktree.           |
| `--force`    | Overwrite existing destinations (spec default is to fail). |
| `--dry-run`  | Report what would happen without making changes.           |
| `--hook`     | Run as a Claude Code WorktreeCreate hook. Reads JSON from stdin (`{"name": "..."}`) , creates the git worktree, materializes entries, and prints the worktree path to stdout. |

### `remove`

Remove materialized entries from the target worktree.

```
worktreeinclude.{py,sh} remove [--source DIR] [--target DIR] [--dry-run] [--hook]
```

| Flag         | Description                                      |
|--------------|--------------------------------------------------|
| `--source`   | Source checkout root. Default: main worktree.    |
| `--target`   | Target worktree root. Default: current worktree. |
| `--dry-run`  | Report what would happen without making changes. |
| `--hook`     | Run as a Claude Code WorktreeRemove hook. Reads JSON from stdin (`{"worktree_path": "..."}`) and removes materialized entries. |

## Exit codes

| Code | Meaning                                                        |
|------|----------------------------------------------------------------|
| `0`  | Success (or no manifest found -- nothing to do).               |
| `1`  | One or more entries failed validation or materialization.       |

## Output format

All output goes to stderr. Each line is prefixed with a status tag:

```
  OK    .env.local (copy)
  OK    storage/local/GeoLite2-City.mmdb (symlink)
  SKIP  .env.test.local (copy|optional) — source not found (optional)
  ERR   .git/config (copy): path refers to Git internals: '.git/config'
  DRY   .env.local (copy): /main/.env.local -> /worktree/.env.local
```

## Spec conformance

Both implementations cover every MUST from the [conformance summary](../SPEC.md#22-conformance-summary):

- Reads `.worktreeinclude` from the source checkout root
- Treats entries as literal repository-relative paths
- Supports `# @symlink` and `# @optional`
- Applies directives only to the next valid path entry
- Fails for missing required paths
- Fails for tracked paths (checked via `git ls-files`)
- Fails for existing destination conflicts by default
- Allows file and directory symlinks
- Prefers relative symlink targets; falls back to absolute
- Uses the manifest as source of truth (no sidecar state files)

## Implementation differences

| Aspect | Python | Bash |
|--------|--------|------|
| Relative symlink computation | `os.path.relpath` | `python3 -c` fallback, or absolute |
| JSON parsing (hook mode) | stdlib `json` | `jq` if available, `sed` fallback |
| Directory copy | `shutil.copytree` | `cp -a` |
| File copy | `shutil.copy2` | `cp -p` |
