#!/usr/bin/env bash
# zs — jbang-style Zig scripts (zig-script)
#
# Requires Bash 4.3+ (nameref). Fedora and Homebrew bash are fine;
# stock macOS /bin/bash 3.2 is not — put Bash 4.3+ first on PATH.
#
#   //DEPS gh:owner/repo/ref
#   //DEPS gh:owner/repo/ref AS depname
#   //DEPS git:https://gitlab.com/user/repo.git#ref
#   //DEPS gh:owner/repo/ref/path/to/module.zig
#
# ZIG — compiler command (default: zig on PATH).
#
# CWD: binary runs with cwd = the directory where you invoked zs.
#      ZS_CWD is also set to that path.
#
set -euo pipefail

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3))); then
    echo "zs: need Bash 4.3+ (found $BASH_VERSION); ensure #!/usr/bin/env bash resolves to it" >&2
    exit 1
fi

die() { echo "zs: $*" >&2; exit 1; }
die_usage() { echo "$*" >&2; usage; exit 2; }

usage() {
    cat <<'EOF' >&2
usage:
  zs <script.zig> [args...]
  zs clean <script>|--all
  zs env init [dir]
  zs env activate [dir]
  zs selfcheck
  zs help
EOF
}

[[ $# -ge 1 ]] || die_usage "missing arguments"

CALLER_PWD="$(pwd -P)"

sha() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$@" | awk '{print $1}'
    else
        openssl dgst -sha256 "$@" | awk '{print $NF}'
    fi
}

resolve_zs_root() {
    if [[ -n "${ZS_ROOT:-}" ]]; then
        printf '%s' "$ZS_ROOT"
    elif [[ -d "$CALLER_PWD/.zs" ]]; then
        printf '%s' "$CALLER_PWD/.zs"
    else
        printf ''
    fi
}

cache_base() {
    if [[ -n "${ZS_CACHE:-}" ]]; then
        printf '%s' "$ZS_CACHE"
    else
        local root
        root="$(resolve_zs_root)"
        if [[ -n "$root" ]]; then
            printf '%s' "$root/cache"
        else
            printf '%s' "${XDG_CACHE_HOME:-$HOME/.cache}/zig-script"
        fi
    fi
}

maybe_isolate_zig() {
    local root
    root="$(resolve_zs_root)"
    [[ -n "$root" ]] || return 0
    export ZS_ROOT="$root"
    export ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-$root/zig-local-cache}"
    mkdir -p "$ZIG_LOCAL_CACHE_DIR"
}

script_cache_dir() {
    local script=$1
    printf '%s/%s' "$(cache_base)" "$(printf '%s' "$script" | sha)"
}

abspath_script() {
    local p=$1
    [[ -f "$p" ]] || die "not a file: $p"
    printf '%s/%s' "$(cd "$(dirname "$p")" && pwd -P)" "$(basename "$p")"
}

read_stamp() {
    local f=$1
    [[ -f "$f" ]] || return 1
    local s
    s=$(<"$f")
    s=${s%"${s##*[![:space:]]}"}
    printf '%s' "$s"
}

_ZS_LOCK=
release_lock() {
    [[ -n "${_ZS_LOCK:-}" ]] || return 0
    rmdir "$_ZS_LOCK" 2>/dev/null || true
    _ZS_LOCK=
}
acquire_lock() {
    local lock=$1
    if mkdir "$lock" 2>/dev/null; then
        _ZS_LOCK=$lock
        trap release_lock EXIT
        return 0
    fi
    die "locked ($lock) — another zs is building this script"
}

find_zig() {
    local path
    if [[ -n "${ZIG:-}" ]]; then
        path="$(type -P "$ZIG")" || die "ZIG='$ZIG' not found on PATH"
        printf '%s' "$path"
        return 0
    fi
    path="$(type -P zig)" || die "zig not found on PATH (install zig or set ZIG)"
    printf '%s' "$path"
}

zig_ver() {
    local bin=$1
    "$bin" version 2>/dev/null | head -n1 || printf '?'
}

fetch() {
    local url=$1 out=$2
    [[ $FORCE_FETCH -eq 0 && -s "$out" ]] && return 0
    curl -fsSL "$url" -o "$out"
}

resolve_as() {
    local def=$1 as=${2:-}
    printf '%s' "${as:-$def}"
}

