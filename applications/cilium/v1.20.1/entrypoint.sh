#!/usr/bin/env bash
set -euo pipefail

cp -f opt/cilium /usr/bin/cilium
cp -f opt/hubble /usr/bin/hubble
chmod 0755 /usr/bin/cilium /usr/bin/hubble

base_values="kubeProxyReplacement=false,k8sServiceHost=apiserver.cluster.local,k8sServicePort=6443"

if [[ -n "${ExtraValues:-}" ]]; then
  cilium install \
    --chart-directory charts/cilium \
    --helm-set "${base_values},${ExtraValues}"
else
  cilium install \
    --chart-directory charts/cilium \
    --helm-set "$base_values"
fi
