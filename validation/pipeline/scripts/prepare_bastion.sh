#!/bin/bash
# Bastion preparation script for Airgap RKE2 pipelines
# This script performs inventory discovery, group_vars rendering, and repo synchronization
# once, then shares paths via environment variables for all subsequent Ansible steps

set -e

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ========================================
# BASTION PREPARATION FUNCTIONS
# ========================================

prepare_ansible_environment() {
    local workspace_dir="${1:-/root/ansible-workspace}"
    
    log_info "Preparing Ansible environment in $workspace_dir"
    
    # Create workspace directory
    mkdir -p "$workspace_dir"
    
    # Setup standard directory structure
    setup_ansible_directories
    
    # Clone or update qa-infra repository if needed
    clone_or_update_qa_infra_repo
    
    # Validate inventory file
    validate_inventory_file
    
    # Generate and prepare group_vars
    prepare_group_vars
    
    # Setup SSH keys
    prepare_ssh_keys
    
    # Create environment file with paths for subsequent steps
    create_ansible_paths_env_file "$workspace_dir"
    
    log_info "Ansible environment preparation completed"
}

prepare_group_vars() {
    log_info "Preparing group_vars"
    
    # Generate group_vars using the centralized script
    if [[ ! -f "/root/group_vars/all.yml" ]]; then
        log_error "Group_vars file not found. Make sure ansible_generate_group_vars.sh was run first."
        exit 1
    fi
    
    # Validate YAML syntax
    validate_yaml_syntax "/root/group_vars/all.yml"
    
    # Copy group_vars to inventory-relative location
    copy_group_vars_to_inventory_location
    
    # Update group_vars with RKE2 version if provided
    if [[ -n "$RKE2_VERSION" ]]; then
        update_group_vars_with_version "/root/ansible/rke2/airgap/group_vars/all.yml" "rke2_version" "$RKE2_VERSION"
    fi
    
    # Update group_vars with Rancher version if provided
    if [[ -n "$RANCHER_VERSION" ]]; then
        update_group_vars_with_version "/root/ansible/rke2/airgap/group_vars/all.yml" "rancher_version" "$RANCHER_VERSION"
    fi
    
    # Create a summary of group_vars content
    create_group_vars_summary "/root/ansible/rke2/airgap/group_vars/all.yml"
    
    log_info "Group_vars preparation completed"
}

prepare_ssh_keys() {
    log_info "Preparing SSH keys"
    
    # Setup SSH key for Jenkins user
    if [[ -n "$AWS_SSH_PEM_KEY" ]]; then
        setup_ssh_key "$AWS_SSH_PEM_KEY" "/root/.ssh/id_rsa"
        
        # Generate public key for Ansible to use
        generate_ssh_public_key "/root/.ssh/id_rsa"
        
        # Create authorized_keys file
        if [[ ! -f /root/.ssh/authorized_keys ]]; then
            cp /root/.ssh/id_rsa.pub /root/.ssh/authorized_keys
            chmod 600 /root/.ssh/authorized_keys
            log_info "Created authorized_keys file from SSH public key"
        fi
        
        # Create SSH config file
        create_ssh_config
        
        log_info "SSH keys preparation completed"
    else
        log_warning "AWS_SSH_PEM_KEY environment variable not set, skipping SSH key setup"
    fi
}

create_ssh_config() {
    local ssh_config_file="/root/.ssh/config"
    
    log_info "Creating SSH config file"
    
    # Extract bastion IP from inventory
    local bastion_ip
    bastion_ip=$(extract_bastion_ip)
    
    if [[ -n "$bastion_ip" ]]; then
        cat > "$ssh_config_file" <<EOF
# SSH configuration for airgap nodes
Host *
    UserKnownHostsFile /dev/null
    StrictHostKeyChecking no
    LogLevel ERROR

Host bastion
    HostName ${bastion_ip}
    User ec2-user
    IdentityFile /root/.ssh/id_rsa
    UserKnownHostsFile /dev/null
    StrictHostKeyChecking no

Host rke2-* ansible-*
    HostName %h
    User ec2-user
    IdentityFile /root/.ssh/id_rsa
    UserKnownHostsFile /dev/null
    StrictHostKeyChecking no
    ProxyJump bastion
EOF
        log_info "SSH config file created with bastion IP: $bastion_ip"
    else
        log_warning "Could not determine bastion IP, creating basic SSH config"
        cat > "$ssh_config_file" <<EOF
# Basic SSH configuration for airgap nodes
Host *
    UserKnownHostsFile /dev/null
    StrictHostKeyChecking no
    LogLevel ERROR
EOF
    fi
    
    chmod 600 "$ssh_config_file"
    log_info "SSH config file created: $ssh_config_file"
}

