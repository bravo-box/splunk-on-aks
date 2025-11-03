# Splunk on AKS Readme

This is blog is written as a quickstart to show how to deploy Splunk on Azure Kubernetes Service (AKS). For a deep dive on AKS be sure to visit the Microsoft Learn content for concepts and architectures.

https://learn.microsoft.com/en-us/azure/aks/core-aks-concepts

https://learn.microsoft.com/en-us/azure/architecture/reference-architectures/containers/aks-mission-critical/mission-critical-intro

The jumpstart architecture we are building is comprised of:

- Azure Kubernetes Service deployed as a private cluster
- Azure Container Registry with a private endpoint and private DNS zone
- Deploys a subnet to an existing vNet and creates network security group and route table
- Two jumpboxes deployed to the same subnet, one Linux and one Windows
- Bash script to provision the Linux box post deployment
- Bash script to deploy Splunk-C3 reference architecture to AKS.

There are a few prerequisites that we are not building within the cluster, this decision was primarily due to giving greater flexibility, there is nothing stopping you from provisioning the prereq's in the infrastructure template.

- KeyVault
- Storage Account
- User Assigned Managed Identity

## Required Pre-requisites
The following are the required pre-requisites before running the deployment scripts.  These include the following:

- A Landing Zone Virtual Network
- EntraID Group for AKS Admins

### Creating the Virtual Network
For this template, it does require that a virtual network exist to be attached to, you can create the virtual network with the following azure CLI commands if a network doesn't exist:

```bash
rg="your-resource-group-name"
location="usgovvirginia"  # or your preferred location
vnet_name="your-vnet-name"
subnet_name="default"
address_space="10.0.0.0"

az network vnet create \
  --resource-group $rg \
  --name $vnet_name \
  --address-prefix "$address_space/16" \
  --subnet-name $subnet_name \
  --subnet-prefix "$address_space/24" \
  --location $location
```

## VSCode Tasks for Repo
This repository includes several VSCode tasks to help streamline development and deployment workflows. These tasks are configured in the `.vscode/tasks.json` file and can be accessed through the Command Palette (`Ctrl+Shift+P` or `Cmd+Shift+P`) by typing "Tasks: Run Task".

### Available Tasks

#### Infrastructure Tasks
- **Login to Azure Commercial** - Performs an az login against azure commercial.
- **Login to Azure Government** - Performs an az login against azure government.
- **Deploy Infrastructure** - Runs the `deploy_infra.sh` script to provision all required Azure resources including Resource Group, Key Vault, Storage Account, and User Assigned Managed Identity
- **Deploy Splunk** - Runs a script to deploy the splunk components on the aks cluster.

### Running Tasks
To execute any task:
1. Open the Command Palette (`Ctrl+Shift+P` or `Cmd+Shift+P`)
2. Type "Tasks: Run Task"
3. Select the desired task from the list
4. Follow any prompts for required parameters

## Deploying with the Shared Services

These tasks can be done either through cli, powershell or the portal.
Througout this post will share the az cli commands that you can run to do the manual configs. We have also provided a full bash script that will build the entire infrastructure for you.
That entails building the Resource Group, Key Vault, Storage Account, User Assigned Managed Identity (UAMI) and assigning the necessary roles to the UAMI. Once the prereqs are complete the bash script will build the parameter file and deploy the ARM template.
Should you decide to use the bash file:

```bash
bash deploy_infra.sh

# Follow the prompts
```

### Assumptions
It is assumed that there is a vNet already in place and that you have an Azure Bastion service already enabled for connectivity to the VMs. If these are not present, you will need to create before proceeding.

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

**Note your keyvault name needs to be globally unique**

### Creating the Storage Account

```cli
az storage account create -n <storageacctname> -g <your_RG> -location <region>  --min-tls-version TLS1_2  --allow-blob-public-access false
```

**Note your keyvault name needs to be globally unique and no special characters, uppercase or spaces or dashes**

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

