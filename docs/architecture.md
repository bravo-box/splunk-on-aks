# Architecture of the Solution:

The following Mermaid diagram shows the Azure resources deployed by the ARM template (`infra.json`):

```mermaid
graph TB
    subgraph "Azure Subscription"
        subgraph "Existing VNet Resource Group"
            VNET[Existing Virtual Network]
            SUBNET[New AKS Subnet<br/>ProjectName-aks-snet<br/>/27 CIDR]
        end
        
        subgraph "Project Resource Group<br/>rg-ProjectName"
            subgraph "Networking Components"
                NSG[Network Security Group<br/>nsg-ProjectName-aks]
                RT[Route Table<br/>rt-ProjectName-aks]
            end
            
            subgraph "AKS Infrastructure"
                AKS[AKS Private Cluster<br/>aks-ProjectName]
                POOL1[System Node Pool<br/>pool01sys<br/>Standard_D4ds_v5<br/>2-8 nodes]
                POOL2[User Node Pool<br/>pool01app<br/>Standard_F16s_v2<br/>2-10 nodes]
            end
            
            subgraph "Container Registry"
                ACR[Azure Container Registry<br/>ProjectName-acr<br/>Premium SKU]
                ACR_PE[Private Endpoint<br/>ProjectName-acr-pe]
                DNS_ZONE[Private DNS Zone<br/>privatelink.azurecr.us]
                DNS_LINK[VNet Link<br/>pvtdns-link]
            end
            
            subgraph "Jumpbox Infrastructure"
                WIN_NIC[Windows NIC<br/>ProjectName-win-nic]
                WIN_VM[Windows Jumpbox<br/>ProjectName-win<br/>Standard_D8s_v3<br/>Windows 11 Enterprise]
                LIN_NIC[Linux NIC<br/>ProjectName-lin-nic]
                LIN_VM[Linux Jumpbox<br/>ProjectName-lin<br/>Standard_D8s_v3<br/>Ubuntu 24.04 LTS]
            end
        end
        
        subgraph "Prerequisites<br/>(External Dependencies)"
            UAMI[User Assigned<br/>Managed Identity]
            KV[Key Vault]
            KEY[Encryption Key<br/>aks-cmk]
            STORAGE[Storage Account]
        end
    end
    
    %% Network Relationships
    VNET --> SUBNET
    SUBNET --> NSG
    SUBNET --> RT
    SUBNET --> AKS
    SUBNET --> WIN_NIC
    SUBNET --> LIN_NIC
    SUBNET --> ACR_PE
    
    %% AKS Relationships
    AKS --> POOL1
    AKS --> POOL2
    AKS --> UAMI
    AKS --> KV
    AKS --> KEY
    
    %% ACR Relationships
    ACR --> ACR_PE
    ACR --> UAMI
    ACR_PE --> DNS_ZONE
    DNS_ZONE --> DNS_LINK
    DNS_LINK --> VNET
    
    %% VM Relationships
    WIN_VM --> WIN_NIC
    LIN_VM --> LIN_NIC
    
    %% Identity and Security
    UAMI --> STORAGE
    UAMI --> KV
    KEY --> KV
      
    class VNET,UAMI,KV,KEY,STORAGE existing
    class NSG,RT,SUBNET,ACR_PE,DNS_ZONE,DNS_LINK,WIN_NIC,LIN_NIC networking
    class AKS,POOL1,POOL2,WIN_VM,LIN_VM compute
    class ACR storage
```

### Resource Summary

The ARM template deploys the following Azure resources:

#### Core Infrastructure
- **Resource Group**: `rg-{projectName}` - Container for all project resources
- **Subnet**: `{projectName}-aks-snet` - Dedicated /27 subnet for AKS within existing VNet
- **Network Security Group**: `nsg-{projectName}-aks` - Network security rules for AKS subnet
- **Route Table**: `rt-{projectName}-aks` - Custom routing rules (optional)

#### Kubernetes Infrastructure  
- **AKS Private Cluster**: `aks-{projectName}` - Private Kubernetes cluster with:
  - System node pool (2-8 Standard_D4ds_v5 VMs)
  - User node pool (2-10 Standard_F16s_v2 VMs)
  - Entra ID integration
  - OIDC issuer and workload identity enabled
  - Key Vault encryption with customer-managed keys
  - FIPS compliance (optional)

#### Container Registry
- **Azure Container Registry**: `{projectName}acr` - Premium SKU registry with:
  - Private endpoint connectivity
  - Network access restrictions
  - Private DNS zone for resolution

#### Management Infrastructure
- **Windows Jumpbox**: `{projectName}-win` - Windows 11 Enterprise VM (Standard_D8s_v3)
- **Linux Jumpbox**: `{projectName}-lin` - Ubuntu 24.04 LTS VM (Standard_D8s_v3)
- **Network Interfaces**: Dedicated NICs for both jumpbox VMs

#### Prerequisites (External)
- **User Assigned Managed Identity**: For AKS cluster authentication
- **Key Vault**: For storing secrets and encryption keys
- **Storage Account**: For persistent storage requirements
- **Existing Virtual Network**: Target network for subnet creation

````