require 'fileutils'

# Read pre-generated SSH private key
def read_ssh_private_key
  private_key_path = '/tmp/git_key'

  # Check if file exists and is readable
  unless File.exist?(private_key_path)
    raise "Private key file not found at #{private_key_path}. Generate it with 'sudo ssh-keygen -t rsa -b 2048 -C \"git_key\" -f /tmp/git_key -N \"\"'"
  end
  unless File.readable?(private_key_path)
    raise "Cannot read private key file at #{private_key_path}. Ensure it is readable by the current user (e.g., adjust permissions with 'sudo chmod 640 /git/ctf_key' or run as root)."
  end

  File.read(private_key_path)
end

# Read SSH private key
begin
  private_key = read_ssh_private_key
  puts "Successfully read SSH private key from /tmp/git_key"
rescue StandardError => e
  puts "Error reading SSH private key: #{e.message}"
  raise
end

# disable admin approval for users registration
ApplicationSetting.current.update!(require_admin_approval_after_user_signup: false)

# Verify changes
puts "Require admin approval: #{ApplicationSetting.current.require_admin_approval_after_user_signup}"

# create user bots
user1 = User.new(
  username: 'x-ci-bot',
  email: 'x-ci-bot@example.com',
  name: 'CI Bot',
  password: 'Rld12SKjDS154',
  password_confirmation: 'Rld12SKjDS154',
  confirmed_at: Time.now
)

user1.skip_confirmation!
user1.save!(validate: false)

user2 = User.new(
  username: 'x-registry-bot',
  email: 'x-registry-bot@example.com',
  name: 'Registry Bot',
  password: 'PSLKDbjk592SQ8SK',
  password_confirmation: 'PSLKDbjk592SQ8SK',
  confirmed_at: Time.now
)

user2.skip_confirmation!
user2.save!(validate: false)

# generate token for x-ci-bot
user = User.find_by_username('x-ci-bot')
ci_token = user.personal_access_tokens.create(
  scopes: [:api, :write_repository],
  name: 'ci-pipeline-token',
  expires_at: 365.days.from_now
)
puts "Created personal access token for x-ci-bot: #{ci_token.token}"

# Find admin and bot users
admin = User.find_by_username('root')
x_ci_bot = User.find_by_username('x-ci-bot')
x_registry_bot = User.find_by_username('x-registry-bot')

# Validate users
unless admin && admin.namespace_id
  raise "Admin user 'root' or admin.namespace_id is not set"
end
unless x_ci_bot
  raise "User 'x-ci-bot' not found"
end
unless x_registry_bot
  raise "User 'x-registry-bot' not found"
end

# Helper method to create a project with Projects::CreateService
def create_project(user, params)
  project = Projects::CreateService.new(user, params).execute
  if project.persisted?
    puts "Project '#{params[:name]}' created successfully."
    # Add custom README content based on project name
    readme_content = case params[:name]
                     when 'devops-tools'
                       <<~MARKDOWN
                         # DevOps Tools
                         Welcome to the `devops-tools` repository, a public hub for CI/CD pipeline configurations used in our development environment.

                         ## Overview
                         This repository contains CI/CD pipeline configurations for building, testing, and deploying applications. It includes a `.gitlab-ci.yml` file that defines build, test, and deploy stages, along with a deployment script. Explore the commit history for potential misconfigurations or exposed secrets!

                         ## Usage
                         - **Pipeline Configuration**: Check `.gitlab-ci.yml` for the CI/CD pipeline setup.
                         - **Deployment Script**: See `scripts/deploy.sh` for Kubernetes deployment commands.

                         ## Repository Details
                         - **Visibility**: Public
                         - **Purpose**: Demonstrates a CI/CD pipeline setup for streamlined development and deployment.
                       MARKDOWN
                     when 'k8s-deployments'
                       <<~MARKDOWN
                         # Kubernetes Deployments
                         Welcome to the `k8s-deployments` repository, a private repository for managing Kubernetes deployment configurations.

                         ## Overview
                         This repository houses Kubernetes deployment configurations and CI/CD pipelines for deploying applications to a cluster. It provides a secure environment for managing deployment manifests and automation scripts.

                         ## Usage
                         - **Deployment Configuration**: See `k8s/deployment.yaml` for NGINX deployment details.
                         - **CI/CD Pipeline**: Check `.gitlab-ci.yml` for deployment automation setup.

                         ## Repository Details
                         - **Visibility**: Private
                         - **Purpose**: Manages Kubernetes deployment configurations and automation.
                       MARKDOWN
                     when 'docker-examples'
                       <<~MARKDOWN
                         # Docker Examples
                         Welcome to the `docker-examples` repository, a public collection of Docker and Kubernetes example configurations.

                         ## Overview
                         This repository offers a set of example configurations for Docker and Kubernetes, serving as a reference for containerized application setups. It includes service accounts and deployment notes for practical use.

                         ## Usage
                         - **Kubernetes Examples**: See `k8s-examples/dashboard.yaml` for a sample service account configuration.
                         - **Deployment Notes**: Check `k8s-examples/comment.txt` for additional context on deployments.

                         ## Repository Details
                         - **Visibility**: Public
                         - **Purpose**: Provides example configurations for Docker and Kubernetes setups.
                       MARKDOWN
                     when 'gitlab-bootstrap'
                       <<~MARKDOWN
                         # GitLab Bootstrap
                         Welcome to the `gitlab-bootstrap` repository, a private repository for infrastructure automation.

                         ## Overview
                         This repository contains Ansible playbooks for automating the setup of GitLab instances. It streamlines infrastructure configuration with secure and reusable automation scripts.

                         ## Usage
                         - **Ansible Playbook**: See `playbooks/gitlab.yml` for GitLab setup automation scripts.

                         ## Repository Details
                         - **Visibility**: Private
                         - **Purpose**: Automates GitLab infrastructure setup with Ansible.
                       MARKDOWN
                     else
                       "# #{params[:name]}\n\nThis is a default README for the #{params[:name]} project."
                     end

    # Create or update README file
    project.repository.create_file(
      user,
      'README.md',
      readme_content,
      branch_name: project.default_branch || 'master',
      message: 'Add detailed README with project overview'
    )

    project
  else
    raise "Failed to create project '#{params[:name]}': #{project.errors.full_messages.join(', ')}"
  end
