#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"

die() { echo "error: $*" >&2; exit 1; }

if [ -n "${MODS_FILE:-}" ] && [ ! -f "$MODS_FILE" ]; then
  die "MODS_FILE not found: $MODS_FILE"
fi
mods_file="${MODS_FILE:-$BUILD_DIR/mods.local.yaml}"
file_flavor=""
extra_mods=""
if [ -f "$mods_file" ]; then
  file_flavor="$(sed -n 's/^flavor:[[:space:]]*\([^#[:space:]]*\).*/\1/p' "$mods_file" | head -1)"
  extra_mods="$(sed -n 's/^[[:space:]]*-[[:space:]]*\(https:[^#[:space:]]*\).*/\1/p' "$mods_file")"
fi
FLAVOR="${FLAVOR:-${file_flavor:-vanilla}}"

# Sourcing sources.env overwrites these, so keep the overrides first.
env_ale="${MOD_ALE_REF:-}"
env_bots="${MOD_PLAYERBOTS_REF:-}"
# shellcheck disable=SC1091
. "$BUILD_DIR/sources.env"
MOD_ALE_REF="${env_ale:-$MOD_ALE_REF}"
MOD_PLAYERBOTS_REF="${env_bots:-$MOD_PLAYERBOTS_REF}"

module_name() { basename "${1%@*}" .git; }

case "$FLAVOR" in
  vanilla)
    CORE_REPO="https://github.com/azerothcore/azerothcore-wotlk.git"
    CORE_REF="${CORE_REF:-$VANILLA_CORE_REF}"
    # The images of AzerothCore carry mod-ale, so the vanilla flavor does too.
    base_mods="https://github.com/azerothcore/mod-ale.git@$MOD_ALE_REF"
    ;;
  playerbots)
    CORE_REPO="https://github.com/mod-playerbots/azerothcore-wotlk.git"
    CORE_REF="${CORE_REF:-$PLAYERBOTS_CORE_REF}"
    base_mods="https://github.com/mod-playerbots/mod-playerbots.git@$MOD_PLAYERBOTS_REF"
    ;;
  *) die "FLAVOR must be vanilla or playerbots" ;;
esac
for m in $extra_mods; do
  case "$(module_name "$m")" in
    mod-playerbots)
      die "mod-playerbots needs the core fork, so it comes with the playerbots flavor only. MOD_PLAYERBOTS_REF selects its revision." ;;
    mod-ale)
      if [ "$FLAVOR" = vanilla ]; then die "the vanilla flavor has mod-ale already. MOD_ALE_REF selects its revision."; fi ;;
  esac
done

IMAGE_PREFIX="azerothcore-$FLAVOR"
CTX="$BUILD_DIR/.build/$FLAVOR"

SHA_LENGTH=40
SHORT_SHA_LENGTH=7

# The image tag and labels record commits, not branch names.
resolve() {
  local repo="$1" ref="$2" sha
  case "$ref" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
      if [ "${#ref}" = "$SHA_LENGTH" ]; then echo "$ref"; return; fi ;;
  esac
  sha="$(git ls-remote "$repo" "$ref" "refs/tags/$ref^{}" | awk 'NR==1 {print $1}')"
  [ -n "$sha" ] || die "cannot resolve $ref in $repo"
  echo "$sha"
}
CORE_REF="$(resolve "$CORE_REPO" "$CORE_REF")"

REGISTRY="${REGISTRY:-local}"
TAG="${TAG:-$(date -u +%Y%m%d)-$(printf '%s' "$CORE_REF" | cut -c1-"$SHORT_SHA_LENGTH")}"
PUSH="${PUSH:-0}"
CACHE_REF="${CACHE_REF:-}"

case "$(uname -m)" in
  arm64|aarch64) HOST_PLATFORM=linux/arm64 ;;
  *)             HOST_PLATFORM=linux/amd64 ;;
