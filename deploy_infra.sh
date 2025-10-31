#!/usr/bin/env bash

#============================================================
# Title: Deploy Private AKS Cluster Infrastructure
#============================================================
# Infrastructure Deployment Script at Azure Subscription Scope to
# build out the necessary resources for an AKS Private Cluster with CMK, UAMI, Key Vault, and Storage Account.
# You will be prompted to create or use existing resources as needed.
# Prerequisites:
#   - Azure CLI installed
#   - Sufficient permissions to create resources and assign roles
#   - Ensure you can run bash scripts on your system
#   - vNet in your subscription and Bastion for connection to the jumpboxes
#============================================================

set -e

# --- DEFAULT VARIABLES ---
SPLUNK_IMAGE="${SPLUNK_IMAGE:-docker.io/splunk/splunk:9.4.5}"
OPERATOR_IMAGE="${OPERATOR_IMAGE:-docker.io/splunk/splunk-operator:3.0.0}"
MY_IP=$(curl -s https://ifconfig.me | awk '{print $1}')
RAND_SUFFIX=$(openssl rand -hex 5)

# Extract the part after the registry (e.g. "splunk/splunk:9.4.5" or "splunk/splunk-operator:3.0.0")
SPLUNK_TAG="${SPLUNK_IMAGE#*/}"  # Removes first part before first "/"
OPERATOR_TAG="${OPERATOR_IMAGE#*/}"  # Removes first part before first "/"


echo "----------------------------------------------"
echo " Azure Subscription Deployment Script"
echo "----------------------------------------------"

# --- SELECT AZURE CLOUD ---
echo "Select your Azure environment:"
select CLOUD_ENV in "AzureCloud" "AzureUSGovernment"; do
  case $CLOUD_ENV in
    AzureCloud|AzureUSGovernment)
      echo "Setting Azure cloud to: $CLOUD_ENV"
      az cloud set --name "$CLOUD_ENV"
      break
      ;;
    *)
      echo "Invalid selection. Please choose 1 or 2."
      ;;
  esac
done
echo

# --- LOGIN CHECK ---
if ! az account show &>/dev/null; then
  echo "You are not logged in. Launching az login..."
  az login --use-device-code >/dev/null
  echo "✅ Login successful."
fi

# --- GET CURRENT SUBSCRIPTION ---
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
SUBSCRIPTION_NAME=$(az account show --query name -o tsv)
echo "Using current subscription:"
echo "  Name: $SUBSCRIPTION_NAME"
echo "  ID:   $SUBSCRIPTION_ID"
echo

# --- SELECT LOCATION ---
echo "Available Azure regions:"
az account list-locations --query "sort_by([].{Name:name, DisplayName:displayName}, &Name)" -o table
echo
read -rp "Enter the Azure region for deployment (e.g., eastus, westus or usgovirginia): " LOCATION
while [[ -z "$LOCATION" ]]; do
  read -rp "Location cannot be empty. Please enter a valid Azure region: " LOCATION
done
echo "Selected location: $LOCATION"
echo

# --- CREATE OR USE EXISTING RESOURCE GROUP ---
while true; do
  read -rp "Do you want to create a new Resource Group for shared services, KV, Storage, UAMI? (y/n): " CREATE_RG
  # normalize to single lowercase char, trim whitespace
  CREATE_RG=$(echo "$CREATE_RG" | tr '[:upper:]' '[:lower:]')           # convert to lowercase
  CREATE_RG="${CREATE_RG%%+([[:space:]])}" # no-op if no extglob; safe fallback
  # Accept only y or n
  if [[ "$CREATE_RG" =~ ^[yn]$ ]]; then
    break
  else
    echo "Please answer 'y' or 'n'."
  fi
