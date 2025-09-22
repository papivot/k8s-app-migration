#!/usr/bin/env bash
set -euo pipefail

# Usage: ./compare_clusters.sh <clusterA_facts> <clusterB_facts> [output.csv]
A="${1:-}"; B="${2:-}"; OUT="${3:-/dev/stdout}"
if [[ -z "$A" || -z "$B" ]]; then
  echo "Usage: $0 <clusterA_facts> <clusterB_facts> [output.csv]" >&2; exit 1
fi

declare -A Amap Bmap
while IFS='=' read -r k v; do [[ -z "$k" ]] && continue; Amap["$k"]="$v"; done < <(grep -v '^\s*$' "$A")
while IFS='=' read -r k v; do [[ -z "$k" ]] && continue; Bmap["$k"]="$v"; done < <(grep -v '^\s*$' "$B")

# Helpers
csvescape() { sed 's/"/""/g; s/\r//g' <<<"$1"; }
join_keys() {
  { printf "%s\n" "${!Amap[@]}"; printf "%s\n" "${!Bmap[@]}"; } | sort -u
}
aslist() { tr ';' '\n' <<<"$1" | sed '/^$/d' | sort -u; }
issuperset() {
  # $1 superset candidate, $2 subset to check
  local sup="$1" sub="$2"
  local supf subf; supf="$(mktemp)"; subf="$(mktemp)"
  trap 'rm -f "$supf" "$subf"' RETURN
  aslist "$sup" >"$supf"; aslist "$sub" >"$subf"
  local missing; missing=$(comm -13 <(sort "$supf") <(sort "$subf") | paste -sd ';' -)
  [[ -z "$missing" ]] && return 0 || return 1
}

