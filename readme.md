# Splunk on AKS Readme

This is written as a quickstart to show how to deploy Splunk on Azure Kubernetes Service (AKS). For a deep dive on AKS be sure to visit the Microsoft Learn content for concepts and architectures.

https://learn.microsoft.com/en-us/azure/aks/core-aks-concepts

https://learn.microsoft.com/en-us/azure/architecture/reference-architectures/containers/aks-mission-critical/mission-critical-intro

If you are looking for Splunk Operator GitHub reference: https://github.com/splunk/splunk-operator/tree/main/docs

This quickstart can be deployed either using the bash wrapper scripts for the Azure Infrastrucutre (deploy_infra.sh) and the Splunk deployment (deploy_splunk_sok_aks.sh). Or you can do a manual deployment which we have provided the various scripts below. Our recommended approach would be to use the bash scripts.

The jumpstart architecture we are building is comprised of:

- Azure Kubernetes Service deployed as a private cluster, FIPS enabled with 2 node pools and Entra ID integrated.
- Azure Container Registry with a private endpoint and private DNS zone
- Deploys a subnet to an existing vNet and creates network security group and route table
- Two jumpboxes deployed to the same subnet as the AKS cluster, one Linux and one Windows. These are to do AKS administration as it is deployed as a private cluster. If your Azure networking is already connected to your deployment machine you likely will not need these.
- Bash script to provision the Linux box post deployment. The enables all the tools required (Az CLI, GH CLI, Helm, Net Tools, KubeCtl, Kubelogin)
- Bash script to deploy Splunk-C3 reference architecture to AKS.
- KeyVault
- Storage Account for the cluster and Splunk Apps
- User Assigned Managed Identity for cluster operations

## Assumptions

It is assumed that there is a vNet already in place and that you have an Azure Bastion service already enabled for connectivity to the jumbox VMs. If these are not present, you will need to create before proceeding.

Here is a simple example if you dont have a vNet or Bastion as yet.

```json
az network vnet create \
    --resource-group <resource-group-name> \
    --name <vnet-name> \
    --address-prefixes <vnet-address-prefix> \
    --location <location>

az network bastion create \
  --location <region> \
  --name <bastion-host-name> \
  --public-ip-address <public-ip-address-name> \
  --resource-group <resource-group-name> \
  --vnet-name <virtual-network-name> \
  --sku Standard
```

## Automated Deployment for the Infrastructure (Recommended)

These tasks can be done either through cli, powershell or the portal.
Througout this post will share the az cli commands that you can run to do the manual configs. We have also provided a full bash script that will build the entire infrastructure for you.

The deploy_infra.sh can create a Resource Group for the prerequisites, Key Vault, Storage Account and User Assigned Managed Identity (UAMI). The bash script will also assign the necessary roles to the UAMI. Once the prereqs are complete the bash script will build the parameter file and deploy the ARM template (infra.json).
Should you decide to use the bash file (recommended approach):

```bash
chmod +x deploy_infra.sh
./deploy_infra.sh
```

You will be prompted for the following, you can chose not to deploy the RG, KV, Storage Account and UAMI. You will need to provide details of them and they will need to be in the same resource group.

1. The cloud you are using, AzureCloud or AzureUSGovernment
2. The location of the resources, use the name of the location not the display name. eg: westus or usgovvirginia. Note that this should be the same as the vNet that you are going to be building in.
3. Resource Group for the KeyVault, Storage Account and UAMI
4. KeyVault name - it will append a 10 digit random number to the end of the name eg: kv-test entered will become kv-testabc123de90
5. Storage Account name - same as above, it will append the 10 digit random number. Note storage accounts can only accecpt alpah numeric, no special characters.
6. User Assigned Managed Identity (UAMI). You can chose to use an existing UAMI if you have one
7. Project name - this is name that will be used to name all resources in this deployment. Should be greater than 5 characters and no spaces or special characters eg: alpha
8. Existing vNet name (we will detect the resource group name and present the subnets and address space that are already in the vNet)
9. Enter the IP address space for the cluster. By default this deployment will provision a /27. You only need to enter the x.x.x.x eg: 10.0.1.0.
10. Enter the username for your jumpboxes
11. Enter the password for the jumboxes
12. Group ID from Entra. This is a group that will be used to manage access to the AKS Cluster. You can get this from Entra ID
13. Tag Cost Center, if you dont use press enter and it will assign n/a
14. Tag Env, this is Dev, Test, Prod. If you dont use tags then enter to skip it will add n/a

