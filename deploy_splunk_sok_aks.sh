#!/usr/bin/env bash
# =============================================================================
# Deploy Splunk Operator + Enterprise (C3 topology) on AKS using Azure Workload Identity
# =============================================================================
# What this script does (idempotent):
#  - Enable AKS OIDC issuer + Workload Identity
#  - Ensure a User Assigned Managed Identity (UAMI) and Federated Identity Credential (FIC)
#  - Grant UAMI "Storage Blob Data Reader" on your storage account
#  - Ensure storage containers + prefixes for Splunk App Framework
#  - Render values-azure.yaml with WI baked in (operator + CR pods labeled & annotated)
#  - Helm template, then install/upgrade
#  - Optional cleanup on "delete" with toggles
#
# Usage:
#   Ensure that you are logged in to Azure and have selected the desired subscription
#     az cloud set -n <cloud>                     # e.g., AzureUSGovernment, AzureCloud
#     az login --use-device-code
#     az account set -s <subscription>
#   bash deploy_splunk_sok_blog.sh                  # apply
#   DELETE_NAMESPACE=true DELETE_UAI=false DELETE_STORAGE_ACCOUNT=false bash deploy_splunk_sok_aks.sh delete
#
# Before running, make updates to the following rows:
#  55 - Resource Group of the Cluster
#  56 - AKS Cluster Name
#  57 - Location of the Cluster
#  63 - UAMI Resource Group Name
#  64 - UAMI Name
#  67 - Storage Account Resource Group
#  68 - Storage Account Name
#  85 & 86 - Update your Azure Container Registry URL
# Customize the section "CUSTOMER VARIABLES" below.
# =============================================================================

set -euo pipefail

# -------------------------
# Logging helpers
# -------------------------
GREEN="\033[0;32m"; YELLOW="\033[1;33m"; RED="\033[0;31m"; NC="\033[0m"
log() { printf "${YELLOW}[%-8s]${NC} %s\n" "$(date +%H:%M:%S)" "$*" >&2; }
ok()  { printf "${GREEN}✓ %-8s${NC} %s\n" "$(date +%H:%M:%S)" "$*" >&2; }
err() { printf "${RED}✗ %-8s${NC} %s\n" "$(date +%H:%M:%S)" "$*" >&2; }
trap 'err "Script failed. Scroll up for details."' ERR

retry() { local -r max="$1"; shift; local -r sleep="$1"; shift; local n=1; until "$@"; do [[ $n -ge $max ]] && return 1; sleep "$sleep"; n=$((n+1)); done; }
need() { command -v "$1" >/dev/null 2>&1 || { err "Missing tool: $1"; exit 1; }; }

# -------------------------
# CUSTOMER VARIABLES (EDIT THESE)
# -------------------------
# Azure subscription (ID or name). Leave blank to use current 'az account show'.
SUB="${SUB:-}"

# AKS cluster details
CLUSTER_RG="${CLUSTER_RG:-x}"
CLUSTER_NAME="${CLUSTER_NAME:-x}"
LOCATION="${LOCATION:-x}"            # e.g., westus2, eastus, westeurope, usgovvirginia

# Kubernetes namespace for operator & Splunk CRs
NAMESPACE="${NAMESPACE:-splunk}"

# UAMI resource group + name (create/reuse)
ID_RG="${ID_RG:-x}"
UAI_NAME="${UAI_NAME:-x}"

# Storage for Splunk App Framework (create/reuse)
APP_STORAGE_RG="${APP_STORAGE_RG:-x}"
APP_STORAGE_ACCOUNT="${APP_STORAGE_ACCOUNT:-x}"   # DNS prefix only; endpoint becomes https://$APP_STORAGE_ACCOUNT.$APP_STORAGE_ENDPOINT_SUFFIX

# Containers + prefixes (directory-like) for app repos
APP_CONTAINER_CM="${APP_CONTAINER_CM:-custom-apps}"
APP_PREFIX_CM="${APP_PREFIX_CM:-indexer}"           # creates indexer/apps-idx-cluster and indexer/apps-cm-admin
APP_CONTAINER_SHC="${APP_CONTAINER_SHC:-custom-apps}"
APP_PREFIX_SHC="${APP_PREFIX_SHC:-searchhead}"      # creates searchhead/apps-sh-admin

