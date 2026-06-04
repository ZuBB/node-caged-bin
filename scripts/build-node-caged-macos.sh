#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/build-node-caged}"
RECIPE_REPO="${RECIPE_REPO:-https://github.com/platformatic/node-caged.git}"
NODE_REPO="${NODE_REPO:-https://github.com/nodejs/node.git}"
NODE_TAG="${NODE_TAG:-}"
JOBS="${JOBS:-}"

RECIPE_DIR="$ROOT_DIR/recipe"
NODE_SRC_DIR="$ROOT_DIR/node-src"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
LOGS_DIR="$ROOT_DIR/logs"
SNAPSHOT_DIR="$ROOT_DIR/deps-snapshot"
MANIFEST="$LOGS_DIR/build-manifest.txt"
CONFIGURE_FLAGS="--experimental-enable-pointer-compression"

mkdir -p "$RECIPE_DIR" "$NODE_SRC_DIR" "$ARTIFACTS_DIR" "$LOGS_DIR" "$SNAPSHOT_DIR"

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

detect_jobs() {
  if [ -n "$JOBS" ]; then
    printf '%s\n' "$JOBS"
    return
  fi

  if jobs_count="$(sysctl -n hw.ncpu 2>/dev/null)" && [ -n "$jobs_count" ]; then
    printf '%s\n' "$jobs_count"
    return
  fi

  if jobs_count="$(getconf _NPROCESSORS_ONLN 2>/dev/null)" && [ -n "$jobs_count" ]; then
    printf '%s\n' "$jobs_count"
    return
  fi

  printf '4\n'
}

snapshot_host() {
  local phase="$1"
  log "Capturing host dependency snapshot: $phase"

  {
    printf 'date_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'uname=%s\n' "$(uname -a)"
    printf 'arch=%s\n' "$(uname -m)"
    printf 'xcode_select=%s\n' "$(xcode-select -p 2>/dev/null || true)"
    printf 'sdk_path=%s\n' "$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
    printf '\nclang:\n'
    clang --version 2>/dev/null || true
    printf '\npython3:\n'
    python3 --version 2>/dev/null || true
    printf '\nmake:\n'
    make --version 2>/dev/null | head -n 1 || true
    printf '\ngit:\n'
    git --version 2>/dev/null || true
  } > "$SNAPSHOT_DIR/host-$phase.txt"

  if command -v brew >/dev/null 2>&1; then
    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_FROM_API=1 \
      brew list --formula --versions > "$SNAPSHOT_DIR/brew-formulae-$phase.txt" \
      2> "$SNAPSHOT_DIR/brew-formulae-$phase.err" || true
    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_FROM_API=1 \
      brew leaves --installed-on-request > "$SNAPSHOT_DIR/brew-leaves-$phase.txt" \
      2> "$SNAPSHOT_DIR/brew-leaves-$phase.err" || true
  fi

  pkgutil --pkgs > "$SNAPSHOT_DIR/pkgutil-$phase.txt" 2>/dev/null || true
}

resolve_latest_v26() {
  log "Resolving latest Node.js v26 tag"
  git ls-remote --tags "$NODE_REPO" 'refs/tags/v26.*' |
    awk -F/ '/refs\/tags\/v26\.[0-9]+\.[0-9]+(\^\{\})?$/ { print $NF }' |
    sed 's/\^{}$//' |
    sort -u |
    python3 -c 'import sys
tags = [line.strip() for line in sys.stdin if line.strip()]
if not tags:
    raise SystemExit("No v26 tags found")
def parts(tag):
    return tuple(int(part) for part in tag[1:].split("."))
print(max(tags, key=parts))'
}

clone_or_update() {
  local repo="$1"
  local dir="$2"
  local ref="$3"

  if [ -d "$dir/.git" ]; then
    log "Fetching $repo in $dir"
    git -C "$dir" fetch --tags --prune
  else
    rm -rf "$dir"
    log "Cloning $repo into $dir"
    git clone "$repo" "$dir"
  fi

  git -C "$dir" checkout "$ref"
}

preflight() {
  log "Running preflight"
  need awk
  need clang
  need clang++
  need date
  need file
  need git
  need make
  need python3
  need sed
  need shasum
  need tar

  if [ "$(uname -s)" != "Darwin" ]; then
    printf 'This script builds a native macOS archive and must run on Darwin.\n' >&2
    exit 1
  fi

  if [ "$(uname -m)" != "arm64" ]; then
    printf 'This script targets darwin-arm64; current arch is %s.\n' "$(uname -m)" >&2
    exit 1
  fi

  if ! xcode-select -p >/dev/null 2>&1; then
    printf 'Xcode Command Line Tools are required.\n' >&2
    exit 1
  fi
}

