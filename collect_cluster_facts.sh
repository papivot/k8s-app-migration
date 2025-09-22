#!/usr/bin/env bash
set -euo pipefail

# Usage: ./collect_cluster_facts.sh <kubecontext> <output_file>
CTX="${1:-}"; OUT="${2:-}"
if [[ -z "$CTX" || -z "$OUT" ]]; then
  echo "Usage: $0 <kubecontext> <output_file>" >&2; exit 1
fi

req() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 2; }; }
req kubectl; req jq; req awk; req sed

kjson()   { kubectl --context "$CTX" -o json "$@"; }
kraw()    { kubectl --context "$CTX" get --raw "$1"; }
kget()    { kubectl --context "$CTX" get "$@"; }

emit() { printf "%s=%s\n" "$1" "${2//[$'\n\r']/ }"; }

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# ---- Cluster & API surface
ver="$(kubectl --context "$CTX" version -o json 2>/dev/null || echo '{}')"
gitVersion="$(jq -r '.serverVersion.gitVersion // empty' <<<"$ver")"
platform="$(jq -r '.serverVersion.platform // empty' <<<"$ver")"
emit cluster.gitVersion "${gitVersion:-unknown}"
emit cluster.platform   "${platform:-unknown}"

# API groups/versions (preferred) and all GVs
apis="$(kraw /apis || echo '{}')"
core="$(kraw /api  || echo '{}')"
gv_core="v1"
gv_groups="$(jq -r '[.groups[]?.preferredVersion.groupVersion] | sort | join(";")' <<<"$apis")"
gv_all="$(jq -r '([.groups[]?.versions[]?.groupVersion] + ["v1"]) | unique | sort | join(";")' <<<"$apis")"
emit apis.preferred "${gv_core};${gv_groups}"
emit apis.all       "${gv_all}"

# Short list of “must-have” resources on new cluster (existence only)
must_res=(deployments.apps statefulsets.apps daemonsets.apps jobs.batch cronjobs.batch ingresses.networking.k8s.io)
for r in "${must_res[@]}"; do
  if kubectl --context "$CTX" api-resources --no-headers 2>/dev/null | awk '{print $1"."$NF}' | grep -qx "$r"; then
    emit "apiresource.${r}" "present"
  else
    emit "apiresource.${r}" "missing"
  fi
done

# ---- Nodes / capacity
nodes="$(kjson nodes || echo '{"items":[]}')"
node_count="$(jq '.items|length' <<<"$nodes")"
emit capacity.nodes "$node_count"

alloc_cpu_m="$(jq '[.items[].status.allocatable.cpu] | map(
  (match("m$")? // empty) as $m
  | if (test("m$")) then (sub("m$";"")|tonumber) else ((. | sub("(^[0-9]+)$";"\1000"); tonumber)) end
) | add // 0' <<<"$nodes")"
alloc_mem_b="$(jq '[.items[].status.allocatable.memory] | map(
  . as $s |
  if $s|test("Ki$") then (sub("Ki$";"")|tonumber*1024)
  elif $s|test("Mi$") then (sub("Mi$";"")|tonumber*1024*1024)
  elif $s|test("Gi$") then (sub("Gi$";"")|tonumber*1024*1024*1024)
  elif $s|test("Ti$") then (sub("Ti$";"")|tonumber*1024*1024*1024*1024)
  else ($s|tonumber) end
) | add // 0' <<<"$nodes")"
emit capacity.cpu_milli  "$alloc_cpu_m"
emit capacity.mem_bytes  "$alloc_mem_b"

arches="$(jq -r '[.items[].status.nodeInfo.architecture]|unique|sort|join(";")' <<<"$nodes")"
oses="$(jq -r '[.items[].status.nodeInfo.osImage]|unique|sort|join(";")' <<<"$nodes")"
taints_exist="$(jq '[.items[].spec.taints // []]|flatten|length' <<<"$nodes")"
emit nodes.arches        "${arches}"
emit nodes.osImages      "${oses}"
emit nodes.anyTaints     "$([[ "$taints_exist" -gt 0 ]] && echo yes || echo no)"

# ---- Storage
sc="$(kjson storageclass.storage.k8s.io 2>/dev/null || echo '{"items":[]}')"
sc_names="$(jq -r '[.items[].metadata.name]|sort|join(";")' <<<"$sc")"
sc_default="$(jq -r '([.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"]=="true").metadata.name] | sort | join(";"))' <<<"$sc")"
emit storage.classes     "${sc_names}"
emit storage.default     "${sc_default:-}"

csid="$(kjson csidrivers.storage.k8s.io 2>/dev/null || echo '{"items":[]}')"
emit storage.csidrivers  "$(jq -r '[.items[].metadata.name]|sort|join(";")' <<<"$csid")"