# Helm bits
HELM_RELEASE="${HELM_RELEASE:-splunk-c3}"
HELM_REPO_NAME="${HELM_REPO_NAME:-splunk}"
HELM_REPO_URL="${HELM_REPO_URL:-https://splunk.github.io/splunk-operator}"
HELM_CHART="${HELM_CHART:-splunk/splunk-enterprise}"
HELM_CHART_VERSION="${HELM_CHART_VERSION:-3.0.0}"   # set "" to use latest from repo
HELM_SKIP_REPO_UPDATE="${HELM_SKIP_REPO_UPDATE:-false}"

# Images (override as needed)
SPLUNK_IMAGE="${SPLUNK_IMAGE:-x/splunk/splunk:9.4.5}" # update with your Azure Container Registry URL
OPERATOR_IMAGE="${OPERATOR_IMAGE:-x/splunk/splunk-operator:3.0.0}" # update with your Azure Container Registry URL

# Output values.yaml
VALUES_FILE="${VALUES_FILE:-$(pwd)/values-azure.yaml}"

# Cleanup toggles for "delete" action
DELETE_NAMESPACE="${DELETE_NAMESPACE:-false}"
DELETE_STORAGE_ACCOUNT="${DELETE_STORAGE_ACCOUNT:-false}"
DELETE_UAI="${DELETE_UAI:-false}"
DELETE_CRDS="${DELETE_CRDS:-false}"
DRY_RUN="${DRY_RUN:-false}"

# -------------------------
# Preflight
# -------------------------
need az; need kubectl; need helm; need sed
az account show >/dev/null 2>&1 || { err "Azure CLI not logged in. Run: az login"; exit 1; }
if [[ -n "${SUB}" ]]; then az account set -s "$SUB" >/dev/null; fi
SUB="$(az account show --query id -o tsv)"
CLOUD_ENV=$(az account show --query "environmentName" -o tsv)
STORAGE_ENDPOINT=$(az cloud show -n ${CLOUD_ENV} --query "suffixes.storageEndpoint" -o tsv)

# -------------------------
# Azure helpers
# -------------------------
ensure_rg() { if az group show -n "$1" >/dev/null 2>&1; then ok "RG '$1' exists"; else log "Creating RG '$1' in '$2'"; az group create -n "$1" -l "$2" >/dev/null; ok "Created RG '$1'"; fi; }
ensure_namespace() { if kubectl get ns "$1" >/dev/null 2>&1; then ok "Namespace '$1' exists"; else log "Creating namespace '$1'"; kubectl create ns "$1" >/dev/null; ok "Created namespace '$1'"; fi; }
get_aks_oidc_issuer() { az aks show -g "$CLUSTER_RG" -n "$CLUSTER_NAME" --query 'oidcIssuerProfile.issuerUrl' -o tsv 2>/dev/null || true; }
ensure_aks_oidc_wi() { log "Ensuring AKS OIDC issuer + Workload Identity"; local issuer; issuer="$(get_aks_oidc_issuer)"; if [[ -z "$issuer" || "$issuer" == "null" ]]; then az aks update -g "$CLUSTER_RG" -n "$CLUSTER_NAME" --enable-oidc-issuer --enable-workload-identity >/dev/null; issuer="$(retry 10 6 get_aks_oidc_issuer)"; fi; [[ -z "$issuer" || "$issuer" == "null" ]] && { err "Failed to enable OIDC issuer"; exit 1; }; printf "%s" "$issuer"; }
ensure_uai() { if az identity show -g "$ID_RG" -n "$UAI_NAME" >/dev/null 2>&1; then ok "UAMI '$UAI_NAME' exists"; else log "Creating UAMI '$UAI_NAME'"; az identity create -g "$ID_RG" -n "$UAI_NAME" >/dev/null; ok "Created UAMI '$UAI_NAME'"; fi; local cid pid; cid="$(retry 20 3 az identity show -g "$ID_RG" -n "$UAI_NAME" --query clientId -o tsv)"; pid="$(retry 20 3 az identity show -g "$ID_RG" -n "$UAI_NAME" --query principalId -o tsv)"; printf "%s|%s" "$cid" "$pid"; }
role_assignment_exists_by_oid() { az role assignment list --assignee-object-id "$1" --scope "$2" --role "$3" -o tsv | grep -q .; }
ensure_role_assignment() { local oid="$1" ptype="$2" role="$3" scope="$4"; if role_assignment_exists_by_oid "$oid" "$scope" "$role"; then ok "Role '$role' already assigned"; else log "Assigning '$role'"; retry 10 6 az role assignment create --assignee-object-id "$oid" --assignee-principal-type "$ptype" --role "$role" --scope "$scope" >/dev/null; ok "Assigned '$role'"; fi; }
fic_exists() { az identity federated-credential show --identity-name "$2" --resource-group "$1" --name "$3" >/dev/null 2>&1; }
ensure_federated_credential() {
  # args: <rg> <identity_name> <issuer_url> <subject> <fic_name>
  local rg="$1" id_name="$2" issuer_in="$3" subject="$4" name="$5"
  local issuer_exact="${issuer_in%/}/"           # ensures trailing slash
  if fic_exists "$rg" "$id_name" "$name"; then ok "FIC '$name' exists"; return 0; fi
  log "Creating FIC '$name' (issuer=$issuer_exact subject=$subject)"
  az identity federated-credential create \
    --identity-name "$id_name" --resource-group "$rg" --name "$name" \
    --issuer "$issuer_exact" --subject "$subject" \
    --audiences "api://AzureADTokenExchange" >/dev/null
  ok "Created FIC '$name'"
}

