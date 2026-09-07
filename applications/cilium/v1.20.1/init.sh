#!/usr/bin/env bash
set -euo pipefail

ARCH="${1:?architecture is required}"

case "$ARCH" in
  amd64)
    cilium_cli_url="${CILIUM_CLI_URL_AMD64:?CILIUM_CLI_URL_AMD64 is required}"
    cilium_cli_sha="${CILIUM_CLI_SHA256_AMD64:?CILIUM_CLI_SHA256_AMD64 is required}"
    hubble_url="${HUBBLE_CLI_URL_AMD64:?HUBBLE_CLI_URL_AMD64 is required}"
    hubble_sha="${HUBBLE_CLI_SHA256_AMD64:?HUBBLE_CLI_SHA256_AMD64 is required}"
    ;;
  arm64)
    cilium_cli_url="${CILIUM_CLI_URL_ARM64:?CILIUM_CLI_URL_ARM64 is required}"
    cilium_cli_sha="${CILIUM_CLI_SHA256_ARM64:?CILIUM_CLI_SHA256_ARM64 is required}"
    hubble_url="${HUBBLE_CLI_URL_ARM64:?HUBBLE_CLI_URL_ARM64 is required}"
    hubble_sha="${HUBBLE_CLI_SHA256_ARM64:?HUBBLE_CLI_SHA256_ARM64 is required}"
    ;;
  *)
    echo "unsupported Cilium architecture: $ARCH" >&2
    exit 1
    ;;
esac

rm -rf charts opt images
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL "${CILIUM_CHART_URL:?CILIUM_CHART_URL is required}" -o "$tmp/cilium.tgz"
echo "${CILIUM_CHART_SHA256:?CILIUM_CHART_SHA256 is required}  $tmp/cilium.tgz" | sha256sum -c -
mkdir -p charts
tar -xzf "$tmp/cilium.tgz" -C charts
test -f charts/cilium/Chart.yaml
grep -Eq '^version:[[:space:]]*1\.20\.1[[:space:]]*$' charts/cilium/Chart.yaml

# Keep the compatibility behavior used by the upstream Sealos cluster-image builder:
# source-only *.tmpl files are not Helm runtime inputs and may confuse image scanning.
find charts/cilium -type f -name '*.tmpl' -exec sh -c 'mv "$1" "$1.bak"' _ {} \;

curl -fsSL "$cilium_cli_url" -o "$tmp/cilium-cli.tgz"
echo "$cilium_cli_sha  $tmp/cilium-cli.tgz" | sha256sum -c -
curl -fsSL "$hubble_url" -o "$tmp/hubble.tgz"
echo "$hubble_sha  $tmp/hubble.tgz" | sha256sum -c -

mkdir -p opt
tar -xzf "$tmp/cilium-cli.tgz" -C opt cilium
tar -xzf "$tmp/hubble.tgz" -C opt hubble
chmod 0755 opt/cilium opt/hubble

# Hashes are the identity check; these executions additionally prove the binaries run on the target architecture.
opt/cilium version --client >/dev/null
opt/hubble version >/dev/null
