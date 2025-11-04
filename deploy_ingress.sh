#!/bin/bash

set -e

# --------------------------------------------------
# Variables
# --------------------------------------------------
WEB_IP="10.0.28.13"
LB_IP="10.0.28.14"
SUBNET_NAME="pulse-aks-snet"
SUBNET_RG="networking-rg"
FQDN="demo.com"
NAMESPACE="splunk"

NGINX_VALUES_FILE="$(pwd)/values-nginx-ingress.yaml"
NGINX_CONFIG_FILE="$(pwd)/nginx-config.yaml"
LB_FILE="$(pwd)/federation-ingress.yaml"

# --------------------------------------------------
# --- DEPLOY WEB INGRESS (y/n) ---
# --------------------------------------------------
echo "----------------------------------------------"
echo "Starting deployment of Web Ingress"
echo "----------------------------------------------"

while true; do
  read -r -p "Do you want to deploy the Web Ingress? (y/n): " deploy_WebIngress
  deploy_WebIngress=${deploy_WebIngress,,}   # normalize to lowercase

  case "$deploy_WebIngress" in
    y|yes)
      DEPLOY_WEB_INGRESS=true
      echo "Starting deployment of nginx ingress controller..."

      # Step 1: Create custom values.yaml
      cat > "$NGINX_VALUES_FILE" <<EOF
controller:
  service:
    type: LoadBalancer
    loadBalancerIP: "$WEB_IP"
    labels:
      azure.workload.identity/use: "true"
    annotations:
      azure.workload.identity/use: "true"
      service.beta.kubernetes.io/azure-load-balancer-internal: "true"
      service.beta.kubernetes.io/azure-load-balancer-ipv4: "$WEB_IP"
      service.beta.kubernetes.io/azure-load-balancer-internal-subnet: "$SUBNET_NAME"
      service.beta.kubernetes.io/azure-load-balancer-internal-subnet-resource-group: "$SUBNET_RG"
    externalTrafficPolicy: Local
    internalTrafficPolicy: Cluster
    allocateLoadBalancerNodePorts: true
  enableSnippets: true
  ports:
    http: 80
    https: 443
EOF

      echo "✅ Custom nginx ingress values file generated at $NGINX_VALUES_FILE"

      # Step 2: Install nginx ingress controller
      helm install splunk-nginx oci://ghcr.io/nginx/charts/nginx-ingress \
        --version 2.2.2 \
        --namespace "$NAMESPACE" \
        -f "$NGINX_VALUES_FILE"

      echo "Waiting for nginx ingress controller service account..."
      for i in {1..30}; do
        if kubectl get sa splunk-nginx-nginx-ingress -n "$NAMESPACE" >/dev/null 2>&1; then
          echo "✅ Service account found."
          break
        fi
        echo "⏳ Waiting for service account to be created..."
        sleep 5
      done

      echo "Waiting for nginx ingress controller pods to be ready..."
      if kubectl rollout status deployment/splunk-nginx-nginx-ingress-controller -n "$NAMESPACE" --timeout=180s; then
          echo "✅ nginx ingress controller rollout completed successfully."
      else
          echo "❌ nginx ingress controller failed to deploy or timed out."
          kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=nginx-ingress --no-headers
          exit 1
      fi

      echo "Waiting an additional 60 seconds to ensure services are up..."
      sleep 60

      # Step 3: Generate ingress configuration
      cat > "$NGINX_CONFIG_FILE" <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: splunk-web
  namespace: $NAMESPACE
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

      # Step 4: Apply ingress
      kubectl apply -f "$NGINX_CONFIG_FILE"
      echo "✅ Ingress configuration applied successfully."

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

# --------------------------------------------------
# --- DEPLOY FEDERATION INGRESS (y/n) ---
# --------------------------------------------------
echo "----------------------------------------------"
echo "Starting deployment of Federation Ingress"
echo "----------------------------------------------"

read -r -p "Do you want to deploy a Federation Ingress (Load Balancer)? (y/n): " deploy_FederationIngress
deploy_FederationIngress=${deploy_FederationIngress,,}   # normalize input

case "$deploy_FederationIngress" in
  y|yes)
    DEPLOY_FEDERATION_INGRESS=true
    echo "Starting deployment of the Federation ingress (Load Balancer) controller..."

    cat > "$LB_FILE" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: splunk-lb
  namespace: $NAMESPACE
  labels:
    azure.workload.identity/use: "true"
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
spec:
  type: LoadBalancer
  loadBalancerIP: $LB_IP
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

    # Apply federation ingress
    kubectl apply -f "$LB_FILE"
    echo "✅ Federation ingress service applied successfully."
    ;;
  n|no)
    DEPLOY_FEDERATION_INGRESS=false
    echo "Skipping Federation ingress deployment."
    ;;
  *)
    echo "Invalid input. Skipping Federation ingress deployment."
    ;;
esac

echo "----------------------------------------------"
echo "🎉 All steps completed successfully!"
echo "----------------------------------------------"
