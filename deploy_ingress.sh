#!/bin/bash

set -e

# Setting the variables for the Ingress deployment
# Make sure to replace LOADBALANCER_IP_ and SUBNET_ in values-nginx-ingress.yaml before running this script
# WebIP is for the Splunk Web Interface
# LoadBalancerIP is for the Load Balancer service for Federation

# --------------------------------------------------
# Variables
# --------------------------------------------------
WEB_IP="10.0.28.13"
LB_IP="10.0.28.14"
SUBNET_NAME="pulse-aks-subnet"
FQDN="demo.com"

NGINX_VALUES_FILE="$(pwd)/values-nginx-ingress.yaml" # Path to the custom values file
NGINX_CONFIG_FILE="$(pwd)/nginx-config.yaml" # Path to the ingress configuration file
LB_FILE="$(pwd)/federation-ingress.yaml" # Path to the federation ingress values file


# Select which Ingress to deploy, Web Ingress, Federation Ingress, or both
echo "----------------------------------------------"
echo "Starting deployment of Web Ingress"
echo "----------------------------------------------"
# --- DEPLOY WEB INGRESS (y/n) ---
while true; do
  read -r -p "Do you want to deploy the Web Ingress? (y/n): " deploy_WebIngress
  deploy_WebIngress=${deploy_WebIngress,,}   # normalize to lowercase

  case "$deploy_WebIngress" in
    y|yes)
      DEPLOY_WEB_INGRESS=true
      echo "Starting deployment of nginx ingress controller..."
      # (your ingress deployment logic here)
      break
      ;;
    n|no)
      DEPLOY_WEB_INGRESS=false
      echo "Skipping nginx ingress deployment."
      break
      ;;
    *)
      echo "Please answer y or n."
      ;;
  esac
done

cat > $NGINX_VALUES_FILE <<EOF
controller:
  service:
    type: LoadBalancer
    loadBalancerIP: "$WEB_IP"
    annotations:
      service.beta.kubernetes.io/azure-load-balancer-internal: "true"
      service.beta.kubernetes.io/azure-load-balancer-ipv4: "$WEB_IP"
      service.beta.kubernetes.io/azure-load-balancer-internal-subnet: "$SUBNET_NAME"
    externalTrafficPolicy: Local
    internalTrafficPolicy: Cluster
    allocateLoadBalancerNodePorts: true
  enableSnippets: true
  ports:
    http: 80
    https: 443
EOF

echo "✅ Custom nginx ingress values file generated at $NGINX_VALUES_FILE"

    # Step 1: Install nginx ingress controller with Helm and custom values
    echo "Installing nginx ingress controller with Helm..."
    helm install splunk-nginx oci://ghcr.io/nginx/charts/nginx-ingress --version 2.2.2 --namespace splunk -f $NGINX_VALUES_FILE

    echo "Waiting for nginx ingress controller pods to be ready..."
            if kubectl rollout status deployment/splunk-nginx-nginx-ingress-controller -n splunk --timeout=180s; then
                echo "✅ nginx ingress controller rollout completed successfully."
            else
                echo "❌ nginx ingress controller failed to deploy or timed out."
                kubectl get pods -n splunk -l app.kubernetes.io/name=nginx-ingress --no-headers
                exit 1
            fi

echo "Waiting an additional 60 seconds to ensure services are up..."
sleep 60


echo "----------------------------------------------"
echo "Starting configuration of nginx ingress controller..."
echo "----------------------------------------------"

cat > $NGINX_CONFIG_FILE <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: splunk-web
  namespace: splunk
spec:
  ingressClassName: nginx
  rules:
  - host: splunk.$FQDN
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: splunk-sh-search-head-service
            port: 
              number: 8000 
  - host: hf.splunk.$FQDN
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: splunk-hf-standalone-service
            port: 
              number: 8000
  - host: deployer.splunk.$FQDN
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: splunk-sh-deployer-service
            port: 
              number: 8000
  - host: cluster-manager.splunk.$FQDN
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: splunk-cm-cluster-manager-service
            port: 
              number: 8000
  - host: license-manager.splunk.$FQDN
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: splunk-lm-license-manager-service
            port: 
              number: 8000
  - host: mc.splunk.$FQDN
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
    - splunk.$FQDN
    - hf.splunk.$FQDN
    - deployer.splunk.$FQDN
    - cluster-manager.splunk.$FQDN
    - license-manager.splunk.$FQDN
    - mc.splunk.$FQDN
    secretName: operator-tls
EOF

echo "✅ Ingress configuration file generated at $NGINX_CONFIG_FILE"

            # Step 2: Apply ingress configuration
            echo "Applying ingress-configuration.yaml..."
            kubectl apply -f $NGINX_CONFIG_FILE
            echo "✅ Ingress configuration applied successfully."
            break
            ;;
        n )
            DEPLOY_WEB_INGRESS=false
            echo "Skipping nginx ingress deployment."
            break
            ;;
        * )
            echo "Please answer y or n."
            ;;
    esac
done

# --- DEPLOY FEDERATION INGRESS (y/n) ---
echo "----------------------------------------------"
echo "Starting deployment of Federation Ingress"
echo "----------------------------------------------"
while true; do
  echo "----------------------------------------------"
  read -r -p "Do you want to deploy a Federation Ingress (Load Balancer)? (y/n): " deploy_FederationIngress
  deploy_FederationIngress=${deploy_FederationIngress,,}   # normalize input to lowercase

  case "$deploy_FederationIngress" in
    y|yes)
      DEPLOY_FEDERATION_INGRESS=true
      echo "Starting deployment of the Federation ingress (Load Balancer) controller..."

    cat > $LB_FILE <<EOF
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
  loadBalancerIP: $LB_IP #update the IP address to your desired static IP within the subnet range
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
EOF
    
    echo "✅ Custom federation ingress values file generated at $LB_FILE"

    # Step 3: Apply federation ingress service
    echo "Applying $LB_FILE..."
    kubectl apply -f $LB_FILE
    echo "✅ Federation ingress service applied successfully."

else
    DEPLOY_FEDERATION_INGRESS=false
    echo "Skipping Federation ingress deployment."
fi

echo "----------------------------------------------"
echo "🎉 All steps completed successfully!"
echo "----------------------------------------------"