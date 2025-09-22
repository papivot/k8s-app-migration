#!/usr/bin/env bash
set -euo pipefail

# Usage: ./app_compat_check.sh <target_kubecontext> <manifests_file_or_dir> <output.csv>
CTX="${1:-}"; SRC="${2:-}"; OUT="${3:-/dev/stdout}"
if [[ -z "$CTX" || -z "$SRC" ]]; then
  echo "Usage: $0 <target_kubecontext> <manifests_file_or_dir> <output.csv>" >&2
  exit 1
fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 2; }; }
need kubectl; need yq; need jq

# Collect all yaml docs into a temp combined file
tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
combined="$tmpd/combined.yaml"

if [[ -d "$SRC" ]]; then
  # concatenate *.y*ml in stable order
  find "$SRC" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort | xargs cat -- > "$combined"
else
  cat "$SRC" > "$combined"
fi

# Header
echo 'Check,Item,Result,Details' > "$OUT"
csv() { # csv "Check" "Item" "Result" "Details"
  awk -v a="$1" -v b="$2" -v c="$3" -v d="$4" 'BEGIN{
    gsub(/"/,"""",a); gsub(/"/,"""",b); gsub(/"/,"""",c); gsub(/"/,"""",d);
    printf "\"%s\",\"%s\",\"%s\",\"%s\"\n", a,b,c,d;
  }' >> "$OUT"
}

# ---------- 1) API availability (GVK) ----------
# Unique list of apiVersion+kind from manifests
# yq spits items like "apps/v1 Deployment"
mapfile -t GVKs < <(yq -r '. as $d ireduce ([]; . + [ ( .apiVersion // "" ) + " " + ( .kind // "" ) ] )' "$combined" \
  | sed '/^ /d;/^$/d' | sort -u)

# Build a map of supported api-resources on target cluster: "groupVersion kind"
# We'll call kubectl api-resources once per apiGroup to avoid N^2
declare -A SUPPORTED
# Get all resources with their group and version
# Format to: "group/version KIND" as uppercase kind
kubectl --context "$CTX" api-resources -o wide 2>/dev/null \
| awk 'NR>1{print $1,$2,$3,$4,$5,$6,$7,$8,$9}' \
| while read -r NAME SHORTNAMES APIGROUP NAMESPACED KIND VERB REST; do
    [[ -z "$KIND" ]] && continue
    if [[ -z "$APIGROUP" || "$APIGROUP" == "<none>" ]]; then
      gv="v1"
    else
      # We don’t get version per-row from plain api-resources; fallback to preferred via /apis
      gv="" ; 
    fi
  done >/dev/null

# More reliable: query /apis and /api for preferred versions, then cross-check Kinds per group
apis="$(kubectl --context "$CTX" get --raw /apis 2>/dev/null || echo '{}')"
core="$(kubectl --context "$CTX" get --raw /api  2>/dev/null || echo '{}')"

# Fill SUPPORTED with preferred groupVersions and all Kinds under them
jq -r '.groups[]?|.preferredVersion.groupVersion as $gv
       | .name as $g
       | $gv
' <<<"$apis" | while read -r gv; do
  # list resources for this groupVersion
  kubectl --context "$CTX" get --raw "/apis/${gv}" 2>/dev/null \
   | jq -r --arg gv "$gv" '.resources[]?|select(has("name") and has("kind"))|"\($gv) \(.kind)"' \
   | while read -r line; do SUPPORTED["$line"]=1; done
done

# core v1
kubectl --context "$CTX" get --raw /api/v1 2>/dev/null \
 | jq -r '.resources[]?|select(has("name") and has("kind"))|"v1 \(.kind)"' \
 | while read -r line; do SUPPORTED["$line"]=1; done

# Now evaluate each manifest GVK (normalize kind capitalization)
for gvk in "${GVKs[@]}"; do
  apiver="${gvk%% *}"; kind="${gvk#* }"
  [[ -z "$apiver" || -z "$kind" ]] && continue
  key="$apiver $kind"
  if [[ -n "${SUPPORTED[$key]:-}" ]]; then
    csv "API" "$key" "OK" "Supported on target"
  else
    # Try to help: is the group present but different preferred version?
    group="${apiver%/*}"
    if [[ "$apiver" == "v1" ]]; then group=""; fi
    hint=""
    if [[ -n "$group" ]]; then
      pref="$(jq -r --arg g "$group" '.groups[]?|select(.name==$g)|.preferredVersion.groupVersion // empty' <<<"$apis")"
      [[ -n "$pref" ]] && hint="Group present; preferred=$pref"
    fi
    csv "API" "$key" "FAIL" "${hint:-Not found on target}"
  fi
done

# ---------- 2) StorageClasses ----------
# Collect referenced SCs from PVCs; also detect PVCs relying on default SC
mapfile -t PVC_SCs < <(yq -r 'select(.kind=="PersistentVolumeClaim") | .spec.storageClassName // ""' "$combined" \
  | sed '/^$/d' | sort -u)

# Does target have a default SC?
defSC="$(kubectl --context "$CTX" get storageclass -o json 2>/dev/null \
  | jq -r '.items[]?|select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"]=="true")|.metadata.name' | head -n1)"

# Inventory target SC names
SC_TARGET="$(kubectl --context "$CTX" get storageclass -o json 2>/dev/null \
  | jq -r '.items[]?.metadata.name' | sort -u)"