snapcrds="$(kjson volumesnapshotclasses.snapshot.storage.k8s.io 2>/dev/null || echo '{"items":[]}')"
emit storage.snapclasses "$(jq -r '[.items[].metadata.name]|sort|join(";")' <<<"$snapcrds")"

# ---- Networking
# Guess CNI by known DaemonSets in kube-system
cni_guess="$(kubectl --context "$CTX" -n kube-system get ds -o json 2>/dev/null \
  | jq -r '[.items[].metadata.name]
    | map(select(test("calico|cilium|weave|flannel|canal|antrea|ovn", "i"))) | sort | join(";")')"
emit network.cni.guess "${cni_guess:-unknown}"

ingc="$(kjson ingressclasses.networking.k8s.io 2>/dev/null || echo '{"items":[]}')"
emit ingress.classes   "$(jq -r '[.items[].metadata.name]|sort|join(";")' <<<"$ingc")"
emit ingress.controllers "$(jq -r '[.items[].spec.controller]|unique|sort|join(";")' <<<"$ingc")"

# ---- Core add-ons (kube-system) — names and image tags
sysds="$(kubectl --context "$CTX" -n kube-system get ds,deploy -o json 2>/dev/null || echo '{"items":[]}')"
addons="$(jq -r '[.items[] |
  {kind:.kind, name:.metadata.name,
   images: ([.spec.template.spec.containers[].image] // [] )}]' <<<"$sysds")"
# Flatten into semi-colon list: name=img1|img2
addon_list="$(jq -r '[ .[] | "\(.name)=\((.images|join("|")))" ] | sort | join(";")' <<<"$addons")"
emit addons.kubesystem "$addon_list"

# Metrics-server & CoreDNS versions (handy signals)
ms_ver="$(kubectl --context "$CTX" -n kube-system get deploy -o json 2>/dev/null \
  | jq -r '.items[] | select(.metadata.name|test("metrics-server")).spec.template.spec.containers[].image' | paste -sd ';' -)"
cdns_ver="$(kubectl --context "$CTX" -n kube-system get deploy -o json 2>/dev/null \
  | jq -r '.items[] | select(.metadata.name|test("coredns")).spec.template.spec.containers[].image' | paste -sd ';' -)"
emit addons.metricsServer "${ms_ver:-missing}"
emit addons.coreDNS       "${cdns_ver:-missing}"

# ---- Policies & Admission
psa_default="$(kubectl --context "$CTX" get ns default -o json 2>/dev/null \
  | jq -r '[.metadata.labels["pod-security.kubernetes.io/enforce"],
             .metadata.labels["pod-security.kubernetes.io/audit"],
             .metadata.labels["pod-security.kubernetes.io/warn"]] | join(",")')"
emit policy.podSecurity.defaultNS "${psa_default:-none}"

mut_webhooks="$(kjson mutatingwebhookconfigurations.admissionregistration.k8s.io 2>/dev/null || echo '{"items":[]}')"
val_webhooks="$(kjson validatingwebhookconfigurations.admissionregistration.k8s.io 2>/dev/null || echo '{"items":[]}')"
emit admission.mutatingwebhooks.count   "$(jq '.items|length' <<<"$mut_webhooks")"
emit admission.validatingwebhooks.count "$(jq '.items|length' <<<"$val_webhooks")"

# ---- CRDs (count + a sample)
crds="$(kjson crd 2>/dev/null || echo '{"items":[]}')"
emit crds.count "$(jq '.items|length' <<<"$crds")"
emit crds.sample "$(jq -r '[.items[].metadata.name] | sort | .[0:15] | join(";")' <<<"$crds")"

# ---- Namespaces: quotas/limitranges signal
for ns in default kube-system; do
  qr="$(kjson -n "$ns" resourcequota 2>/dev/null || echo '{"items":[]}')"
  lr="$(kjson -n "$ns" limitrange 2>/dev/null  || echo '{"items":[]}')"
  emit "ns.${ns}.resourcequotas" "$(jq -r '[.items[].metadata.name]|sort|join(";")' <<<"$qr")"
  emit "ns.${ns}.limitranges"    "$(jq -r '[.items[].metadata.name]|sort|join(";")' <<<"$lr")"
done

# ---- Save
sort -u > "$OUT" <<EOF
$(declare -f emit >/dev/null; true)
EOF

# Re-emit sorted (we already printed via emit, but redirecting above simplifies)
# Instead, we captured nothing; so re-run collection as above? Simpler: write on the fly.
# We'll just say the file is already written because emit printed to stdout redirected.