## Manual Deployment

### Creating the keyVault

```cli
az cloud set AzureCloud or AzureUSGovernment
az login --use-device-code

rg="<your_RG_Name>"
SUBSCRIPTION_ID="<sub-id>"
location="<location>"
uami_name="<UAMI Name>"
storage_account_name="<storage name>"
$kv_name="keyVault Name"

az keyvault create -n <kvname> -g <your_RG> -location <location>
```

#### Note your keyvault name needs to be globally unique

### Creating the Storage Account

```cli
az storage account create -n <storageacctname> -g <your_RG> -location <region>  --min-tls-version TLS1_2  --allow-blob-public-access false
```

#### Note your keyvault name needs to be globally unique and no special characters, uppercase or spaces or dashes

Reference for Azure naming requirements here: https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/resource-name-rules

### Creating the User Assigned Managed Identity

```cli
az identity create -n $uami_name -g $rg$ -location $location
```

Once you have created these resources you will need to assign the following rights to the UAMI you have just created. We are using least required privledge, the reason for the Managed Identity Operator is that as AKS deploys it creates the underlying infrastructure in a managed resource group which would inherit the role. 

- Storage Blob Data Reader on the storage account
- Key Vault Certificate User on the keyVault
- Key Vault Crypto User on the keyVault
- Key Vault Secrets User on the keyVault
- Managed Identity Operator at the subscription

```cli
# Define your parameters
UAMI_PRINCIPAL_ID=$(az identity show -n $uami_name -g $rg --query "principalId" -o tsv)
STORAGE_ACCOUNT_ID="az storage account show -n $storage_account_name -g $rg --query "id" -o tsv"
KEYVAULT_ID="az keyvault show -n $kv_name -g $rg --query "id" -o tsv"

az role assignment create \
  --assignee $UAMI_PRINCIPAL_ID \
  --role "Storage Blob Data Reader" \
  --scope $STORAGE_ACCOUNT_ID

for role in "Key Vault Certificate User" "Key Vault Crypto User" "Key Vault Secrets User"; do
  az role assignment create \
    --assignee $UAMI_PRINCIPAL_ID \
    --role "$role" \
    --scope $KEYVAULT_ID
done

az role assignment create \
  --assignee $UAMI_PRINCIPAL_ID \
  --role "Managed Identity Operator" \
  --scope "/subscriptions/$SUBSCRIPTION_ID"


az keyvault key create --vault-name <vault name> -n aks-cmk
```

Now that you have all the prerequisites done. We are ready to deploy the infrastructure template.

## AKS Deployment

The ARM template provided will build all the infrastructure needed to standup the AKS infra, this includes the AKS cluster, Azure Container Registry, networking components and jumpboxes.
It is important to note that this deployment is deployed as a private cluster. All resources are deployed to an existing vNet however we create a subnet in the vNet. The subnet created by default is a /27, should you need to make it bigger adjust the prefix in the ARM template (row 491). Ensure that the prefix that you use in the parameter file can support the address space if you change it. The jumpboxes are deployed into the subnet you define.
For the subnet there is an NSG and RT that gets builts you have the choice of deploying the routes to the route table.
Before you deploy verify all the details in the parameter file, you will need to capture the following:

You can get your public IP for the ACR firewall rule here, you can place this in the parameter file for the infrastructure deployment.

```bash
curl -s https://ifconfig.me | awk '{print $1}')
```

Contents for infra.parameter.json