# -------------------------
# Storage helpers
# -------------------------
ensure_storage_account() {
  if az storage account show -g "$1" -n "$2" >/dev/null 2>&1; then ok "Storage '$2' exists"; else
    log "Creating storage '$2' in '$1' ($3)"
    az storage account create -g "$1" -n "$2" -l "$3" \
      --sku Standard_LRS --kind StorageV2 \
      --allow-blob-public-access false --min-tls-version TLS1_2 >/dev/null
    ok "Created storage '$2'"
  fi
}
ensure_container() { if az storage container show --account-name "$1" --name "$2" --auth-mode login >/dev/null 2>&1; then ok "Container '$2' exists"; else log "Creating container '$2'"; az storage container create --account-name "$1" --name "$2" --auth-mode login >/dev/null; ok "Created '$2'"; fi; }
upload_placeholder_blob() { local account="$1" container="$2" blob="$3"; local tmp; tmp="$(mktemp)"; printf "x" > "$tmp"; az storage blob upload --account-name "$account" -c "$container" -n "$blob" --auth-mode login --file "$tmp" --overwrite >/dev/null; rm -f "$tmp"; ok "Ensured '$container/$blob'"; }
ensure_prefix() { local account="$1" container="$2" prefix="$3"; [[ -z "$prefix" ]] && return 0; local blob="${prefix%/}/.keep"; if az storage blob show --account-name "$account" -c "$container" -n "$blob" --auth-mode login >/dev/null 2>&1; then ok "Prefix '$container/$prefix' exists"; else upload_placeholder_blob "$account" "$container" "$blob"; fi; }
ensure_app_locations() {
  ensure_storage_account "$APP_STORAGE_RG" "$APP_STORAGE_ACCOUNT" "$LOCATION"
  ensure_container "$APP_STORAGE_ACCOUNT" "$APP_CONTAINER_CM"
  ensure_container "$APP_STORAGE_ACCOUNT" "$APP_CONTAINER_SHC"
#  ensure_prefix "$APP_STORAGE_ACCOUNT" "$APP_CONTAINER_CM"  "${APP_PREFIX_CM:+${APP_PREFIX_CM%/}/}apps-idx-cluster"
#  ensure_prefix "$APP_STORAGE_ACCOUNT" "$APP_CONTAINER_CM"  "${APP_PREFIX_CM:+${APP_PREFIX_CM%/}/}apps-cm-admin"
#  ensure_prefix "$APP_STORAGE_ACCOUNT" "$APP_CONTAINER_SHC" "${APP_PREFIX_SHC:+${APP_PREFIX_SHC%/}/}apps-sh-admin"
}

# -------------------------
# Create Splunk Namespace if it doesn't exist
# -------------------------

echo "Running bootstrap requirements..."
echo "Checking if namespace '$NAMESPACE' exists..."
if kubectl get namespace "$NAMESPACE" &>/dev/null; then
    echo "✅ Namespace '$NAMESPACE' already exists."
else
    echo "Creating namespace '$NAMESPACE'..."
    kubectl create namespace "$NAMESPACE"
    echo "✅ Namespace '$NAMESPACE' created."
fi

# -------------------------
# Splunk Prerequisites, deploy CRDs and License ConfigMap
# -------------------------

