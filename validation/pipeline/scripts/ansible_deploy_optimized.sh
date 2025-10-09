#!/bin/bash
# Optimized Ansible deployment script for Airgap RKE2 pipelines
# This script consolidates SSH setup, RKE2 deployment, kubectl setup, and Rancher deployment
# into a single optimized workflow with shared state and reduced overhead

set -e

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ========================================
# ANSIBLE DEPLOYMENT CONFIGURATION
# ========================================

# Default configuration
DEFAULT_ANSIBLE_TIMEOUT=45
DEFAULT_PLAYBOOK_VERBOSITY="-v"
DEFAULT_LOG_DIR="/root/ansible-logs"

# Deployment stages
STAGES=("ssh-setup" "rke2-deploy" "kubectl-setup" "rancher-deploy")

# ========================================
# ANSIBLE DEPLOYMENT FUNCTIONS
# ========================================

init_ansible_deployment() {
    local workspace_dir="${1:-/root/ansible-workspace}"
    
    log_info "Initializing optimized Ansible deployment"
    
    # Load paths from bastion preparation
    load_ansible_paths
    
    # Create log directory
    mkdir -p "${ANSIBLE_LOG_DIR:-$DEFAULT_LOG_DIR}"
    
    # Create deployment state file
    create_deployment_state_file
    
    # Validate environment
    validate_deployment_environment
    
    log_info "Ansible deployment initialization completed"
}

load_ansible_paths() {
    local workspace_dir="${ANSIBLE_WORKSPACE:-/root/ansible-workspace}"
    local env_file="${workspace_dir}/ansible_paths.env"
    
    if [[ -f "$env_file" ]]; then
        log_info "Loading Ansible paths from environment file"
        source "$env_file"
        
        # Export paths to current environment
        export ANSIBLE_WORKSPACE="$ANSIBLE_WORKSPACE"
        export ANSIBLE_INVENTORY_FILE="$ANSIBLE_INVENTORY_FILE"
        export ANSIBLE_GROUP_VARS_FILE="$ANSIBLE_GROUP_VARS_FILE"
        export QA_INFRA_REPO_PATH="$QA_INFRA_REPO_PATH"
        export SSH_CONFIG_FILE="$SSH_CONFIG_FILE"
        export SSH_PRIVATE_KEY="$SSH_PRIVATE_KEY"
        export SSH_PUBLIC_KEY="$SSH_PUBLIC_KEY"
        export GROUP_VARS_SUMMARY_FILE="$GROUP_VARS_SUMMARY_FILE"
        
        log_info "Ansible paths loaded successfully"
    else
        log_warning "Ansible paths environment file not found: $env_file"
        log_warning "Using default paths"
        
        # Set default paths
        export ANSIBLE_WORKSPACE="${ANSIBLE_WORKSPACE:-/root/ansible-workspace}"
        export ANSIBLE_INVENTORY_FILE="${ANSIBLE_INVENTORY_FILE:-/root/ansible/rke2/airgap/inventory.yml}"
        export ANSIBLE_GROUP_VARS_FILE="${ANSIBLE_GROUP_VARS_FILE:-/root/ansible/rke2/airgap/group_vars/all.yml}"
        export QA_INFRA_REPO_PATH="${QA_INFRA_REPO_PATH:-/root/qa-infra-automation}"
        export SSH_CONFIG_FILE="${SSH_CONFIG_FILE:-/root/.ssh/config}"
        export SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY:-/root/.ssh/id_rsa}"
        export SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-/root/.ssh/id_rsa.pub}"
    fi
    
    # Override with environment variables if they exist
    export ANSIBLE_LOG_DIR="${ANSIBLE_LOG_DIR:-$DEFAULT_LOG_DIR}"
    export ANSIBLE_TIMEOUT="${ANSIBLE_TIMEOUT:-$DEFAULT_ANSIBLE_TIMEOUT}"
    export ANSIBLE_VERBOSITY="${ANSIBLE_VERBOSITY:-$DEFAULT_PLAYBOOK_VERBOSITY}"
}

