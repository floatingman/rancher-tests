#!/bin/bash
# Common shell utilities for Airgap RKE2 pipelines
# This script provides shared functions used across multiple pipeline stages

set -e

# ========================================
# LOGGING UTILITIES
# ========================================

log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $*"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

log_warning() {
    echo "[WARNING] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

log_debug() {
    if [[ "${DEBUG_MODE:-false}" == "true" ]]; then
        echo "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
    fi
}

# ========================================
# ENVIRONMENT SETUP UTILITIES
# ========================================

setup_aws_credentials() {
    log_info "Setting up AWS credentials"
    
    # Export AWS credentials for OpenTofu/Terraform
    export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}"
    export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}"
    export AWS_REGION="${AWS_REGION:-us-east-2}"
    export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-2}"
    
    log_info "AWS credentials configured (access key: ${AWS_ACCESS_KEY_ID:+[SET]})"
}

source_environment_file() {
    local env_file="${1:-/tmp/.env}"
    
    if [[ -f "$env_file" ]]; then
        log_info "Sourcing environment file: $env_file"
        source "$env_file"
        
        # Export critical variables explicitly
        export S3_BUCKET_NAME="${S3_BUCKET_NAME}"
        export S3_REGION="${S3_REGION}"
        export S3_KEY_PREFIX="${S3_KEY_PREFIX}"
        export TF_WORKSPACE="${TF_WORKSPACE}"
        export TERRAFORM_VARS_FILENAME="${TERRAFORM_VARS_FILENAME}"
        export TERRAFORM_BACKEND_VARS_FILENAME="${TERRAFORM_BACKEND_VARS_FILENAME}"
    else
        log_warning "Environment file not found at $env_file, using Docker environment variables"
    fi
}

validate_required_variables() {
    local required_vars=("$@")
    local missing_vars=()
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var}" ]]; then
            missing_vars+=("$var")
        fi
    done
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log_error "Missing required environment variables: ${missing_vars[*]}"
        exit 1
    fi
    
    log_info "All required variables validated successfully"
}

# ========================================
# INFRASTRUCTURE UTILITIES
# ========================================

change_to_infra_directory() {
    local infra_path="${1:-$QA_INFRA_WORK_PATH}"
    
    if [[ -z "$infra_path" ]]; then
        log_error "QA_INFRA_WORK_PATH not set"
        exit 1
    fi
    
    if [[ ! -d "$infra_path" ]]; then
        log_error "Infrastructure directory not found: $infra_path"
        exit 1
    fi
    
    cd "$infra_path"
    log_info "Changed to infrastructure directory: $(pwd)"
}

create_workspace_if_needed() {
    local workspace_name="${TF_WORKSPACE}"
    
    if [[ -z "$workspace_name" ]]; then
        log_error "TF_WORKSPACE not set"
        exit 1
    fi
    
    log_info "Checking workspace: $workspace_name"
    
    # Check if workspace exists
    local workspace_exists
    workspace_exists=$(tofu -chdir=tofu/aws/modules/airgap workspace list 2>/dev/null | grep -w "$workspace_name" || true)
    
    if [[ -z "$workspace_exists" ]]; then
        log_info "Workspace $workspace_name does not exist, creating it..."
        # Temporarily unset TF_WORKSPACE to allow workspace creation
        unset TF_WORKSPACE
        tofu -chdir=tofu/aws/modules/airgap workspace new "$workspace_name"
        # Set TF_WORKSPACE back for subsequent operations
        export TF_WORKSPACE="$workspace_name"
        log_info "Workspace $workspace_name created successfully"
    else
        log_info "Workspace $workspace_name already exists"
    fi
}

# ========================================
# ANSIBLE UTILITIES
# ========================================

setup_ansible_directories() {
    log_info "Setting up Ansible directory structure"
    
    # Create standard directory structure
    mkdir -p /root/ansible/rke2/airgap/inventory/
    mkdir -p /root/ansible/rke2/airgap/group_vars/
    mkdir -p /root/group_vars/
    
    log_info "Ansible directories created"
}