write_manifest_header() {
  {
    printf 'build_date_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'root_dir=%s\n' "$ROOT_DIR"
    printf 'recipe_repo=%s\n' "$RECIPE_REPO"
    printf 'recipe_commit=%s\n' "$(git -C "$RECIPE_DIR" rev-parse HEAD)"
    printf 'node_repo=%s\n' "$NODE_REPO"
    printf 'node_tag=%s\n' "$NODE_TAG"
    printf 'node_commit=%s\n' "$(git -C "$NODE_SRC_DIR" rev-parse HEAD)"
    printf 'configure_flags=%s\n' "$CONFIGURE_FLAGS"
    printf 'jobs=%s\n' "$JOBS"
  } > "$MANIFEST"
}

build_node() {
  log "Creating upstream-style binary package with pointer compression"
  (
    cd "$NODE_SRC_DIR"
    make -j"$JOBS" binary CONFIG_FLAGS="$CONFIGURE_FLAGS" XZ=0
  ) | tee "$LOGS_DIR/make-binary.log"
}

collect_artifact() {
  local tarball
  tarball="$(find "$NODE_SRC_DIR" -maxdepth 1 -name 'node-v*-darwin-arm64.tar.gz' -print -quit)"
  if [ -z "$tarball" ]; then
    printf 'Could not find generated darwin-arm64 tarball in %s\n' "$NODE_SRC_DIR" >&2
    exit 1
  fi

  rm -f "$ARTIFACTS_DIR"/node-v*-darwin-arm64.tar.gz \
    "$ARTIFACTS_DIR"/node-v*-darwin-arm64.tar.gz.sha256
  cp "$tarball" "$ARTIFACTS_DIR/"
  (
    cd "$ARTIFACTS_DIR"
    shasum -a 256 "$(basename "$tarball")" > "$(basename "$tarball").sha256"
  )

  printf 'artifact=%s\n' "$ARTIFACTS_DIR/$(basename "$tarball")" >> "$MANIFEST"
  printf 'sha256=%s\n' "$(awk '{ print $1 }' "$ARTIFACTS_DIR/$(basename "$tarball").sha256")" >> "$MANIFEST"
}

validate_artifact() {
  local heap_limit pointer_config tarball unpack_dir node_bin
  tarball="$(find "$ARTIFACTS_DIR" -maxdepth 1 -name 'node-v*-darwin-arm64.tar.gz' -print -quit)"
  unpack_dir="$ARTIFACTS_DIR/validation"
  rm -rf "$unpack_dir"
  mkdir -p "$unpack_dir"

  log "Validating artifact"
  tar -xzf "$tarball" -C "$unpack_dir"
  node_bin="$(find "$unpack_dir" -path '*/bin/node' -print -quit)"

  file "$node_bin" | tee "$LOGS_DIR/validation-file.log"
  "$node_bin" -v | tee "$LOGS_DIR/validation-node-version.log"
  "$node_bin" -p "process.platform + '-' + process.arch" | tee "$LOGS_DIR/validation-platform.log"
  "$node_bin" -e "console.log('ok')" | tee "$LOGS_DIR/validation-smoke.log"
  "$node_bin" "$RECIPE_DIR/tests/verify-pointer-compression.js" | tee "$LOGS_DIR/validation-pointer-compression.log"

  pointer_config="$("$node_bin" -p "[
    process.config.variables.v8_enable_pointer_compression,
    process.config.variables.v8_enable_31bit_smis_on_64bit_arch,
    process.config.variables.v8_enable_external_code_space
  ].join(',')")"
  printf '%s\n' "$pointer_config" | tee "$LOGS_DIR/validation-pointer-config.log"

  if [ "$pointer_config" != "1,1,1" ]; then
    printf 'Pointer compression config is not enabled: %s\n' "$pointer_config" >&2
    exit 1
  fi

  heap_limit="$("$node_bin" -p "require('v8').getHeapStatistics().heap_size_limit")"
  printf '%s\n' "$heap_limit" | tee "$LOGS_DIR/validation-heap-limit.log"
  if [ "$heap_limit" -ge 5368709120 ]; then
    printf 'Heap limit is too high for a pointer-compressed build: %s\n' "$heap_limit" >&2
    exit 1
  fi

  if [ "$("$node_bin" -p "process.platform + '-' + process.arch")" != "darwin-arm64" ]; then
    printf 'Built node is not darwin-arm64.\n' >&2
    exit 1
  fi

  if [ "$("$node_bin" -v)" != "$NODE_TAG" ]; then
    printf 'Built node version does not match %s.\n' "$NODE_TAG" >&2
    exit 1
  fi
}

main() {
  preflight
  JOBS="$(detect_jobs)"
  snapshot_host before

  clone_or_update "$RECIPE_REPO" "$RECIPE_DIR" main

  if [ -z "$NODE_TAG" ]; then
    NODE_TAG="$(resolve_latest_v26)"
  fi
  log "Using Node.js $NODE_TAG"

  clone_or_update "$NODE_REPO" "$NODE_SRC_DIR" "$NODE_TAG"
  write_manifest_header
  build_node
  collect_artifact
  validate_artifact
  snapshot_host after

  log "Done. Artifacts are in $ARTIFACTS_DIR"
}

main "$@"
