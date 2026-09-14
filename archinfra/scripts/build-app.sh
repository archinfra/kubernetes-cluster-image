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

case "$BUILD_ARCH" in
  amd64)
    SELECTED_RUNTIME_IMAGE="$KUBERNETES_RUNTIME_IMAGE"
    SELECTED_RUNTIME_DIGEST="$KUBERNETES_RUNTIME_DIGEST"
    SELECTED_HELM_SHA256="$HELM_SHA256_AMD64"
    SELECTED_CILIUM_CLI_SHA256="$CILIUM_CLI_SHA256_AMD64"
    SELECTED_HUBBLE_CLI_SHA256="$HUBBLE_CLI_SHA256_AMD64"
    ;;
  arm64)
    SELECTED_RUNTIME_IMAGE="${KUBERNETES_RUNTIME_IMAGE_ARM64:?KUBERNETES_RUNTIME_IMAGE_ARM64 is required}"
    SELECTED_RUNTIME_DIGEST="${KUBERNETES_RUNTIME_DIGEST_ARM64:?KUBERNETES_RUNTIME_DIGEST_ARM64 is required}"
    SELECTED_HELM_SHA256="${HELM_SHA256_ARM64:?HELM_SHA256_ARM64 is required}"
    SELECTED_CILIUM_CLI_SHA256="${CILIUM_CLI_SHA256_ARM64:?CILIUM_CLI_SHA256_ARM64 is required}"
    SELECTED_HUBBLE_CLI_SHA256="${HUBBLE_CLI_SHA256_ARM64:?HUBBLE_CLI_SHA256_ARM64 is required}"
    ;;
  *)
    echo "unsupported target architecture: $BUILD_ARCH" >&2
    exit 1
    ;;
esac

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

for cmd in sealos skopeo jq sha256sum curl tar file grep; do
  command -v "$cmd" >/dev/null || { echo "required command missing: $cmd" >&2; exit 1; }
done
[[ -d "$APP_DIR" ]] || { echo "application source missing: $APP_DIR" >&2; exit 1; }
: "${GHCR_USER:?GHCR_USER is required}"
: "${GHCR_TOKEN:?GHCR_TOKEN is required}"

verify_image_arch_digest() {
  local image="$1" expected_digest="$2" expected_arch="$3" creds="${4:-}" inspect actual_digest actual_arch
  local args=(inspect --override-os linux --override-arch "$expected_arch")
  if [[ -n "$creds" ]]; then
    args+=(--creds "$creds")
  fi
  inspect="$(skopeo "${args[@]}" "docker://$image")"
  actual_digest="$(jq -r '.Digest' <<<"$inspect")"
  actual_arch="$(jq -r '.Architecture' <<<"$inspect")"
  [[ "$actual_digest" == "$expected_digest" ]] || {
    echo "registry digest mismatch: image=$image expected=$expected_digest actual=$actual_digest" >&2
    exit 1
  }
  [[ "$actual_arch" == "$expected_arch" ]] || {
    echo "registry architecture mismatch: image=$image expected=$expected_arch actual=$actual_arch" >&2
    exit 1
  }
  echo "[archinfra-cluster-image] verified image: $image -> $expected_arch $actual_digest"
}

# Tie this application release to the exact already-verified Kubernetes runtime.
verify_image_arch_digest \
  "$SELECTED_RUNTIME_IMAGE" \
  "$SELECTED_RUNTIME_DIGEST" \
  "$BUILD_ARCH" \
  "$GHCR_USER:$GHCR_TOKEN"

# Tags are release-qualified and architecture-specific so an r2 rerun cannot
# collide with r1 or a future release using the same application version.
GHCR_IMAGE="${GHCR_REPOSITORY}:${APP_VERSION}-${RELEASE_VERSION}-${BUILD_ARCH}"
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

