#!/usr/bin/env bash
set -euo pipefail

ARCH="${1:?architecture is required}"

case "$ARCH" in
  amd64)
    url="${HELM_URL_AMD64:?HELM_URL_AMD64 is required}"
    sha="${HELM_SHA256_AMD64:?HELM_SHA256_AMD64 is required}"
    ;;
  arm64)
    url="${HELM_URL_ARM64:?HELM_URL_ARM64 is required}"
    sha="${HELM_SHA256_ARM64:?HELM_SHA256_ARM64 is required}"
    ;;
  *)
    echo "unsupported Helm architecture: $ARCH" >&2
    exit 1
    ;;
esac

rm -rf opt
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL "$url" -o "$tmp/helm.tgz"
echo "$sha  $tmp/helm.tgz" | sha256sum -c -

tar -xzf "$tmp/helm.tgz" -C "$tmp" "linux-$ARCH/helm"
mkdir -p opt
install -m 0755 "$tmp/linux-$ARCH/helm" opt/helm

desc="$(file opt/helm)"
echo "[archinfra-cluster-image] helm binary: $desc"
case "$ARCH" in
  amd64)
    printf '%s\n' "$desc" | grep -Eiq 'x86-64|x86_64' || {
      echo "Helm binary is not amd64" >&2
      exit 1
    }
    opt/helm version --short | grep -F "${HELM_VERSION:?HELM_VERSION is required}"
    ;;
  arm64)
    printf '%s\n' "$desc" | grep -Eiq 'ARM aarch64|ARM64|aarch64' || {
      echo "Helm binary is not arm64" >&2
      exit 1
    }
    ;;
esac