```json
{
    "\$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "location": { 
          "value": "" 
          },
        "projectName": { 
          "value": "" 
          },
        "createdbyTag": { 
          "value": "" 
          },
        "costcenter": { 
          "value": "" 
          },
        "Env": { 
          "value": "" 
          },
        "adminUsername": {
            "metadata": { "description": "Admin username for the jumpboxes. Must be between 1 and 20 characters long." },
            "value": ""
        },
        "adminPassword": {
            "metadata": { "description": "Admin password for the jumpboxes. Must be at least 12 characters long and meet complexity requirements." },
            "value": ""
        },
        "existingVNETName": {
            "metadata": { "description": "Name of the existing VNET" },
            "value": ""
        },
        "existingVnetResourceGroup": {
            "metadata": { "description": "Resource Group of the existing VNET" },
            "value": ""
        },
        "newSubnetAddressPrefix": {
            "metadata": { "description": "Address prefix for the new Subnet. Must be a subset of the existing VNET address space. AKS will deploy /27 all you need is the x.x.x.0" },
            "value": ""
        },
        "kubernetes_version": {
            "metadata": { "description": "Kubernetes version for the AKS Cluster." },
            "value": "1.33.2"
        },
        "clusterDNSprefix": {
            "metadata": { "description": "Enter the DNS prefix for the AKS Cluster." },
            "value": ""
        },
        "keyVaultName": {
            "metadata": { "description": "Key Vault Name to store secrets" },
            "value": ""
        },
        "keyName": {
            "metadata": { "description": "Key Vault Key Name to encrypt secrets" },
            "value": "aks-cmk"
        },
        "userAssignedID": {
            "metadata": { "description": "User Assigned Managed Identity Name" },
            "value": ""
        },
        "userIDRGName": {
            "metadata": { "description": "User Assigned Managed Identity Resource Group Name" },
            "value": ""
        },
        "keyVaultAccess": {
            "metadata": { "description": "Enable Key Vault access via public endpoint or private endpoint" },
            "value": "Public"
        },
        "adminGroupObjectIDs": {
            "metadata": { "description": "Entra ID Group Object IDs that will be assigned as AKS Admins" },
            "value": ""
        },
        "myIP": {
            "metadata": { "description": "Your public IP address for the ACR firewall rules" },
            "value": ""
            }
    }
}
```

Once you have captured / updated all the parameters in the infra.parameters.json file you can run the deployment.

** Note that this deployment is a subscription deployment not a resource group deployment

```json
az deployment sub create -n <deployment_name> -l <location> -f infra.json -p infra.parameters.json

# if you want to run a test first

az deployment sub create -n <deployment_name> -l <location> -f infra.json -p infra.parameters.json --what-if
```

Great, we now have all the resources ready to deploy the Splunk instance.
You have an AKS cluster with managed identity enabled. Your identity has been connected up and ready to authenticate the Splunk instance to the various Azure resources.

Things to verify before we move forward.

1. In the AKS cluster check the security settings have your group identity attached. You may need to change the drop down to Entra ID and kubernetes RBAC for it to be displayed.
2. Verify that OIDC and workload identity are enabled on the cluster, this can be found on the security configuration tab.

## Configuring the jumbox (Linux)

Lets get the linux jumpbox configured and ready to manage the cluster. Once you have connected to your Linux jumpbox VM using Bastion, run the following script to download the configuration script.

```bash
curl -sLO https://raw.githubusercontent.com/bravo-box/splunk-on-aks/refs/heads/main/setup_lin_jumpbox.sh && bash setup_lin_jumpbox.sh
```

This will setup the following resources on your jumpbox

- Azure CLI
- Go
- Make
- NetTools
- KubeLogin
- Kubectl
- Git CLI
- Helm

Once the tools are run do an Azure Login to ensure that you are have access to your environment

```bash
az cloud set AzureCloud or AzureUSGovernment
az login --use-device-code

az account show
```

Now that we have access to the Azure environment from the Azure Linux jumpbox, we will need to get the AKS credentials into your kubeconfig file.

