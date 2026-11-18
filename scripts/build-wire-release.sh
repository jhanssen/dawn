#!/usr/bin/env bash
#
# build-wire-release.sh
#
# Build a wire-enabled Dawn binary release tarball for Linux/Wayland (Vulkan)
# or macOS (Metal) and (optionally) publish it to github.com/jhanssen/dawn via
# `gh release`.
#
# Produces a monolithic static install containing:
#   - libwebgpu_dawn.a       native Dawn + wire SERVER (GPU process side)
#   - libwebgpu_dawn_wire.a  wire CLIENT + proc table, no native (core side)
#   plus headers and a relocatable lib/cmake/Dawn export.
#
# This is a MANUAL release helper: there is no CI. Run it from a checkout of
# the wire branch with dependencies already fetched (see PREREQUISITES).
#
# PREREQUISITES (one time, in the Dawn checkout):
#   git checkout <wire-branch>
#   python3 tools/fetch_dawn_dependencies.py
# The gpuweb dependency is NOT managed by fetch_dawn_dependencies.py, so this
# script checks it out to the DEPS-pinned commit itself (otherwise idlgen
# generates interop from the wrong webgpu.idl and the node binding fails).
#
# USAGE:
#   scripts/build-wire-release.sh [options]
#
# OPTIONS:
#   --node             also build dawn.node and include it in the tarball
#   --publish          upload the tarball to the GitHub release <tag> on
#                      jhanssen/dawn (creates the release if it doesn't exist)
#   --tag <tag>        release tag (default: v<YYYYMMDD>-linux-wayland-wire-alpha)
#   --jobs <N>         ninja parallelism (default: number of CPUs)
#   --build-dir <dir>  build directory (default: out/wire-release)
#   -h, --help         show this help

set -euo pipefail

# --- locate repo root ---------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# --- platform detection -------------------------------------------------------
OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS" in
  Linux)
    PLATFORM="linux-${ARCH}-wayland"
    PLATFORM_DESC="Linux ${ARCH} Wayland"
    NCPU="$(nproc)"
    # Vulkan backend with Wayland + X11 surface support.
    PLATFORM_CMAKE_ARGS=( -DDAWN_ENABLE_VULKAN=ON -DDAWN_USE_WAYLAND=ON -DDAWN_USE_X11=ON )
    ;;
  Darwin)
    PLATFORM="macos-${ARCH}"
    PLATFORM_DESC="macOS ${ARCH} (Metal)"
    NCPU="$(sysctl -n hw.ncpu)"
    # Metal is Dawn's default backend on macOS; no extra backend flags.
    # Pin the deployment target explicitly: Dawn's own default (12.0, in
    # DawnCompilerPlatformFlags.cmake) is set after project(), when the cache
    # entry already exists, so it is a no-op and clang falls back to the
    # *host* macOS version -- the binaries would then require the build
    # machine's OS. Override with MACOSX_DEPLOYMENT_TARGET.
    MACOS_MIN="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
    PLATFORM_DESC="macOS ${ARCH} (Metal, macOS ${MACOS_MIN}+)"
    PLATFORM_CMAKE_ARGS=( -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" )
    ;;
  *) echo "unsupported OS: $OS" >&2; exit 1 ;;
esac

# --- defaults -----------------------------------------------------------------
BUILD_TYPE="Release"
BUILD_DIR="out/wire-release"
JOBS="$NCPU"
WANT_NODE=0
WANT_PUBLISH=0
RELEASE_REPO="jhanssen/dawn"
TAG=""

# --- arg parsing --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --node) WANT_NODE=1; shift ;;
    --publish) WANT_PUBLISH=1; shift ;;
    --tag) TAG="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --build-dir) BUILD_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

log() { printf '\033[1;34m== %s\033[0m\n' "$*"; }
die() { printf '\033[1;31merror: %s\033[0m\n' "$*" >&2; exit 1; }

# --- derive names -------------------------------------------------------------
COMMIT="$(git rev-parse HEAD)"
SHORT="$(git rev-parse --short HEAD)"
DATE="$(date +%Y%m%d)"
[[ -n "$TAG" ]] || TAG="v${DATE}-linux-wayland-wire-alpha"

RELEASE_NAME="Dawn-${COMMIT}-${PLATFORM}-${BUILD_TYPE}"
STAGING="${BUILD_DIR}/${RELEASE_NAME}"
TARBALL="${BUILD_DIR}/${RELEASE_NAME}.tar.gz"

# --- preflight ----------------------------------------------------------------
log "Repo:    $REPO_ROOT"
log "Branch:  $(git rev-parse --abbrev-ref HEAD) @ $SHORT"
log "Platform: $PLATFORM_DESC"
log "Tag:     $TAG"
log "Tarball: $TARBALL"