validate_inventory_file() {
    local inventory_file="${1:-/root/ansible/rke2/airgap/inventory.yml}"
    
    if [[ ! -f "$inventory_file" ]]; then
        log_error "Inventory file not found: $inventory_file"
        exit 1
    fi
    
    log_info "Validating inventory structure"
    
    # Check for required groups
    if grep -q "rke2_servers:" "$inventory_file"; then
        local server_count
        server_count=$(grep -A 20 "rke2_servers:" "$inventory_file" | grep "rke2-server-" | wc -l)
        log_info "✓ rke2_servers group found ($server_count servers)"
    else
        log_warning "rke2_servers group not found"
    fi
    
    if grep -q "rke2_agents:" "$inventory_file"; then
        local agent_count
        agent_count=$(grep -A 20 "rke2_agents:" "$inventory_file" | grep "rke2-agent-" | wc -l)
        log_info "✓ rke2_agents group found ($agent_count agents)"
    else
        log_warning "rke2_agents group not found"
    fi
    
    log_info "Inventory validation completed"
}

copy_group_vars_to_inventory_location() {
    local source_file="${1:-/root/group_vars/all.yml}"
    local target_file="${2:-/root/ansible/rke2/airgap/group_vars/all.yml}"
    
    if [[ ! -f "$source_file" ]]; then
        log_error "Group_vars source file not found: $source_file"
        exit 1
    fi
    
    # Ensure target directory exists
    mkdir -p "$(dirname "$target_file")"
    
    # Copy file and ensure it ends with newline
    cp "$source_file" "$target_file"
    [[ -n $(tail -c1 "$target_file") ]] && echo "" >> "$target_file"
    
    log_info "Group_vars copied to inventory-relative location: $target_file"
}

update_group_vars_with_version() {
    local group_vars_file="${1:-/root/ansible/rke2/airgap/group_vars/all.yml}"
    local version_key="${2:-rke2_version}"
    local version_value="${3:-$RKE2_VERSION}"
    
    if [[ -z "$version_value" ]]; then
        log_warning "$version_key not provided, skipping update"
        return 0
    fi
    
    if [[ ! -f "$group_vars_file" ]]; then
        log_error "Group_vars file not found: $group_vars_file"
        exit 1
    fi
    
    log_info "Updating $version_key in group_vars: $version_value"
    
    # Check if version key is already in the file
    if grep -q "^${version_key}:" "$group_vars_file"; then
        # Replace existing line
        sed -i "s/^${version_key}:.*/${version_key}: \"${version_value}\"/" "$group_vars_file"
        log_info "Updated existing $version_key in group_vars"
    else
        # Add new line
        echo "${version_key}: \"${version_value}\"" >> "$group_vars_file"
        log_info "Added $version_key to group_vars"
    fi
    
    # Verify the variable is set
    if grep -q "^${version_key}:" "$group_vars_file"; then
        log_info "✓ $version_key successfully set in group_vars"
        grep "^${version_key}:" "$group_vars_file"
    else
        log_error "Failed to set $version_key in group_vars file"
        exit 1
    fi
}

clone_or_update_qa_infra_repo() {
    local repo_url="${QA_INFRA_REPO_URL:-https://github.com/rancher/qa-infra-automation.git}"
    local repo_branch="${QA_INFRA_REPO_BRANCH:-main}"
    local target_dir="${1:-/root/qa-infra-automation}"
    
    if [[ ! -d "$target_dir" ]]; then
        log_info "Cloning qa-infra-automation repository..."
        git clone -b "$repo_branch" "$repo_url" "$target_dir"
    else
        log_info "Updating qa-infra-automation repository..."
        cd "$target_dir"
        git fetch origin
        git checkout "$repo_branch"
        git pull origin "$repo_branch"
        cd /root
    fi
    
    log_info "QA infra repository ready at $target_dir"
}

validate_yaml_syntax() {
    local yaml_file="$1"
    
    if [[ ! -f "$yaml_file" ]]; then
        log_error "YAML file not found: $yaml_file"
        exit 1
    fi
    
    log_info "Validating YAML syntax for: $yaml_file"
    
    if command -v python3 &> /dev/null; then
        if python3 -c "import yaml, sys; yaml.safe_load(open('$yaml_file'))" 2>&1; then
            log_info "✓ YAML is valid"
        else
            log_error "✗ YAML has syntax errors (see above)"
            exit 1
        fi
    elif command -v yamllint &> /dev/null; then
        if yamllint "$yaml_file"; then
            log_info "✓ YAML is valid"
        else
            log_error "✗ YAML has validation errors"
            exit 1
        fi
    else
        log_warning "No YAML validation tool available (python3 or yamllint)"
        log_warning "Proceeding without validation - errors may occur during processing"
    fi
}

# ========================================
# KUBECTL UTILITIES
# ========================================

