#!/bin/bash
# k8s_cluster_setup.sh - Setup script for CTF K8s cluster (second machine)

set -e

echo "=== Setting up K8s Cluster for CTF Challenge ==="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration variables
RUNNER_SA_NAME="gitlab-runner"
CI_NAMESPACE="ci-build"
REGISTRY_SECRET_NAME="gitlab-registry-secret"
KUBECONFIG_FILE="/tmp/kubeconfig.yml"

echo -e "${YELLOW}1. Verifying gitlab-runner service account in ci-build namespace...${NC}"

# Ensure gitlab-runner service account exists
if ! kubectl get serviceaccount ${RUNNER_SA_NAME} -n ${CI_NAMESPACE} &>/dev/null; then
    echo -e "${RED}Error: Service account ${RUNNER_SA_NAME} not found in namespace ${CI_NAMESPACE}${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Service account ${RUNNER_SA_NAME} exists${NC}"

echo -e "${YELLOW}2. Ensuring token secret for gitlab-runner service account...${NC}"

# Check for existing secret
SA_SECRET_NAME=$(kubectl get serviceaccount ${RUNNER_SA_NAME} -n ${CI_NAMESPACE} -o jsonpath='{.secrets[0].name}' 2>/dev/null || echo "")

if [ -z "$SA_SECRET_NAME" ]; then
    echo "Creating token secret for service account..."
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${RUNNER_SA_NAME}-token
  namespace: ${CI_NAMESPACE}
  annotations:
    kubernetes.io/service-account.name: ${RUNNER_SA_NAME}
type: kubernetes.io/service-account-token
EOF
    SA_SECRET_NAME="${RUNNER_SA_NAME}-token"
    # Associate secret with service account
    kubectl patch serviceaccount ${RUNNER_SA_NAME} -n ${CI_NAMESPACE} -p '{"secrets":[{"name":"'"${RUNNER_SA_NAME}"'-token"}]}'
    sleep 2
fi

echo -e "${GREEN}✓ Token secret ${SA_SECRET_NAME} created or exists${NC}"

echo -e "${YELLOW}3. Setting up role and role binding for gitlab-runner service account...${NC}"

# Create role and role binding with vulnerable RBAC permissions
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: ${CI_NAMESPACE}
  name: ci-runner-role
rules:
- apiGroups: [""]
  resources: ["pods", "services", "configmaps", "secrets"]
  verbs: ["get", "list", "create", "update", "patch", "delete"]
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets"]
  verbs: ["get", "list", "create", "update", "patch", "delete"]
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
  verbs: ["*"]  # Vulnerable: allows escalation to cluster-admin
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ci-runner-binding
  namespace: ${CI_NAMESPACE}
subjects:
- kind: ServiceAccount
  name: ${RUNNER_SA_NAME}
  namespace: ${CI_NAMESPACE}
roleRef:
  kind: Role
  name: ci-runner-role
  apiGroup: rbac.authorization.k8s.io
EOF

echo -e "${GREEN}✓ Role and role binding created for gitlab-runner service account${NC}"

echo -e "${YELLOW}4. Generating kubeconfig for CI service account...${NC}"

# Extract token and certificate
SA_TOKEN=$(kubectl get secret ${SA_SECRET_NAME} -n ${CI_NAMESPACE} -o jsonpath='{.data.token}' | base64 -d)
SA_CA_CERT=$(kubectl get secret ${SA_SECRET_NAME} -n ${CI_NAMESPACE} -o jsonpath='{.data.ca\.crt}')

# Get private IP using IMDSv2 for cluster endpoint
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
if [ -z "$TOKEN" ] || echo "$TOKEN" | grep -q "<html"; then
    echo -e "${YELLOW}Warning: Failed to retrieve IMDSv2 token, falling back to alternative method${NC}"
    PRIVATE_IP=$(hostname -I | awk '{print $1}')
    if [ -z "$PRIVATE_IP" ]; then
        echo -e "${RED}Error: Failed to retrieve private IP${NC}"
        exit 1
    fi
else
    PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" http://169.254.169.254/latest/meta-data/local-ipv4)
    if [ -z "$PRIVATE_IP" ] || echo "$PRIVATE_IP" | grep -q "<html"; then
        echo -e "${YELLOW}Warning: Failed to retrieve private IP from metadata service, falling back to alternative method${NC}"
        PRIVATE_IP=$(hostname -I | awk '{print $1}')
        if [ -z "$PRIVATE_IP" ]; then
            echo -e "${RED}Error: Failed to retrieve private IP${NC}"
            exit 1
        fi
    fi
fi
CLUSTER_ENDPOINT="https://${PRIVATE_IP}:6443"

# Create kubeconfig content
KUBE_CONFIG=$(cat <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${SA_CA_CERT}
    server: ${CLUSTER_ENDPOINT}
  name: runner-cluster
contexts:
- context:
    cluster: runner-cluster
    namespace: ${CI_NAMESPACE}
    user: ${RUNNER_SA_NAME}
  name: runner-context
current-context: runner-context
users:
- name: ${RUNNER_SA_NAME}
  user:
    token: ${SA_TOKEN}
EOF
)

# Save kubeconfig to file
echo "${KUBE_CONFIG}" > ${KUBECONFIG_FILE}
chmod 600 ${KUBECONFIG_FILE}

echo -e "${GREEN}✓ Kubeconfig generated and saved to ${KUBECONFIG_FILE}${NC}"

echo -e "${YELLOW}5. Creating GitLab registry secret...${NC}"

# Pre-compute .dockerconfigjson base64 string
DOCKER_CONFIG_JSON=$(echo -n '{"auths":{"http://<ip>":{"username":"x-registry-bot","password":"<token>","auth":"'$(echo -n "x-registry-bot:<token>" | base64 -w0)'"}}}' | base64 -w0)

# Create secret for GitLab registry access with over-privileged token
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${REGISTRY_SECRET_NAME}
  namespace: ${CI_NAMESPACE}
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: ${DOCKER_CONFIG_JSON}
EOF

echo -e "${GREEN}✓ GitLab registry secret created${NC}"

echo -e "${GREEN}=== K8s Cluster Setup Complete! ===${NC}"
echo ""
echo -e "${YELLOW}Summary of what was created:${NC}"
echo "- Role and RoleBinding: ci-runner-role and ci-runner-binding for gitlab-runner (with vulnerable RBAC permissions)"
echo "- Secret: ${RUNNER_SA_NAME}-token in ${CI_NAMESPACE} (for gitlab-runner kubeconfig)"
echo "- Kubeconfig: Generated and saved to ${KUBECONFIG_FILE}"
echo "- Secret: ${REGISTRY_SECRET_NAME} in ${CI_NAMESPACE} (over-privileged GitLab registry access)"