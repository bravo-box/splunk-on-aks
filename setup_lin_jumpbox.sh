#!/bin/bash
# Prep Ubuntu box with AzCli, Kubectl, Kubelogin, Go, Make, GH Cli and NetTools
# Works when downloaded from GitHub and run as: curl -sLO <url> && bash <script>

set -euo pipefail

LOGFILE="$HOME/provision.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "==== Starting Provisioning on $(date) ===="

# -----------------------------
# Update package index
# -----------------------------
echo "Updating package index..."
sudo apt update -y

# -----------------------------
# Install prerequisites
# -----------------------------
echo "Installing prerequisites..."
sudo apt-get install -y ca-certificates curl apt-transport-https lsb-release gnupg build-essential gcc make net-tools

# -----------------------------
# Add Microsoft’s GPG Key and Azure CLI repo
# -----------------------------
echo "Adding Microsoft GPG key..."
sudo mkdir -p /etc/apt/keyrings
curl -sSL https://packages.microsoft.com/keys/microsoft.asc -o /tmp/microsoft.asc
sudo gpg --dearmor --batch --yes -o /etc/apt/keyrings/microsoft.gpg /tmp/microsoft.asc
rm /tmp/microsoft.asc

echo "Adding Azure CLI repo..."
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ $(lsb_release -cs) main" \
    | sudo tee /etc/apt/sources.list.d/azure-cli.list

echo "Updating repositories..."
sudo apt-get update -y

# -----------------------------
# Install Azure CLI
# -----------------------------
echo "Installing Azure CLI..."
sudo apt-get install -y azure-cli
az version

# -----------------------------
# Install Go
# -----------------------------
echo "Installing Go..."
sudo apt install -y golang-go
go version

# -----------------------------
# Verify Make
# -----------------------------
echo "Verifying Make..."
make --version

# -----------------------------
# Install kubectl
# -----------------------------
echo "Installing kubectl..."

# Update system packages
sudo apt-get update

# Install dependencies for apt repo
sudo apt-get install -y apt-transport-https ca-certificates curl

# Download and install the GPG key
sudo mkdir -p /etc/apt/keyrings
sudo rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | \
  sudo gpg --dearmor --yes --batch -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Add Kubernetes APT repo
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list

# Update again and install kubectl
sudo apt-get update
sudo apt-get install -y kubectl

# -----------------------------
# Install Kubelogin
# -----------------------------
echo "Installing kubelogin..."
# Download the latest release of kubelogin
curl -sL https://github.com/Azure/kubelogin/releases/latest/download/kubelogin-linux-amd64.zip -o /tmp/kubelogin.zip && \
sudo apt install -y unzip && \
unzip -o /tmp/kubelogin.zip -d /tmp && \
sudo mv /tmp/bin/linux_amd64/kubelogin /usr/local/bin/ && \
sudo chmod +x /usr/local/bin/kubelogin && \
rm -rf /tmp/kubelogin.zip /tmp/bin && \
kubelogin --version

# -----------------------------
# Install Helm
# -----------------------------
echo "Installing Helm..."

 curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Verify
helm version

# Update again and install GH CLI
echo "Installing GitHub CLI..."
sudo apt-get update
sudo apt-get install -y gh

gh --version

# -----------------------------
# Verify net-tools
# -----------------------------
echo "Verifying net-tools installation..."
ifconfig || echo "ifconfig not available."

# -----------------------------
# Final Success Summary
# -----------------------------
echo
echo "==== Verifying all installations ===="

# Azure CLI
if command -v az &>/dev/null; then
    echo "✅ Azure CLI installed: $(az version --query '["azure-cli"]' -o tsv)"
else
    echo "❌ Azure CLI NOT installed"
fi

# Go
if command -v go &>/dev/null; then
    echo "✅ Go installed: $(go version)"
else
    echo "❌ Go NOT installed"
fi

# Make
if command -v make &>/dev/null; then
    echo "✅ Make installed: $(make --version | head -n1)"
else
    echo "❌ Make NOT installed"
fi

# kubectl
if command -v kubectl &>/dev/null; then
    echo "✅ kubectl installed: $(kubectl version --client | grep "Client Version" | awk '{print $3}')"
else
    echo "❌ kubectl NOT installed"
fi

# kubelogin
if command -v kubelogin &>/dev/null; then
    echo "✅ kubelogin installed (git hash): $(kubelogin --version | grep "git hash" | awk '{print $3}')"
else
    echo "❌ kubelogin NOT installed"
fi

# helm
if command -v helm &>/dev/null; then
    echo "✅ helm installed: $(helm version --short)"
else
    echo "❌ helm NOT installed"
fi

# GH CLI 
if command -v gh &>/dev/null; then
    echo "✅ GH CLI installed: $(gh --version | head -n1)"
else
    echo "❌ GH CLI NOT installed"
fi

# Net-tools
if command -v ifconfig &>/dev/null; then
    echo "✅ net-tools installed"
else
    echo "❌ net-tools NOT installed"
fi

# --- REBOOT ---
while true; do
  read -rp "Do you want to reboot now? (y/n): " REBOOT
  # Convert to lowercase for comparison
  REBOOT=${REBOOT,,}

  if [[ "$REBOOT" == "y" ]]; then
    echo "Rebooting..."
    sudo reboot
    break
  elif [[ "$REBOOT" == "n" ]]; then
    echo "Reboot canceled."
    break
  else
    echo "Invalid input. Please enter 'y' or 'n'."
  fi
done


echo "==== Provisioning SUCCESSFUL on $(date) ===="