if [[ "$APP" == "cilium" && -s "$WORK_DIR/images/shim/ciliumImages" ]]; then
  while IFS= read -r image; do
    [[ -n "$image" ]] || continue
    inspect="$(skopeo inspect --override-os linux --override-arch "$BUILD_ARCH" "docker://$image")"
    image_arch="$(jq -r '.Architecture' <<<"$inspect")"
    [[ "$image_arch" == "$BUILD_ARCH" ]] || {
      echo "Cilium offline image lacks target architecture: image=$image expected=$BUILD_ARCH actual=$image_arch" >&2
      exit 1
    }
    echo "[archinfra-cluster-image] cilium payload image OK: $image -> linux/$BUILD_ARCH"
  done < "$WORK_DIR/images/shim/ciliumImages"
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
PROVENANCE="$ROOT/out/${APP}-${APP_VERSION}-${RELEASE_VERSION}-${BUILD_ARCH}.provenance.env"
rm -f "$PROVENANCE"

sudo sealos login -u "$GHCR_USER" -p "$GHCR_TOKEN" ghcr.io >/dev/null

(
  cd "$WORK_DIR"
  sudo sealos build \
    -t "$GHCR_IMAGE" \
    --isolation=chroot \
    --platform "linux/$BUILD_ARCH" \
    --label "io.archinfra.release=$RELEASE_VERSION" \
    --label "io.archinfra.app=$APP" \
    --label "io.archinfra.arch=$BUILD_ARCH" \
    -f "$BUILD_FILE" \
    .
)

sudo sealos push "$GHCR_IMAGE"

GHCR_INSPECT="$(skopeo inspect \
  --override-os linux \
  --override-arch "$BUILD_ARCH" \
  --creds "$GHCR_USER:$GHCR_TOKEN" \
  "docker://$GHCR_IMAGE")"
GHCR_DIGEST="$(jq -r '.Digest' <<<"$GHCR_INSPECT")"
GHCR_ARCH="$(jq -r '.Architecture' <<<"$GHCR_INSPECT")"

[[ "$GHCR_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo "invalid GHCR digest: $GHCR_DIGEST" >&2
  exit 1
}
[[ "$GHCR_ARCH" == "$BUILD_ARCH" ]] || {
  echo "published image architecture mismatch: expected=$BUILD_ARCH actual=$GHCR_ARCH" >&2
  exit 1
}

cat >"$PROVENANCE" <<EOF
BUILD_STATUS=VERIFIED_BUILD_ONLY
RELEASE_VERSION=$RELEASE_VERSION
APP=$APP
APP_VERSION=$APP_VERSION
ARCH=$BUILD_ARCH
KUBERNETES_VERSION=$KUBERNETES_VERSION
KUBERNETES_RUNTIME_IMAGE=$SELECTED_RUNTIME_IMAGE
KUBERNETES_RUNTIME_DIGEST=$SELECTED_RUNTIME_DIGEST
KUBERNETES_RUNTIME_BUILD_GIT_SHA=${KUBERNETES_RUNTIME_BUILD_GIT_SHA:-unknown}
KUBERNETES_RUNTIME_BUILD_RUN_ID=${KUBERNETES_RUNTIME_BUILD_RUN_ID:-unknown}
SEALOS_VERSION=$SEALOS_VERSION
BUILD_GIT_REPOSITORY=${GITHUB_REPOSITORY:-local}
BUILD_GIT_SHA=${GITHUB_SHA:-local}
BUILD_RUN_ID=${GITHUB_RUN_ID:-local}
GHCR_IMAGE=$GHCR_IMAGE
GHCR_DIGEST=$GHCR_DIGEST
GHCR_ARCH=$GHCR_ARCH
EOF

case "$APP" in
  helm)
    cat >>"$PROVENANCE" <<EOF
HELM_VERSION=$HELM_VERSION
HELM_SOURCE_SHA256=$SELECTED_HELM_SHA256
EOF
    ;;
  cilium)
    cat >>"$PROVENANCE" <<EOF
CILIUM_VERSION=$CILIUM_VERSION
CILIUM_KUBE_PROXY_REPLACEMENT=$CILIUM_KUBE_PROXY_REPLACEMENT
CILIUM_CHART_GIT_COMMIT=$CILIUM_CHART_GIT_COMMIT
CILIUM_CHART_SHA256=$CILIUM_CHART_SHA256
CILIUM_CLI_VERSION=$CILIUM_CLI_VERSION
CILIUM_CLI_SHA256=$SELECTED_CILIUM_CLI_SHA256
HUBBLE_CLI_VERSION=$HUBBLE_CLI_VERSION
HUBBLE_CLI_SHA256=$SELECTED_HUBBLE_CLI_SHA256
EOF
    ;;