create_deployment_state_file() {
    local state_file="${ANSIBLE_LOG_DIR}/deployment_state.json"
    
    log_info "Creating deployment state file: $state_file"
    
    cat > "$state_file" <<EOF
{
  "deployment_id": "$(uuidgen)",
  "start_time": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "stages": {
EOF
    
    # Add initial stage states
    local first=true
    for stage in "${STAGES[@]}"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo "," >> "$state_file"
        fi
        echo "    \"${stage}\": {\"status\": \"pending\", \"start_time\": null, \"end_time\": null, \"exit_code\": null}" >> "$state_file"
    done
    
    cat >> "$state_file" <<EOF
  },
  "config": {
    "rke2_version": "${RKE2_VERSION:-not_set}",
    "rancher_version": "${RANCHER_VERSION:-not_set}",
    "hostname_prefix": "${HOSTNAME_PREFIX:-not_set}",
    "rancher_hostname": "${RANCHER_HOSTNAME:-not_set}"
  }
}
EOF
    
    export DEPLOYMENT_STATE_FILE="$state_file"
    log_info "Deployment state file created: $state_file"
}

validate_deployment_environment() {
    log_info "Validating deployment environment"
    
    # Validate required files
    local required_files=(
        "$ANSIBLE_INVENTORY_FILE"
        "$ANSIBLE_GROUP_VARS_FILE"
        "$SSH_PRIVATE_KEY"
        "$SSH_CONFIG_FILE"
    )
    
    for file in "${required_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            log_error "Required file not found: $file"
            exit 1
        fi
    done
    
    # Validate required directories
    local required_dirs=(
        "$ANSIBLE_WORKSPACE"
        "$(dirname "$ANSIBLE_INVENTORY_FILE")"
        "$(dirname "$ANSIBLE_GROUP_VARS_FILE")"
        "$(dirname "$SSH_PRIVATE_KEY")"
    )
    
    for dir in "${required_dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            log_error "Required directory not found: $dir"
            exit 1
        fi
    done
    
    # Validate inventory structure
    validate_inventory_file "$ANSIBLE_INVENTORY_FILE"
    
    # Validate SSH key permissions
    local key_perms
    key_perms=$(stat -c "%a" "$SSH_PRIVATE_KEY")
    if [[ "$key_perms" != "600" ]]; then
        log_warning "SSH key has unusual permissions: $key_perms (expected: 600)"
    fi
    
    log_info "Deployment environment validation completed"
}

update_stage_status() {
    local stage="$1"
    local status="$2"
    local state_file="${DEPLOYMENT_STATE_FILE}"
    
    if [[ ! -f "$state_file" ]]; then
        log_warning "Deployment state file not found: $state_file"
        return 1
    fi
    
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    
    # Create a temporary file with the updated state
    local temp_file
    temp_file=$(mktemp)
    
    if [[ "$status" == "start" ]]; then
        # Update stage status to running and set start time
        jq ".stages.${stage}.status = \"running\" | .stages.${stage}.start_time = \"${timestamp}\"" "$state_file" > "$temp_file"
    elif [[ "$status" == "success" ]]; then
        # Update stage status to success, set end time, and exit code
        jq ".stages.${stage}.status = \"success\" | .stages.${stage}.end_time = \"${timestamp}\" | .stages.${stage}.exit_code = 0" "$state_file" > "$temp_file"
    elif [[ "$status" == "failure" ]]; then
        # Update stage status to failure, set end time, and exit code
        local exit_code="${3:-1}"
        jq ".stages.${stage}.status = \"failure\" | .stages.${stage}.end_time = \"${timestamp}\" | .stages.${stage}.exit_code = ${exit_code}" "$state_file" > "$temp_file"
    fi
    
    # Replace the original state file with the updated one
    mv "$temp_file" "$state_file"
    
    log_info "Stage '${stage}' status updated to '${status}'"
}