find_kubeconfig() {
    local search_paths=(
        "/root/.kube/config"
        "/etc/rancher/rke2/rke2.yaml"
        "/root/ansible/rke2/airgap/kubeconfig"
        "/tmp/kubeconfig.yaml"
    )
    
    for config_path in "${search_paths[@]}"; do
        if [[ -f "$config_path" ]]; then
            log_info "Found kubeconfig at: $config_path"
            echo "$config_path"
            return 0
        fi
    done
    
    log_warning "Kubeconfig not found in any expected location"
    return 1
}

extract_bastion_ip() {
    local inventory_file="${1:-/root/ansible/rke2/airgap/inventory.yml}"
    local bastion_ip=""
    
    if [[ ! -f "$inventory_file" ]]; then
        log_error "Inventory file not found: $inventory_file"
        return 1
    fi
    
    log_info "Extracting bastion IP from inventory"
    
    # Method 1: Look for bastion-node in inventory (multiple patterns)
    bastion_ip=$(grep -A 10 "bastion-node:" "$inventory_file" | grep "ansible_host:" | head -1 | awk '{print $2}' | tr -d '"' | tr -d "'" || echo "")
    
    # Method 2: Try different inventory patterns if first method failed
    if [[ -z "$bastion_ip" ]]; then
        bastion_ip=$(grep -A 10 "bastion:" "$inventory_file" | grep "ansible_host:" | head -1 | awk '{print $2}' | tr -d '"' | tr -d "'" || echo "")
    fi
    
    # Method 3: Try to get any IP from inventory
    if [[ -z "$bastion_ip" ]]; then
        bastion_ip=$(grep -E "ansible_host.*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" "$inventory_file" | head -1 | awk '{print $2}' | tr -d '"' | tr -d "'" || echo "")
    fi
    
    # Method 4: Try to get bastion IP from infrastructure outputs
    if [[ -z "$bastion_ip" && -f "/root/infrastructure-outputs.json" ]]; then
        bastion_ip=$(grep -o '"bastion_public_dns":"[^"]*"' /root/infrastructure-outputs.json | cut -d'"' -f4 | head -1 || echo "")
    fi
    
    # Method 5: Try to get from hostname
    if [[ -z "$bastion_ip" ]]; then
        bastion_ip=$(hostname -I | awk '{print $1}' || echo "")
    fi
    
    # Method 6: Try to get from ip addr
    if [[ -z "$bastion_ip" ]]; then
        bastion_ip=$(ip addr show | grep 'inet ' | grep -v '127.0.0.1' | head -1 | awk '{print $2}' | cut -d'/' -f1 || echo "")
    fi
    
    if [[ -n "$bastion_ip" ]]; then
        echo "$bastion_ip"
        return 0
    else
        log_error "Could not determine bastion IP using any method"
        return 1
    fi
}

update_kubeconfig_server() {
    local kubeconfig_file="$1"
    local server_url="${2:-}"
    
    if [[ -z "$kubeconfig_file" ]]; then
        kubeconfig_file=$(find_kubeconfig)
        if [[ $? -ne 0 ]]; then
            log_error "Kubeconfig not found"
            return 1
        fi
    fi
    
    if [[ -z "$server_url" ]]; then
        local bastion_ip
        bastion_ip=$(extract_bastion_ip)
        if [[ $? -eq 0 ]]; then
            server_url="https://${bastion_ip}:6443"
        else
            log_error "Could not determine server URL"
            return 1
        fi
    fi
    
    log_info "Updating kubeconfig server URL to: $server_url"
    
    # Show original kubeconfig server URL for debugging
    log_info "Original kubeconfig server URL:"
    grep "server:" "$kubeconfig_file" || echo "Could not find server line"
    
    # Replace any server URL with the correct one
    sed -i "s|server:.*|server: ${server_url}|" "$kubeconfig_file"
    
    # Verify the change
    log_info "Kubeconfig server URL after update:"
    grep "server:" "$kubeconfig_file" || echo "Failed to verify server URL"
    
    log_info "✓ Kubeconfig server URL updated successfully"
}

copy_kubeconfig_to_shared_volume() {
    local source_config="$1"
    local target_config="${2:-/root/kubeconfig.yaml}"
    
    if [[ -z "$source_config" ]]; then
        source_config=$(find_kubeconfig)
        if [[ $? -ne 0 ]]; then
            log_error "Kubeconfig not found"
            return 1
        fi
    fi
    
    cp "$source_config" "$target_config"
    chmod 644 "$target_config"
    
    log_info "✓ Kubeconfig copied to shared volume: $target_config"
}