echo "Deploying Splunk CRDs..."
kubectl apply -f https://github.com/splunk/splunk-operator/releases/download/3.0.0/splunk-operator-crds.yaml --server-side

# Creating the config map for heavy forwarder defaults
echo "Creating heavy forwarder ConfigMap"
SPLUNK_HF_CFM="splunk-hf-defaults.yaml"

cat > "$SPLUNK_HF_CFM" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: splunk-defaults
  namespace: $NAMESPACE
data:
  default.yml: |-
    splunk:
      conf:
        - key: outputs
          value:
            directory: /opt/splunk/etc/system/local
            content:
              tcpout:
                defaultGroup: idx_svc
                useACK: true
                indexAndForward: false   # HF parses, forwards only (no local copy)
                autoLBFrequency: 30
                compressed: true
              "tcpout:idx_svc":
                server: "splunk-idx-indexer-service.$NAMESPACE.svc.cluster.local:9997"
                sslVerifyServerCert: true
              "tcpout-server://splunk-idx-indexer-service.$NAMESPACE.svc.cluster.local:9997": {}
        - key: props
          value:
            directory: /opt/splunk/etc/system/local
            content:
              my_noisy_sourcetype:
                TRANSFORMS-null: drop_noise
              "host::db-*.example.com":
                TRANSFORMS-routing: to_idx_svc
        - key: transforms
          value:
            directory: /opt/splunk/etc/system/local
            content:
              drop_noise:
                REGEX: "DEBUG"
                DEST_KEY: queue
                FORMAT: nullQueue
              to_idx_svc:
                REGEX: "."
                DEST_KEY: _TCP_ROUTING
                FORMAT: idx_svc
EOF

echo "Applying heavy forwarder ConfigMap"
kubectl apply -f "$SPLUNK_HF_CFM"

echo "Heavy forwarder ConfigMap created..."

echo "Verifying Splunk CRDs..."
# List all CRDs and filter for Splunk
splunk_crds=$(kubectl get crds | grep splunk)

if [ -z "$splunk_crds" ]; then
    echo "❌ No Splunk CRDs found. Deployment may have failed."
    exit 1
else
    echo "✅ Splunk CRDs successfully deployed:"
    echo "$splunk_crds"
fi

# license ConfigMap (optional - drop your license here)

echo "Creating license ConfigMap file for bootstrap..."
LICENSE_FILE="splunk-license.yaml"

cat > "$LICENSE_FILE" <<EOF

apiVersion: v1
kind: ConfigMap
metadata:
  name: splunk-licenses
  namespace: $NAMESPACE
data:
  # The key below (enterprise.lic) will be the filename inside the mounted volume.
  # Ensure your Splunk Operator CR (LicenseManager, Standalone) references this filename
  # in its 'licenseUrl' (e.g., /mnt/licenses/enterprise.lic).
  enterprise.lic: |
    enterlicensekeyhere
EOF

echo "Applying license file"
kubectl apply -f "$LICENSE_FILE"

echo "Verifying Splunk License Manager..."
# List Config Maps and filter for Splunk
splunk_lm=$(kubectl get cm -A | grep splunk-licenses)

if [ -z "$splunk_lm" ]; then
    echo "❌ No Splunk License Manager found. Deployment may have failed."
    exit 1
else
    echo "✅ Splunk License Manager successfully deployed."
    echo "$splunk_lm"
fi