# Assessments
assess_api_surface() {
  local src="${Amap[apis.preferred]:-}"; local dst="${Bmap[apis.preferred]:-}"
  local musts=(apiresource.deployments.apps apiresource.statefulsets.apps apiresource.daemonsets.apps apiresource.jobs.batch apiresource.cronjobs.batch apiresource.ingresses.networking.k8s.io)
  local miss=()
  if ! issuperset "$dst" "$src"; then miss+=("target lacks some preferred API group/versions"); fi
  for m in "${musts[@]}"; do
    [[ "${Amap[$m]:-}" == "present" && "${Bmap[$m]:-}" != "present" ]] && miss+=("target missing $m")
  done
  if ((${#miss[@]})); then echo "FAIL|${miss[*]}"; else echo "OK|compatible API surface"; fi
}

assess_capacity() {
  local cpuA="${Amap[capacity.cpu_milli]:-0}" memA="${Amap[capacity.mem_bytes]:-0}"
  local cpuB="${Bmap[capacity.cpu_milli]:-0}" memB="${Bmap[capacity.mem_bytes]:-0}"
  local notes=()
  (( cpuB >= cpuA )) || notes+=("CPU target<source ($cpuB<$cpuA)")
  (( memB >= memA )) || notes+=("MEM target<source ($memB<$memA)")
  if ((${#notes[@]})); then echo "FAIL|${notes[*]}"; else echo "OK|target ≥ source capacity"; fi
}

assess_storage() {
  local defA="${Amap[storage.default]:-}" defB="${Bmap[storage.default]:-}"
  local scA="${Amap[storage.classes]:-}" scB="${Bmap[storage.classes]:-}"
  local notes=()
  if [[ -n "$defA" ]]; then
    # If source had a default class, ensure target has a default (name may differ)
    [[ -n "$defB" ]] || notes+=("target has no default StorageClass")
  fi
  # Optional: check that all SC names from A exist in B (relaxed)
  # if ! issuperset "$scB" "$scA"; then notes+=("target missing some StorageClasses"); fi
  if ((${#notes[@]})); then echo "WARN|${notes[*]}"; else echo "OK|storage defaults present"; fi
}

assess_network_stack() {
  local cniA="${Amap[network.cni.guess]:-unknown}" cniB="${Bmap[network.cni.guess]:-unknown}"
  local ingCtlA="${Amap[ingress.controllers]:-}"; local ingCtlB="${Bmap[ingress.controllers]:-}"
  local notes=()
  [[ "$cniA" == "$cniB" ]] || notes+=("CNI differs ($cniA vs $cniB)")
  if ! issuperset "$ingCtlB" "$ingCtlA"; then notes+=("Ingress controllers differ"); fi
  if ((${#notes[@]})); then echo "WARN|${notes[*]}"; else echo "OK|network stack comparable"; fi
}

assess_addons() {
  local addA="${Amap[addons.kubesystem]:-}" addB="${Bmap[addons.kubesystem]:-}"
  # Compare by names only (ignore versions in first pass)
  local names() { tr ';' '\n' <<<"$1" | cut -d'=' -f1 | sort -u | paste -sd ';' -; }
  local aN="$(names "$addA")"; local bN="$(names "$addB")"
  if issuperset "$bN" "$aN"; then echo "OK|target has superset of kube-system add-ons"
  else echo "WARN|target lacks some add-ons present on source"
  fi
}

assess_policies() {
  local psaA="${Amap[policy.podSecurity.defaultNS]:-none}" psaB="${Bmap[policy.podSecurity.defaultNS]:-none}"
  local mutA="${Amap[admission.mutatingwebhooks.count]:-0}" mutB="${Bmap[admission.mutatingwebhooks.count]:-0}"
  local valA="${Amap[admission.validatingwebhooks.count]:-0}" valB="${Bmap[admission.validatingwebhooks.count]:-0}"
  local notes=()
  [[ "$psaA" == "$psaB" ]] || notes+=("PSA labels differ (default ns)")
  (( valB >= valA )) || notes+=("fewer validating webhooks on target")
  # This is advisory; webhooks vary per platform
  if ((${#notes[@]})); then echo "WARN|${notes[*]}"; else echo "OK|policy posture comparable"; fi
}

# Emit header
echo 'Key,ClusterA,ClusterB,Assessment,Notes' > "$OUT"

emit_row() {
  local key="$1" a="${Amap[$1]:-}" b="${Bmap[$1]:-}" assess="$2" notes="$3"
  printf '"%s","%s","%s","%s","%s"\n' \
    "$(csvescape "$key")" "$(csvescape "$a")" "$(csvescape "$b")" \
    "$assess" "$(csvescape "$notes")" >> "$OUT"
}

# Core assessments (summary rows)
read -r api_ass api_note <<<"$(assess_api_surface | awk -F'|' '{print $1, $2}')"
emit_row "__SUMMARY.API_SURFACE__" "" "" "$api_ass" "$api_note"

read -r cap_ass cap_note <<<"$(assess_capacity | awk -F'|' '{print $1, $2}')"
emit_row "__SUMMARY.CAPACITY__" "" "" "$cap_ass" "$cap_note"

read -r st_ass st_note <<<"$(assess_storage | awk -F'|' '{print $1, $2}')"
emit_row "__SUMMARY.STORAGE__" "" "" "$st_ass" "$st_note"

read -r nw_ass nw_note <<<"$(assess_network_stack | awk -F'|' '{print $1, $2}')"
emit_row "__SUMMARY.NETWORK_STACK__" "" "" "$nw_ass" "$nw_note"

read -r pol_ass pol_note <<<"$(assess_policies | awk -F'|' '{print $1, $2}')"
emit_row "__SUMMARY.POLICY__" "" "" "$pol_ass" "$pol_note"

# Then, detailed rows for every key we have
for k in $(join_keys); do
  # Skip summaries (already emitted)
  [[ "$k" == __SUMMARY.* ]] && continue
  local a="${Amap[$k]:-}" b="${Bmap[$k]:-}"
  local assess="SAME"; local note=""
  if [[ "$a" != "$b" ]]; then assess="DIFF"; fi
  emit_row "$k" "$assess" "$note" "$assess" "$note"
done