done

  if [[ "$CREATE_RG" == "y" ]]; then
    echo
    read -rp "Enter new Resource Group name (e.g., myresourcegroup-rg): " RESOURCE_GROUP
    while [[ -z "$RESOURCE_GROUP" ]]; do
      read -rp "Resource group name cannot be empty. Please enter a name: " RESOURCE_GROUP
    done

  echo "Creating resource group '$RESOURCE_GROUP' in '$LOCATION'..."
  az group create -n "$RESOURCE_GROUP" -l "$LOCATION" >/dev/null
  echo "✅ Resource group created."

    else
      echo
      read -rp "Enter existing Resource Group name where your KV, Storage Account and UAMI exist: " RESOURCE_GROUP
      while [[ -z "$RESOURCE_GROUP" ]]; do
        read -rp "Resource Group name cannot be empty. Enter existing Resource Group name: " RESOURCE_GROUP
      done
    fi

    if ! az group show -n "$RESOURCE_GROUP" &>/dev/null; then
      echo "❌ Resource Group '$RESOURCE_GROUP' not found. Please verify and rerun the script."
      exit 1
    fi

  LOCATION=$(az group show -n "$RESOURCE_GROUP" --query "location" -o tsv)
  echo "✅ Using existing Resource Group: $RESOURCE_GROUP (location: $LOCATION)"

# --- DEPLOY OR USE EXISTING KEY VAULT + STORAGE ACCOUNT ---
read -p "Do you want to deploy a Key Vault and Storage Account before the ARM template? (y/n): " CREATE_PREDEPLOY

if [[ "$CREATE_PREDEPLOY" =~ ^[Yy]$ ]]; then
  echo
  read -rp "Enter Key Vault name (must be globally unique): " KV_NAME
  read -rp "Enter Storage Account name (must be globally unique, 3-24 lowercase letters/numbers): " SA_NAME

  # Append it to the KV name (make sure to stay under Azure's 24-char limit for KV names)
  KV_NAME="${KV_NAME}${RAND_SUFFIX}"

  echo "Creating Key Vault '$KV_NAME'..."
  az keyvault create \
    -n "$KV_NAME" \
    -g "$RESOURCE_GROUP" \
    -l "$LOCATION" \
    >/dev/null
  echo "✅ Key Vault created."

  # Append it to the SA name (make sure to stay under Azure's 24-char limit for SA names)
  SA_NAME="${SA_NAME}${RAND_SUFFIX}"

  echo "Creating Storage Account '$SA_NAME'..."
  az storage account create \
    -n "$SA_NAME" \
    -g "$RESOURCE_GROUP" \
    -l "$LOCATION" \
    --min-tls-version TLS1_2 \
    --allow-blob-public-access false \
    >/dev/null
  echo "✅ Storage Account created."

else
  echo
  echo "ℹ️ Skipping deployment of new Key Vault and Storage Account."
  echo "You will need to provide existing resource names."

  # --- PROMPT FOR EXISTING RESOURCES ---
  read -rp "Enter existing Key Vault name: " KV_NAME
  while [[ -z "$KV_NAME" ]]; do
    read -rp "Key Vault name cannot be empty. Enter existing Key Vault name: " KV_NAME
  done

  read -rp "Enter existing Storage Account name: " SA_NAME
  while [[ -z "$SA_NAME" ]]; do
    read -rp "Storage Account name cannot be empty. Enter existing Storage Account name: " SA_NAME
  done

  # --- VALIDATE EXISTENCE ---
  if ! az keyvault show -n "$KV_NAME" &>/dev/null; then
    echo "❌ Key Vault '$KV_NAME' not found. Please verify the name and rerun the script."
    exit 1
  fi

  if ! az storage account show -n "$SA_NAME" &>/dev/null; then
    echo "❌ Storage Account '$SA_NAME' not found. Please verify the name and rerun the script."
    exit 1
  fi

  echo "✅ Using existing Key Vault: $KV_NAME"
  echo "✅ Using existing Storage Account: $SA_NAME"