# -------------------------
# Helm helpers
# -------------------------
ensure_helm_repo() {
  if ! helm repo list | awk '{print $1}' | grep -qx "$HELM_REPO_NAME"; then
    helm repo add "$HELM_REPO_NAME" "$HELM_REPO_URL" >/dev/null
  fi
  if [[ "$HELM_SKIP_REPO_UPDATE" != "true" ]]; then helm repo update >/dev/null; fi
  ok "Helm repo ready"
}
helm_validate_render() {
  log "Validating 'helm template'"
  if [[ -n "$HELM_CHART_VERSION" ]]; then
    helm template "$HELM_RELEASE" "$HELM_CHART" -n "$NAMESPACE" -f "$1" --version "$HELM_CHART_VERSION" >/dev/null
  else
    helm template "$HELM_RELEASE" "$HELM_CHART" -n "$NAMESPACE" -f "$1" >/dev/null
  fi
  ok "Helm template OK"
}
helm_install_or_upgrade() {
  if helm -n "$NAMESPACE" status "$HELM_RELEASE" >/dev/null 2>&1; then
    log "Upgrading Helm release '$HELM_RELEASE'"
    if [[ -n "$HELM_CHART_VERSION" ]]; then
      helm upgrade "$HELM_RELEASE" "$HELM_CHART" -n "$NAMESPACE" -f "$1" --version "$HELM_CHART_VERSION"
    else
      helm upgrade "$HELM_RELEASE" "$HELM_CHART" -n "$NAMESPACE" -f "$1"
    fi
  else
    log "Installing Helm release '$HELM_RELEASE'"
    if [[ -n "$HELM_CHART_VERSION" ]]; then
      helm install "$HELM_RELEASE" "$HELM_CHART" -n "$NAMESPACE" --create-namespace -f "$1" --version "$HELM_CHART_VERSION"
    else
      helm install "$HELM_RELEASE" "$HELM_CHART" -n "$NAMESPACE" --create-namespace -f "$1"
    fi
  fi
  log "adding label to service account"
    kubectl label sa splunk-operator-controller-manager -n "$NAMESPACE" azure.workload.identity/use=true --overwrite
  ok "Helm action completed"
}
wait_for_operator_ready() {
  log "Waiting for operator rollout to complete"
  retry 40 6 kubectl -n "$NAMESPACE" rollout status deploy/splunk-operator-controller-manager --timeout=10s
  ok "Operator ready"
}