command -v cmake >/dev/null  || die "cmake not found"
command -v ninja >/dev/null  || die "ninja not found"
command -v go    >/dev/null  || die "go not found (required by idlgen)"
[[ $WANT_NODE -eq 1 ]] && { command -v node >/dev/null || die "node not found (--node)"; }
[[ $WANT_PUBLISH -eq 1 ]] && { command -v gh >/dev/null || die "gh not found (--publish)"; }

# --- ensure dawn.node deps are at their DEPS-pinned commits -------------------
# fetch_dawn_dependencies.py does not manage the dawn_node-conditional deps
# (gpuweb, node-api-headers, node-addon-api). If they are missing, configure
# fails; if gpuweb is at the wrong revision, idlgen produces interop types that
# mismatch the binding code. So for --node, init/pin them here.
# Note: test for <dir>/.git rather than just running `git -C <dir> rev-parse`,
# because for an uninitialized (empty) submodule dir git walks up and silently
# reports the *Dawn* repo's HEAD.
ensure_dep_pinned() {  # <path relative to repo root>
  local dir="$1" pin cur
  pin="$(grep -A2 "'$dir'" DEPS | grep -o '@[a-f0-9]\{40\}' | head -1 | cut -c2-)"
  [[ -n "$pin" ]] || die "could not read $dir pin from DEPS"
  if [[ ! -e "$dir/.git" ]]; then
    log "Initializing $dir submodule"
    git submodule update --init --depth 1 "$dir" || die "failed to initialize $dir"
  fi
  cur="$(git -C "$dir" rev-parse HEAD)"
  if [[ "$cur" != "$pin" ]]; then
    log "Pinning $dir to $pin (was $cur)"
    git -C "$dir" fetch origin "$pin" --depth 1
    git -C "$dir" checkout "$pin"
  fi
  [[ "$(git -C "$dir" rev-parse HEAD)" == "$pin" ]] || die "$dir is not at the DEPS pin $pin"
}
if [[ $WANT_NODE -eq 1 ]]; then
  for dep in third_party/gpuweb third_party/node-api-headers third_party/node-addon-api; do
    ensure_dep_pinned "$dep"
  done
fi

# --- configure ----------------------------------------------------------------
log "Configuring ($BUILD_DIR)"
CMAKE_ARGS=(
  -S . -B "$BUILD_DIR" -GNinja
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE"
  ${PLATFORM_CMAKE_ARGS[@]+"${PLATFORM_CMAKE_ARGS[@]}"}
  -DDAWN_BUILD_MONOLITHIC_LIBRARY=STATIC
  -DBUILD_SHARED_LIBS=OFF
  -DDAWN_ENABLE_INSTALL=ON
  -DDAWN_ENABLE_PIC=ON
  # Keep the install limited to Dawn's libs: don't drag in tint cmd tools /
  # fuzzers / tint install (their install rules reference unbuilt binaries).
  -DTINT_BUILD_CMD_TOOLS=OFF
  -DTINT_ENABLE_INSTALL=OFF
  -DDAWN_BUILD_FUZZERS=OFF
  -DDAWN_BUILD_TESTS=OFF
  -DDAWN_BUILD_SAMPLES=OFF
  -DTINT_BUILD_TESTS=OFF
  -DCMAKE_INSTALL_PREFIX="$STAGING"
)
[[ $WANT_NODE -eq 1 ]] && CMAKE_ARGS+=( -DDAWN_BUILD_NODE_BINDINGS=ON )
cmake "${CMAKE_ARGS[@]}"

# --- build --------------------------------------------------------------------
log "Building libraries (jobs=$JOBS)"
# webgpu_upstream_cpp_headers_gen is only built by 'all', but install needs its headers.
ninja -C "$BUILD_DIR" -j "$JOBS" webgpu_dawn webgpu_dawn_wire webgpu_upstream_cpp_headers_gen
if [[ $WANT_NODE -eq 1 ]]; then
  log "Building dawn.node"
  ninja -C "$BUILD_DIR" -j "$JOBS" dawn_node
fi

# --- install ------------------------------------------------------------------
log "Installing to $STAGING"
rm -rf "$STAGING"
cmake --install "$BUILD_DIR"

if [[ $WANT_NODE -eq 1 ]]; then
  # dawn.node is not part of the install rules; copy it in alongside the libs.
  cp "$BUILD_DIR/dawn.node" "$STAGING/" 2>/dev/null || die "dawn.node not found in build dir"
fi

