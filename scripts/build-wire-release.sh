#!/usr/bin/env bash
#
# build-wire-release.sh
#
# Build a wire-enabled Dawn binary release tarball for Linux/Wayland and
# (optionally) publish it to github.com/jhanssen/dawn via `gh release`.
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
#   --publish          create a GitHub release on jhanssen/dawn and upload
#   --tag <tag>        release tag (default: v<YYYYMMDD>-linux-wayland-wire-alpha)
#   --jobs <N>         ninja parallelism (default: nproc)
#   --build-dir <dir>  build directory (default: out/wire-release)
#   -h, --help         show this help

set -euo pipefail

# --- locate repo root ---------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# --- defaults -----------------------------------------------------------------
PLATFORM="linux-x86_64-wayland"
BUILD_TYPE="Release"
BUILD_DIR="out/wire-release"
JOBS="$(nproc)"
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
log "Tag:     $TAG"
log "Tarball: $TARBALL"

command -v cmake >/dev/null  || die "cmake not found"
command -v ninja >/dev/null  || die "ninja not found"
command -v go    >/dev/null  || die "go not found (required by idlgen)"
[[ $WANT_NODE -eq 1 ]] && { command -v node >/dev/null || die "node not found (--node)"; }
[[ $WANT_PUBLISH -eq 1 ]] && { command -v gh >/dev/null || die "gh not found (--publish)"; }

# --- ensure gpuweb is at the DEPS-pinned commit -------------------------------
# fetch_dawn_dependencies.py does not manage third_party/gpuweb. If it is at the
# wrong revision, idlgen produces interop types that mismatch the binding code.
GPUWEB_PIN="$(grep -A2 "'third_party/gpuweb'" DEPS | grep -o 'gpuweb@[a-f0-9]*' | cut -d@ -f2)"
[[ -n "$GPUWEB_PIN" ]] || die "could not read gpuweb pin from DEPS"
if CUR_GPUWEB="$(git -C third_party/gpuweb rev-parse HEAD 2>/dev/null)"; then
  if [[ "$CUR_GPUWEB" != "$GPUWEB_PIN" ]]; then
    log "Pinning gpuweb to $GPUWEB_PIN (was $CUR_GPUWEB)"
    git -C third_party/gpuweb fetch origin "$GPUWEB_PIN" --depth 1
    git -C third_party/gpuweb checkout "$GPUWEB_PIN"
  fi
else
  die "third_party/gpuweb not present; run: python3 tools/fetch_dawn_dependencies.py"
fi

# --- configure ----------------------------------------------------------------
log "Configuring ($BUILD_DIR)"
CMAKE_ARGS=(
  -S . -B "$BUILD_DIR" -GNinja
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE"
  -DDAWN_ENABLE_VULKAN=ON
  -DDAWN_USE_WAYLAND=ON
  -DDAWN_USE_X11=ON
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
ninja -C "$BUILD_DIR" -j "$JOBS" webgpu_dawn webgpu_dawn_wire
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
# wire client bundle must NOT contain native, monolith MUST contain wire server
if nm "$STAGING/lib/libwebgpu_dawn_wire.a" 2>/dev/null | grep -q 'dawn..native..GetProcs'; then
  die "libwebgpu_dawn_wire.a unexpectedly contains native Dawn"
fi
nm "$STAGING/lib/libwebgpu_dawn.a" 2>/dev/null | grep -q 'WireServer' \
  || die "libwebgpu_dawn.a missing wire server symbols"

# --- tarball ------------------------------------------------------------------
log "Creating tarball"
( cd "$BUILD_DIR" && tar czf "${RELEASE_NAME}.tar.gz" "$RELEASE_NAME" )
ls -lh "$TARBALL"

# --- publish ------------------------------------------------------------------
if [[ $WANT_PUBLISH -eq 1 ]]; then
  log "Publishing release $TAG to $RELEASE_REPO"
  TITLE="Dawn Linux x86_64 Wayland (GCC 15) — wire client/server bundle"
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
  gh release create "$TAG" "$TARBALL" \
    --repo "$RELEASE_REPO" \
    --title "$TITLE" \
    --notes "$NOTES"
  log "Published: https://github.com/${RELEASE_REPO}/releases/tag/${TAG}"
else
  log "Built tarball only. To publish:"
  echo "  gh release create $TAG \"$TARBALL\" --repo $RELEASE_REPO --title '...' --notes '...'"
  echo "  (or re-run with --publish)"
fi

log "Done."