# Sanitize dependency key for build.zig.zon (lowercase alnum + underscore).
dep_key() {
    local s=$1
    s=${s//[^A-Za-z0-9_]/_}
    [[ "$s" =~ ^[A-Za-z] ]] || s="dep_$s"
    printf '%s' "$s"
}

fetch_github_zig() {
    local spec=$1 owner repo ref path url
    owner=${spec%%/*}; spec=${spec#*/}
    repo=${spec%%/*};  spec=${spec#*/}
    ref=${spec%%/*};  path=${spec#*/}
    url="https://raw.githubusercontent.com/$owner/$repo/$ref/$path"
    fetch "$url" "$(basename "$path")"
}

# PACKAGES: key|git_url|import_name
# GH_FILES: fetched .zig basenames
PACKAGES=()
GH_FILES=()

add_deps_ref() {
    local raw=$1 as=${2:-} opts=${3:-}
    local kind ref n owner repo tag key url import_name

    case "$raw" in
        gh:*)  kind=gh;  ref=${raw#gh:} ;;
        git:*) kind=git; ref=${raw#git:} ;;
        *) die "//DEPS needs gh: or git: prefix — got: $raw" ;;
    esac
    [[ -n "$opts" ]] && die "zs: dependency options [...] not supported yet: $raw"

    if [[ "$kind" == git ]]; then
        [[ "$ref" == http* ]] || die "git: must be a full URL (https://...#ref) — got: $ref"
        key=$(dep_key "$(resolve_as "$(basename "${ref%%#*}" .git)" "$as")")
        url="git+${ref}"
        import_name=$(resolve_as "$key" "$as")
        PACKAGES+=("$key|$url|$import_name")
        return 0
    fi

    n=$(awk -F/ '{print NF}' <<<"$ref")
    if [[ "$n" -eq 3 ]]; then
        owner=${ref%%/*}; ref=${ref#*/}
        repo=${ref%%/*}; tag=${ref#*/}
        key=$(dep_key "$(resolve_as "${repo%.zig}" "$as")")
        url="git+https://github.com/${owner}/${repo}.git#${tag}"
        import_name=$(resolve_as "$key" "$as")
        PACKAGES+=("$key|$url|$import_name")
        return 0
    fi
    if [[ "$n" -ge 4 ]]; then
        fetch_github_zig "$ref"
        GH_FILES+=("$(basename "${ref##*/}")")
        return 0
    fi
    die "gh: ref needs owner/repo/ref or owner/repo/ref/path — got: $ref"
}

write_build_zig() {
    local body="" entry key url import_name

    for entry in ${PACKAGES[@]+"${PACKAGES[@]}"}; do
        IFS='|' read -r key url import_name <<<"$entry"
        body+=$'    const '"$key"$' = b.dependency("'$key$'", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("'$import_name$'", '"$key"$'.module("'$import_name$'"));
'
    done

    cat >build.zig <<EOF
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const exe = b.addExecutable(.{
        .name = "script",
        .root_source_file = b.path("script.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addIncludePath(b.path("."));

$body
    b.installArtifact(exe);
}
EOF
}

fetch_packages() {
    local zig_bin=$1
    cat >build.zig.zon <<'EOF'
.{
    .name = .script,
    .version = "0.0.0",
}
EOF
    local entry key url _import_name
    for entry in ${PACKAGES[@]+"${PACKAGES[@]}"}; do
        IFS='|' read -r key url _import_name <<<"$entry"
        "$zig_bin" fetch --save="$key" "$url"
    done
}

zig_build() {
    local zig_bin=$1
    fetch_packages "$zig_bin"
    write_build_zig
    "$zig_bin" build -Doptimize=ReleaseFast
}

zig_build_exe() {
    local zig_bin=$1
    local -a args=("$zig_bin" build-exe -OReleaseFast "script.zig" --name script)
    [[ ${#GH_FILES[@]} -eq 0 ]] || args+=(-I.)
    "${args[@]}"
}

# --- subcommands -------------------------------------------------------------

cmd_help() { usage; exit 0; }

cmd_clean() {
    local target=${1:-}
    [[ -n "$target" ]] || die_usage "usage: zs clean <script>|--all"
    maybe_isolate_zig
    if [[ "$target" == --all ]]; then
        local base
        base="$(cache_base)"
        echo "zs: removing $base"
        rm -rf "$base"
        exit 0
    fi
    local script dir
    script="$(abspath_script "$target")"
    dir="$(script_cache_dir "$script")"
    echo "zs: removing $dir"
    rm -rf "$dir"
    exit 0
}

cmd_env_init() {
    local dir=${1:-$CALLER_PWD}
    mkdir -p "$dir"
    dir="$(cd "$dir" && pwd -P)"
    local root="$dir/.zs"
    mkdir -p "$root/cache" "$root/zig-local-cache"
    cat >"$root/activate" <<'EOF'
# usage: source .zs/activate
_ZS="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
export ZS_ROOT="$_ZS"
export ZS_CACHE="$_ZS/cache"
export ZIG_LOCAL_CACHE_DIR="$_ZS/zig-local-cache"
mkdir -p "$ZS_CACHE" "$ZIG_LOCAL_CACHE_DIR"
echo "zs: env $_ZS" >&2
EOF
    echo "zs: initialized $root"
    echo "zs:   source $root/activate"
    echo "zs:   add .zs/ to .gitignore"
    exit 0
}

cmd_env_activate() {
    local dir=${1:-$CALLER_PWD}
    dir="$(cd "$dir" && pwd -P)"
    local root="$dir/.zs"
    [[ -d "$root" ]] || die "no $root — run: zs env init"
    cat <<EOF
export ZS_ROOT=$(printf '%q' "$root")
export ZS_CACHE=$(printf '%q' "$root/cache")
export ZIG_LOCAL_CACHE_DIR=$(printf '%q' "$root/zig-local-cache")
mkdir -p "\$ZS_CACHE" "\$ZIG_LOCAL_CACHE_DIR"
EOF
    exit 0
}

cmd_env() {
    local sub=${1:-}
    shift || true
    case "$sub" in
        init)     cmd_env_init "$@" ;;
        activate) cmd_env_activate "$@" ;;
        *) die_usage "usage: zs env init|activate [dir]" ;;
    esac
}

cmd_selfcheck() {
    local tmp failures=0 out zig_bin
    tmp="$(mktemp -d "$CALLER_PWD/.zs-selfcheck.XXXXXX")"
    trap 'rm -rf -- '"$(printf '%q' "$tmp")" EXIT

    echo "zs: bash $BASH_VERSION"
    zig_bin="$(find_zig)"
    echo "zs: ok zig -> $zig_bin ($(zig_ver "$zig_bin"))"

    command -v curl >/dev/null || { echo "zs: missing curl" >&2; failures=1; }

    local re line
    re='^[[:space:]]*//DEPS[[:space:]]+([^[:space:][]+)(\[([^]]*)\])?([[:space:]]+AS[[:space:]]+([^[:space:]]+))?[[:space:]]*$'
    line='//DEPS gh:ziglang/zig/v0.14.0'
    if [[ "$line" =~ $re ]] && [[ "${BASH_REMATCH[1]}" == "gh:ziglang/zig/v0.14.0" ]]; then
        echo "zs: ok //DEPS parse"
    else
        echo "zs: //DEPS parse failed" >&2
        failures=1
    fi

    cat >"$tmp/hi.zig" <<'EOF'
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    try std.Io.File.stdout().writeStreamingAll(init.io, "ok\n");
}
EOF
    out="$(ZS_CACHE="$tmp/cache" "$0" "$tmp/hi.zig" 2>/dev/null || true)"
    if [[ "$out" == "ok" ]]; then
        echo "zs: ok no-deps compile+run"
    else
        echo "zs: no-deps compile+run failed" >&2
        ZS_CACHE="$tmp/cache" "$0" "$tmp/hi.zig" >&2 || true
        failures=1
    fi

    [[ $failures -eq 0 ]] || exit 1
    echo "zs: selfcheck passed"
    exit 0
}

case "$1" in
    help|-h|--help) cmd_help ;;
    clean) shift; cmd_clean "$@" ;;
    env) shift; cmd_env "$@" ;;
    selfcheck) cmd_selfcheck ;;