run_ansible_playbook() {
    local playbook_name="$1"
    local stage_name="$2"
    local log_prefix="$3"
    local extra_vars="$4"
    local timeout="${5:-$ANSIBLE_TIMEOUT}"
    
    local playbook_path="${QA_INFRA_REPO_PATH}/ansible/rke2/airgap/playbooks/${playbook_name}"
    local log_file="${ANSIBLE_LOG_DIR}/${log_prefix}.log"
    
    log_info "Running Ansible playbook: $playbook_name"
    update_stage_status "$stage_name" "start"
    
    if [[ ! -f "$playbook_path" ]]; then
        log_error "Playbook not found: $playbook_path"
        update_stage_status "$stage_name" "failure" "1"
        return 1
    fi
    
    # Prepare ansible command
    local ansible_cmd="cd ${QA_INFRA_REPO_PATH}/ansible/rke2/airgap && ANSIBLE_HOST_KEY_CHECKING=False ANSIBLE_SSH_ARGS='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null' ansible-playbook -i ${ANSIBLE_INVENTORY_FILE} playbooks/${playbook_name} ${ANSIBLE_VERBOSITY} --timeout ${timeout}"
    
    # Add extra variables if provided
    if [[ -n "$extra_vars" ]]; then
        ansible_cmd="$ansible_cmd $extra_vars"
    fi
    
    log_info "Executing: $ansible_cmd"
    
    # Run the playbook and capture output
    local exit_code=0
    eval "$ansible_cmd" 2>&1 | tee "$log_file" || exit_code=$?
    
    # Copy log to shared volume
    cp "$log_file" "/root/${log_prefix}.log"
    
    # Update stage status based on exit code
    if [[ $exit_code -eq 0 ]]; then
        update_stage_status "$stage_name" "success"
        log_info "✅ Playbook '$playbook_name' completed successfully"
    else
        update_stage_status "$stage_name" "failure" "$exit_code"
        log_error "❌ Playbook '$playbook_name' failed with exit code: $exit_code"
        
        # Handle specific failure scenarios
        handle_playbook_failure "$stage_name" "$exit_code" "$log_file"
    fi
    
    return $exit_code
}

handle_playbook_failure() {
    local stage_name="$1"
    local exit_code="$2"
    local log_file="$3"
    
    log_info "Handling playbook failure for stage: $stage_name (exit code: $exit_code)"
    
    # Check if this is an Ansible exit code 2 (failed tasks) but deployment might still be successful
    if [[ $exit_code -eq 2 && ("$stage_name" == "rke2-deploy" || "$stage_name" == "rancher-deploy") ]]; then
        log_warning "Ansible returned exit code 2 (failed tasks), checking if deployment actually succeeded..."
        
        # Give a moment for any async operations to complete
        sleep 10
        
        # Check if the deployment actually succeeded based on the stage
        if [[ "$stage_name" == "rke2-deploy" ]]; then
            check_rke2_deployment_success
        elif [[ "$stage_name" == "rancher-deploy" ]]; then
            check_rancher_deployment_success
        fi
        
        local deployment_check_result=$?
        
        if [[ $deployment_check_result -eq 0 ]]; then
            log_info "Despite Ansible task failures, deployment appears to be successful"
            log_info "Updating stage status to success"
            # Update stage status back to success
            local temp_file
            temp_file=$(mktemp)
            local timestamp
            timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
            jq ".stages.${stage_name}.status = \"success\" | .stages.${stage_name}.end_time = \"${timestamp}\" | .stages.${stage_name}.exit_code = 0" "$DEPLOYMENT_STATE_FILE" > "$temp_file"
            mv "$temp_file" "$DEPLOYMENT_STATE_FILE"
            return 0
        else
            log_error "Deployment check failed, keeping stage status as failure"
            return 1
        fi
    else
        log_error "Critical failure in stage: $stage_name"
        return 1
    fi
}

check_rke2_deployment_success() {
    log_info "Checking if RKE2 deployment succeeded despite Ansible task failures"
    
    # Try to find a kubeconfig
    local kubeconfig_file
    kubeconfig_file=$(find_kubeconfig)
    
    if [[ $? -eq 0 && -n "$kubeconfig_file" ]]; then
        log_info "Found kubeconfig: $kubeconfig_file"
        
        # Update kubeconfig to use bastion IP
        update_kubeconfig_server "$kubeconfig_file"
        
        # Check if nodes are ready
        if validate_cluster_readiness "$kubeconfig_file"; then
            log_info "✓ RKE2 cluster is operational despite Ansible task failures"
            return 0
        else
            log_error "❌ RKE2 cluster is not operational"
            return 1
        fi
    else
        log_error "❌ Kubeconfig not found, cannot validate RKE2 deployment"
        return 1
    fi
}

check_rancher_deployment_success() {
    log_info "Checking if Rancher deployment succeeded despite Ansible task failures"
    
    # Try to find a kubeconfig
    local kubeconfig_file
    kubeconfig_file=$(find_kubeconfig)
    
    if [[ $? -eq 0 && -n "$kubeconfig_file" ]]; then
        log_info "Found kubeconfig: $kubeconfig_file"
        
        # Check if Rancher pods are ready
        if kubectl --kubeconfig="$kubeconfig_file" get pods -n cattle-system --no-headers | grep -q "1/1.*Running"; then
            log_info "✓ Rancher pods are operational despite Ansible task failures"
            return 0
        else
            log_error "❌ Rancher pods are not operational"
            return 1
        fi
    else
        log_error "❌ Kubeconfig not found, cannot validate Rancher deployment"
        return 1
    fi
}

