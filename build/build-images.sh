#!/usr/bin/env bash
#
# Build AzerothCore server images with a selectable base flavor and modules.
#
# Reads build/mods.yaml (see that file for syntax). Environment overrides:
#   MODS_FILE   path to the mods file                  (default: build/mods.yaml)
#   FLAVOR      vanilla|playerbots                     (overrides mods file)
#   REGISTRY    image namespace                        (default: local)
#   TAG         image tag                              (default: $FLAVOR)
#   PLATFORMS   buildx platforms                       (default: host arch)
#   PUSH        1 = push to REGISTRY                   (default: load into docker)
#   BUILD_DIR   scratch dir for the build              (default: build/.build)
#
# Layer and compiler caches live in dockerd's buildkit, so re-running this
# script after changing the mod list only recompiles what changed (plus a
# worldserver relink) instead of the whole core.
#
# Writes build/images.generated.yaml — pass it to helm with -f.
#
# Works with the stock macOS bash 3.2; requires git + docker buildx.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODS_FILE="${MODS_FILE:-$REPO_ROOT/build/mods.yaml}"
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/build/.build}"
REGISTRY="${REGISTRY:-local}"
PUSH="${PUSH:-0}"

VANILLA_REPO="https://github.com/azerothcore/azerothcore-wotlk.git"
VANILLA_BRANCH="master"
PLAYERBOTS_REPO="https://github.com/mod-playerbots/azerothcore-wotlk.git"
PLAYERBOTS_BRANCH="Playerbot"
PLAYERBOTS_MOD="https://github.com/mod-playerbots/mod-playerbots.git"
# NOTE: mod-eluna is intentionally absent: modern AzerothCore ships the Lua
# engine (ALE) in the core. Enable it at runtime with ALE.Enabled = 1.

die() { echo "error: $*" >&2; exit 1; }

# ------------------------------------------------------------------ mods file
[ -f "$MODS_FILE" ] || die "mods file not found: $MODS_FILE"

FILE_FLAVOR="$(sed -n 's/^flavor:[[:space:]]*\([^#[:space:]]*\).*/\1/p' "$MODS_FILE" | head -1)"
FLAVOR="${FLAVOR:-${FILE_FLAVOR:-vanilla}}"
TAG="${TAG:-$FLAVOR}"

# "- url[@ref]" lines, one per line (comments never match: they lack "http")
MODS="$(sed -n 's/^[[:space:]]*-[[:space:]]*\(http[^#[:space:]]*\).*/\1/p' "$MODS_FILE")"

has_mod() { printf '%s\n' $MODS | grep -q "$1"; }

case "$FLAVOR" in
  vanilla)
    BASE_REPO="$VANILLA_REPO"; BASE_BRANCH="$VANILLA_BRANCH"
    if has_mod "mod-playerbots"; then
      die "mod-playerbots needs the forked core: use flavor: playerbots, not vanilla"
    fi
    ;;
  playerbots)
    BASE_REPO="$PLAYERBOTS_REPO"; BASE_BRANCH="$PLAYERBOTS_BRANCH"
    has_mod "mod-playerbots.git" || MODS="$PLAYERBOTS_MOD${MODS:+ $MODS}"
    ;;
  *) die "unknown flavor: $FLAVOR (want vanilla|playerbots)" ;;
esac

case "$(uname -m)" in
  arm64|aarch64) HOST_PLATFORM=linux/arm64 ;;
  *)             HOST_PLATFORM=linux/amd64 ;;
esac
PLATFORMS="${PLATFORMS:-$HOST_PLATFORM}"

MULTI_ARCH=0
case "$PLATFORMS" in
  *,*) MULTI_ARCH=1 ;;
esac
if [ "$MULTI_ARCH" = "1" ] && [ "$PUSH" != "1" ]; then
  die "multi-platform builds require PUSH=1 (docker cannot --load multi-arch images)"
fi

# The default docker driver cannot do multi-platform; use a container driver.
BUILDER_ARGS=""
if [ "$MULTI_ARCH" = "1" ]; then
  docker buildx inspect acbuild >/dev/null 2>&1 || docker buildx create --name acbuild --driver docker-container
  BUILDER_ARGS="--builder acbuild"
