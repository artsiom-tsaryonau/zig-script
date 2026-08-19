# zig-script

A script runner for Zig with inline //DEPS — GitHub and git remotes.

jbang-style single-file scripts. Every dep is explicit: `gh:` or `git:`.

### Runner (put `zs` on PATH)

```bash
git clone git@github.com:artsiom-tsaryonau/zig-script.git
cd zig-script
chmod +x zs
export PATH="$PWD:$PATH"
# permanent: sudo ln -sf "$PWD/zs" /usr/local/bin/zs
# Needs Bash 4.3+ (nameref). On macOS: brew install bash
zs selfcheck
```

### Install (once per machine)

Host tools only — Bash, zig, curl. Package *trees* land in the script cache (or `.zs/cache`), not in system prefixes.

**Fedora**

```bash
sudo dnf install bash zig curl git
```

**macOS**

```bash
brew install bash zig curl git
export PATH="$(brew --prefix bash)/bin:$PATH"   # stock /bin/bash is 3.2
```

You do **not** need a global `build.zig.zon` or checked-in `build.zig`. `zs` generates those per script in the cache. You do **not** need different `//DEPS` per OS.

Still global by design: the `zig` compiler, `curl`, and `git` (used by `zig fetch`). Everything those tools *download* for a script lands under the cache entry for that script.

## Usage

```bash
zs examples/hello.zig
zs clean examples/hello.zig
```

Scripts use normal `.zig` extensions. The binary runs with **cwd = the directory where you invoked `zs`** (not the cache build dir). `ZS_CWD` is set to the same path.

### Project env (optional)

```bash
zs env init                 # .zs/{cache,zig-local-cache,activate}
source .zs/activate         # or: eval "$(zs env activate)"
zs examples/hello.zig       # builds → .zs/cache
```

Layout:

```text
.zs/
  activate
  cache/                 # per-script builds
  zig-local-cache/       # ZIG_LOCAL_CACHE_DIR when env active
```

If `.zs/` exists in the current directory (or `ZS_ROOT` is set), `zs` picks it up automatically. Add `.zs/` to `.gitignore`.

```bash
zs clean examples/hello.zig   # drop one script's build dir
zs clean --all                # wipe cache only
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for the pipeline.

## `//DEPS`

Same comment style as [cx-script](https://github.com/artsiom-tsaryonau/cx-script). **No Conan/vcpkg** — Zig-native git deps only.

Prefix is **required**:

| Prefix | Ref | Backend |
|--------|-----|---------|
| `gh:` | `owner/repo/ref` (3 parts) | GitHub → `build.zig.zon` + `zig fetch` |
| `gh:` | `owner/repo/ref/path/…` (4+) | GitHub raw file(s) → cache dir, `@import` by basename |
| `git:` | `https://host/…/repo.git#ref` | Any git host → `build.zig.zon` + `zig fetch` |

`gh:` is GitHub shorthand. `git:` is the same fetch path with a **full repository URL** (GitLab, Codeberg, self-hosted, …). Raw single-file fetch remains `gh:` only (GitHub raw URLs).

Optional `AS import_name` when the default module name is wrong (must match the dependency's exported module):

```zig
//DEPS gh:zigzap/zap/v0.1.7-pre
//DEPS gh:owner/my-lib/v1.0 AS my_lib
//DEPS gh:owner/repo/ref/path/file.zig
//DEPS git:https://gitlab.com/user/repo.git#v1.0
```

With no `//DEPS`, `zs` uses `zig build-exe` directly. With git deps, it generates `build.zig` / `build.zig.zon` and runs `zig build`.

## Shebang

```zig
#!/usr/bin/env zs
```

## Cache

Resolution order:

1. `ZS_CACHE` if set  
2. `$ZS_ROOT/cache` or `./.zs/cache` when a project env exists  
3. `${XDG_CACHE_HOME:-~/.cache}/zig-script`

Each script gets `<cache>/<sha256(abspath)>/`. Stamp is `content|host|zig@version`. Unchanged stamp → warm exec.

## Platforms

Tested target: **macOS** and **Fedora** with Homebrew/dnf `bash`, `zig`, and `curl`.
