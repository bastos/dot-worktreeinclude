#!/bin/sh
# install.sh — one-command setup for .worktreeinclude in any project
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/bastos/dot-worktreeinclude/main/install.sh | sh
#   curl -fsSL ... | sh -s -- --python
#   curl -fsSL ... | sh -s -- --dir bin
set -eu

# --- Defaults ---
IMPL="bash"
DIR="scripts"
BASE_URL="https://raw.githubusercontent.com/bastos/dot-worktreeinclude/main/implementations"

# --- Argument parsing ---
while [ $# -gt 0 ]; do
  case "$1" in
    --python)
      IMPL="python"
      shift
      ;;
    --dir)
      if [ -z "${2:-}" ]; then
        echo "Error: --dir requires an argument" >&2
        exit 1
      fi
      DIR="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: install.sh [--python] [--dir DIR]" >&2
      echo "" >&2
      echo "  --python   Install Python implementation instead of Bash" >&2
      echo "  --dir DIR  Install directory (default: scripts)" >&2
      exit 0
      ;;
    *)
      echo "Error: unknown option '$1'" >&2
      exit 1
      ;;
  esac
done

# --- Dependency checks ---
if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is required but not found. Please install curl." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required for safe JSON merging but not found." >&2
  echo "Install it with: brew install jq (macOS) or apt-get install jq (Debian/Ubuntu)" >&2
  exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Warning: not inside a git repository. Continuing anyway." >&2
fi

# --- Resolve filenames and URLs ---
if [ "$IMPL" = "python" ]; then
  FILENAME="worktreeinclude.py"
  SOURCE_URL="${BASE_URL}/python/${FILENAME}"
  HOOK_CMD="python3 ${DIR}/${FILENAME}"
else
  FILENAME="worktreeinclude.sh"
  SOURCE_URL="${BASE_URL}/bash/${FILENAME}"
  HOOK_CMD="${DIR}/${FILENAME}"
fi

TARGET="${DIR}/${FILENAME}"

# --- Download implementation ---
if [ -f "$TARGET" ]; then
  echo "Skipping download: ${TARGET} already exists." >&2
else
  echo "Downloading ${IMPL} implementation to ${TARGET}..." >&2
  mkdir -p "$DIR"
  if ! curl -fsSL "$SOURCE_URL" -o "$TARGET"; then
    echo "Error: failed to download from ${SOURCE_URL}" >&2
    rm -f "$TARGET"
    exit 1
  fi
  chmod +x "$TARGET"
  echo "Downloaded ${TARGET}" >&2
fi

# --- Configure .claude/settings.json ---
SETTINGS_DIR=".claude"
SETTINGS_FILE="${SETTINGS_DIR}/settings.json"

# Build the hooks JSON with the correct command paths
HOOKS_JSON=$(cat <<EOF
{
  "hooks": {
    "WorktreeCreate": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${HOOK_CMD} create --hook"
          }
        ]
      }
    ],
    "WorktreeRemove": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${HOOK_CMD} remove --hook"
          }
        ]
      }
    ]
  }
}
EOF
)

mkdir -p "$SETTINGS_DIR"

if [ -f "$SETTINGS_FILE" ]; then
  # Check if hooks already reference worktreeinclude
  if jq -e '.hooks' "$SETTINGS_FILE" >/dev/null 2>&1 && \
     grep -q "worktreeinclude" "$SETTINGS_FILE" 2>/dev/null; then
    echo "Skipping settings: ${SETTINGS_FILE} already has worktreeinclude hooks." >&2
  else
    echo "Updating ${SETTINGS_FILE} with worktreeinclude hooks..." >&2
    MERGED=$(printf '%s\n' "$HOOKS_JSON" | jq -s '.[0] * .[1]' "$SETTINGS_FILE" -)
    printf '%s\n' "$MERGED" > "$SETTINGS_FILE"
    echo "Updated ${SETTINGS_FILE}" >&2
  fi
else
  echo "Creating ${SETTINGS_FILE}..." >&2
  printf '%s\n' "$HOOKS_JSON" | jq '.' > "$SETTINGS_FILE"
  echo "Created ${SETTINGS_FILE}" >&2
fi

# --- Create .worktreeinclude template ---
MANIFEST=".worktreeinclude"

if [ -f "$MANIFEST" ]; then
  echo "Skipping template: ${MANIFEST} already exists." >&2
else
  echo "Creating ${MANIFEST} template..." >&2
  cat > "$MANIFEST" <<'TEMPLATE'
# .worktreeinclude — files to materialize into Git worktrees
#
# List repository-relative paths, one per line.
# These files will be copied from the main worktree into linked worktrees.
#
# Directives (apply to the next entry only):
#   # @symlink   — symlink instead of copy (saves disk, shares changes)
#   # @optional  — skip if the source file doesn't exist
#
# Examples:
#   .env.local
#   config/credentials/dev.key
#
#   # @symlink
#   storage/large-fixture.db
#
#   # @optional
#   .env.test.local
TEMPLATE
  echo "Created ${MANIFEST}" >&2
fi

# --- Done ---
echo "" >&2
echo "Setup complete! .worktreeinclude is ready." >&2
echo "  Script:   ${TARGET}" >&2
echo "  Hooks:    ${SETTINGS_FILE}" >&2
echo "  Manifest: ${MANIFEST}" >&2
echo "" >&2
echo "Next steps:" >&2
echo "  1. Add files to .worktreeinclude (one path per line)" >&2
echo "  2. Commit .worktreeinclude and ${TARGET} to your repo" >&2
echo "  3. Claude Code will auto-materialize files into new worktrees" >&2