```bash
rg=<resource group name>
cn=<cluster name>

az aks get-credentials -n $cn -g $rg
```

Should see a message that your cluster details have been merged into your kubeconfig file.
It should also show the following: convert-kubeconfig -l azurecli

If not, we will need to ensure that kubelogin is configured correctly. We do this by running the kubelogin command to activate via Az CLI.

```bash
kubelogin convert-kubeconfig -l azurecli
```

To test you can now run the following against your cluster

```kubectl
kubectl get ns

# or

kubectl get pods -A

# or

kubectl cluster-info
```

You may be prompted to login in. Once you have logged in, you will be presented with the default namespaces in the cluster.

** The Windows jumpbox can be used as well, particularly for access to the portal. You can log into the azure portal and view the resources in your cluster. 

Remember as this is a private cluster you cannot see the resources from the portal if you are connecting from a machine that outside of your network eg: a home machine that is not on VPN or if you are on a network that is not peered and routed correctly to the network in Azure.

Next you would want to pull the repo for the splunk installation assets down to the jumpbox.

```bash
git clone https://github.com/bravo-box/splunk-on-aks.git
```

## Deploying Splunk

### Recommended Auto-deployment

Run these steps from the Linux jumpbox

If you had run the deploy_infra.sh it would have pulled the repo locally to your Azure Container Registry, from here you can make the following ammendments to the deploy_splunk_sok_aks.sh file.

This bash will do a few things:

1. Create a new namespace
2. Validate all the roles are correct and apply if not
3. Enable Federated identity and get the URL from AKS cluster
4. Deploy the necessary Splunk CRDs
5. Build the Splunk-License ConfigMap which is required for all other services to come online
6. Add Helm repo and install the chart

To prepare for the run update the following rows in the deploy_splunk_sok_aks.sh to reflect the resources in your Azure environment. NOTE: do not remove the preceding -, just replace the x with your values.

- 55 - Resource Group of the Cluster
- 56 - AKS Cluster Name
- 57 - Location of the Cluster
- 63 - UAMI Resource Group Name
- 64 - UAMI Name
- 67 - Storage Account Resource Group
- 68 - Storage Account Name
- 85 & 86 - Update your Azure Container Registry URL

Once that has been completed proceed in running the deploy_splunk_sok_aks.sh

```bash
chmod +x deploy_splunk_sok_aks.sh
./deploy_splunk_sok_aks.sh
```

Once this completes you can check the status of you Splunk roll-out, proceed to the section in the document "Checking your Deployment"


You should see the pods coming online, this will take around 30-45 minutes for all to be ready.

### Manual Deployment Splunk-C3

Firstly lets ensure that we have a namespace deployed to our cluster
It is our recommendation to keep the default namespace to splunk. If you chose to adjust the namespace you will need to make changes to the script down the way.

```bash
nano ns.yaml

# copy this into your ns.yaml file
kind: Namespace
apiVersion: v1
metadata:
  name: busybox
---

# exit and save the file
```

```bash
kubectl apply -f ns.yaml file
```

### Check your newly created namespace

```bash
kubectl get ns

# OPTIONAL: Clean up CRDs before moving forward
kubectl get crds | grep splunk | awk '{print $1}' | xargs kubectl delete crd

# Deploy all the required CRDs
kubectl apply -f https://github.com/splunk/splunk-operator/releases/download/3.0.0/splunk-operator-crds.yaml --server-side
```

### Create the license manager file

