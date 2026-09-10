#!/usr/bin/env bash
set -euo pipefail

cp -f opt/cilium /usr/bin/cilium
cp -f opt/hubble /usr/bin/hubble
chmod 0755 /usr/bin/cilium /usr/bin/hubble

# Hubble (relay + UI) is enabled by default so a deployed cluster ships with
# Cilium observability out of the box (Mirantis/cri-dockerd#569 unrelated; this
# is the Cilium built-in Hubble component).
base_values="kubeProxyReplacement=false,k8sServiceHost=apiserver.cluster.local,k8sServicePort=6443,hubble.relay.enabled=true,hubble.ui.enabled=true"

if [[ -n "${ExtraValues:-}" ]]; then
  cilium install \
    --chart-directory charts/cilium \
    --helm-set "${base_values},${ExtraValues}"
else
  cilium install \
    --chart-directory charts/cilium \
    --helm-set "$base_values"
fi