# -------------------------
# Values renderer (Workload Identity baked in)
# - Operator SA annotated with UAMI client-id
# - Operator pods labeled + annotated: azure.workload.identity/use: "true"
# - All Splunk CRs use same SA and include label + annotation on pods
# -------------------------
render_values_from_provided() {
  local outfile="$1" client_id="$2" endpoint="$3" cm_container="$4" cm_prefix="$5" shc_container="$6" shc_prefix="$7"
  local cm_path="$cm_container";  [[ -n "$cm_prefix" ]] && cm_path="${cm_path}/${cm_prefix}"
  local shc_path="$shc_container"; [[ -n "$shc_prefix" ]] && shc_path="${shc_path}/${shc_prefix}"

  cat > "$outfile" <<RAWYAML

# Install Splunk Operator and wire Azure Workload Identity
splunk-operator:
  enabled: true
  image:
    repository: ${SPLUNK_IMAGE}
  labels:
    azure.workload.identity/use: "true"
  splunkOperator:
    splunkGeneralTerms: "--accept-sgt-current-at-splunk-com"
    image:
      repository: ${OPERATOR_IMAGE}
      pullPolicy: IfNotPresent
    serviceAccount:
      create: true
      name: splunk-operator-controller-manager
    labels:
      azure.workload.identity/use: "true"
    annotations:
      azure.workload.identity/client-id: "${client_id}"
    # Your cluster's WI webhook matches on LABEL. Add both for clarity.
    podLabels:
      azure.workload.identity/use: "true"
    podAnnotations:
      azure.workload.identity/use: "true"

# C3 topology (Cluster Manager + Indexer Cluster + Search Head Cluster)
sva:
  c3:
    enabled: true
    indexerClusters:
      - name: idx
    searchHeadClusters:
      - name: sh
  
  s1:
    enabled: false

# Cluster Manager
clusterManager:
  enabled: true
  name: "cm"
  serviceAccountName: splunk-operator-controller-manager
  additionalLabels:
    azure.workload.identity/use: "true"
  additionalAnnotations:
    azure.workload.identity/use: "true"
  appRepo:
    appsRepoPollIntervalSeconds: 900
    defaults:
      volumeName: volume_app_repo_us
      scope: cluster
    appSources:
      - name: idxApps
        location: apps-idx-cluster/
      - name: cmAdminApps
        location: apps-cm-admin/
        scope: local
    volumes:
      - name: volume_app_repo_us
        storageType: blob
        provider: azure
        path: ${cm_path}/
        endpoint: "${endpoint}"
  startupProbe:
    initialDelaySeconds: 600
  etcVolumeStorageConfig:
    ephemeralStorage: false
    storageCapacity: 10Gi
    storageClassName: managed-premium
  varVolumeStorageConfig:
    ephemeralStorage: false
    storageCapacity: 100Gi
    storageClassName: managed-premium
  extraEnv:
    - name: NO_HEALTHCHECK
      value : "true"

# Indexer Cluster
indexerCluster:
  enabled: true
  name: "idx"
  replicaCount: 3
  serviceAccountName: splunk-operator-controller-manager
  additionalLabels:
    azure.workload.identity/use: "true"
  additionalAnnotations:
    azure.workload.identity/use: "true"
  etcVolumeStorageConfig:
    ephemeralStorage: false
    storageCapacity: 10Gi
    storageClassName: managed-premium
  varVolumeStorageConfig:
    ephemeralStorage: false
    storageCapacity: 9Ti
    storageClassName: managed-premium
  extraEnv:
    - name: NO_HEALTHCHECK
      value : "true"

# Search Head Cluster
searchHeadCluster:
  enabled: true
  name: "sh"
  replicaCount: 3
  serviceAccountName: splunk-operator-controller-manager
  additionalLabels:
    azure.workload.identity/use: "true"
  additionalAnnotations:
    azure.workload.identity/use: "true"
  etcVolumeStorageConfig:
    ephemeralStorage: false
    storageCapacity: 10Gi
    storageClassName: managed-premium
  varVolumeStorageConfig:
    ephemeralStorage: false
    storageCapacity: 9Ti
    storageClassName: managed-premium
  appRepo:
    appsRepoPollIntervalSeconds: 900
    defaults:
      volumeName: volume_app_repo_us
      scope: cluster
    appSources:
      - name: shcadminApps
        location: apps-sh-admin/
        scope: cluster
      - name: searchApps
        location: apps-sh-cluster/
        scope: cluster
    volumes:
      - name: volume_app_repo_us
        storageType: blob
        provider: azure
        path: ${shc_path}/
        endpoint: "${endpoint}"
  livenessInitialDelaySeconds: 900
  readinessInitialDelaySeconds: 60
  extraEnv:
    - name: NO_HEALTHCHECK
      value : "true"

standalone:
  enabled: true
  name: "hf"
  namespaceOverride: "splunk"
  additionalLabels:
    azure.workload.identity/use: "true"
  additionalAnnotations: 
    azure.workload.identity/use: "true"
  replicaCount: 1
  extraEnv:
    - name: NO_HEALTHCHECK
      value : "true"
  appRepo: 
    appsRepoPollIntervalSeconds: 600
    defaults:
      volumeName: volume_app_repo_us
      scope: local
    appSources:
      - name: hfApps # heavy forwarder apps only
        location: apps-hf/
    volumes:
      - name: volume_app_repo_us
        storageType: blob
        provider: azure
        path: ${shc_path}/
        endpoint: "${endpoint}"
    # smartstore: {}
    # defaults:
    #   volumeName:
    # indexes:
    #   - name:
    #     volumeName:
    #     remotePath:
    # volumes:
    #   - name:
    #     path:
    #     endpoint:
    #     secretRef:
  volumes:
    - name: defaults
      configMap:
        name: splunk-defaults
  defaultsUrl: /mnt/defaults/default.yml
  #- name: kv-secrets
  #  csi:
  #    driver: secrets-store.csi.k8s.io
  #    readOnly: true
  #    volumeAttributes:
  #     secretProviderClass: "azure-kv-spc"
  #extraVolumeMounts:
  #- name: kv-secrets
  #  mountPath: "/mnt/kv-secrets"
  #   readOnly: true

# Optional License Manager (drop your license via ConfigMap 'splunk-licenses')
licenseManager:
  enabled: true
  name: "lm"
  serviceAccountName: splunk-operator-controller-manager
  additionalLabels:
    azure.workload.identity/use: "true"
  additionalAnnotations:
    azure.workload.identity/use: "true"
  volumes:
    - name: licenses
      configMap:
        name: splunk-licenses
  licenseUrl: /mnt/licenses/enterprise.lic
RAWYAML
}