end

begin
  # 1. Create public devops-tools repository
  public_repo = create_project(admin, {
    name: 'devops-tools',
    path: 'devops-tools',
    namespace_id: admin.namespace_id,
    visibility_level: 20, # Public
    initialize_with_readme: false # Handled by create_project
  })

  # Add initial commit with leaked token for x-ci-bot
  public_repo.repository.create_file(
    admin,
    '.gitlab-ci.yml',
    <<~YAML,
      stages:
        - build
        - test
        - deploy

      variables:
        CI_REGISTRY: "registry.example.com"
        API_ENDPOINT: "https://api.example.com/v1"

      build_job:
        stage: build
        image: docker:latest
        services:
          - docker:dind
        script:
          - echo "Building project..."
          - docker build -t $CI_REGISTRY/webapp:latest .
          - docker login -u x-ci-bot -p "#{ci_token.token}" $CI_REGISTRY
          - docker push $CI_REGISTRY/webapp:latest
        only:
          - master

      test_job:
        stage: test
        image: ruby:2.7
        script:
          - echo "Running tests..."
          - bundle install
          - rake test
        only:
          - master

      deploy_job:
        stage: deploy
        image: bitnami/kubectl:latest
        script:
          - echo "Deploying to Kubernetes..."
          - kubectl apply -f deployment.yaml
        only:
          - master
    YAML
    branch_name: public_repo.default_branch || 'master',
    message: 'Add initial CI configuration with build, test, and deploy stages'
  )

  # "Remove" token in new commit
  public_repo.repository.update_file(
    admin,
    '.gitlab-ci.yml',
    <<~YAML,
      stages:
        - build
        - test
        - deploy

      variables:
        CI_REGISTRY: "registry.example.com"
        API_ENDPOINT: "https://api.example.com/v1"

      build_job:
        stage: build
        image: docker:latest
        services:
          - docker:dind
        script:
          - echo "Building project..."
          - docker build -t $CI_REGISTRY/webapp:latest .
          - docker login -u x-ci-bot -p "[REDACTED]" $CI_REGISTRY
          - docker push $CI_REGISTRY/webapp:latest
        only:
          - master

      test_job:
        stage: test
        image: ruby:2.7
        script:
          - echo "Running tests..."
          - bundle install
          - rake test
        only:
          - master

      deploy_job:
        stage: deploy
        image: bitnami/kubectl:latest
        script:
          - echo "Deploying to Kubernetes..."
          - kubectl apply -f deployment.yaml
        only:
          - master
    YAML
    branch_name: public_repo.default_branch || 'master',
    message: 'Updating .gitlab-ci.yml to redact token'
  )

  # Add deployment script
  public_repo.repository.create_file(
    admin,
    'scripts/deploy.sh',
    "kubectl apply -f deployment.yaml",
    branch_name: public_repo.default_branch || 'master',
    message: 'Add deployment script'
  )

  # 2. Create private k8s-deployments repository
  private_repo = create_project(admin, {
    name: 'k8s-deployments',
    path: 'k8s-deployments',
    namespace_id: admin.namespace_id,
    visibility_level: 0, # Private
    initialize_with_readme: false # Handled by create_project
  })

  # Add x-ci-bot as maintainer
  ProjectMember.find_or_create_by!(project: private_repo, user: x_ci_bot) do |pm|
    pm.access_level = 40 # Maintainer
  end
  puts "Added x-ci-bot as maintainer to k8s-deployments."

  # Get and display runner registration token for k8s-deployments
  k8s_project = Project.find_by_full_path('root/k8s-deployments')
  unless k8s_project
    raise "Project 'root/k8s-deployments' not found"
  end
  runner_registration_token = k8s_project.runners_token
  puts "Runner registration token for k8s-deployments: #{runner_registration_token}"

  # Get GitLab instance URL for container registry path
  gitlab_url = Gitlab.config.gitlab.host rescue 'localhost'
  registry_path = "#{gitlab_url}:5050/#{public_repo.full_path}"

  # Add deployment config
  private_repo.repository.create_file(
    admin,
    'k8s/deployment.yaml',
    <<~YAML,
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: nginx-deployment
        namespace: ci-build
        labels:
          app: nginx
      spec:
        replicas: 3
        selector:
          matchLabels:
            app: nginx
        template:
          metadata:
            labels:
              app: nginx
          spec:
            containers:
            - name: nginx
              image: nginx:latest
              ports:
              - containerPort: 80
    YAML
    branch_name: private_repo.default_branch || 'master',
    message: 'Add NGINX deployment configuration'
  )

  # Add CI/CD config to expose KUBE_CONFIG
  private_repo.repository.create_file(
    admin,
    '.gitlab-ci.yml',
    <<~YAML,
      ---
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
    YAML
    branch_name: private_repo.default_branch || 'master',
    message: 'Add CI/CD pipeline'
  )

  # 3. Create public docker-examples repository
  docker_repo = create_project(admin, {
    name: 'docker-examples',
    path: 'docker-examples',
    namespace_id: admin.namespace_id,
    visibility_level: 20, # Public
    initialize_with_readme: false # Handled by create_project
  })

  # Add example files
  docker_repo.repository.create_file(
    admin,
    'k8s-examples/dashboard.yaml',
    <<~YAML,
      apiVersion: v1
      kind: ServiceAccount
      metadata:
        name: admin-user
        namespace: kubernetes-dashboard
    YAML
    branch_name: docker_repo.default_branch || 'master',
    message: 'Add dashboard'
  )

  # Add hint file
  docker_repo.repository.create_file(
    admin,
    'k8s-examples/comment.txt',
    "# Remember to use the CI bot account when deploying to production cluster\n# Cluster config is in the private k8s-deployments repo\n# Registry access via x-registry-bot",
    branch_name: docker_repo.default_branch || 'master',
    message: 'Add deployment notes'
  )

  # 4. Create infrastructure/gitlab-bootstrap repository
  ansible_repo = create_project(admin, {
    name: 'gitlab-bootstrap',
    path: 'gitlab-bootstrap',
    namespace_id: admin.namespace_id,
    visibility_level: 0, # Private
    initialize_with_readme: false # Handled by create_project
  })

  # Add x-registry-bot as member with read access
  ProjectMember.find_or_create_by!(project: ansible_repo, user: x_registry_bot) do |pm|
    pm.access_level = 30 # Developer (read_repository access)
  end
  puts "Added x-registry-bot as developer to gitlab-bootstrap."

  # Add Ansible playbook with SSH private key
  ansible_repo.repository.create_file(
    admin,
    'playbooks/gitlab.yml',
    <<~YAML,
      ---
      - hosts: gitlab
        become: yes
        vars:
          ssh_private_key: |
            #{private_key.gsub(/^/, '            ')}
        tasks:
          - name: Copy SSH key for GitLab access
            copy:
              content: "{{ ssh_private_key }}"
              dest: /root/.ssh/id_rsa
              mode: '0600'
    YAML
    branch_name: ansible_repo.default_branch || 'master',
    message: 'Add GitLab Ansible playbook with SSH key'
  )

  # Create or find personal access token for x-registry-bot and ensure it's printed
  registry_token = PersonalAccessToken.find_or_create_by(user: x_registry_bot, name: 'registry-access') do |pm|
    pm.scopes = [:api, :write_repository]
    pm.expires_at = 1.year.from_now
  end
  # Explicitly fetch the token to ensure it’s printed
  registry_token_value = registry_token.token || PersonalAccessToken.find_by(user: x_registry_bot, name: 'registry-access')&.token
  puts "Created personal access token for x-registry-bot: #{registry_token_value}"

  puts "Repositories setup complete!"
rescue ActiveRecord::RecordInvalid => e
  puts "Validation failed: #{e.message}"
rescue Gitlab::Git::Repository::NoRepository => e
  puts "Repository error: #{e.message}"
rescue StandardError => e
  puts "Unexpected error: #{e.message}"
end
