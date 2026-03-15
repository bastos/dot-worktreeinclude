# Spec: .worktreeinclude

- **Status:** Draft
- **Version:** 0.2
- **Last updated:** 2026-03-15

## 1. Purpose

`.worktreeinclude` defines which repository-relative paths must be materialized into a newly created Git worktree when those paths are not provided by Git itself.

This spec exists for the boring but real problem of local development state: ignored environment files, local credentials, framework-specific development config, and large local assets that make a fresh worktree unusable without manual copying.

The spec is split into two conformance levels:

- **Base** -- every entry is copied from the source checkout into the target worktree. Missing source paths and existing destination paths cause failure by default.
- **Extra** -- extends the base with two per-entry directives:
  - `# @symlink`, materialize the next entry as a symbolic link instead of a copy
  - `# @optional`, do not fail if the next entry does not exist in the source checkout

The base level is deliberately minimal so that simple implementations can conform without supporting directives. A manifest written for Extra still works with a base-only implementation -- it just copies everything and fails loudly on missing paths.

The format is intentionally small, explicit, and line-oriented.

## 2. Scope

This spec covers:

- manifest file name and location
- file format and directive syntax
- path validation and resolution
- copy and symlink semantics
- required failure behavior
- directory handling
- conformance levels (base and extra)
- examples for common frameworks

This spec does not define:

- dependency installation
- service startup
- secret management
- remote synchronization
- pattern matching or globbing
- any sidecar state file for tracking materialized entries

## 3. Terminology

### 3.1 Source checkout

The existing checkout from which ignored or local files are read.

### 3.2 Target worktree

The newly created Git worktree that receives materialized entries.

### 3.3 Manifest

The `.worktreeinclude` file at the repository root.

### 3.4 Entry

A single repository-relative path line in the manifest.

### 3.5 Materialize

Create the destination path in the target worktree by either copying or symlinking the corresponding source path.

## 4. Conformance levels

This spec defines two conformance levels. An implementation MUST declare which level it supports.

### 4.1 Base conformance

A base-conforming implementation:

- Reads the manifest and treats every non-empty, non-comment line as a path entry.
- Copies every entry from the source checkout into the target worktree.
- Treats all lines starting with `#` as comments, including `# @symlink` and `# @optional`.
- Fails by default when a source path does not exist.
- Fails by default when a destination path already exists.
- MAY provide options to suppress or downgrade these failures.

Base conformance is the minimum viable implementation. A manifest that uses Extra directives is still a valid manifest for a base implementation -- the directives are ignored as comments and every path entry is copied with default failure behavior.

### 4.2 Extra conformance

An Extra-conforming implementation supports everything in Base, plus:

- Recognizes `# @symlink` and `# @optional` as directives (not comments).
- Applies directives only to the next valid path entry.
- Supports symlink materialization mode.
- Supports optional entries that are silently skipped when the source is absent.
- SHOULD reject unknown `# @*` lines as parse errors.

An Extra-conforming implementation is a strict superset of a base implementation.

### 4.3 Backwards compatibility

The two-level design provides forwards compatibility for manifests:

| Manifest uses     | Base implementation         | Extra implementation          |
|-------------------|-----------------------------|-------------------------------|
| Plain paths only  | Copies all. Fails on miss.  | Copies all. Fails on miss.    |
| `# @optional`     | Ignores directive. Copies all. Fails on miss. | Skips missing optional entries. |
| `# @symlink`      | Ignores directive. Copies all. | Creates symlinks as directed. |
| Both directives   | Ignores directives. Copies all. Fails on miss. | Full directive support. |

A manifest author who wants maximum compatibility SHOULD assume that some implementations will only support the base level. If a base implementation encounters a `# @symlink` entry, it copies instead of symlinking. If it encounters a `# @optional` entry whose source is missing, it fails -- unless the implementation provides its own option to suppress missing-source failures.

## 5. Behavioral model

A conforming implementation MUST process `.worktreeinclude` after the target worktree exists on disk and before any subsequent setup step that may depend on materialized files.

The manifest is intended for paths that Git does not populate in the new worktree, typically because they are ignored or otherwise local-only.