# -------------------------
# Cleanup helpers
# -------------------------
run_or_echo() { if [[ "$DRY_RUN" == "true" ]]; then echo "DRY_RUN: $*"; else eval "$@"; fi; }
role_assignment_id_by_oid() { az role assignment list --assignee-object-id "$1" --scope "$2" --role "$3" --query '[0].id' -o tsv 2>/dev/null || true; }
delete_role_assignment_if_exists() { local rid; rid="$(role_assignment_id_by_oid "$1" "$2" "$3")"; if [[ -n "$rid" && "$rid" != "null" ]]; then log "Deleting role assignment '$3'"; run_or_echo az role assignment delete --ids "$rid"; ok "Deleted role assignment"; else ok "Role assignment not present"; fi; }
delete_federated_credential_if_exists() { if az identity federated-credential show --identity-name "$2" --resource-group "$1" --name "$3" >/dev/null 2>&1; then log "Deleting FIC '$3'"; run_or_echo az identity federated-credential delete --identity-name "$2" --resource-group "$1" --name "$3"; ok "Deleted FIC '$3'"; else ok "FIC '$3' not present"; fi; }
delete_storage_account_if_requested() { if [[ "$DELETE_STORAGE_ACCOUNT" != "true" ]]; then ok "Skipping storage delete (set DELETE_STORAGE_ACCOUNT=true)"; return 0; fi; if az storage account show -g "$1" -n "$2" >/dev/null 2>&1; then log "Deleting storage '$2'"; run_or_echo az storage account delete -g "$1" -n "$2" --yes; ok "Deleted storage '$2'"; else ok "Storage '$2' not present"; fi; }
delete_namespace_if_requested() { if [[ "$DELETE_NAMESPACE" != "true" ]]; then ok "Skipping namespace delete (set DELETE_NAMESPACE=true)"; return 0; fi; if kubectl get ns "$1" >/dev/null 2>&1; then log "Deleting namespace '$1'"; run_or_echo kubectl delete ns "$1" --wait=true; ok "Deleted namespace '$1'"; else ok "Namespace '$1' not present"; fi; }
delete_uai_if_requested() { if [[ "$DELETE_UAI" != "true" ]]; then ok "Skipping UAMI delete (set DELETE_UAI=true)"; return 0; fi; if az identity show -g "$1" -n "$2" >/dev/null 2>&1; then log "Deleting UAMI '$2'"; run_or_echo az identity delete -g "$1" -n "$2"; ok "Deleted UAMI '$2'"; else ok "UAMI '$2' not present"; fi; }
delete_crds_if_requested() {
  if [[ "$DELETE_CRDS" != "true" ]]; then ok "Skipping CRD delete (set DELETE_CRDS=true)"; return 0; fi
  for crd in clustermanagers.enterprise.splunk.com indexerclusters.enterprise.splunk.com searchheadclusters.enterprise.splunk.com ; do
    if kubectl get crd "$crd" >/dev/null 2>&1; then log "Deleting CRD $crd"; run_or_echo kubectl delete crd "$crd"; fi
  done
  ok "CRD cleanup attempted"
}
cleanup_everything() {
  log "Cleanup starting"
  if helm -n "$NAMESPACE" status "$HELM_RELEASE" >/dev/null 2>&1; then
    log "Uninstalling Helm release '$HELM_RELEASE'"; run_or_echo helm uninstall "$HELM_RELEASE" -n "$NAMESPACE"; ok "Helm release uninstalled"
  else
    ok "Helm release '$HELM_RELEASE' not present"
  fi
  delete_crds_if_requested
  delete_federated_credential_if_exists "$ID_RG" "$UAI_NAME" "splunk-operator-fic"
  APP_SCOPE="/subscriptions/${SUB}/resourceGroups/${APP_STORAGE_RG}/providers/Microsoft.Storage/storageAccounts/${APP_STORAGE_ACCOUNT}"
  if az identity show -g "$ID_RG" -n "$UAI_NAME" >/dev/null 2>&1; then
    UAI_PRINCIPAL_ID="$(az identity show -g "$ID_RG" -n "$UAI_NAME" --query principalId -o tsv)"
    delete_role_assignment_if_exists "$UAI_PRINCIPAL_ID" "$APP_SCOPE" "Storage Blob Data Reader"
  else
    ok "UAMI not found, skipping role removal"
  fi
  delete_namespace_if_requested "$NAMESPACE"
  delete_storage_account_if_requested "$APP_STORAGE_RG" "$APP_STORAGE_ACCOUNT"
  delete_uai_if_requested "$ID_RG" "$UAI_NAME"
  ok "Cleanup completed"
}

# -------------------------
# Main
# -------------------------
ACTION="${1:-apply}"
if [[ "$ACTION" == "delete" ]]; then cleanup_everything; exit 0; fi

# 0) Ensure infra containers exist
log "Step 0 - Ensure identity resource group"
ensure_rg "$ID_RG" "$LOCATION"
log "Step 1 - Ensure namespace"
ensure_namespace "$NAMESPACE"

