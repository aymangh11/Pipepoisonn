# PipePoison Lab Setup 

One leaked token. A poisoned pipeline. Total cluster takeover.

Dive into a modern DevOps nightmare, exploit misconfigured SVC accounts, escalate from GitLab push to K8s cluster-admin, then pillage the GitLab vault for the final root.

## Lab Architecture

- **Machine 1**: GitLab CE server with vulnerable repositories and CI/CD configurations
- **Machine 2**: Kubernetes cluster with GitLab Runner and misconfigured RBAC permissions

## Prerequisites

- Two Ubuntu machines
- Ansible installed on the GitLab machine
- SSH access between machines

## Setup Instructions

### Step 1: Install Ansible

On the GitLab machine, install Ansible:

```bash
apt update
apt install ansible -y
```

### Step 2: Configure Inventory

Create and modify the `inventory.ini` file:

```ini
[k8s]
<KUBERNETES_MACHINE_IP>

[all:vars]
ansible_user=ubuntu 
ansible_ssh_private_key_file=<PATH_TO_SSH_PRIVATE_KEY>
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
```

**Important**: Replace `<KUBERNETES_MACHINE_IP>` with the actual IP address of your Kubernetes machine and `<PATH_TO_SSH_PRIVATE_KEY>` with the path to your SSH private key for accessing the Kubernetes machine.

### Step 3: Clone Repository and Setup

```bash
git clone <REPOSITORY_URL>
cd SETUP
```

### Step 4: Install GitLab

Run the GitLab installation playbook:

```bash
ansible-playbook install_gitlab.yml
```

This playbook will:
- Install GitLab CE on the local machine
- Set the root password to `SecDojo123`
- Configure GitLab with the machine's public IP
- Generate SSH key pairs for later use in the attack scenario
- Set up the foundational GitLab environment

### Step 5: Configure GitLab

Execute the GitLab configuration playbook:

```bash
ansible-playbook setup_gitlab.yml
```

This playbook creates the vulnerable environment by:

#### User Accounts Created:
- **x-ci-bot**: CI/CD service account with API and repository write access
- **x-registry-bot**: Container registry service account with over-privileged permissions

#### Repositories Created:

**Public Repositories:**
1. **devops-tools**: Contains `.gitlab-ci.yml` with leaked CI bot token in commit history
2. **docker-examples**: Distractor repository with Kubernetes examples and deployment hints

**Private Repositories:**
1. **k8s-deployments**: Contains vulnerable CI/CD pipeline that exposes `KUBE_CONFIG` environment variable
2. **gitlab-bootstrap**: Infrastructure repository with embedded SSH private keys in Ansible playbooks

#### Vulnerable Configurations:
- CI bot token embedded in GitLab CI configuration (later "redacted" but available in git history)
- Kubernetes deployment pipeline that prints sensitive environment variables
- Over-privileged service account tokens with unnecessary scopes

### Step 6: Setup Kubernetes Cluster

Deploy and configure the Kubernetes environment:

```bash
ansible-playbook -i inventory.ini k8s_setup.yml
```

This playbook will:

#### Kubernetes Setup:
- Install Kubernetes on the remote machine
- Configure kubectl and Helm
- Create the `ci-build` namespace for CI/CD operations

#### GitLab Runner Configuration:
- Install GitLab Runner using Helm with Kubernetes executor
- Register runner with the GitLab instance using extracted tokens
- Configure runner to use service account authentication

#### Vulnerable RBAC Configuration:
- Create `gitlab-runner` service account in `ci-build` namespace
- Assign role with dangerous wildcard permissions on RBAC resources
- Allow privilege escalation to cluster-admin through role manipulation

#### Secret Management:
- Generate kubeconfig for CI service account
- Create container registry authentication secrets
- Embed over-privileged registry bot tokens in Kubernetes secrets