Tracked files are already present in the target worktree through normal Git checkout behavior. Using `.worktreeinclude` for tracked files is invalid.

## 6. File name and location

The manifest file name is:

```
.worktreeinclude
```

The file MUST live at the repository root of the source checkout.

## 7. File format

The format is line-oriented.

### 7.1 Basic rules (Base)

- Empty lines are ignored.
- Lines starting with `#` are comments.
- Non-empty, non-comment lines are literal repository-relative paths.
- Paths use forward slashes (`/`) as separators.
- Paths MUST be interpreted literally. This spec does not define globbing, wildcard matching, or `.gitignore` pattern semantics.
- Default mode for every entry is copy.

### 7.2 Directives (Extra)

Extra-conforming implementations reinterpret two specific comment forms as directives:

```
# @symlink
# @optional
```

Directive semantics:

- `# @symlink` changes the next entry from copy to symlink.
- `# @optional` suppresses the default missing-source failure for the next entry only.
- Directives apply only to the next valid path entry.
- Multiple directives MAY stack for the next valid path entry.

Example:

```
.env.local
# @optional
.env.test.local
# @symlink
storage/local/GeoLite2-City.mmdb
# @optional
# @symlink
vendor/models/embeddings
```

Interpretation under Extra:

- `.env.local` is copied and required.
- `.env.test.local` is copied and optional.
- `storage/local/GeoLite2-City.mmdb` is symlinked and required.
- `vendor/models/embeddings` is symlinked and optional.

Interpretation under Base:

- All four paths are copied and required. The `# @optional` and `# @symlink` lines are ignored as comments.

### 7.3 Unknown directives (Extra)

A line beginning with `# @` that is not `# @symlink` or `# @optional` SHOULD cause a parse error in an Extra-conforming implementation.

A base-conforming implementation treats all `# @*` lines as regular comments.

That keeps the format honest and avoids quietly doing the wrong thing, which is a classic computer gremlin move.

## 8. Path rules

Each entry MUST be a repository-relative path.

Implementations MUST reject:

- absolute paths
- paths that normalize outside the repository root
- paths that refer to Git internals, including `.git`
- paths containing `.` or `..` segments after normalization if they escape the repository root

Examples of invalid entries:

```
/etc/passwd
../../secret.txt
.git/config
```

Examples of valid entries:

```
.env.local
config/database.yml
storage/local/GeoLite2-City.mmdb
frontend/.env.development.local
```

## 9. Eligibility rules

`.worktreeinclude` is for paths that are not populated by Git checkout.

A conforming implementation MUST treat a manifest entry that resolves to a tracked Git path as invalid.

Default behavior for an invalid tracked entry is failure.

An implementation MAY provide an explicit non-default compatibility mode to suppress or downgrade this failure, but that behavior is outside this spec.

## 10. Materialization modes

### 10.1 Copy mode (Base)

Copy mode is the default for all entries at the base conformance level, and for entries without a `# @symlink` directive at the Extra level.

For a copy entry whose source exists:

- if the source path is a file, the destination MUST be a file
- if the source path is a directory, the destination MUST be a directory copied recursively
- parent directories in the target MUST be created as needed

A conforming implementation SHOULD preserve file permissions when practical.

### 10.2 Symlink mode (Extra)

Symlink mode is enabled by `# @symlink` for the next entry. This is only available at the Extra conformance level.

For a symlink entry whose source exists:

- the implementation MUST create a symbolic link in the target worktree
- if the source path is a file, the destination MUST be a file symlink when the platform distinguishes file and directory symlinks
- if the source path is a directory, the destination MUST be a directory symlink, junction, or platform-equivalent link type
- parent directories in the target MUST be created as needed

Directory symlinks are allowed by this spec.

### 10.3 Relative vs absolute symlink targets (Extra)

When creating a symlink, the implementation SHOULD use a relative symlink target when that target can be represented correctly on the current platform.

If a relative target cannot be represented or would be invalid on the current platform, the implementation MUST fall back to an absolute target.

Rationale:

- relative links are usually more robust when the source checkout and target worktree are moved together
- absolute links are sometimes required on platforms or layouts where a relative target is not representable or practical, such as different Windows drive roots