# 2) Enable AKS OIDC + WI
log "Step 2 - Enable AKS OIDC + Workload Identity"
AKS_OIDC_ISSUER="$(ensure_aks_oidc_wi)"
AKS_OIDC_ISSUER="${AKS_OIDC_ISSUER%/}"
ok "AKS OIDC issuer: $AKS_OIDC_ISSUER"

# 3) UAMI
log "Step 3 - Ensure UAMI"
UAI_IDS="$(ensure_uai)"; UAI_CLIENT_ID="${UAI_IDS%%|*}"; UAI_PRINCIPAL_ID="${UAI_IDS#*|}"
[[ ! "$UAI_CLIENT_ID" =~ ^[0-9a-fA-F-]{8}-[0-9a-fA-F-]{4}-[0-9a-fA-F-]{4}-[0-9a-fA-F-]{4}-[0-9a-fA-F-]{12}$ ]] && { err "UAMI clientId looks wrong: '$UAI_CLIENT_ID'"; exit 1; }
ok "UAMI clientId=$UAI_CLIENT_ID principalId=$UAI_PRINCIPAL_ID"

# 4) Storage RBAC
log "Step 4 - Grant Storage Blob Data Reader"
APP_SCOPE="/subscriptions/${SUB}/resourceGroups/${APP_STORAGE_RG}/providers/Microsoft.Storage/storageAccounts/${APP_STORAGE_ACCOUNT}"
ensure_role_assignment "$UAI_PRINCIPAL_ID" "ServicePrincipal" "Storage Blob Data Reader" "$APP_SCOPE"

# 5) Storage structure
log "Step 5 - Ensure storage containers and prefixes"
ensure_app_locations
APP_ENDPOINT="https://${APP_STORAGE_ACCOUNT}.${STORAGE_ENDPOINT}"

# 6) Federated Identity Credential for operator SA subject
log "Step 6 - Ensure Federated Identity Credential"
SUBJECT="system:serviceaccount:${NAMESPACE}:splunk-operator-controller-manager"
ensure_federated_credential "$ID_RG" "$UAI_NAME" "$AKS_OIDC_ISSUER" "$SUBJECT" "splunk-operator-fic"

# 7) Render values.yaml with WI label+annotation and shared SA
log "Step 7 - Render Helm values"
render_values_from_provided "$VALUES_FILE" "$UAI_CLIENT_ID" "$APP_ENDPOINT" "$APP_CONTAINER_CM" "$APP_PREFIX_CM" "$APP_CONTAINER_SHC" "$APP_PREFIX_SHC"
ok "Rendered: $VALUES_FILE"

# 8) Helm repo
log "Step 8 - Helm repo"
ensure_helm_repo

# 9) Validate templates
log "Step 9 - Validate helm template"
helm_validate_render "$VALUES_FILE"

# 10) Install/upgrade
log "Step 10 - Helm install/upgrade"
helm_install_or_upgrade "$VALUES_FILE"

# 11) Wait for operator rollout
log "Step 11 - Wait for operator readiness"
wait_for_operator_ready

# Summary
echo
echo "================ Summary ================"
echo "Subscription:             $SUB"
echo "Cluster RG, Name:         $CLUSTER_RG, $CLUSTER_NAME"
echo "OIDC Issuer:              $AKS_OIDC_ISSUER"
echo "UAMI ClientId:            $UAI_CLIENT_ID"
echo "Namespace:                $NAMESPACE"
echo "Helm Release:             $HELM_RELEASE"
echo "Values file:              $VALUES_FILE"
echo "Blob endpoint:            $APP_ENDPOINT"
echo "Namespace:                $NAMESPACE"
echo "License ConfigMap:        $LICENSE_FILE"
echo "Heavy Fwdr ConfigMap:     $SPLUNK_HF_CFM"
echo
echo "App Framework paths ensured:"
echo "  - ${APP_CONTAINER_CM}/${APP_PREFIX_CM:+${APP_PREFIX_CM}/}apps-idx-cluster/"
echo "  - ${APP_CONTAINER_CM}/${APP_PREFIX_CM:+${APP_PREFIX_CM}/}apps-cm-admin/"
echo "  - ${APP_CONTAINER_SHC}/${APP_PREFIX_SHC:+${APP_PREFIX_SHC}/}apps-sh-admin/"
echo
echo "All Splunk CRs use SA: splunk-operator-controller-manager"
echo "C3 topology: cm, idx, sh"
echo "Standalone HF: heavy-forwarder deployed"
echo "========================================"
echo
ok "Done"
