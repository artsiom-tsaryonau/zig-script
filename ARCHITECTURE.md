# Architecture

How `zs` turns a script into a running binary.

## Bash baseline

Requires **Bash 4.3+** (`nameref`, solid arrays). `zs selfcheck` verifies bash version, zig, curl, a no-deps compile/run, and the `//DEPS` regex.

Notable practices: `set -euo pipefail`, `type -P` for zig, `pwd -P`, mkdir locks (not `flock`), stamp re-check after lock, no `eval` for path mutation.

```text
script.zig
    │
    ├─ cache base: ZS_CACHE | $ZS_ROOT/cache | ./.zs/cache | XDG ~/.cache/zig-script
    │
    ├─ warm?  (.zs_stamp == content|host|zig@version && binary exists)
    │         → prepare_run_env → cd $CALLER_PWD → exec
    │
    ├─ parse //DEPS lines
    │     gh:…/…/ref           → build.zig.zon + zig fetch (GitHub)
    │     git:https://…#ref    → build.zig.zon + zig fetch (any git host)
    │     gh:…/…/ref/path/…    → curl raw file(s) into cache dir
    │
    ├─ strip shebang → copy as script.zig in cache
    │
    ├─ if git deps (PACKAGES): generate build.zig.zon + build.zig → zig build
    │     else if raw files only: zig build-exe -I. (include fetched basenames)
    │     else: zig build-exe -OReleaseFast
    │
    └─ prepare_run_env → cd $CALLER_PWD → exec
         (binary at cache/script or cache/zig-out/bin/script)
```

Build uses **ReleaseFast** (via generated `build.zig`). With package deps, `zs` generates ephemeral `build.zig` / `build.zig.zon` in the cache workspace — nothing checked into the script repo. Requires **Zig 0.16+** for the generated build files.

### CWD contract

Build artifacts live under the cache dir; **execution** restores the caller’s working directory and sets `ZS_CWD` to that path. Scripts do not receive a synthetic `argv[1]` path.

### Run-time libraries

Zig links statically by default for most deps. No separate `LD_LIBRARY_PATH` step unless the script or a dependency opts into dynamic linking.

## Project env (`.zs/`)

```text
.zs/
  activate              # source this, or eval "$(zs env activate)"
  cache/                # per-script build workspaces
  zig-local-cache/      # ZIG_LOCAL_CACHE_DIR when env active
```

`zs env init` creates this layout. Presence of `./.zs` (or `ZS_ROOT`) redirects cache and sets `ZIG_LOCAL_CACHE_DIR` without requiring activate.

**Still host-global:** `zig`, `curl`, `git`. **Env-local:** per-script build trees and zig’s local cache dir when the env is active.

This is **not** a VM or a full sysroot. Recreate `.zs` on each machine with `zs env init`; don’t copy it across OS/arch.

## `//DEPS` contract

Every dependency **must** start with a prefix:

| Prefix | Role |
|--------|------|
| `gh:` | GitHub — whole-repo `zig fetch` or raw files |
| `git:` | Any git host — whole-repo `zig fetch` (`https://…#ref`) |

No Conan/vcpkg — Zig-native git deps only.

### `gh:` shape

- **3** path segments (`owner/repo/ref`) → `git+https://github.com/owner/repo.git#ref` in `build.zig.zon`, then `zig fetch --save=key`.
- **4+** segments → download from `raw.githubusercontent.com` into the cache dir; script `@import`s by basename (`-I.` on `build-exe`).

### `git:` shape

- `git:https://gitlab.com/user/repo.git#v1.0` → `git+https://…` URL for `zig fetch`; `#` suffix is the ref/tag.
- Optional `AS import_name` overrides the module name wired in generated `build.zig`.

### Brackets `[…]`

Not supported yet — `zs` errors if options appear in brackets.

## Why zig fetch + generated build.zig

- **zig fetch** owns the dependency *graph* for git packages (via `build.zig.zon`).
- **Generated build.zig** wires fetched packages into the ephemeral executable’s root module.
- **Raw gh: files** skip the package system — curl + include path is enough for single-file drops.
- Portable unit is `//DEPS` (+ optional project `.zs` layout), not downloaded package blobs in the script repo.

## Invalidation

| Change | Effect |
|--------|--------|
| Script bytes change | New `.zs_stamp` → rebuild; raw `gh:` files re-fetched when stamp miss |
| OS/arch or zig path/version | New stamp → rebuild |
| `//DEPS` lines change | Regenerate build files → full build |
| Otherwise | warm `exec` |

## CLI

```bash
zs <script.zig> [args...]
zs clean <script>|--all
zs env init [dir]
zs env activate [dir]    # eval "$(zs env activate)"
zs selfcheck
```

## What we deliberately skip (for now)

- Bracket options on `gh:` / `git:` deps
- Shared global dedup across scripts (zig’s own caches help)
- Bundled zig toolchain
- Replacing `//DEPS` with a second lock dialect
- Content-hashing build *workspaces* beyond script bytes + host + compiler stamp