fi

  # --- CREATE USER-ASSIGNED MANAGED IDENTITY, ASSIGN ROLES ---
  echo
    # --- CREATE OR USE EXISTING USER-ASSIGNED MANAGED IDENTITY ---
    read -p "Do you want to create a new User-Assigned Managed Identity (UAMI)? (y/n): " CREATE_UAMI

    if [[ "$CREATE_UAMI" =~ ^[Yy]$ ]]; then
    echo
    read -rp "Enter a name for the new UAMI: " UAMI_NAME
    while [[ -z "$UAMI_NAME" ]]; do
        read -rp "UAMI name cannot be empty. Please enter a name: " UAMI_NAME
    done

    echo "Creating User-Assigned Managed Identity '$UAMI_NAME'..."
    az identity create \
        -n "$UAMI_NAME" \
        -g "$RESOURCE_GROUP" \
        -l "$LOCATION" \
        >/dev/null
    echo "✅ UAMI '$UAMI_NAME' created."

    else
    echo
    read -rp "Enter existing UAMI name: " UAMI_NAME
    while [[ -z "$UAMI_NAME" ]]; do
        read -rp "UAMI name cannot be empty. Please enter existing UAMI name: " UAMI_NAME
    done

    # Validate existence and get details
    if ! az identity show -n "$UAMI_NAME" -g "$RESOURCE_GROUP" &>/dev/null; then
        echo "❌ UAMI '$UAMI_NAME' not found in resource group '$RESOURCE_GROUP'. Please verify and rerun the script."
        exit 1
    fi

    echo "✅ Using existing UAMI '$UAMI_NAME'."
    fi

    # --- GET UAMI DETAILS ---
    UAMI_ID=$(az identity show -n "$UAMI_NAME" -g "$RESOURCE_GROUP" --query id -o tsv)
    UAMI_PRINCIPAL_ID=$(az identity show -n "$UAMI_NAME" -g "$RESOURCE_GROUP" --query principalId -o tsv)
    echo "  ↳ Resource ID:   $UAMI_ID"
    echo "  ↳ Principal ID:  $UAMI_PRINCIPAL_ID"

    # --- GET RESOURCE IDs ---
    STORAGE_ACCOUNT_ID=$(az storage account show -n "$SA_NAME" -g "$RESOURCE_GROUP" --query "id" -o tsv)
    KEYVAULT_ID=$(az keyvault show -n "$KV_NAME" -g "$RESOURCE_GROUP" --query "id" -o tsv)

    # Get your current user principal ID
    DEPLOYER_PRINCIPAL_ID=$(az ad signed-in-user show --query id -o tsv)

    # Assign Key Vault Crypto Officer role to Key Vault management for current signed in user
    az role assignment create \
        --assignee "$DEPLOYER_PRINCIPAL_ID" \
        --role "Key Vault Crypto Officer" \
        --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.KeyVault/vaults/$KV_NAME"
    
    # --- VALIDATE ROLE ASSIGNMENT ---
    echo "Validating role assignment propagation...This can take up to 5 minutes."
    MAX_WAIT=300  # seconds
    INTERVAL=10   # seconds
    ELAPSED=0

    while true; do
        ASSIGNED=$(az role assignment list \
            --assignee "$DEPLOYER_PRINCIPAL_ID" \
            --role "Key Vault Crypto Officer" \
            --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.KeyVault/vaults/$KV_NAME" \
            --query "length([])" -o tsv)

        if [[ "$ASSIGNED" -gt 0 ]]; then
            echo "✅ Role assignment confirmed."
            break
        fi

        if [[ "$ELAPSED" -ge "$MAX_WAIT" ]]; then
            echo "❌ Timeout waiting for role assignment to propagate."
            exit 1
        fi

        echo "Waiting for role assignment to propagate... ($ELAPSED/$MAX_WAIT seconds)"
        sleep "$INTERVAL"
        ELAPSED=$((ELAPSED + INTERVAL))
    done
    
    echo "  ✅ Assigned 'Key Vault Crypto Officer' to deployer for key creation."

    echo "Assigning roles to the UAMI..."
    # --- STORAGE ROLE ---
    az role assignment create \
      --assignee "$UAMI_PRINCIPAL_ID" \
      --role "Storage Blob Data Reader" \
      --scope "$STORAGE_ACCOUNT_ID" >/dev/null
    echo "  ✅ Assigned 'Storage Blob Data Reader' on $SA_NAME"

    # --- KEY VAULT ROLES ---
    for role in "Key Vault Certificate User" "Key Vault Crypto User" "Key Vault Secrets User"; do
      az role assignment create \
        --assignee "$UAMI_PRINCIPAL_ID" \
        --role "$role" \
        --scope "$KEYVAULT_ID" >/dev/null
      echo "  ✅ Assigned '$role' on $KV_NAME"
    done

    # --- MANAGED IDENTITY OPERATOR ROLE ---
    az role assignment create \
      --assignee "$UAMI_PRINCIPAL_ID" \
      --role "Managed Identity Operator" \
      --scope "/subscriptions/$SUBSCRIPTION_ID" >/dev/null
    echo "  ✅ Assigned 'Managed Identity Operator' at subscription level"

    # --- CREATE KEY IN KEYVAULT ---
    echo "Creating Key 'aks-cmk' in Key Vault '$KV_NAME'..."
    az keyvault key create --vault-name "$KV_NAME" -n aks-cmk >/dev/null
    echo "  ✅ Key 'aks-cmk' created in Key Vault '$KV_NAME'"

# --- GET PARAMETERS FOR ARM TEMPLATE ---
    CREATED_BY=$(az ad signed-in-user show --query displayName -o tsv)
    
    # Capture ProjectName from user
    read -rp "Enter your project Name for this deployment, lower case, no spaces or special characters, min 5 characters: " PROJECT_NAME
    while [[ -z "$PROJECT_NAME" ]]; do
      read -rp "Project Name cannot be empty. Please enter your project Name: " PROJECT_NAME
    done

    # List all vNets in the subscription that are bound to the location specified
    echo "Existing vNets in location '$LOCATION':"
    VNET_LIST=$(az network vnet list --query "[?location=='$LOCATION'].{Name:name, ResourceGroup:resourceGroup}" -o table)
    echo "vNets that you can use for your AKS Private Cluster based in the location $LOCATION:"
    echo "$VNET_LIST"

    # vNet name for your AKS Private Cluster
    read -rp "Enter the name of your existing VNet (e.g., vnet1): " existingVNETName
    while [[ -z "$existingVNETName" ]]; do
      read -rp "VNet name cannot be empty. Please enter your existing VNet name: " existingVNETName
    done

    # Get vNet Resource Group name for your AKS Private Cluster
    existingVnetResourceGroup=$(az network vnet list --query "[?name=='$existingVNETName'].resourceGroup" -o tsv)
    echo "Using VNet Resource Group: $existingVnetResourceGroup"

    # Get the subnet list for the existing vNet
    SUBNET_LIST=$(az network vnet list --query "[?name=='$existingVNETName'].subnets[].{Name:name, Address:addressPrefix}" -o table)
    echo "Existing subnets in VNet '$existingVNETName':"
    echo "$SUBNET_LIST"

    # Enter the IP Address prefix for the deployed subnet
    read -rp "Enter the IP Address prefix for the new subnet (e.g., 10.0.0.0) the template will add a /27 to the appendix: " SUBNET_PREFIX
    while [[ -z "$SUBNET_PREFIX" ]]; do
      read -rp "Subnet prefix cannot be empty. Please enter the IP Address prefix: " SUBNET_PREFIX
    done

    # Capture Admin User Name from user
    read -rp "Enter an admin user name for the jumpbox (1-20 characters): " ADMIN_NAME
    while [[ -z "$ADMIN_NAME" || ${#ADMIN_NAME} -lt 1 || ${#ADMIN_NAME} -gt 20 ]]; do
      read -rp "Admin user name must be between 1 and 20 characters. Please enter a valid admin user name: " ADMIN_NAME
    done

    # Capture Admin Password from user
    read -rsp "Enter an admin password for the jumpbox (at least 12 characters): " ADMIN_PASSWORD
    echo
    while [[ -z "$ADMIN_PASSWORD" || ${#ADMIN_PASSWORD} -lt 12 ]]; do
      read -rsp "Admin password must be at least 12 characters. Please enter a valid admin password: " ADMIN_PASSWORD
      echo
    done
    
    # Enter the Entra group ID that will be used for AKS Admins
    read -rp "Enter the Entra ID Group Object ID for AKS Admins (e.g., 558a10de-c70a-43fd-9400-0d56c0d49a2c): " ADMIN_GROUP_ID
    while [[ -z "$ADMIN_GROUP_ID" ]]; do
      read -rp "Entra ID Group Object ID cannot be empty. Please enter the Group Object ID: " ADMIN_GROUP_ID
    done 

    # Enter the Cost Center tag value
    read -rp "Enter your Cost Center (e.g., 12345, leave blank for n/a): " COST_CENTER
    COST_CENTER=${COST_CENTER:-n/a}
    echo "Cost Center set to: $COST_CENTER"

    # Enter the Environment tag value
    read -rp "Enter your Environment tag value (e.g., Dev, Test, Prod): " ENVIRONMENT
    ENVIRONMENT=${ENVIRONMENT:-n/a}
    echo "ENVIRONMENT set to: $ENVIRONMENT"


    echo "Getting parameters for ARM template..."
    echo "  ↳ Created By:           $CREATED_BY"
    echo "  ↳ Project Name:         $PROJECT_NAME"
    echo "  ↳ Location:             $LOCATION"
    echo "  ↳ vNet Name:            $existingVNETName"
    echo "  ↳ vNet RG:              $existingVnetResourceGroup"
    echo "  ↳ Subnet Prefix:        $SUBNET_PREFIX"
    echo "  ↳ Key Vault Name:       $KV_NAME"
    echo "  ↳ Storage Account:      $SA_NAME"
    echo "  ↳ UAMI Name:            $UAMI_NAME"
    echo "  ↳ Admin User Name:      $ADMIN_NAME"
    echo "  ↳ Admin Password:       (hidden)"
    echo "  ↳ Entra Admin Group ID: $ADMIN_GROUP_ID"    

  # --- FINAL CONFIRMATION BEFORE TEMPLATE DEPLOYMENT ---
  echo
  echo "----------------------------------------------"
  echo "✅ Prerequisite resources have been successfully deployed / verified and roles assigned:"
  echo "   - Resource Group: $RESOURCE_GROUP"
  echo "   - Key Vault: $KV_NAME"
  echo "    ↳ Key created in Key Vault: aks-cmk"
  echo "   - Storage Account: $SA_NAME"
  echo "   - UAMI: $UAMI_NAME"
  
  echo "----------------------------------------------"
  echo
  read -p "Proceed with ARM template deployment? (y/n): " CONFIRM_DEPLOY
  if [[ ! "$CONFIRM_DEPLOY" =~ ^[Yy]$ ]]; then
    echo "Deployment cancelled after prerequisites."
    exit 0
  fi

# --- GET TEMPLATE INFO ---
read -rp "Enter full path to ARM template file (.json): " TEMPLATE_FILE
while [[ ! -f "$TEMPLATE_FILE" ]]; do
  read -rp "Template file not found. Please enter a valid path: " TEMPLATE_FILE
done

read -rp "Enter full path to parameters file (.json) [Press Enter to skip, if you skip we will create based on your input]: " PARAM_FILE
if [[ -n "$PARAM_FILE" && ! -f "$PARAM_FILE" ]]; then
  echo "⚠️ Parameter file not found. Ignoring and deploying without parameters."
  PARAM_FILE=""
fi

read -rp "Enter a name for this deployment [Press Enter for default]: " DEPLOYMENT_NAME
DEPLOYMENT_NAME=${DEPLOYMENT_NAME:-sub-deploy-$(date +%Y%m%d%H%M%S)}

# --- SUMMARY ---
echo
echo "----------------------------------------------"
echo "Deployment Summary"
echo "----------------------------------------------"
echo "Cloud Environment: $CLOUD_ENV"
echo "Subscription:      $SUBSCRIPTION_NAME ($SUBSCRIPTION_ID)"
echo "Location:          $LOCATION"
echo "Resource Group:    $RESOURCE_GROUP"
if [[ "$CREATE_PREDEPLOY" =~ ^[Yy]$ ]]; then
  echo "Key Vault:         ${KV_NAME:-N/A}"
  echo "Storage Account:   ${SA_NAME:-N/A}"
  [[ "$CREATE_UAMI" =~ ^[Yy]$ ]] && echo "UAMI:              ${UAMI_NAME:-N/A}"
fi
echo "Template File:     $TEMPLATE_FILE"
[[ -n "$PARAM_FILE" ]] && echo "Parameters File:   $PARAM_FILE" || echo "Parameters File:   (none)"
echo "Deployment Name:   $DEPLOYMENT_NAME"
echo "----------------------------------------------"
echo

read -p "Confirm final deployment to subscription scope? (y/n): " CONFIRM_FINAL
if [[ ! "$CONFIRM_FINAL" =~ ^[Yy]$ ]]; then
  echo "Deployment cancelled."
  exit 0
fi

# --- GENERATE PARAMETERS FILE ---
echo
echo "----------------------------------------------"
echo "📄 Generating ARM parameters file: 1_aks.parameters.json"
echo "----------------------------------------------"

cat > infra.parameters.json <<EOF
{
    "\$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "location": { "value": "${LOCATION}" },
        "projectName": { "value": "${PROJECT_NAME}" },
        "createdbyTag": { "value": "${CREATED_BY}" },
        "costcenter": { "value": "${COST_CENTER}" },
        "Env": { "value": "${ENVIRONMENT}" },
        "adminUsername": {
            "metadata": { "description": "Admin username for the jumpboxes. Must be between 1 and 20 characters long." },
            "value": "$ADMIN_NAME"
        },
        "adminPassword": {
            "metadata": { "description": "Admin password for the jumpboxes. Must be at least 12 characters long and meet complexity requirements." },
            "value": "$ADMIN_PASSWORD"
        },
        "existingVNETName": {
            "metadata": { "description": "Name of the existing VNET" },
            "value": "$existingVNETName"
        },
        "existingVnetResourceGroup": {
            "metadata": { "description": "Resource Group of the existing VNET" },
            "value": "$existingVnetResourceGroup"
        },
        "newSubnetAddressPrefix": {
            "metadata": { "description": "Address prefix for the new Subnet. Must be a subset of the existing VNET address space. AKS will deploy /27 all you need is the x.x.x.0" },
            "value": "$SUBNET_PREFIX"
        },
        "kubernetes_version": {
            "metadata": { "description": "Kubernetes version for the AKS Cluster." },
            "value": "1.33.2"
        },
        "clusterDNSprefix": {
            "metadata": { "description": "Enter the DNS prefix for the AKS Cluster." },
            "value": "$PROJECT_NAME"
        },
        "keyVaultName": {
            "metadata": { "description": "Key Vault Name to store secrets" },
            "value": "$KV_NAME"
        },
        "keyName": {
            "metadata": { "description": "Key Vault Key Name to encrypt secrets" },
            "value": "aks-cmk"
        },
        "userAssignedID": {
            "metadata": { "description": "User Assigned Managed Identity Name" },
            "value": "$UAMI_NAME"
        },
        "userIDRGName": {
            "metadata": { "description": "User Assigned Managed Identity Resource Group Name" },
            "value": "$RESOURCE_GROUP"
        },
        "keyVaultAccess": {
            "metadata": { "description": "Enable Key Vault access via public endpoint or private endpoint" },
            "value": "Public"
        },
        "adminGroupObjectIDs": {
            "metadata": { "description": "Entra ID Group Object IDs that will be assigned as AKS Admins" },
            "value": "$ADMIN_GROUP_ID"
        },
        "myIP": {
            "metadata": { "description": "Your public IP address for the ACR firewall rules" },
            "value": "$MY_IP"
            }
    }
}
EOF

PARAM_FILE="$(pwd)/infra.parameters.json"

echo "----------------------------------------------"
echo "✅ Parameters file created: $PARAM_FILE"
echo "----------------------------------------------"
echo

# --- DEPLOY ARM TEMPLATE USING GENERATED PARAMETERS FILE ---
DEPLOYMENT_NAME="${PROJECT_NAME}-deploy-$(date +%Y%m%d%H%M)"
echo "Starting subscription-scope ARM deployment: $DEPLOYMENT_NAME"
az deployment sub create \
  --name "$DEPLOYMENT_NAME" \
  --location "$LOCATION" \
  --template-file "$TEMPLATE_FILE" \
  --parameters @"$PARAM_FILE"

echo "----------------------------------------------"
echo "✅ ARM deployment completed: $DEPLOYMENT_NAME"
echo "----------------------------------------------"

# Assign Network Contributor role to UAMI for AKS Ingress deployments
echo "Assigning network role to the UAMI for AKS Ingress deployments..."
    # --- NETWORK ROLE ---
    # Get subnet ID
    SUBNET_ID=$(az network vnet subnet show \
    -g "$existingVnetResourceGroup" \
    --vnet-name "$existingVNETName" \
    -n "${PROJECT_NAME}-aks-snet" \
    --query "id" -o tsv)

    # Assign role to the UAMI
    az role assignment create \
    --assignee "$UAMI_PRINCIPAL_ID" \
    --role "Network Contributor" \
    --scope "$SUBNET_ID"

    echo "----------------------------------------------"
    echo "  ✅ Assigned 'Network Contributor' on $PROJECT_NAME-aks-snet"
    echo "----------------------------------------------"

# Assign ACR Pull role to UAMI for AKS ACR access
echo "Assigning ACR Pull role to the UAMI for AKS ACR access..."
    # --- ACR PULL ROLE ---
    # Get ACR name
    ACR_NAME=$(az acr list -g "rg-$PROJECT_NAME" --query "[?starts_with(name, '${PROJECT_NAME}')].name" -o tsv)
    ACR_ID=$(az acr show -n "$ACR_NAME" -g "rg-$PROJECT_NAME" --query "id" -o tsv)

    # Assign ACR Pull role to the UAMI
    az role assignment create \
    --assignee "$UAMI_PRINCIPAL_ID" \
    --role "AcrPull" \
    --scope "$ACR_ID"

    echo "----------------------------------------------"
    echo "  ✅ Assigned 'AcrPull' on $ACR_NAME"
    echo "----------------------------------------------"

# Assign ACR Push and Pull role for current signed in user
echo "Assigning ACR Push role to the current user for AKS ACR access..."
    # --- ACR PUSH ROLE ---
    # Get current user principal ID
    CURRENT_USER_ID=$(az ad signed-in-user show --query id -o tsv)

    # Assign ACR Push role to the current user
    az role assignment create \
      --assignee "$CURRENT_USER_ID" \
      --role "AcrPush" \
      --scope "$ACR_ID"

    echo "----------------------------------------------"
    echo "  ✅ Assigned 'AcrPush' on $ACR_NAME to current user"
    echo "----------------------------------------------"

    # Assign ACR Pull role to the current user
    az role assignment create \
      --assignee "$CURRENT_USER_ID" \
      --role "AcrPull" \
      --scope "$ACR_ID"

    echo "----------------------------------------------"
    echo "  ✅ Assigned 'AcrPull' on $ACR_NAME to current user"
    echo "----------------------------------------------"

# ACR Push for Splunk Assets to Container Registry
echo "Pushing Splunk Operator container image to ACR..."
    az acr import \
      --name "$ACR_NAME" \
      --source $OPERATOR_IMAGE \
      --image $OPERATOR_TAG

    echo "----------------------------------------------"
    echo "  ✅ Splunk Operator container image ($OPERATOR_IMAGE) pushed to ACR: $ACR_NAME"
    echo "----------------------------------------------"

echo "Pushing Splunk container image to ACR..."
    az acr import \
      --name "$ACR_NAME" \
      --source $SPLUNK_IMAGE \
      --image $SPLUNK_TAG

    echo "----------------------------------------------"
    echo "  ✅ Splunk container image ($SPLUNK_IMAGE) pushed to ACR: $ACR_NAME"
    echo "----------------------------------------------"

# Waiting for 30 seconds to ensure ACR replication and RBAC propagation
echo "Waiting 30 seconds..."
sleep 30
echo "Done waiting."

# Output of container images pushed
echo "----------------------------------------------"
echo "Container images in ACR '$ACR_NAME':"
echo "----------------------------------------------"
  CONTAINER_IMAGES=$(az acr repository list --name "$ACR_NAME" --output tsv)
  echo "$CONTAINER_IMAGES"

echo "----------------------------------------------"
echo "✅ Deployment '$DEPLOYMENT_NAME' completed successfully at subscription scope."
echo "----------------------------------------------"