create_group_vars_summary() {
    local group_vars_file="$1"
    local summary_file="/root/group_vars_summary.txt"
    
    log_info "Creating group_vars summary"
    
    cat > "$summary_file" <<EOF
=== GROUP_VARS SUMMARY ===
File: $group_vars_file
Size: $(wc -c < "$group_vars_file") bytes
Lines: $(wc -l < "$group_vars_file")

Key variables:
EOF
    
    # Extract key variables from group_vars
    local key_vars=(
        "rke2_version"
        "rancher_version"
        "hostname_prefix"
        "rancher_hostname"
        "private_registry_url"
        "enable_private_registry"
    )
    
    for var in "${key_vars[@]}"; do
        local value
        value=$(grep "^${var}:" "$group_vars_file" 2>/dev/null | head -1 | cut -d':' -f2- | xargs || echo "NOT_SET")
        echo "  ${var}: ${value}" >> "$summary_file"
    done
    
    echo "" >> "$summary_file"
    echo "=== END GROUP_VARS SUMMARY ===" >> "$summary_file"
    
    log_info "Group_vars summary created: $summary_file"
}

create_ansible_paths_env_file() {
    local workspace_dir="$1"
    local env_file="${workspace_dir}/ansible_paths.env"
    
    log_info "Creating Ansible paths environment file: $env_file"
    
    cat > "$env_file" <<EOF
# Environment file with paths for Ansible operations
# Generated by prepare_bastion.sh

# Core paths
ANSIBLE_WORKSPACE="${workspace_dir}"
ANSIBLE_INVENTORY_FILE="/root/ansible/rke2/airgap/inventory.yml"
ANSIBLE_GROUP_VARS_FILE="/root/ansible/rke2/airgap/group_vars/all.yml"

# Repository paths
QA_INFRA_REPO_PATH="/root/qa-infra-automation"

# SSH configuration
SSH_CONFIG_FILE="/root/.ssh/config"
SSH_PRIVATE_KEY="/root/.ssh/id_rsa"
SSH_PUBLIC_KEY="/root/.ssh/id_rsa.pub"

# Kubeconfig paths
KUBECONFIG_SOURCE_PATHS="/root/.kube/config /etc/rancher/rke2/rke2.yaml /root/ansible/rke2/airgap/kubeconfig /tmp/kubeconfig.yaml"
KUBECONFIG_TARGET_PATH="/root/kubeconfig.yaml"

# Log paths
ANSIBLE_LOG_DIR="${workspace_dir}/logs"
mkdir -p "\${ANSIBLE_LOG_DIR}"

# Summary paths
GROUP_VARS_SUMMARY_FILE="/root/group_vars_summary.txt"
EOF
    
    log_info "Ansible paths environment file created: $env_file"
    
    # Export paths to current environment
    export ANSIBLE_WORKSPACE="$workspace_dir"
    export ANSIBLE_INVENTORY_FILE="/root/ansible/rke2/airgap/inventory.yml"
    export ANSIBLE_GROUP_VARS_FILE="/root/ansible/rke2/airgap/group_vars/all.yml"
    export QA_INFRA_REPO_PATH="/root/qa-infra-automation"
    export SSH_CONFIG_FILE="/root/.ssh/config"
    export SSH_PRIVATE_KEY="/root/.ssh/id_rsa"
    export SSH_PUBLIC_KEY="/root/.ssh/id_rsa.pub"
    export GROUP_VARS_SUMMARY_FILE="/root/group_vars_summary.txt"
}