if [[ ${#PVC_SCs[@]} -eq 0 ]]; then
  # No explicit SCs in manifests → default must exist
  if [[ -n "$defSC" ]]; then
    csv "StorageClass" "(implicit default)" "OK" "Target default=$defSC"
  else
    csv "StorageClass" "(implicit default)" "FAIL" "No default StorageClass on target"
  fi
else
  # Check each referenced SC
  for sc in "${PVC_SCs[@]}"; do
    if grep -qx "$sc" <<<"$SC_TARGET"; then
      csv "StorageClass" "$sc" "OK" "Exists on target"
    else
      if [[ -n "$defSC" ]]; then
        csv "StorageClass" "$sc" "WARN" "Missing; target default=$defSC will be used unless overridden"
      else
        csv "StorageClass" "$sc" "FAIL" "Missing and no default StorageClass on target"
      fi
    fi
  done
fi

# ---------- 3) IngressClass ----------
mapfile -t ICLS < <(yq -r 'select(.kind=="Ingress") | .spec.ingressClassName // ""' "$combined" \
  | sed '/^$/d' | sort -u)
# Target IngressClasses
ICL_TARGET="$(kubectl --context "$CTX" get ingressclass -o json 2>/dev/null \
  | jq -r '.items[]?.metadata.name' | sort -u)"
# Default ingress class annotation (controller-specific; best effort)
defICL="$(kubectl --context "$CTX" get configmap -n ingress-nginx ingress-nginx-controller -o json 2>/dev/null \
  | jq -r '.data.default-ingress-class // empty' || true)"

if [[ ${#ICLS[@]} -eq 0 ]]; then
  csv "IngressClass" "(none specified)" "INFO" "Relies on controller default; ensure one is set"
else
  for ic in "${ICLS[@]}"; do
    if grep -qx "$ic" <<<"$ICL_TARGET"; then
      csv "IngressClass" "$ic" "OK" "Exists on target"
    else
      csv "IngressClass" "$ic" "FAIL" "IngressClass not found on target"
    fi
  done
fi

# ---------- 4) Namespaces ----------
# Namespaces required by namespaced resources:
mapfile -t NS_USED < <(yq -r 'select(has("metadata") and .metadata.namespace != null) | .metadata.namespace' "$combined" \
  | sed '/^$/d' | sort -u)
# Namespaces created by the manifests:
mapfile -t NS_CREATED < <(yq -r 'select(.kind=="Namespace") | .metadata.name' "$combined" \
  | sed '/^$/d' | sort -u)

# Target existing namespaces
NS_TARGET="$(kubectl --context "$CTX" get ns -o json 2>/dev/null | jq -r '.items[].metadata.name' | sort -u)"

for ns in "${NS_USED[@]:-}"; do
  if grep -qx "$ns" <<<"$(printf "%s\n" "${NS_CREATED[@]:-}")"; then
    csv "Namespace" "$ns" "OK" "Created by manifests"
  elif grep -qx "$ns" <<<"$NS_TARGET"; then
    csv "Namespace" "$ns" "OK" "Exists on target"
  else
    csv "Namespace" "$ns" "FAIL" "Namespace not present and not created"
  fi
done

# ---------- 5) RBAC subjects: ServiceAccounts referenced by RoleBindings ----------
# Collect SA subjects from RoleBindings/ClusterRoleBindings
mapfile -t SA_SUBJ < <(yq -r '
  select(.kind=="RoleBinding" or .kind=="ClusterRoleBinding")
  | .subjects[]? | select(.kind=="ServiceAccount")
  | (.namespace // "default") + "/" + .name' "$combined" \
  | sed '/^\/$/d' | sort -u)

# ServiceAccounts created by manifests
mapfile -t SA_CREATED < <(yq -r 'select(.kind=="ServiceAccount") | (.metadata.namespace // "default") + "/" + .metadata.name' "$combined" \
  | sort -u)

# Target SAs
# (We’ll query for each SA/namespace pair lazily)
for sa in "${SA_SUBJ[@]:-}"; do
  ns="${sa%%/*}"; name="${sa#*/}"
  if grep -qx "$sa" <<<"$(printf "%s\n" "${SA_CREATED[@]:-}")"; then
    csv "RBAC.ServiceAccount" "$sa" "OK" "Created by manifests"
  else
    if kubectl --context "$CTX" -n "$ns" get sa "$name" >/dev/null 2>&1; then
      csv "RBAC.ServiceAccount" "$sa" "OK" "Exists on target"
    else
      csv "RBAC.ServiceAccount" "$sa" "FAIL" "Missing on target and not created"
    fi
  fi
done

# ---------- 6) Server-side validation (authoritative API check) ----------
# Let the API server validate *all* docs in one pass; we capture errors without applying.
if ! kubectl --context "$CTX" apply --dry-run=server -f "$combined" >/dev/null 2>"$tmpd/ssv.err"; then
  # Emit each distinct error line as a FAIL
  # Clean up noisy warnings; keep “no matches for kind” and validation errors
  grep -E "error|no matches for|validation|Invalid|not found" "$tmpd/ssv.err" \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sort -u \
    | while read -r line; do
        csv "ServerDryRun" "(bundle)" "FAIL" "$line"
      done
else
  csv "ServerDryRun" "(bundle)" "OK" "API server accepted all objects (dry-run)"
fi
