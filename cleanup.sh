#!/usr/bin/env bash

#============================================================
# Title: Delete all Splunk related resources
#============================================================
# Removes Splunk-C3 helm deployment
# Removes All CRDs
# Removes License configmap
# Removes Namespace
# Removes all PVCs in the namespace
#============================================================

set -euo pipefail

# Initialize status flags
HELM_UNINSTALLED=false
CRDS_REMOVED=false
CONFIGMAPS_REMOVED=false
PVCS_REMOVED=false
NAMESPACE_REMOVED=false

# Initial confirmation before cleanup
read -rp "WARNING: This will completely clean up the 'splunk' namespace including Helm releases, CRDs, configmaps, PVCs, and the namespace itself. Do you want to proceed? (y/N): " proceed
if [[ ! "$proceed" =~ ^[Yy]$ ]]; then
    echo "Cleanup aborted."
    exit 0
fi

# Get the first Helm release name in 'splunk' namespace
CHART_FULL=$(helm list -n splunk -o json | jq -r '.[0].name')

# Uninstall Splunk-C3 Helm deployment
echo "Uninstalling $CHART_FULL Helm deployment..."
if helm uninstall "$CHART_FULL" -n splunk; then
    HELM_UNINSTALLED=true
else
    echo "$CHART_FULL Helm deployment not found, skipping uninstall."
fi

# List CRDs containing 'splunk'
CRDS=$(kubectl get crd -o name | grep splunk || true)
if [[ -n "$CRDS" ]]; then
    echo "Removing CRDs containing 'splunk'..."
    kubectl delete $CRDS
    CRDS_REMOVED=true
else
    echo "No CRDs found containing 'splunk', skipping removal."
fi

# Remove all configmaps
echo "Removing all ConfigMaps..."
if kubectl delete configmap --all -n splunk; then
    CONFIGMAPS_REMOVED=true
else
    echo "ConfigMaps not found, skipping removal."
fi

# Prompt before removing all PVCs
read -rp "Are you sure you want to remove ALL PVCs in the 'splunk' namespace? (y/N): " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
    echo "Removing all PVCs in the namespace..."
    if kubectl delete pvc --all -n splunk; then
        PVCS_REMOVED=true
    else
        echo "No PVCs found, skipping removal."
    fi
else
    echo "Skipped PVC removal."
fi

# Remove Namespace
echo "Removing Namespace..."
if kubectl delete ns splunk; then
    NAMESPACE_REMOVED=true
else
    echo "Namespace not found, skipping removal."
fi

# -----------------------------
# Cleanup Summary
# -----------------------------
echo
echo "==== Cleanup Summary ===="
echo "Helm release uninstalled:         $HELM_UNINSTALLED - $CHART_FULL"
echo "CRDs removed:                     $CRDS_REMOVED"
echo "ConfigMaps removed:               $CONFIGMAPS_REMOVED"
echo "PVCs removed:                     $PVCS_REMOVED"
echo "Namespace removed:                $NAMESPACE_REMOVED - splunk"
echo "=========================="