esac
PLATFORMS="${PLATFORMS:-$HOST_PLATFORM}"

MULTI_ARCH=0
case "$PLATFORMS" in *,*) MULTI_ARCH=1 ;; esac
if [ "$MULTI_ARCH" = "1" ] && [ "$PUSH" != "1" ]; then
  die "multi-platform builds require PUSH=1 (docker cannot --load multi-arch images)"
fi

# The default docker driver cannot build multi-platform images or export a cache.
BUILDER_ARGS=""
if [ "$MULTI_ARCH" = "1" ] || [ -n "$CACHE_REF" ]; then
  docker buildx inspect azerothcore >/dev/null 2>&1 || docker buildx create --name azerothcore --driver docker-container
  BUILDER_ARGS="--builder azerothcore"
fi

OUTPUT="--load"
[ "$PUSH" = "1" ] && OUTPUT="--push"

origin_url() {
  local url
  url="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null)" || return 0
  url="${url%.git}"
  case "$url" in
    git@*) url="${url#git@}"; url="https://${url/://}" ;;
  esac
  printf '%s\n' "$url"
}
# GHCR links a package to the repository in org.opencontainers.image.source.
IMAGE_SOURCE="${IMAGE_SOURCE:-$(origin_url)}"
IMAGE_REVISION="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"

echo "==> flavor      $FLAVOR"
echo "==> core        $CORE_REPO @ $CORE_REF"

if [ "$(git -C "$CTX" remote get-url origin 2>/dev/null)" != "$CORE_REPO" ]; then
  rm -rf "$CTX"
  git init -q "$CTX"
  git -C "$CTX" remote add origin "$CORE_REPO"
fi
if [ "$(git -C "$CTX" rev-parse -q --verify HEAD 2>/dev/null)" != "$CORE_REF" ]; then
  git -C "$CTX" fetch -q --depth 1 origin "$CORE_REF"
  git -C "$CTX" checkout -q --force --detach FETCH_HEAD
fi
# An earlier run deleted the index (see below), and the reset rebuilds it.
git -C "$CTX" reset -q --hard
# CMake compiles every folder in modules/, so drop the modules of earlier builds.
git -C "$CTX" clean -q -ffdx

# The runtime stage installs libncurses5-dev, which pulls in the kernel headers
# and thousands of scanner findings with them. The servers need only the
# libncurses.so.6 and libtinfo.so.6 libraries. The build stage keeps the headers.
dockerfile="$CTX/apps/docker/Dockerfile"
sed 's/ libicu74 libncurses5-dev / libicu74 libncurses6 /' "$dockerfile" > "$dockerfile.patched"
mv "$dockerfile.patched" "$dockerfile"
grep -q ' libicu74 libncurses6 ' "$dockerfile" \
  || die "the runtime packages of apps/docker/Dockerfile changed, update the libncurses5-dev patch"