## 11. Missing source paths

By default, a missing source path is an error. This applies at both conformance levels.

If an entry's source path does not exist, the implementation MUST fail by default.

An implementation MAY provide an explicit option to suppress or downgrade this failure. For example, a base implementation might offer a `--skip-missing` flag or choose to skip missing sources by default. That behavior is implementation-specific and outside this spec.

At the Extra conformance level, `# @optional` provides per-entry control: if an entry is marked `# @optional` and the source path does not exist, the implementation MUST skip that entry without failing.

This spec chooses failure by default because silent absence is a terrific way to waste an afternoon.

## 12. Existing destination paths

If the destination path already exists in the target worktree, the implementation MUST NOT silently replace it.

Default behavior is failure. This applies at both conformance levels.

An implementation MAY provide an explicit force or overwrite mode, but that behavior is outside this spec.

This rule applies to both copy and symlink entries.

## 13. Idempotence and re-application

A conforming implementation MAY support re-applying `.worktreeinclude` to an existing worktree.

When it does, it MUST derive behavior from the current manifest and current filesystem state. It MUST NOT require a separate metadata file to remember what was previously materialized.

If an implementation offers cleanup, sync, or reconciliation behavior, it MUST use the manifest itself as the source of truth.

## 14. Safety rules

A conforming implementation MUST reject source paths that resolve to unsafe filesystem object types when materialization would be ambiguous or dangerous, including:

- device files
- named pipes
- sockets
- entries inside `.git`

An implementation MAY choose to support additional filesystem types, but that behavior is outside this spec.

## 15. Cross-platform requirements

### 15.1 POSIX platforms

On Linux and macOS, Extra implementations SHOULD use standard symbolic links for `@symlink` entries.

### 15.2 Windows

On Windows, Extra implementations MAY use the closest safe equivalent for directory symlinks, such as junctions, when standard symlink creation is unavailable or requires elevated privileges.

If the platform cannot create the required link type, the implementation MUST fail unless it offers an explicit compatibility mode outside this spec.

It MUST NOT silently downgrade `@symlink` to copy.

## 16. Security considerations

`.worktreeinclude` can duplicate secrets and local credentials into additional directories.

Repository maintainers SHOULD assume that every copied secret creates another place that must be protected.

Recommendations:

- use copy for files that should diverge per worktree
- use symlink for large, read-mostly, intentionally shared assets
- avoid symlinking mutable files that should not be shared across worktrees
- review the manifest as carefully as code, because it changes what local state gets propagated

## 17. Parsing model

### 17.1 Base parser

A minimal base parser ignores all comment lines and treats every other non-empty line as a copy entry:

```
entries = []

for each line in file:
  trimmed = trim(line)

  if trimmed is empty:
    continue

  if trimmed starts with "#":
    continue

  entries << {
    path: trimmed,
    mode: copy,
    optional: false
  }
```

### 17.2 Extra parser

An Extra parser extends the base parser to recognize directives:

```
pending_mode = copy
pending_optional = false
entries = []

for each line in file:
  trimmed = trim(line)

  if trimmed is empty:
    continue

  if trimmed == "# @symlink":
    pending_mode = symlink
    continue

  if trimmed == "# @optional":
    pending_optional = true
    continue

  if trimmed starts with "# @":
    fail("unknown directive")

  if trimmed starts with "#":
    continue

  entries << {
    path: trimmed,
    mode: pending_mode,
    optional: pending_optional
  }

  pending_mode = copy
  pending_optional = false
```

## 18. Execution model

A conforming implementation SHOULD behave as follows:

1. Determine the repository root of the source checkout.
2. Create the target worktree.
3. Read `.worktreeinclude` from the source checkout root, if present.
4. Parse the manifest (base or extra parser).
5. Validate each entry.
6. For each entry, resolve the source path in the source checkout and the destination path in the target worktree.
7. Enforce failure rules for tracked paths, missing required paths, unsafe paths, and existing destination conflicts.
8. Materialize the entry as copy (base) or copy/symlink (extra).

## 19. Example: Vanilla Rails