synchronize_repositories() {
    log_info "Synchronizing repositories"
    
    # Sync qa-infra-automation repository if it exists
    if [[ -d "/root/qa-infra-automation" ]]; then
        log_info "Updating qa-infra-automation repository..."
        cd /root/qa-infra-automation
        git fetch origin
        git checkout "${QA_INFRA_REPO_BRANCH:-main}"
        git pull origin "${QA_INFRA_REPO_BRANCH:-main}"
        cd /root
    else
        log_info "Cloning qa-infra-automation repository..."
        clone_or_update_qa_infra_repo
    fi
    
    # Copy repository to workspace directory
    local workspace_dir="${ANSIBLE_WORKSPACE:-/root/ansible-workspace}"
    if [[ -d /root/qa-infra-automation && -n "$workspace_dir" ]]; then
        mkdir -p "${workspace_dir}/qa-infra-automation"
        cp -r /root/qa-infra-automation/* "${workspace_dir}/qa-infra-automation/"
        log_info "qa-infra-automation repository copied to workspace"
    fi
    
    log_info "Repository synchronization completed"
}

validate_ansible_setup() {
    log_info "Validating Ansible setup"
    
    # Validate inventory file
    if [[ ! -f "$ANSIBLE_INVENTORY_FILE" ]]; then
        log_error "Inventory file not found: $ANSIBLE_INVENTORY_FILE"
        exit 1
    fi
    
    # Validate group_vars file
    if [[ ! -f "$ANSIBLE_GROUP_VARS_FILE" ]]; then
        log_error "Group_vars file not found: $ANSIBLE_GROUP_VARS_FILE"
        exit 1
    fi
    
    # Validate SSH key
    if [[ ! -f "$SSH_PRIVATE_KEY" ]]; then
        log_error "SSH private key not found: $SSH_PRIVATE_KEY"
        exit 1
    fi
    
    # Validate SSH config
    if [[ ! -f "$SSH_CONFIG_FILE" ]]; then
        log_error "SSH config file not found: $SSH_CONFIG_FILE"
        exit 1
    fi
    
    # Test SSH connectivity to bastion
    test_ssh_connectivity
    
    log_info "Ansible setup validation completed"
}

test_ssh_connectivity() {
    log_info "Testing SSH connectivity to bastion"
    
    # Extract bastion IP from inventory
    local bastion_ip
    bastion_ip=$(extract_bastion_ip)
    
    if [[ -n "$bastion_ip" ]]; then
        # Test SSH connection to bastion
        if ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no \
            -i "$SSH_PRIVATE_KEY" -F "$SSH_CONFIG_FILE" \
            ec2-user@"$bastion_ip" "echo 'SSH connectivity test successful'" 2>/dev/null; then
            log_info "✓ SSH connectivity to bastion ($bastion_ip) successful"
        else
            log_warning "SSH connectivity to bastion ($bastion_ip) failed"
            log_warning "This might be expected if the infrastructure is still being provisioned"
        fi
    else
        log_warning "Could not determine bastion IP for SSH connectivity test"
    fi
}

# ========================================
# MODE WRAPPER FUNCTIONS
# ========================================

execute_preparation_mode() {
    local mode="${1:-prepare}"
    
    log_info "Executing bastion preparation mode: $mode"
    
    case "$mode" in
        "prepare")
            prepare_ansible_environment
            ;;
        "sync")
            synchronize_repositories
            ;;
        "validate")
            validate_ansible_setup
            ;;
        *)
            log_error "Unknown preparation mode: $mode"
            log_info "Valid modes: prepare, sync, validate"
            exit 1
            ;;
    esac
    
    log_info "Bastion preparation mode '$mode' completed successfully"
}

# ========================================
# INITIALIZATION
# ========================================

# Initialize bastion preparation environment
init_bastion_environment() {
    log_info "Initializing bastion preparation environment"
    
    # Initialize common environment
    init_common_environment
    
    # Validate required bastion preparation variables
    validate_required_variables "QA_INFRA_WORK_PATH" "TF_WORKSPACE"
    
    log_info "Bastion preparation environment initialized"
}

# Execute initialization if not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Parse command line arguments
    if [[ $# -eq 0 ]]; then
        # Default to prepare mode if no arguments provided
        mode="prepare"
    else
        mode="$1"
    fi
    
    # Initialize environment
    init_bastion_environment
    
    # Execute the specified mode
    execute_preparation_mode "$mode"
fi