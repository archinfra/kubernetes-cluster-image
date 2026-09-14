#!/usr/bin/env bash
set -euo pipefail

APP="${1:?usage: publish-app-manifest.sh <helm|cilium>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RELEASE_FILE="${RELEASE_FILE:-$ROOT/archinfra/releases/k8s-v1.36.4-r2.env}"
OUT_DIR="${OUT_DIR:-$ROOT/out}"

[[ -s "$RELEASE_FILE" ]] || { echo "release lock not found: $RELEASE_FILE" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
source "$RELEASE_FILE"
set +a

case "$APP" in
  helm)
    APP_VERSION="$HELM_VERSION"
    GHCR_REPOSITORY="$HELM_GHCR_REPOSITORY"
    ;;
  cilium)
    APP_VERSION="$CILIUM_VERSION"
    GHCR_REPOSITORY="$CILIUM_GHCR_REPOSITORY"
    ;;
  *)
    echo "unsupported app: $APP" >&2
    exit 1
    ;;
esac

for cmd in docker skopeo jq sha256sum; do
  command -v "$cmd" >/dev/null || { echo "required command missing: $cmd" >&2; exit 1; }
done
: "${GHCR_USER:?GHCR_USER is required}"
: "${GHCR_TOKEN:?GHCR_TOKEN is required}"

log() { printf '[archinfra-cluster-image] %s\n' "$*"; }

single_digest() {
  local image="$1" arch="$2" creds="$3"
  skopeo inspect \
    --override-os linux \
    --override-arch "$arch" \
    --creds "$creds" \
    "docker://$image" | jq -r '.Digest'
}

verify_manifest() {
  local target="$1" amd_digest="$2" arm_digest="$3" creds="$4" raw digest
  raw="$(skopeo inspect --raw --creds "$creds" "docker://$target")"

  jq -e \
    --arg amd "$amd_digest" \
    --arg arm "$arm_digest" '
      (.manifests | length) == 2 and
      ([.manifests[] | select(.platform.os == "linux" and .platform.architecture == "amd64") | .digest] == [$amd]) and
      ([.manifests[] | select(.platform.os == "linux" and .platform.architecture == "arm64") | .digest] == [$arm])
    ' <<<"$raw" >/dev/null || {
      echo "multi-arch manifest verification failed: $target" >&2
      echo "$raw" | jq . >&2 || true
      return 1
    }

  digest="$(skopeo inspect --raw --creds "$creds" "docker://$target" | sha256sum | awk '{print "sha256:" $1}')"
  printf '%s\n' "$digest"
}

ensure_manifest() {
  local target="$1" amd_image="$2" arm_image="$3" creds="$4"
  local amd_digest arm_digest manifest_digest

  amd_digest="$(single_digest "$amd_image" amd64 "$creds")"
  arm_digest="$(single_digest "$arm_image" arm64 "$creds")"
  [[ "$amd_digest" == sha256:* ]] || { echo "invalid amd64 digest for $amd_image" >&2; exit 1; }
  [[ "$arm_digest" == sha256:* ]] || { echo "invalid arm64 digest for $arm_image" >&2; exit 1; }

  if skopeo inspect --raw --creds "$creds" "docker://$target" >/dev/null 2>&1; then
    manifest_digest="$(verify_manifest "$target" "$amd_digest" "$arm_digest" "$creds")" || {
      echo "ERROR: immutable multi-arch tag already exists with different content: $target" >&2
      exit 1
    }
    log "immutable multi-arch tag exists; reuse: $target@$manifest_digest"
  else
    log "create multi-arch manifest: $target"
    docker buildx imagetools create \
      --tag "$target" \
      "$amd_image" \
      "$arm_image"
    manifest_digest="$(verify_manifest "$target" "$amd_digest" "$arm_digest" "$creds")"
    log "multi-arch manifest verified: $target@$manifest_digest"
  fi

  MANIFEST_TARGET="$target"
  MANIFEST_DIGEST="$manifest_digest"
  MANIFEST_AMD64_IMAGE="$amd_image"
  MANIFEST_AMD64_DIGEST="$amd_digest"
  MANIFEST_ARM64_IMAGE="$arm_image"
  MANIFEST_ARM64_DIGEST="$arm_digest"
}

