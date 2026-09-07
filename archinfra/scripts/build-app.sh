#!/usr/bin/env bash
set -euo pipefail

APP="${1:?usage: build-app.sh <helm|cilium> [arch]}"
BUILD_ARCH="${2:-amd64}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RELEASE_FILE="${RELEASE_FILE:-$ROOT/archinfra/releases/k8s-v1.36.4-r1.env}"

[[ -s "$RELEASE_FILE" ]] || { echo "release lock not found: $RELEASE_FILE" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
source "$RELEASE_FILE"
set +a

[[ "$BUILD_ARCH" == "$TARGET_ARCH" ]] || {
  echo "r1 only permits TARGET_ARCH=$TARGET_ARCH, requested=$BUILD_ARCH" >&2
  exit 1
}

case "$APP" in
  helm)
    APP_VERSION="$HELM_VERSION"
    APP_DIR="$ROOT/applications/helm/$HELM_VERSION"
    GHCR_REPOSITORY="$HELM_GHCR_REPOSITORY"
    ;;
  cilium)
    APP_VERSION="$CILIUM_VERSION"
    APP_DIR="$ROOT/applications/cilium/$CILIUM_VERSION"
    GHCR_REPOSITORY="$CILIUM_GHCR_REPOSITORY"
    ;;
  *)
    echo "unsupported app: $APP" >&2
    exit 1
    ;;
esac

for cmd in sealos skopeo jq sha256sum curl tar; do
  command -v "$cmd" >/dev/null || { echo "required command missing: $cmd" >&2; exit 1; }
done
[[ -d "$APP_DIR" ]] || { echo "application source missing: $APP_DIR" >&2; exit 1; }
: "${GHCR_USER:?GHCR_USER is required}"
: "${GHCR_TOKEN:?GHCR_TOKEN is required}"

GHCR_IMAGE="${GHCR_REPOSITORY}:${APP_VERSION}-${BUILD_ARCH}"
WORK_DIR="$(mktemp -d)"
# sealos build runs rootful and may create root-owned offline-registry files in WORK_DIR.
trap 'sudo rm -rf "$WORK_DIR"' EXIT
cp -a "$APP_DIR/." "$WORK_DIR/"

if [[ -s "$WORK_DIR/init.sh" ]]; then
  (
    cd "$WORK_DIR"
    bash init.sh "$BUILD_ARCH" "$APP" "$APP_VERSION"
  )
fi

if [[ -s "$WORK_DIR/Dockerfile" ]]; then
  BUILD_FILE=Dockerfile
elif [[ -s "$WORK_DIR/Kubefile" ]]; then
  BUILD_FILE=Kubefile
else
  echo "no Dockerfile/Kubefile found for $APP" >&2
  exit 1
fi

mkdir -p "$ROOT/out"
PROVENANCE="$ROOT/out/${APP}-${APP_VERSION}-${BUILD_ARCH}.provenance.env"
rm -f "$PROVENANCE"

sudo sealos login -u "$GHCR_USER" -p "$GHCR_TOKEN" ghcr.io >/dev/null

(
  cd "$WORK_DIR"
  sudo sealos build \
    -t "$GHCR_IMAGE" \
    --isolation=chroot \
    --platform "linux/$BUILD_ARCH" \
    -f "$BUILD_FILE" \
    .
)

sudo sealos push "$GHCR_IMAGE"
GHCR_DIGEST="$(skopeo inspect \
  --creds "$GHCR_USER:$GHCR_TOKEN" \
  "docker://$GHCR_IMAGE" | jq -r '.Digest')"
[[ "$GHCR_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo "invalid GHCR digest: $GHCR_DIGEST" >&2
  exit 1
}

cat >"$PROVENANCE" <<EOF
BUILD_STATUS=VERIFIED_BUILD_ONLY
RELEASE_VERSION=$RELEASE_VERSION
APP=$APP
APP_VERSION=$APP_VERSION
ARCH=$BUILD_ARCH
KUBERNETES_VERSION=$KUBERNETES_VERSION
KUBERNETES_RUNTIME_IMAGE=$KUBERNETES_RUNTIME_IMAGE
KUBERNETES_RUNTIME_DIGEST=$KUBERNETES_RUNTIME_DIGEST
SEALOS_VERSION=$SEALOS_VERSION
BUILD_GIT_REPOSITORY=${GITHUB_REPOSITORY:-local}
BUILD_GIT_SHA=${GITHUB_SHA:-local}
BUILD_RUN_ID=${GITHUB_RUN_ID:-local}
GHCR_IMAGE=$GHCR_IMAGE
GHCR_DIGEST=$GHCR_DIGEST
EOF

case "$APP" in
  helm)
    cat >>"$PROVENANCE" <<EOF