# --- sanity checks ------------------------------------------------------------
log "Verifying install"
[[ -f "$STAGING/lib/libwebgpu_dawn.a" ]]       || die "libwebgpu_dawn.a missing"
[[ -f "$STAGING/lib/libwebgpu_dawn_wire.a" ]]  || die "libwebgpu_dawn_wire.a missing"
[[ -f "$STAGING/include/dawn/wire/WireServer.h" ]] || die "wire headers missing"
[[ -f "$STAGING/lib/cmake/Dawn/DawnConfig.cmake" ]] || die "Dawn CMake export missing"
# wire client bundle must NOT contain native, monolith MUST contain wire server.
# Symbols are matched demangled (nm -C), which also drops the Mach-O leading
# underscore. nm output goes to a file first so an nm failure is fatal rather
# than silently passing, and so `grep -q` exiting early can't SIGPIPE nm and
# trip pipefail.
NATIVE_SYM='dawn::native::GetProcs()'
nm_syms() {  # <archive> <outfile>
  nm -C "$1" > "$2" 2>/dev/null || die "nm failed on $1"
}
nm_syms "$STAGING/lib/libwebgpu_dawn_wire.a" "$BUILD_DIR/nm-wire.txt"
nm_syms "$STAGING/lib/libwebgpu_dawn.a"      "$BUILD_DIR/nm-monolith.txt"
if grep -qF "$NATIVE_SYM" "$BUILD_DIR/nm-wire.txt"; then
  die "libwebgpu_dawn_wire.a unexpectedly contains native Dawn ($NATIVE_SYM)"
fi
# Positive control: the same pattern must match the native monolith, otherwise
# the check above is not actually testing anything.
grep -qF "$NATIVE_SYM" "$BUILD_DIR/nm-monolith.txt" \
  || die "native-Dawn check is broken: $NATIVE_SYM not found in libwebgpu_dawn.a"
grep -qF 'dawn::wire::WireServer' "$BUILD_DIR/nm-monolith.txt" \
  || die "libwebgpu_dawn.a missing wire server symbols"
# macOS: every object must carry the requested minimum OS, not the host's.
if [[ "$OS" == Darwin ]]; then
  bins=( "$STAGING"/lib/*.a )
  [[ $WANT_NODE -eq 1 ]] && bins+=( "$STAGING/dawn.node" )
  for bin in "${bins[@]}"; do
    mins="$(otool -l "$bin" | awk '/LC_BUILD_VERSION/{f=1} f&&$1=="minos"{print $2; f=0}' | sort -u)"
    [[ -n "$mins" ]] || die "$(basename "$bin"): no LC_BUILD_VERSION minos found"
    [[ "$mins" == "$MACOS_MIN" ]] \
      || die "$(basename "$bin") has minos $(echo $mins) (expected $MACOS_MIN)"
  done
fi

# --- tarball ------------------------------------------------------------------
log "Creating tarball"
( cd "$BUILD_DIR" && tar czf "${RELEASE_NAME}.tar.gz" "$RELEASE_NAME" )
ls -lh "$TARBALL"

# --- publish ------------------------------------------------------------------
if [[ $WANT_PUBLISH -eq 1 ]]; then
  log "Publishing $TARBALL to release $TAG on $RELEASE_REPO"
  TITLE="Dawn ${PLATFORM_DESC} — wire client/server bundle"
  NOTES="$(cat <<EOF
Wire-enabled Dawn build from \`$(git rev-parse --abbrev-ref HEAD)\` @ ${SHORT}.

Contains, in addition to the standard native monolith:
- \`libwebgpu_dawn.a\` — native Dawn + Dawn wire **server** (GPU process side)
- \`libwebgpu_dawn_wire.a\` — Dawn wire **client** + proc table, no native (core side)
- \`dawn/wire/*\` headers and a relocatable \`lib/cmake/Dawn\` export

Consume via \`find_package(Dawn)\`; link \`dawn::webgpu_dawn\` (GPU process) or
\`dawn::webgpu_dawn_wire\` (wire client). Wire client consumers must build with
\`-fno-rtti\` to match Dawn (only vtables, not typeinfo, are emitted for the
wire transport classes).
EOF
)"
  if gh release view "$TAG" --repo "$RELEASE_REPO" >/dev/null 2>&1; then
    # Release already exists (e.g. created by the build on another platform):
    # just attach this platform's tarball, leaving title/notes untouched.
    gh release upload "$TAG" "$TARBALL" --repo "$RELEASE_REPO"
  else
    gh release create "$TAG" "$TARBALL" \
      --repo "$RELEASE_REPO" \
      --title "$TITLE" \
      --notes "$NOTES"
  fi
  log "Published: https://github.com/${RELEASE_REPO}/releases/tag/${TAG}"
else
  log "Built tarball only. To publish:"
  echo "  gh release upload $TAG \"$TARBALL\" --repo $RELEASE_REPO   # existing release"
  echo "  gh release create $TAG \"$TARBALL\" --repo $RELEASE_REPO --title '...' --notes '...'   # new release"
  echo "  (or re-run with --publish)"
fi

log "Done."