run_deployment_stages() {
    local stages=("$@")
    local failed_stages=()
    local overall_exit_code=0
    
    log_info "Running deployment stages: ${stages[*]}"
    
    for stage in "${stages[@]}"; do
        log_info "=========================================="
        log_info "Starting stage: $stage"
        log_info "=========================================="
        
        local stage_exit_code=0
        
        case "$stage" in
            "ssh-setup")
                run_ssh_setup_stage || stage_exit_code=$?
                ;;
            "rke2-deploy")
                run_rke2_deploy_stage || stage_exit_code=$?
                ;;
            "kubectl-setup")
                run_kubectl_setup_stage || stage_exit_code=$?
                ;;
            "rancher-deploy")
                run_rancher_deploy_stage || stage_exit_code=$?
                ;;
            *)
                log_error "Unknown deployment stage: $stage"
                stage_exit_code=1
                ;;
        esac
        
        if [[ $stage_exit_code -ne 0 ]]; then
            failed_stages+=("$stage")
            overall_exit_code=1
            
            # Check if we should continue on failure
            if [[ "${CONTINUE_ON_FAILURE:-false}" != "true" ]]; then
                log_error "Stage '$stage' failed, stopping deployment"
                break
            else
                log_warning "Stage '$stage' failed, continuing deployment (CONTINUE_ON_FAILURE=true)"
            fi
        fi
        
        log_info "Stage '$stage' completed with exit code: $stage_exit_code"
    done
    
    # Report failed stages
    if [[ ${#failed_stages[@]} -gt 0 ]]; then
        log_error "=========================================="
        log_error "FAILED STAGES: ${failed_stages[*]}"
        log_error "=========================================="
    else
        log_info "=========================================="
        log_info "ALL STAGES COMPLETED SUCCESSFULLY"
        log_info "=========================================="
    fi
    
    # Update final deployment state
    final_deployment_state_update "$overall_exit_code"
    
    return $overall_exit_code
}

run_ssh_setup_stage() {
    local extra_vars=""
    
    # Add RKE2 version as extra variable if available
    if [[ -n "$RKE2_VERSION" ]]; then
        extra_vars="-e rke2_version=$RKE2_VERSION"
    fi
    
    run_ansible_playbook "setup/setup-ssh-keys.yml" "ssh-setup" "ssh_setup" "$extra_vars"
}

run_rke2_deploy_stage() {
    local extra_vars=""
    
    # Add RKE2 version as extra variable if available
    if [[ -n "$RKE2_VERSION" ]]; then
        extra_vars="-e rke2_version=$RKE2_VERSION"
    fi
    
    run_ansible_playbook "deploy/rke2-tarball-playbook.yml" "rke2-deploy" "rke2_deployment" "$extra_vars"
}

run_kubectl_setup_stage() {
    local extra_vars=""
    
    # Add RKE2 version as extra variable if available
    if [[ -n "$RKE2_VERSION" ]]; then
        extra_vars="-e rke2_version=$RKE2_VERSION"
    fi
    
    run_ansible_playbook "setup/setup-kubectl-access.yml" "kubectl-setup" "kubectl_access" "$extra_vars"
}

run_rancher_deploy_stage() {
    local extra_vars=""
    
    # Add Rancher version as extra variable if available
    if [[ -n "$RANCHER_VERSION" ]]; then
        extra_vars="-e rancher_version=$RANCHER_VERSION"
    fi
    
    run_ansible_playbook "deploy/rancher-deployment.yml" "rancher-deploy" "rancher_deployment" "$extra_vars"
}

final_deployment_state_update() {
    local exit_code="$1"
    local state_file="${DEPLOYMENT_STATE_FILE}"
    
    if [[ ! -f "$state_file" ]]; then
        log_warning "Deployment state file not found: $state_file"
        return 1
    fi
    
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    
    # Update final deployment state
    local temp_file
    temp_file=$(mktemp)
    
    local status="success"
    if [[ $exit_code -ne 0 ]]; then
        status="failed"
    fi
    
    jq ".end_time = \"${timestamp}\" | .exit_code = ${exit_code} | .status = \"${status}\"" "$state_file" > "$temp_file"
    
    # Replace the original state file with the updated one
    mv "$temp_file" "$state_file"
    
    log_info "Final deployment state updated (status: $status, exit_code: $exit_code)"
    
    # Copy state file to shared volume
    cp "$state_file" "/root/deployment_state.json"
}

generate_deployment_summary() {
    local state_file="${DEPLOYMENT_STATE_FILE}"
    local summary_file="${ANSIBLE_LOG_DIR}/deployment_summary.txt"
    
    log_info "Generating deployment summary"
    
    if [[ ! -f "$state_file" ]]; then
        log_warning "Deployment state file not found: $state_file"
        return 1
    fi
    
    cat > "$summary_file" <<EOF
====================================
DEPLOYMENT SUMMARY
====================================
Deployment ID: $(jq -r '.deployment_id' "$state_file")
Start Time: $(jq -r '.start_time' "$state_file")
End Time: $(jq -r '.end_time // "N/A"' "$state_file")
Exit Code: $(jq -r '.exit_code' "$state_file")
Status: $(jq -r '.status // "N/A"' "$state_file")

Configuration:
- RKE2 Version: $(jq -r '.config.rke2_version' "$state_file")
- Rancher Version: $(jq -r '.config.rancher_version' "$state_file")
- Hostname Prefix: $(jq -r '.config.hostname_prefix' "$state_file")
- Rancher Hostname: $(jq -r '.config.rancher_hostname' "$state_file")

Stages:
EOF
    
    # Add stage information
    for stage in "${STAGES[@]}"; do
        local stage_data
        stage_data=$(jq ".stages.${stage}" "$state_file")
        
        local stage_status
        stage_status=$(echo "$stage_data" | jq -r '.status')
        
        local stage_start
        stage_start=$(echo "$stage_data" | jq -r '.start_time // "N/A"')
        
        local stage_end
        stage_end=$(echo "$stage_data" | jq -r '.end_time // "N/A"')
        
        local stage_exit_code
        stage_exit_code=$(echo "$stage_data" | jq -r '.exit_code // "N/A"')
        
        echo "- ${stage}: ${stage_status} (start: ${stage_start}, end: ${stage_end}, exit_code: ${stage_exit_code})" >> "$summary_file"
    done
    
    cat >> "$summary_file" <<EOF

====================================
END DEPLOYMENT SUMMARY
====================================
EOF
    
    # Copy summary to shared volume
    cp "$summary_file" "/root/deployment_summary.txt"
    
    log_info "Deployment summary generated: $summary_file"
}

# ========================================
# MODE WRAPPER FUNCTIONS
# ========================================

execute_deployment_mode() {
    local mode="${1:-deploy}"
    
    log_info "Executing Ansible deployment mode: $mode"
    
    case "$mode" in
        "init")
            init_ansible_deployment
            ;;
        "deploy")
            init_ansible_deployment
            run_deployment_stages "${STAGES[@]}"
            generate_deployment_summary
            ;;
        "deploy-custom")
            shift
            local custom_stages=("$@")
            if [[ ${#custom_stages[@]} -eq 0 ]]; then
                log_error "No stages specified for custom deployment"
                log_info "Usage: $0 deploy-custom <stage1> <stage2> ..."
                exit 1
            fi
            init_ansible_deployment
            run_deployment_stages "${custom_stages[@]}"
            generate_deployment_summary
            ;;
        "summary")
            generate_deployment_summary
            ;;
        *)
            log_error "Unknown deployment mode: $mode"
            log_info "Valid modes: init, deploy, deploy-custom <stages...>, summary"
            exit 1
            ;;
    esac
    
    log_info "Ansible deployment mode '$mode' completed"
}

# ========================================
# INITIALIZATION
# ========================================

# Initialize Ansible deployment environment
init_ansible_deployment_environment() {
    log_info "Initializing Ansible deployment environment"
    
    # Initialize common environment
    init_common_environment
    
    # Validate required Ansible deployment variables
    validate_required_variables "QA_INFRA_WORK_PATH" "TF_WORKSPACE"
    
    log_info "Ansible deployment environment initialized"
}

# Execute initialization if not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Parse command line arguments
    if [[ $# -eq 0 ]]; then
        # Default to deploy mode if no arguments provided
        mode="deploy"
    else
        mode="$1"
        shift
    fi
    
    # Initialize environment
    init_ansible_deployment_environment
    
    # Execute the specified mode
    execute_deployment_mode "$mode" "$@"
fi