# ========================================
# SSH UTILITIES
# ========================================

setup_ssh_key() {
    local ssh_key_content="${1:-$AWS_SSH_PEM_KEY}"
    local ssh_key_file="${2:-/root/.ssh/id_rsa}"
    
    if [[ -z "$ssh_key_content" ]]; then
        log_error "SSH key content not provided"
        return 1
    fi
    
    log_info "Setting up SSH key"
    
    # Create SSH directory
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    
    # First, decode the base64 key if it's encoded
    if echo "$ssh_key_content" | grep -q "^LS0t"; then
        log_info "SSH key appears to be base64 encoded, decoding..."
        echo "$ssh_key_content" | base64 -d > "$ssh_key_file"
    else
        echo "$ssh_key_content" > "$ssh_key_file"
    fi
    
    # Ensure the key file has proper permissions
    chmod 600 "$ssh_key_file"
    
    log_info "SSH key configured successfully: $ssh_key_file"
}

generate_ssh_public_key() {
    local private_key_file="${1:-/root/.ssh/id_rsa}"
    local public_key_file="${2:-/root/.ssh/id_rsa.pub}"
    
    if [[ ! -f "$private_key_file" ]]; then
        log_error "SSH private key file not found: $private_key_file"
        return 1
    fi
    
    log_info "Generating SSH public key from private key"
    
    # Extract the public key from the private key
    if ssh-keygen -y -f "$private_key_file" > "$public_key_file" 2>/dev/null; then
        chmod 644 "$public_key_file"
        log_info "SSH public key generated successfully: $public_key_file"
        return 0
    else
        log_error "Failed to generate public key from SSH private key"
        return 1
    fi
}

# ========================================
# ARTIFACT UTILITIES
# ========================================

backup_artifact() {
    local source_file="$1"
    local backup_dir="${2:-/root/backups}"
    local backup_name="$3"
    
    if [[ ! -f "$source_file" ]]; then
        log_error "Source file not found: $source_file"
        return 1
    fi
    
    # Create backup directory
    mkdir -p "$backup_dir"
    
    # Generate backup name if not provided
    if [[ -z "$backup_name" ]]; then
        local timestamp
        timestamp=$(date +%Y%m%d-%H%M%S)
        local filename
        filename=$(basename "$source_file")
        backup_name="${filename%.${filename##*.}}-${timestamp}.${filename##*.}"
    fi
    
    local backup_path="$backup_dir/$backup_name"
    
    cp "$source_file" "$backup_path"
    log_info "Artifact backed up: $backup_path"
    
    echo "$backup_path"
}

copy_to_shared_volume() {
    local source_file="$1"
    local target_path="${2:-/root/$(basename "$source_file")}"
    
    if [[ ! -f "$source_file" ]]; then
        log_error "Source file not found: $source_file"
        return 1
    fi
    
    cp "$source_file" "$target_path"
    log_info "File copied to shared volume: $target_path"
}

# ========================================
# VALIDATION UTILITIES
# ========================================

validate_cluster_readiness() {
    local kubeconfig_file="${1:-}"
    
    if [[ -z "$kubeconfig_file" ]]; then
        kubeconfig_file=$(find_kubeconfig)
        if [[ $? -ne 0 ]]; then
            log_error "Kubeconfig not found"
            return 1
        fi
    fi
    
    log_info "Validating cluster readiness"
    
    export KUBECONFIG="$kubeconfig_file"
    
    # Check if nodes are ready
    if kubectl get nodes --no-headers | grep -q "Ready"; then
        local ready_nodes
        ready_nodes=$(kubectl get nodes --no-headers | grep -c "Ready" || echo "0")
        local total_nodes
        total_nodes=$(kubectl get nodes --no-headers | wc -l || echo "0")
        
        log_info "✓ Cluster is operational ($ready_nodes/$total_nodes nodes ready)"
        return 0
    else
        log_error "Cluster is not operational"
        return 1
    fi
}

# ========================================
# INITIALIZATION
# ========================================

# Initialize common environment
init_common_environment() {
    log_info "Initializing common environment"
    
    # Setup AWS credentials
    setup_aws_credentials
    
    # Source environment file if it exists
    source_environment_file
    
    # Setup basic directory structure
    mkdir -p /root/tmp
    mkdir -p /root/backups
    
    log_info "Common environment initialized"
}

# Execute initialization if not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    init_common_environment
    log_info "Common utilities loaded successfully"
fi