```bash
nano license.yaml

# copy this into license.yaml

apiVersion: v1
kind: ConfigMap
metadata:
  name: splunk-licenses
  namespace: splunk
data:
  # The key below (enterprise.lic) will be the filename inside the mounted volume.
  # Ensure your Splunk Operator CR (LicenseManager, Standalone) references this filename
  # in its 'licenseUrl' (e.g., /mnt/licenses/enterprise.lic).
  enterprise.lic: |
    PD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0iVVRGLTgiPz4KPGxpY2Vuc2U+CiAgPHNpZ25hdHVyZT5pTEZBZnVVZU5rK0dVVDNGbDFkTWttQjB3dEFvTHJqTy9wT1plR25nZDBMejNzb1dxblo2UlJkMSt4T0N2dlI0Zk9wd3Jk
    allMemp2SnYxdWJuVXF1RzhMQ1JhR2N6WUswWnF1YytSU2RJVlVmZ1p1NW91d2N2d2VqaENhckRQem9kOFBMWlJUbDBOWHVSR2xRZjRCSmE3N0x0dy9wSnp0WmhYWUxtUUhwNUkxQWkrNjRLT2h5c0tLK212ZUthUVFqTjdPblpDRW1jTWdo
    QnV3aVJCK0ZYTFBJaGMxQ3lzS282TDJKY0hMblNYTmRDbUlLVzVqTElRNWJoQzh6cHJObW1IaTVvMEF2bWE4enpBWm5IajN0Y1prTGRlU0lMdFdsdjI0eGliVGMrcFd1NnJ5Ri9mMTNzdnRZWjFuNlVpUHNqaHZvREJPUlZMTVJNTEp0djU4
    REE9PTwvc2lnbmF0dXJlPgogIDxwYXlsb2FkPgogICAgPHR5cGU+ZW50ZXJwcmlzZTwvdHlwZT4KICAgIDxncm91cF9pZD5FbnRlcnByaXNlPC9ncm91cF9pZD4KICAgIDxxdW90YT4xMDczNzQxODI0MDwvcXVvdGE+CiAgICA8bWF4X3Zp
    b2xhdGlvbnM+NTwvbWF4X3Zpb2xhdGlvbnM+CiAgICA8d2luZG93X3BlcmlvZD4zMDwvd2luZG93X3BlcmlvZD4KICAgIDxjcmVhdGlvbl90aW1lPjE3MzkxNzQ0MDA8L2NyZWF0aW9uX3RpbWU+CiAgICA8bGFiZWw+U3BsdW5rIERldmVs
    b3BlciBQZXJzb25hbCBMaWNlbnNlIERPIE5PVCBESVNUUklCVVRFPC9sYWJlbD4KICAgIDxleHBpcmF0aW9uX3RpbWU+MTc1NDgwOTE5OTwvZXhwaXJhdGlvbl90aW1lPgogICAgPGZlYXR1cmVzPgogICAgICA8ZmVhdHVyZT5BdXRoPC9m
    ZWF0dXJlPgogICAgICA8ZmVhdHVyZT5Gd2REYXRhPC9mZWF0dXJlPgogICAgICA8ZmVhdHVyZT5SY3ZEYXRhPC9mZWF0dXJlPgogICAgICA8ZmVhdHVyZT5Mb2NhbFNlYXJjaDwvZmVhdHVyZT4KICAgICAgPGZlYXR1cmU+RGlzdFNlYXJj
    aDwvZmVhdHVyZT4KICAgICAgPGZlYXR1cmU+UmN2U2VhcmNoPC9mZWF0dXJlPgogICAgICA8ZmVhdHVyZT5TY2hlZHVsZWRTZWFyY2g8L2ZlYXR1cmU+CiAgICAgIDxmZWF0dXJlPkFsZXJ0aW5nPC9mZWF0dXJlPgogICAgICA8ZmVhdHVy
    ZT5EZXBsb3lDbGllbnQ8L2ZlYXR1cmU+CiAgICAgIDxmZWF0dXJlPkRlcGxveVNlcnZlcjwvZmVhdHVyZT4KICAgICAgPGZlYXR1cmU+U3BsdW5rV2ViPC9mZWF0dXJlPgogICAgICA8ZmVhdHVyZT5TaWduaW5nUHJvY2Vzc29yPC9mZWF0
    dXJlPgogICAgICA8ZmVhdHVyZT5TeXNsb2dPdXRwdXRQcm9jZXNzb3I8L2ZlYXR1cmU+CiAgICAgIDxmZWF0dXJlPkNhbkJlUmVtb3RlTWFzdGVyPC9mZWF0dXJlPgogICAgPC9mZWF0dXJlcz4KICAgIDxhZGRfb25zPgogICAgICA8YWRk
    X29uIG5hbWU9Iml0c2kiIHR5cGU9ImFwcCI+CiAgICAgICAgPHBhcmFtZXRlciBrZXk9InNpemUiIHZhbHVlPSIxMCIvPgogICAgICA8L2FkZF9vbj4KICAgIDwvYWRkX29ucz4KICAgIDxzb3VyY2V0eXBlcy8+CiAgICA8Z3VpZD5DNDky
    NTI5OC0xRjNFLTRGODMtQjVCNC1CNzM0QjRDMzUwMzU8L2d1aWQ+CiAgPC9wYXlsb2FkPgo8L2xpY2Vuc2U+Cg==

```

