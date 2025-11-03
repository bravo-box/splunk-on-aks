#!/bin/bash

set -e

# Setting the variables for the Ingress deployment
# Make sure to replace LOADBALANCER_IP_ and SUBNET_ in values-nginx-ingress.yaml before running this script
# WebIP is for the Splunk Web Interface
# LoadBalancerIP is for the Load Balancer service for Federation

WEB_IP="x.x.x.x"
LB_IP="y.y.y.y"
SUBNET_NAME="my-subnet"
FQDN="demo.com"

NGINX_VALUES_FILE="$(pwd)/values-nginx-ingress.yaml" # Path to the custom values file
NGINX_CONFIG_FILE="$(pwd)/nginx-config.yaml" # Path to the ingress configuration file


# Select which Ingress to deploy, Web Ingress, Federation Ingress, or both
echo "----------------------------------------------"
echo "Do you want to deploy both Web Ingress (y/n)"
echo "----------------------------------------------"
select deploy_WebIngress in "y" "n"; do
    case $deploy_WebIngress in
        y )
            DEPLOY_WEB_INGRESS=true
            echo "Starting deployment of nginx ingress controller..."

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
EOF

echo "✅ Custom nginx ingress values file generated at $NGINX_VALUES_FILE"

            # Step 1: Install nginx ingress controller with Helm and custom values
            echo "Installing nginx ingress controller with Helm..."
            helm install splunk-nginx oci://ghcr.io/nginx/charts/nginx-ingress \
              --version 2.2.2 \
              --namespace splunk \
              --create-namespace \
              -f $NGINX_VALUES_FILE

            echo "Waiting for nginx ingress controller pods to be ready..."
            kubectl rollout status deployment/splunk-nginx-nginx-ingress-controller -n splunk --timeout=180s || true
            echo "✅ nginx ingress controller rollout completed successfully."

echo "----------------------------------------------"
echo "Starting configuration of nginx ingress controller..."
echo "----------------------------------------------"

cat > $NGINX_CONFIG_FILE <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: splunk-ingress
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
            name: splunk-heavy-forwarder-standalone-service
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

echo "----------------------------------------------"
echo "Do you want to deploy a Federation Ingress (Load Balancer)? (y/n)"
echo "----------------------------------------------"
read -r deploy_FederationIngress

# Normalize input (handle uppercase Y/N too)
deploy_FederationIngress=${deploy_FederationIngress,,}

if [[ "$deploy_FederationIngress" == "y" ]]; then
    DEPLOY_FEDERATION_INGRESS=true
    echo "Starting deployment of the Federation ingress (Load Balancer) controller..."

    # Step 3: Apply federation ingress service
    echo "Applying federation-ingress.yaml..."
    kubectl apply -f ingress-controller/federation-ingress.yaml

    echo "Waiting for Federation ingress service to be ready..."
    if kubectl rollout status deployment/federation-ingress-controller -n splunk --timeout=180s; then
        echo "✅ Federation ingress controller deployed successfully."
    else
        echo "❌ Federation ingress controller failed to deploy or timed out."
        kubectl get pods -n splunk -l app=federation-ingress --no-headers
        exit 1
    fi

elif [[ "$deploy_FederationIngress" == "n" ]]; then
    DEPLOY_FEDERATION_INGRESS=false
    echo "Skipping Federation ingress deployment."
else
    echo "Invalid input. Please enter 'y' or 'n'."
    exit 1
fi

echo "All steps completed."