printf '%s' "$GHCR_TOKEN" | docker login ghcr.io --username "$GHCR_USER" --password-stdin >/dev/null
GHCR_CREDS="$GHCR_USER:$GHCR_TOKEN"
GHCR_BASE="${GHCR_REPOSITORY}:${APP_VERSION}-${RELEASE_VERSION}"
ensure_manifest \
  "$GHCR_BASE" \
  "${GHCR_BASE}-amd64" \
  "${GHCR_BASE}-arm64" \
  "$GHCR_CREDS"

mkdir -p "$OUT_DIR"
PROVENANCE="$OUT_DIR/${APP}-${APP_VERSION}-${RELEASE_VERSION}-multiarch.provenance.env"
cat >"$PROVENANCE" <<EOF
BUILD_STATUS=VERIFIED_MULTIARCH
RELEASE_VERSION=$RELEASE_VERSION
APP=$APP
APP_VERSION=$APP_VERSION
BUILD_GIT_REPOSITORY=${GITHUB_REPOSITORY:-local}
BUILD_GIT_SHA=${GITHUB_SHA:-local}
BUILD_RUN_ID=${GITHUB_RUN_ID:-local}
GHCR_IMAGE=$MANIFEST_TARGET
GHCR_DIGEST=$MANIFEST_DIGEST
GHCR_AMD64_IMAGE=$MANIFEST_AMD64_IMAGE
GHCR_AMD64_DIGEST=$MANIFEST_AMD64_DIGEST
GHCR_ARM64_IMAGE=$MANIFEST_ARM64_IMAGE
GHCR_ARM64_DIGEST=$MANIFEST_ARM64_DIGEST
PLATFORMS=linux/amd64,linux/arm64
EOF

if [[ "${PUBLISH_ALIYUN:-false}" == "true" ]]; then
  : "${ALIYUN_REGISTRY:?ALIYUN_REGISTRY is required when PUBLISH_ALIYUN=true}"
  : "${ALIYUN_NAMESPACE:?ALIYUN_NAMESPACE is required when PUBLISH_ALIYUN=true}"
  : "${ALIYUN_USERNAME:?ALIYUN_USERNAME is required when PUBLISH_ALIYUN=true}"
  : "${ALIYUN_PASSWORD:?ALIYUN_PASSWORD is required when PUBLISH_ALIYUN=true}"

  printf '%s' "$ALIYUN_PASSWORD" | docker login "$ALIYUN_REGISTRY" --username "$ALIYUN_USERNAME" --password-stdin >/dev/null
  ALIYUN_CREDS="$ALIYUN_USERNAME:$ALIYUN_PASSWORD"
  ALIYUN_BASE="${ALIYUN_REGISTRY}/${ALIYUN_NAMESPACE}/${APP}:${APP_VERSION}-${RELEASE_VERSION}"
  ensure_manifest \
    "$ALIYUN_BASE" \
    "${ALIYUN_BASE}-amd64" \
    "${ALIYUN_BASE}-arm64" \
    "$ALIYUN_CREDS"

  cat >>"$PROVENANCE" <<EOF
ALIYUN_MIRROR_STATUS=VERIFIED_MULTIARCH
ALIYUN_IMAGE=$MANIFEST_TARGET
ALIYUN_DIGEST=$MANIFEST_DIGEST
ALIYUN_AMD64_IMAGE=$MANIFEST_AMD64_IMAGE
ALIYUN_AMD64_DIGEST=$MANIFEST_AMD64_DIGEST
ALIYUN_ARM64_IMAGE=$MANIFEST_ARM64_IMAGE
ALIYUN_ARM64_DIGEST=$MANIFEST_ARM64_DIGEST
EOF
fi

cat "$PROVENANCE"
log "SUCCESS multiarch app=$APP platforms=linux/amd64,linux/arm64"