HELM_VERSION=$HELM_VERSION
HELM_SOURCE_SHA256=$HELM_SHA256_AMD64
EOF
    ;;
  cilium)
    cat >>"$PROVENANCE" <<EOF
CILIUM_VERSION=$CILIUM_VERSION
CILIUM_KUBE_PROXY_REPLACEMENT=$CILIUM_KUBE_PROXY_REPLACEMENT
CILIUM_CHART_GIT_COMMIT=$CILIUM_CHART_GIT_COMMIT
CILIUM_CHART_SHA256=$CILIUM_CHART_SHA256
CILIUM_CLI_VERSION=$CILIUM_CLI_VERSION
CILIUM_CLI_SHA256=$CILIUM_CLI_SHA256_AMD64
HUBBLE_CLI_VERSION=$HUBBLE_CLI_VERSION
HUBBLE_CLI_SHA256=$HUBBLE_CLI_SHA256_AMD64
EOF
    ;;
esac

if [[ "${PUBLISH_ALIYUN:-false}" == "true" ]]; then
  : "${ALIYUN_REGISTRY:?ALIYUN_REGISTRY is required when PUBLISH_ALIYUN=true}"
  : "${ALIYUN_NAMESPACE:?ALIYUN_NAMESPACE is required when PUBLISH_ALIYUN=true}"
  : "${ALIYUN_USERNAME:?ALIYUN_USERNAME is required when PUBLISH_ALIYUN=true}"
  : "${ALIYUN_PASSWORD:?ALIYUN_PASSWORD is required when PUBLISH_ALIYUN=true}"

  ALIYUN_IMAGE="${ALIYUN_REGISTRY}/${ALIYUN_NAMESPACE}/${APP}:${APP_VERSION}-${BUILD_ARCH}"
  echo "Mirroring $GHCR_IMAGE@$GHCR_DIGEST -> $ALIYUN_IMAGE"

  skopeo copy \
    --all \
    --preserve-digests \
    --src-creds "$GHCR_USER:$GHCR_TOKEN" \
    --dest-creds "$ALIYUN_USERNAME:$ALIYUN_PASSWORD" \
    "docker://$GHCR_IMAGE" \
    "docker://$ALIYUN_IMAGE"

  ALIYUN_DIGEST="$(skopeo inspect \
    --creds "$ALIYUN_USERNAME:$ALIYUN_PASSWORD" \
    "docker://$ALIYUN_IMAGE" | jq -r '.Digest')"

  [[ "$ALIYUN_DIGEST" == "$GHCR_DIGEST" ]] || {
    echo "Aliyun digest mismatch: GHCR=$GHCR_DIGEST Aliyun=$ALIYUN_DIGEST" >&2
    exit 1
  }

  cat >>"$PROVENANCE" <<EOF
ALIYUN_MIRROR_STATUS=VERIFIED
ALIYUN_IMAGE=$ALIYUN_IMAGE
ALIYUN_DIGEST=$ALIYUN_DIGEST
EOF
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## $APP Cluster Image"
    echo
    echo "- Version: \`$APP_VERSION\`"
    echo "- GHCR: \`$GHCR_IMAGE@$GHCR_DIGEST\`"
    if [[ "${PUBLISH_ALIYUN:-false}" == "true" ]]; then
      echo "- Aliyun: \`$ALIYUN_IMAGE@$ALIYUN_DIGEST\`"
    fi
  } >>"$GITHUB_STEP_SUMMARY"
fi

cat "$PROVENANCE"
echo "[archinfra-cluster-image] SUCCESS app=$APP image=$GHCR_IMAGE@$GHCR_DIGEST"