A vanilla Rails application often depends on ignored local config, local credentials, and one or two large development assets.

Example:

```
config/database.yml
config/cable.yml
config/storage.yml
config/credentials/development.key
config/credentials/test.key
.env.development.local
# @optional
.env.test.local
# @symlink
storage/local/GeoLite2-City.mmdb
```

Interpretation (Extra):

- the config files and local env files are copied into the new worktree
- `.env.test.local` is copied only if it exists
- the large GeoIP database is symlinked instead of duplicated

Interpretation (Base):

- all eight paths are copied and required
- if `.env.test.local` does not exist, the implementation fails (unless it provides its own option to suppress missing-source failures)

Why this split makes sense:

- `database.yml` and credential keys are small and often worktree-specific
- a large read-mostly binary asset is a better symlink candidate

## 20. Example: Next.js

A Next.js application commonly needs local environment files and occasionally a large local asset or model used only in development.

Example:

```
.env.local
.env.development.local
# @optional
.env.test.local
.vercel/project.json
# @symlink
public/dev-assets/embeddings
```

Interpretation (Extra):

- the local environment files are copied
- the optional test environment file is skipped if absent
- the Vercel project linkage file is copied
- a large local embeddings directory is symlinked

Interpretation (Base):

- all five paths are copied and required

Why this split makes sense:

- `.env.local` usually needs to exist as a real file in each worktree
- a large local asset directory should not be copied over and over like a caffeinated raccoon hoarding pebbles

## 21. Example: Django

A Django application often uses a local settings file, local env file, and one or more downloaded development datasets.

Example:

```
.env
.env.local
config/settings.local.py
# @optional
config/settings.test.local.py
# @symlink
data/GeoLite2-City.mmdb
# @optional
# @symlink
data/ml-models
```

Interpretation (Extra):

- `.env`, `.env.local`, and `config/settings.local.py` are copied
- `config/settings.test.local.py` is copied only if present
- the GeoIP database is symlinked
- the local models directory is symlinked only if present

Interpretation (Base):

- all six paths are copied and required

## 22. Non-example: things that SHOULD NOT go here

These entries are poor candidates for `.worktreeinclude`:

```
app/models/user.rb
package.json
Gemfile
requirements.txt
```

Why:

- they are tracked files
- Git already populates them in the target worktree
- listing them here is either pointless or dangerous

Likewise, large generated caches that are cheap to recreate may be better handled by a framework-specific bootstrap step than by this manifest.

## 23. Conformance summary

### 23.1 Base conformance

A base-conforming implementation MUST:

- read `.worktreeinclude` from the source checkout root
- treat entries as literal repository-relative paths
- treat all `#` lines as comments (including `# @symlink` and `# @optional`)
- copy every entry from source to target
- fail by default for missing source paths
- fail by default for tracked paths
- fail by default for existing destination conflicts
- create parent directories as needed
- reject unsafe source paths (device files, pipes, sockets, `.git` entries)
- use the manifest itself, not sidecar metadata, as the source of truth

A base-conforming implementation MAY:

- provide options to suppress or downgrade missing-source failures
- provide options to suppress or downgrade existing-destination failures
- skip missing sources by default (if clearly documented)

### 23.2 Extra conformance

An Extra-conforming implementation MUST satisfy all base requirements, plus:

- support `# @symlink`
- support `# @optional`
- apply directives only to the next valid path entry
- allow file and directory symlinks
- prefer relative symlink targets when valid on the current platform
- fall back to absolute symlink targets when relative targets are not valid or representable
- SHOULD reject unknown `# @*` lines as parse errors

## 24. Conclusion

`.worktreeinclude` should be a tiny, explicit spec for materializing local development files into a fresh worktree.

The core model is simple:

- entries are literal paths
- copy is the default and the base behavior
- a base implementation copies everything and fails loudly
- Extra adds `@symlink` to opt into shared filesystem state
- Extra adds `@optional` to opt out of failure for missing source paths
- the same manifest works at both conformance levels

That keeps the feature understandable, auditable, and practical for real projects built with Rails, Next.js, Django, and similar frameworks -- regardless of which implementation is in use.