### Apply the license file

```bash
kubectl apply -f license.yaml
```

Now that you have the namespace created, the CRDs are applyed and the license config map are in place you are almost ready to deploy the Splunk-C3 infra.

### Adding the HELM repo

```bash
helm repo add splunk https://splunk.github.io/splunk-operator
helm repo update

helm install splunk-c3 3.0.0 -n splunk
```

**The below step is important to tag the splunk-operator-controller-manager to use the azure workload identity.**

```bash
kubectl label sa splunk-operator-controller-manager -n "splunk" azure.workload.identity/use=true --overwrite
```

## Checking your deployment

Now that your environment has been deployed it you can check to see the pods that have been created.

```bash
kubectl get pods -n splunk
```

You will see the pods starting to come online. This can take around 45min for all pods to be active and running.

In the interim you can test to see that your connection to the storage account is working.

```cli
kubectl get pods -n splunk

# look for the name of the splunk-operator-controller-manager pod. It will have a series of numbers and characters behind it

kubectl logs splunk-operator-controller-manager-xsdfsfe32 -n splunk | grep -i azure

# you should see a successful connection to the storage account 
```

You should now have a fully running and operational Splunk instance inside AKS. You should eventually see the following running pods:

- splunk-cm-cluster-manager-0
- splunk-heavy-forwarder-standalone-0
- splunk-idx-indexer-0
- splunk-idx-indexer-1
- splunk-idx-indexer-2
- splunk-lm-license-manager-0
- splunk-operator-controller-manager-xxxxxxxxxxx-xxxxx
- splunk-sh-search-head-0
- splunk-sh-search-head-1
- splunk-sh-search-head-2

## Deploying ingress controllers

### Automated deployment of ingress

Coming Soon !

```bash
# edit the bash with you IPs and subnet

```

### Manual deployment of ingress

Now to finalize this deployment we will need to deploy ingress controllers and load balancer so that you can federate and manage the environment.
For this we will use a combination of nginx and Azure Load Balancer. Both of these services are configured as internal and connected to our existing subnet which we created in the infrastructure deployment.
One of the prerequisites for the configuration he is for our User Assignd Managed Identity to have network contributor role, this is so that IPs can be assigned to ingress services.. In keeping with the least privledge princple, we could not create the role assignment earlier as the subnet had not been created. You can do this through the portal by going to the subnet, selecting the 3 dots ... to the right on the blade and selecting managing users.
Here is the Azure CLI to perform this:

```cli
UAMI_PRINCIPAL_ID=$(az identity show -n $uami_name -g $rg --query "principalId" -o tsv)
existingVNETName="vnet defined in ARM template"
existingVnetResourceGroup="existing vNet resource group"
subnetName="aks subnet name"

az role assignment create \
  --assignee $UAMI_PRINCIPAL_ID \
  --role "Network Contributor" \
  --scope $(az network vnet subnet show -g $existingVnetResourceGroup --vnet-name $existingVNETName -n $subnetName --query "id" -o tsv)
```