esac

if [[ "${PUBLISH_ALIYUN:-false}" == "true" ]]; then
  : "${ALIYUN_REGISTRY:?ALIYUN_REGISTRY is required when PUBLISH_ALIYUN=true}"
  : "${ALIYUN_NAMESPACE:?ALIYUN_NAMESPACE is required when PUBLISH_ALIYUN=true}"
  : "${ALIYUN_USERNAME:?ALIYUN_USERNAME is required when PUBLISH_ALIYUN=true}"
  : "${ALIYUN_PASSWORD:?ALIYUN_PASSWORD is required when PUBLISH_ALIYUN=true}"

  ALIYUN_IMAGE="${ALIYUN_REGISTRY}/${ALIYUN_NAMESPACE}/${APP}:${APP_VERSION}-${RELEASE_VERSION}-${BUILD_ARCH}"
  echo "Mirroring $GHCR_IMAGE@$GHCR_DIGEST -> $ALIYUN_IMAGE"

  mirror_ok=false
  for attempt in 1 2 3; do
    if skopeo copy \
      --all \
      --preserve-digests \
      --src-creds "$GHCR_USER:$GHCR_TOKEN" \
      --dest-creds "$ALIYUN_USERNAME:$ALIYUN_PASSWORD" \
      "docker://$GHCR_IMAGE" \
      "docker://$ALIYUN_IMAGE"; then
      mirror_ok=true
      break
    fi

    if [[ "$attempt" -lt 3 ]]; then
      delay=$((attempt * 5))
      echo "Aliyun mirror attempt $attempt failed; retrying in ${delay}s" >&2
      sleep "$delay"
    fi
  done

  [[ "$mirror_ok" == "true" ]] || {
    echo "Aliyun mirror failed after 3 attempts" >&2
    exit 1
  }

  ALIYUN_INSPECT="$(skopeo inspect \
    --override-os linux \
    --override-arch "$BUILD_ARCH" \
    --creds "$ALIYUN_USERNAME:$ALIYUN_PASSWORD" \
    "docker://$ALIYUN_IMAGE")"
  ALIYUN_DIGEST="$(jq -r '.Digest' <<<"$ALIYUN_INSPECT")"
  ALIYUN_ARCH="$(jq -r '.Architecture' <<<"$ALIYUN_INSPECT")"

  [[ "$ALIYUN_DIGEST" == "$GHCR_DIGEST" ]] || {
    echo "Aliyun digest mismatch: GHCR=$GHCR_DIGEST Aliyun=$ALIYUN_DIGEST" >&2
    exit 1
  }
  [[ "$ALIYUN_ARCH" == "$BUILD_ARCH" ]] || {
    echo "Aliyun architecture mismatch: expected=$BUILD_ARCH actual=$ALIYUN_ARCH" >&2
    exit 1
  }

  cat >>"$PROVENANCE" <<EOF
ALIYUN_MIRROR_STATUS=VERIFIED
ALIYUN_IMAGE=$ALIYUN_IMAGE
ALIYUN_DIGEST=$ALIYUN_DIGEST
ALIYUN_ARCH=$ALIYUN_ARCH
EOF
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## $APP Cluster Image ($BUILD_ARCH)"
    echo
    echo "- Release: \`$RELEASE_VERSION\`"
    echo "- Version: \`$APP_VERSION\`"
    echo "- GHCR: \`$GHCR_IMAGE@$GHCR_DIGEST\`"
    echo "- Platform: \`linux/$GHCR_ARCH\`"
    if [[ "${PUBLISH_ALIYUN:-false}" == "true" ]]; then
      echo "- Aliyun: \`$ALIYUN_IMAGE@$ALIYUN_DIGEST\`"
    fi
  } >>"$GITHUB_STEP_SUMMARY"
fi

cat "$PROVENANCE"
echo "[archinfra-cluster-image] SUCCESS app=$APP arch=$BUILD_ARCH image=$GHCR_IMAGE@$GHCR_DIGEST"