```json

    "location": {
        "value": "USGov Virginia"
    },
    "projectName": {
        "value": "xxxx"
    },
    "createdbyTag": {
        "value": "xxxx"
    },
    "costcenter": {
        "value": "xxxx"
    },
    "Service": {
        "value": "xxxx"
    },
    "CostCategory": {
        "value": "xxxx"
    },
    "Env": {
        "value": "xxxx"
    },
    "BSO": {
        "value": "xxxx"
    },
    "BillingId": {
        "value": "xxxxx"
    },
    "adminUsername": {
        "metadata": {
            "description": "Admin username for the jumpboxes. Must be between 1 and 20 characters long."
        },
        "value": "xxxxxx"
    },
    "adminPassword": {
        "metadata": {
            "description": "Admin password for the jumpboxes. Must be at least 12 characters long and meet complexity requirements."
        },
        "value": ""
    },
    "existingVNETName": {
        "metadata": {
            "description": "Name of the existing VNET"
        },
        "value": "xxxxx"
    },
    "existingVnetResourceGroup": {
        "metadata": {
            "description": "Resource Group of the existing VNET"
        },
        "value": "xxxxxxxx"
    },
    "newSubnetAddressPrefix": {
        "metadata": {
            "description": "Address prefix for the new Subnet. Must be a subset of the existing VNET address space. AKS will deploy /27 all you need is the x.x.x.0"
        },
        "value": "10.0.27.0"
    },
    "kubernetes_version": {
        "metadata": {
            "description": "Kubernetes version for the AKS Cluster."
        },
        "value": "1.33.2"
    },
    "clusterDNSprefix": {
        "metadata": {
            "description": "Enter the DNS prefix for the AKS Cluster. eg: test, note no . or local or com etc"
        },
        "value": "xxxxx"
    },
    "deployRoutes": {
        "metadata": {
            "description": "Deploy custom routes to the new Subnet, yes or no"
        },
        "value": "no"
    },
    "routeDefinitions": {
        "value": [
            {
                "name": "External",
                "properties": {
                    "addressPrefix": "0.0.0.0/0",
                    "nextHopType": "VirtualAppliance",
                    "nextHopIpAddress": "1.2.3.4"
                }
            },
            {
                "name": "route 1",
                "properties": {
                    "addressPrefix": "4.3.2.1/32",
                    "nextHopType": "VirtualAppliance",
                    "nextHopIpAddress": "1.2.3.4"
                }
            },
            {
                "name": "route 2",
                "properties": {
                    "addressPrefix": "5.6.7.8/32",
                    "nextHopType": "VirtualAppliance",
                    "nextHopIpAddress": "5.6.7.8"
                }
            },
            {
                "name": "route 3",
                "properties": {
                    "addressPrefix": "6.7.8.9/32",
                    "nextHopType": "VirtualAppliance",
                    "nextHopIpAddress": "6.7.8.9"
                }
            }
        ]
    },
    "keyVaultName": {
        "metadata": {
            "description": "Key Vault Name to store secrets"
        },
        "value": "xxxxx"
    },
    "keyName": {
        "metadata": {
            "description": "Key Vault Key Name to encrypt secrets"
        },
        "value": "xxxxx"
    },
    "userAssignedID": {
        "metadata": {
            "description": "User Assigned Managed Identity Name"
        },
        "value": "xxxxxx"
    },
    "userIDRGName": {
        "metadata": {
            "description": "User Assigned Managed Identity Resource Group Name"
        },
        "value": "xxxxxxx"
    },
    "keyVaultAccess": {
        "metadata": {
            "description": "Enable Key Vault access via public endpoint or private endpoint"
        },
        "value": "Public"
    },
    "entraIDEnabled":{
        "metadata": {
            "description": "Enable Entra ID integration with your AKS Cluster, True or False"
        },
        "value": true
    },
    "fipsEnabled": {
        "metadata": {
            "description": "Enable FIPS on your node pool, True or False"
        },
        "value": true
    },
    "deployACR": {
        "metadata": {
            "description": "Deploy an Azure Container Registry (ACR) along with the AKS Cluster"
        },
        "value": "yes"
    },
    "deployNsgRT": {
        "metadata": {
            "description": "Deploy NSG and Route Table to the new Subnet"
        },
        "value": "yes"
    },
    "adminGroupObjectIDs": {
        "metadata": {
            "description": "Entra ID Group Object IDs that will be assigned as AKS Admins"
        },
        "value": "xxxxxxxxxxxx"
    }
```

Once you have captured / updated all the parameters in the aka.parameters.json file you can run the deployment.

** Note that this deployment is a subscription deployment not a resource group deployment

```json
az deployment sub create -n test -f  -p 
```

