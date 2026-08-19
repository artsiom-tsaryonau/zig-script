# zig-script

jbang-style single-file Zig scripts. Dependencies live in `//DEPS` comments; builds cache under `~/.cache/zig-script` (or `.zs/cache`).

## Install

Put `zs` on your `PATH`. Requires **Bash 4.3+**, **zig**, and **curl**.

```bash
chmod +x zs
sudo ln -sf "$PWD/zs" /usr/local/bin/zs   # optional
zs selfcheck
```

## Usage

```bash
zs examples/hello.zig
zs clean examples/hello.zig
zs env init    # optional project-local .zs/
```

## //DEPS

Same comment style as [cx-script](https://github.com/artsiom-tsaryonau/cx-script). **No Conan/vcpkg** — Zig-native git deps only.

| Prefix | Example | Meaning |
| --- | --- | --- |
| `gh:` | `//DEPS gh:zigzap/zap/v0.1.7-pre` | GitHub package → `build.zig.zon` |
| `gh:` | `//DEPS gh:owner/repo/ref/path/file.zig` | Raw file fetch (include via `@import`) |
| `git:` | `//DEPS git:https://gitlab.com/user/repo.git#v1.0` | Any git host |

Optional alias (import name must match the dependency's exported module):

```
//DEPS gh:owner/my-lib/v1.0 AS my_lib
```

## gh: vs git:

- **`gh:owner/repo/ref`** — GitHub shorthand (same idea as cx). Use this by default.
- **`git:https://...#ref`** — full URL for GitLab, Codeberg, self-hosted git, etc.

cx-style `gh:` keeps scripts portable across the cx / zs / ns family; `git:` is the escape hatch when the host is not GitHub.

## Shebang

```zig
#!/usr/bin/env zs
```

## Platforms

Tested target: **macOS** and **Fedora** with Homebrew/dnf `bash`, `zig`, and `curl`.