Now that we have assigned the Network contributor role to the managed identity, lets build the ingress controllers and load balancer. At this juncture we have two ingress points, one for web management and another for Splunk Federation. If you do not require Splunk Federation there is no need to create the load balancer.

If you require the load balancer for Federation on port 8089, proceed below. Else jump to the nginx controller for the web management.
You can either create a new .yaml file with the contents below and then run kubectl apply

```yaml
# First the load balancer
apiVersion: v1
kind: Service
metadata:
  name: splunk-lb
  namespace: splunk
  labels:
    azure.workload.identity/use: "true"
  annotations: 
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
spec:
  type: LoadBalancer
  loadBalancerIP: x.x.x.x #update the IP address to your desired static IP within the subnet range
  selector:
    app.kubernetes.io/instance: splunk-sh-deployer
    app.kubernetes.io/component: search-head
    app.kubernetes.io/name: deployer
    app.kubernetes.io/part-of: splunk-sh-search-head
  ports:
    - name: splunk-lb-port
      protocol: TCP
      port: 8089
      targetPort: 8089
  sessionAffinity: None
  externalTrafficPolicy: Cluster
  ipFamilies:
    - IPv4
  ipFamilyPolicy: SingleStack
  allocateLoadBalancerNodePorts: true
  internalTrafficPolicy: Cluster
```

```bash
kubectl apply -f <file name>
```

Or you can copy the contents of the yaml above and in the Azure portal, create a yaml deployment.

Secondly, lets create the nginx controller for web management.

First you will need to ensure that the repo is local to the machine you are deploying from.

```helm
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx

# Validate that you have the repo
helm repo list
```

Now that you have the repo locally, we can proceed in configuring the ingress service. You will require another IP, this is for the traffic over 8000 so that you can do web management. You will also require the name of the subnet that you AKS Cluster is built in. Take the yaml below and create a helm values file that you can use for the helm deployment.

```yaml
controller:
  service:
    type: LoadBalancer
    loadBalancerIP: "<set up>"
    annotations:
      service.beta.kubernetes.io/azure-load-balancer-internal: "true"
      service.beta.kubernetes.io/azure-load-balancer-ipv4: "<set IP>"
      service.beta.kubernetes.io/azure-load-balancer-internal-subnet: "<azure subnet>"
    externalTrafficPolicy: Local
    internalTrafficPolicy: Cluster
    allocateLoadBalancerNodePorts: true
  enableSnippets: true
```

```helm
helm install splunk-web ingress-nginx/ingress-nginx --version 4.13.3 --namespace splunk -f <values file>.yaml

# values file was what you created in the step above
```

Now that we have the service created, will need to apply the routing rules. The below yaml file will create routing rules for the ingress. Ensure that you apply your fqdn to the values. Note for the TLS you will need to apply the certificates after the deployment for the connection.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: splunk-ingress
  namespace: splunk
spec:
  ingressClassName: nginx
  rules:
  - host: splunk.<fqdn>
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: splunk-sh-search-head-service
            port: 
              number: 8000 
  - host: hf.splunk.<fqdn>
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: splunk-heavy-forwarder-standalone-service
            port: 
              number: 8000
  - host: hf.splunk.<fqdn>
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: splunk-heavy-forwarder-standalone-service
            port: 
              number: 8000
  - host: deployer.splunk.<fqdn>
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: splunk-sh-deployer-service
            port: 
              number: 8000
  - host: cluster-manager.splunk.<fqdn>
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: splunk-cm-cluster-manager-service
            port: 
              number: 8000
  - host: license-manager.splunk.<fqdn>
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: splunk-lm-license-manager-service
            port: 
              number: 8000
  - host: mc.splunk.<fqdn>
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: splunk-mc-monitoring-console-service
            port: 
              number: 8000
  tls:
  - hosts:
    - splunk.<fqdn>
    - hf.splunk.<fqdn>
    - deployer.splunk.<fqdn>
    - cluster-manager.splunk.<fqdn>
    - license-manager.splunk.<fqdn>
    - mc.splunk.<fqdn>
    secretName: operator-tls

```