fi

echo "==> flavor    $FLAVOR"
echo "==> base      $BASE_REPO @ $BASE_BRANCH"
if [ -n "$MODS" ]; then printf '%s\n' $MODS | sed 's/^/==> mod       /'; else echo "==> mods      (none)"; fi
echo "==> images    $REGISTRY/ac-wotlk-{worldserver,authserver,db-import}:$TAG"
echo "==> platforms $PLATFORMS (push=$PUSH)"

# ------------------------------------------------------------------ sources
CTX="$BUILD_DIR/context"
mkdir -p "$BUILD_DIR"
if [ -d "$CTX/.git" ] && git -C "$CTX" remote get-url origin 2>/dev/null | grep -q "${BASE_REPO#https://github.com/}"; then
  echo "==> updating base source"
  git -C "$CTX" fetch --depth 1 origin "$BASE_BRANCH"
  git -C "$CTX" reset --hard FETCH_HEAD
else
  echo "==> cloning base source"
  rm -rf "$CTX"
  git clone --depth 1 --branch "$BASE_BRANCH" "$BASE_REPO" "$CTX"
fi

mkdir -p "$CTX/modules"
for m in $MODS; do
  url="${m%@*}"
  ref=""
  case "$m" in *@*) ref="${m##*@}" ;; esac
  name="$(basename "$url" .git)"
  dest="$CTX/modules/$name"
  if [ -d "$dest/.git" ]; then
    echo "==> updating module $name"
    if [ -n "$ref" ]; then
      git -C "$dest" fetch --depth 1 origin "$ref"
      git -C "$dest" reset --hard FETCH_HEAD
    else
      git -C "$dest" pull --ff-only
    fi
  else
    echo "==> cloning module $name${ref:+ @ $ref}"
    if [ -n "$ref" ]; then
      git clone --depth 1 --branch "$ref" "$url" "$dest"
    else
      git clone --depth 1 "$url" "$dest"
    fi
  fi
done

# Prune modules that are no longer listed. git reset --hard keeps untracked
# directories, and CMake compiles every module that it finds here.
for dir in "$CTX"/modules/*/; do
  [ -d "$dir" ] || continue
  base="$(basename "$dir")"
  keep=0
  for m in $MODS; do
    url="${m%@*}"
    if [ "$(basename "$url" .git)" = "$base" ]; then keep=1; break; fi
  done
  if [ "$keep" = "0" ]; then
    echo "==> pruning stale module $base"
    rm -rf "$dir"
  fi
done

# ------------------------------------------------------------------ build
OUTPUT="--load"
[ "$PUSH" = "1" ] && OUTPUT="--push"

for target in db-import authserver worldserver; do
  echo "==> building $target"
  # shellcheck disable=SC2086
  docker buildx build $BUILDER_ARGS "$CTX" \
    --file "$CTX/apps/docker/Dockerfile" \
    --target "$target" \
    --platform "$PLATFORMS" \
    --build-arg "CACHEBUST=$(git -C "$CTX" rev-parse HEAD)" \
    --tag "$REGISTRY/ac-wotlk-$target:$TAG" \
    "$OUTPUT"
done

# ------------------------------------------------------------------ values file
registry_host="${REGISTRY%%/*}"
repo_prefix="${REGISTRY#*/}"
[ "$repo_prefix" = "$REGISTRY" ] && repo_prefix=""

GENERATED="$REPO_ROOT/build/images.generated.yaml"
{
  echo "# Generated by build-images.sh on $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "# Deploy with: helm install ac charts/azerothcore -f build/images.generated.yaml -f your-values.yaml"
  echo "images:"
  for pair in "worldserver ac-wotlk-worldserver" "authserver ac-wotlk-authserver" "dbImport ac-wotlk-db-import"; do
    set -- $pair
    printf '  %s:\n    registry: %s\n    repository: %s%s%s\n    tag: %s\n    digest: ""\n' \
      "$1" "$registry_host" "$repo_prefix" "${repo_prefix:+/}" "$2" "$TAG"
  done
} > "$GENERATED"

# client-data has no modded code; the chart keeps using the pinned upstream image.
echo "==> wrote $GENERATED"
cat "$GENERATED"