# The compile step bind-mounts .git, so the content of .git is part of its cache
# key. A fetch writes a pack, an index and reflogs that differ between two runs.
# Loose objects depend only on the commit.
for pack in "$CTX"/.git/objects/pack/*.pack; do
  [ -e "$pack" ] || continue
  mv "$pack" "$CTX/.git/unpack.tmp"
  rm -f "${pack%.pack}".*
  git -C "$CTX" unpack-objects -q < "$CTX/.git/unpack.tmp"
  rm "$CTX/.git/unpack.tmp"
done
rm -rf "$CTX/.git/index" "$CTX/.git/logs" "$CTX/.git/FETCH_HEAD" "$CTX/.git/ORIG_HEAD" \
  "$CTX/.git/objects/info/packs"

module_revisions=""
for m in $base_mods $extra_mods; do
  url="${m%@*}"
  ref="${m##*@}"
  [ "$ref" = "$m" ] && ref=HEAD
  name="$(module_name "$m")"
  sha="$(resolve "$url" "$ref")"
  echo "==> module      $url @ $sha"
  git init -q "$CTX/modules/$name"
  git -C "$CTX/modules/$name" fetch -q --depth 1 "$url" "$sha"
  git -C "$CTX/modules/$name" checkout -q --detach FETCH_HEAD
  # The db-import image copies modules/ as it is.
  rm -rf "$CTX/modules/$name/.git"
  module_revisions="${module_revisions:+$module_revisions }$name@$sha"
done

echo "==> images      $REGISTRY/$IMAGE_PREFIX-{worldserver,authserver,db-import,client-data}:$TAG"
echo "==> platforms   $PLATFORMS (push=$PUSH)"

description() {
  case "$1" in
    worldserver) echo "AzerothCore worldserver for World of Warcraft 3.3.5a, $FLAVOR flavor" ;;
    authserver)  echo "AzerothCore authserver for World of Warcraft 3.3.5a, $FLAVOR flavor" ;;
    db-import)   echo "AzerothCore database importer for World of Warcraft 3.3.5a, $FLAVOR flavor" ;;
    client-data) echo "AzerothCore client data downloader for World of Warcraft 3.3.5a" ;;
  esac
}

CREATED="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
for target in worldserver authserver db-import client-data; do
  cache_args=""
  if [ -n "$CACHE_REF" ]; then
    cache_args="--cache-from type=registry,ref=$CACHE_REF-$target"
    cache_args="$cache_args --cache-to type=registry,ref=$CACHE_REF-$target,mode=max,image-manifest=true,oci-mediatypes=true,ignore-error=true"
  fi
  labels=(
    --label "org.opencontainers.image.created=$CREATED"
    --label "org.opencontainers.image.version=$TAG"
    --label "org.opencontainers.image.title=$IMAGE_PREFIX-$target"
    --label "org.opencontainers.image.description=$(description "$target")"
    --label "org.azerothcore.flavor=$FLAVOR"
    --label "org.azerothcore.core.revision=$CORE_REF"
    --label "org.azerothcore.modules=$module_revisions"
  )
  [ -n "$IMAGE_SOURCE" ] && labels+=(--label "org.opencontainers.image.source=$IMAGE_SOURCE")
  [ -n "$IMAGE_REVISION" ] && labels+=(--label "org.opencontainers.image.revision=$IMAGE_REVISION")
  echo "==> building $target"
  # CTOOLS_BUILD: the chart downloads extracted client data, so dbimport is
  # the only tool that the images need.
  # shellcheck disable=SC2086
  docker buildx build $BUILDER_ARGS $cache_args "$CTX" \
    --file "$CTX/apps/docker/Dockerfile" \
    --target "$target" \
    --platform "$PLATFORMS" \
    --build-arg "CTOOLS_BUILD=db-only" \
    "${labels[@]}" \
    --tag "$REGISTRY/$IMAGE_PREFIX-$target:$TAG" \
    $OUTPUT
done

registry_host="${REGISTRY%%/*}"
repo_prefix="${REGISTRY#*/}"
[ "$repo_prefix" = "$REGISTRY" ] && repo_prefix=""

GENERATED="$BUILD_DIR/images.generated.yaml"
{
  echo "# Generated by build-images.sh on $CREATED"
  echo "# core $CORE_REF, modules: $module_revisions"
  echo "flavor: $FLAVOR"
  echo "images:"
  echo "  $FLAVOR:"
  for pair in worldserver:worldserver authserver:authserver dbImport:db-import clientData:client-data; do
    printf '    %s:\n      registry: %s\n      repository: %s%s%s\n      tag: "%s"\n      digest: ""\n' \
      "${pair%%:*}" "$registry_host" "$repo_prefix" "${repo_prefix:+/}" "$IMAGE_PREFIX-${pair#*:}" "$TAG"
  done
} > "$GENERATED"

echo "==> wrote $GENERATED"
cat "$GENERATED"