Great, we now have all the resources ready to deploy the Splunk instance.
You have an AKS cluster with managed identity enabled. Your identity has been connected up and ready to authenticate the Splunk instance to the various Azure resources.

Things to verify before we move forward.

1. In the AKS cluster check the security settings have your group identity attached. You may need to change the drop down to Entra ID and kubernetes RBAC for it to be displayed.
2. Verify that OIDC and workload identity are enabled on the cluster, this can be found on the security configuration tab.

### Configuring the jumbox (Linux)

Moving along lets get the linux jumpbox configured and ready to manage the cluster. Once you have connected to your Linux jumpbox VM, run the following script to download the configuration script.

```bash
curl -sLO https://raw.githubusercontent.com/wayneme75/prov/refs/heads/main/setup_lin_jumpbox.sh && bash setup_lin_jumpbox.sh
```

This will setup the following resources on your jumpbox

- Azure CLI
- Go
- Make
- NetTools
- KubeLogin
- Git CLI
- Helm
- Kubectl

Once the tools are run do an Azure Login to ensure that you are have access to your environment

```bash
az cloud set AzureCloud or AzureUSGovernment
az login --use-device-code

az account show
```

Now that we have access to the Azure environment from the Azure Linux jumpbox, we will need to get the AKS credentials into our kubeconfig file.

```bash
rg=<resource group name>
cn=<cluster name>

az aks get-credentials -n $cn -g $rg
```

Should see a message that your cluster details have been merged into your kubeconfig file.

As we have enabled Entra ID on the cluster we will need to ensure that kubelogin is configured correctly. We do this by running the kubelogin command to activate via Az CLI.

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

You should be prompted to login in. Once you have logged in, you will be presented with the default namespaces in the cluster.

** The Windows jumpbox can be used as well, particularly for the portal. You can log into the azure portal and view the resources in your cluster. Remember as this is a private cluster you cannot see the resources from a machine that is not on the same network

Next you would want to pull the repo for the splunk installation assets down to the jumpbox.

```bash
git clone <some url>
```

## Deploying Splunk

Firstly lets ensure that we have a namespace deployed to our cluster
It is our recommendation to keep the default namespace to splunk. If you chose to adjust the namespace you will need to make changes to the script down the way.

```bash
kubectl apply -f <path to the git ns.yaml file>

# Check your newly created namespace

kubectl get ns

# OPTIONAL: Clean up CRDs before moving forward
kubectl get crds | grep splunk | awk '{print $1}' | xargs kubectl delete crd

# Deploy all the required CRDs
kubectl apply -f https://github.com/splunk/splunk-operator/releases/download/3.0.0/splunk-operator-crds.yaml --server-side

# Deploy license manager
# Sample below

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

Now that you have the namespace created and the Azure infrastructure and the files are on the local jumpbox you are almost ready to deploy the Splunk-C3 infra. You will need to update some parameters to match those of your Azure resources.

In the bash script called blah.sh update the following rows to reflect the resources in your Azure environment. NOTE: do not remove the preceding -

- Row 46 - enter your resource group name
- Row 47 - name of your AKS cluster
- Row 48 - location / region of your resources
- Row 51 - the namespace you are deploying to
- Row 54 - resource group for your managed identity
- Row 55 - name of your managed identity
- Row 58 - resource group for your storage account
- Row 59 - the name of the storage account

Ensure that you are logged into Azure CLI prior to running the bash script for the Splunk implementation. To verify you can run the following:

```cli
az account show
```

If you are logged in proceed to run the bash script for the Splunk implementation

### NEED TO GET THE CRDS FOR THE INSTALL

```bash
bash splunk_script_filename.sh
```

The script will give you an output that all has been completed, to verify:

```cli
kubectl get pods -n splunk
```

You will see the pods starting to come online. This can take around 45min for all pods to be active and running.

In the interim you can test to see that your connection to the storage account is working.

```cli
kubectl get pods -n <name of namespace>

# look for the name of the splunk-operator-controller-manager pod. It will have a series of numbers and characters behind it

kubectl logs splunk-operator-controller-manager-xsdfsfe32 -n splunk | grep -i azure

# you should see connection to the storage account and successfully pulled down apps
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

Now to finalize this deployment we will need to deploy ingress controllers so that you can federate and manage the environment.
For this we will use a combination of nginx and Azure Load Balanecer. Both of these services are configured as internal and connected to our existing subnet which we created in the infrastructure deployment.
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