esac

# --- run script --------------------------------------------------------------

maybe_isolate_zig

SCRIPT="$(abspath_script "$1")"
shift
[[ "${SCRIPT##*.}" == zig ]] || die "unsupported extension (use .zig)"

ZIG_BIN="$(find_zig)"
HOST="$(uname -s)-$(uname -m)"
STAMP_ZIG="${ZIG_BIN}@$(zig_ver "$ZIG_BIN")"

ROOT="$(script_cache_dir "$SCRIPT")"
mkdir -p "$ROOT"
cd "$ROOT"

CONTENT_HASH="$(sha "$SCRIPT")"
STAMP="${CONTENT_HASH}|${HOST}|${STAMP_ZIG}"
BIN="$ROOT/script"

prepare_run_env() {
    export ZS_CWD="$CALLER_PWD"
}

run_bin() {
    prepare_run_env
    cd "$CALLER_PWD"
    exec "$BIN" "$@"
}

is_warm() {
    local cur
    cur="$(read_stamp "$ROOT/.zs_stamp")" || return 1
    [[ "$cur" == "$STAMP" ]] || return 1
    if [[ -x "$ROOT/script" ]]; then
        BIN="$ROOT/script"
        return 0
    fi
    if [[ -x "$ROOT/zig-out/bin/script" ]]; then
        BIN="$ROOT/zig-out/bin/script"
        return 0
    fi
    return 1
}

if is_warm; then
    run_bin "$@"
fi

acquire_lock "$ROOT/.zs_lock"
if is_warm; then
    run_bin "$@"
fi

FORCE_FETCH=1
if cur="$(read_stamp "$ROOT/.zs_stamp")" && [[ "$cur" == "$STAMP" ]]; then
    FORCE_FETCH=0
fi

PACKAGES=()
GH_FILES=()

DEPS_RE='^[[:space:]]*//DEPS[[:space:]]+([^[:space:][]+)(\[([^]]*)\])?([[:space:]]+AS[[:space:]]+([^[:space:]]+))?[[:space:]]*$'
while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ $DEPS_RE ]] || continue
    add_deps_ref "${BASH_REMATCH[1]}" "${BASH_REMATCH[5]:-}" "${BASH_REMATCH[3]:-}"
done <"$SCRIPT"

sed '1{/^#!/d;}' "$SCRIPT" >script.zig

if [[ ${#PACKAGES[@]} -gt 0 ]]; then
    zig_build "$ZIG_BIN"
    BIN="$ROOT/zig-out/bin/script"
else
    zig_build_exe "$ZIG_BIN"
    BIN="$ROOT/script"
fi

[[ -x "$BIN" ]] || die "build succeeded but binary missing: $BIN"

printf '%s\n' "$STAMP" >.zs_stamp
run_bin "$@"
