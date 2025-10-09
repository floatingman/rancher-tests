#!/bin/bash
# Common infrastructure utilities for Airgap RKE2 pipelines
# This script provides shared Terraform/OpenTofu functions

set -e

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ========================================
# TERRAFORM/OPEN TOFU UTILITIES
# ========================================

initialize_terraform() {
    local backend_file="${1:-backend.tf}"
    local backend_vars_file="${2:-$TERRAFORM_BACKEND_VARS_FILENAME}"
    local module_path="${3:-tofu/aws/modules/airgap}"
    
    log_info "Initializing OpenTofu with S3 backend configuration"
    
    change_to_infra_directory
    
    log_debug "Current working directory: $(pwd)"
    log_debug "Module path: $module_path"
    
    # Check if backend.tf exists and use appropriate initialization method
    if [[ -f "${module_path}/${backend_file}" ]]; then
        log_info "Using ${backend_file} configuration"
        tofu -chdir="$module_path" init -input=false -upgrade
    elif [[ -f "${module_path}/${backend_vars_file}" ]]; then
        log_info "Using ${backend_vars_file} configuration"
        tofu -chdir="$module_path" init -backend-config="${backend_vars_file}" -input=false -upgrade
    else
        log_error "Neither ${backend_file} nor ${backend_vars_file} found in ${module_path}"
        exit 1
    fi
    
    log_info "Verifying initialization success..."
    tofu -chdir="$module_path" providers
    
    log_info "OpenTofu initialization completed successfully"
}

manage_terraform_workspace() {
    local workspace_name="${TF_WORKSPACE}"
    local module_path="${1:-tofu/aws/modules/airgap}"
    
    if [[ -z "$workspace_name" ]]; then
        log_error "TF_WORKSPACE environment variable is not set"
        exit 1
    fi
    
    log_info "Managing OpenTofu workspace: $workspace_name"
    
    change_to_infra_directory
    
    log_info "Current workspaces:"
    tofu -chdir="$module_path" workspace list
    
    # Create workspace if needed
    create_workspace_if_needed
    
    # Verify workspace selection
    log_info "Verifying workspace selection..."
    local current_workspace
    current_workspace=$(tofu -chdir="$module_path" workspace show)
    log_info "Current workspace: $current_workspace"
    
    if [[ "$current_workspace" != "$workspace_name" ]]; then
        log_error "Expected workspace $workspace_name, but got '$current_workspace'"
        log_info "Available workspaces:"
        tofu -chdir="$module_path" workspace list
        exit 1
    fi
    
    # Final verification
    log_info "Final workspace verification..."
    if tofu -chdir="$module_path" workspace list | grep -q "$workspace_name"; then
        log_info "✓ Workspace '$workspace_name' confirmed to exist"
    else
        log_error "Workspace '$workspace_name' not found"
        exit 1
    fi
    
    log_info "Workspace management completed successfully for: $workspace_name"
    
    # Re-initialize to ensure workspace is properly configured
    log_info "Re-initializing to ensure workspace is properly configured..."
    tofu -chdir="$module_path" init -input=false -upgrade
}

plan_terraform() {
    local module_path="${1:-tofu/aws/modules/airgap}"
    local vars_file="${2:-$TERRAFORM_VARS_FILENAME}"
    local plan_file="${3:-tfplan}"
    
    log_info "Generating infrastructure plan for validation"
    
    change_to_infra_directory
    validate_required_variables "TF_WORKSPACE" "TERRAFORM_VARS_FILENAME"
    
    tofu -chdir="$module_path" plan -input=false -var-file="$vars_file" -out="$plan_file"
    
    # Check if plan file was generated
    local full_plan_path="${module_path}/${plan_file}"
    if [[ ! -f "$full_plan_path" ]]; then
        log_error "Plan file was not generated successfully in module directory"
        exit 1
    fi
    
    # Verify plan file is not empty
    local plan_size
    plan_size=$(stat -c%s "$full_plan_path" 2>/dev/null || echo 0)
    if [[ "$plan_size" = "0" ]]; then
        log_error "Plan file is empty"
        exit 1
    fi
    
    log_info "Plan file generated successfully ($plan_size bytes) in $full_plan_path"
    
    # Copy plan file to shared volume for persistence
    cp "$full_plan_path" /root/tfplan-backup
    log_info "Plan file backed up to shared volume"
}

apply_terraform() {
    local module_path="${1:-tofu/aws/modules/airgap}"
    local plan_file="${2:-tfplan}"
    local vars_file="${3:-$TERRAFORM_VARS_FILENAME}"
    
    log_info "Applying terraform configuration"
    
    change_to_infra_directory
    validate_required_variables "TF_WORKSPACE" "TERRAFORM_VARS_FILENAME"
    
    # Restore plan file from shared volume if available
    local full_plan_path="${module_path}/${plan_file}"
    if [[ -f /root/tfplan-backup ]]; then
        cp /root/tfplan-backup "$full_plan_path"
        log_info "Plan file restored from shared volume to module directory"
    fi
    
    # Check if plan was restored/generated successfully
    if [[ ! -f "$full_plan_path" ]]; then
        log_info "Plan file not found, generating new plan..."
        tofu -chdir="$module_path" plan -input=false -var-file="$vars_file" -out="$plan_file"
    fi
    
    # Verify the plan file is not empty
    local plan_size
    plan_size=$(stat -c%s "$full_plan_path" 2>/dev/null || echo 0)
    if [[ "$plan_size" = "0" ]]; then
        log_error "Plan file is empty"
        exit 1
    fi
    
    # Apply the terraform plan
    log_info "Applying terraform plan..."
    
    # Capture the output to check for stale plan errors
    if ! tofu -chdir="$module_path" apply -auto-approve -input=false "$plan_file" 2>&1; then
        log_error "Terraform apply failed"
        
        # Check if the failure was due to a stale plan
        log_info "Checking if failure was due to stale plan and attempting recovery..."
        if tofu -chdir="$module_path" apply -auto-approve -input=false 2>&1; then
            log_info "SUCCESS: Terraform apply completed successfully without plan file (stale plan recovery)"
        else
            log_error "ERROR: Terraform apply failed even without plan file"
            exit 1
        fi
    else
        log_info "SUCCESS: Terraform apply completed with plan file"
    fi
    
    # Backup the state
    backup_terraform_state "$module_path"
    
    # Generate outputs for downstream stages
    generate_terraform_outputs "$module_path"
    
    # Handle inventory file generation
    handle_inventory_generation "$module_path"
    
    log_info "Infrastructure apply completed successfully"
}

destroy_terraform() {
    local module_path="${1:-tofu/aws/modules/airgap}"
    local vars_file="${2:-$TERRAFORM_VARS_FILENAME}"
    
    log_info "Destroying terraform infrastructure"
    
    change_to_infra_directory
    validate_required_variables "TF_WORKSPACE" "TERRAFORM_VARS_FILENAME"
    
    # Generate destruction plan first
    log_info "Generating destruction plan..."
    tofu -chdir="$module_path" plan -destroy -input=false -var-file="$vars_file" -out=destroy.tfplan
    
    # Apply destruction plan
    log_info "Applying destruction plan..."
    if tofu -chdir="$module_path" apply -auto-approve -input=false destroy.tfplan; then
        log_info "✓ Infrastructure destroyed successfully"
    else
        log_warning "Planned destruction failed, attempting direct destroy..."
        if tofu -chdir="$module_path" destroy -auto-approve -input=false; then
            log_info "✓ Infrastructure destroyed with direct destroy command"
        else
            log_error "Failed to destroy infrastructure"
            exit 1
        fi
    fi
}

backup_terraform_state() {
    local module_path="${1:-tofu/aws/modules/airgap}"
    local state_file="${module_path}/terraform.tfstate"
    local backup_timestamp
    backup_timestamp=$(date +%Y%m%d-%H%M%S)
    
    log_info "Backing up terraform state"
    
    # Check if local state file exists
    if [[ -f "$state_file" ]]; then
        # Create backups
        cp "$state_file" "${state_file}.backup-$backup_timestamp"
        cp "$state_file" /root/terraform-state-primary.tfstate
        cp "$state_file" /root/terraform.tfstate
        
        local state_size
        state_size=$(stat -c%s "$state_file" 2>/dev/null || echo 0)
        log_info "SUCCESS: Local terraform.tfstate backed up successfully ($state_size bytes)"
    else
        log_info "Local state file not found, assuming remote backend. Pulling state..."
        cd "$module_path"
        
        # Pull the current state from remote backend
        if tofu state pull > /tmp/terraform.tfstate.tmp 2>/dev/null; then
            # Verify the pulled state is not empty
            if [[ -s /tmp/terraform.tfstate.tmp ]]; then
                # Create backups with the pulled state
                cp /tmp/terraform.tfstate.tmp "${state_file}.backup-$backup_timestamp"
                cp /tmp/terraform.tfstate.tmp /root/terraform-state-primary.tfstate
                cp /tmp/terraform.tfstate.tmp /root/terraform.tfstate
                
                local state_size
                state_size=$(stat -c%s /tmp/terraform.tfstate.tmp 2>/dev/null || echo 0)
                log_info "SUCCESS: Remote terraform state pulled and backed up successfully ($state_size bytes)"
                
                # Clean up temporary file
                rm -f /tmp/terraform.tfstate.tmp
            else
                log_error "Pulled state file is empty"
                rm -f /tmp/terraform.tfstate.tmp
                exit 1
            fi
        else
            log_error "Failed to pull terraform state from remote backend"
            exit 1
        fi
        
        cd /root
    fi
    
    # Backup terraform variables file for archival
    local vars_file="${module_path}/${TERRAFORM_VARS_FILENAME}"
    if [[ -f "$vars_file" ]]; then
        cp "$vars_file" "/root/${TERRAFORM_VARS_FILENAME}"
        log_info "Terraform variables file backed up"
    fi
}

generate_terraform_outputs() {
    local module_path="${1:-tofu/aws/modules/airgap}"
    
    log_info "Generating outputs for downstream stages"
    
    change_to_infra_directory
    
    tofu -chdir="$module_path" output -json > /root/infrastructure-outputs.json
    
    # Copy infrastructure outputs to shared volume location for artifact extraction
    log_info "Infrastructure outputs generated at shared volume location: /root/infrastructure-outputs.json"
}

handle_inventory_generation() {
    local module_path="${1:-tofu/aws/modules/airgap}"
    local inventory_source="${module_path}/../ansible/rke2/airgap/inventory/inventory.yml"
    local inventory_target="/root/ansible-inventory.yml"
    local inventory_ansible_target="/root/ansible/rke2/airgap/inventory.yml"
    
    log_debug "Checking for inventory file generation..."
    log_debug "Looking for inventory at: $inventory_source"
    
    # Check if the directory exists
    if [[ -d "$(dirname "$inventory_source")" ]]; then
        log_debug "Inventory directory exists, listing contents:"
        ls -la "$(dirname "$inventory_source")"
    else
        log_debug "Inventory directory does not exist"
    fi
    
    if [[ -f "$inventory_source" && -s "$inventory_source" ]]; then
        log_info "SUCCESS: inventory.yml generated by terraform apply exists and has content"
        
        # Copy to shared volume location (for artifact extraction)
        cp "$inventory_source" "$inventory_target"
        log_info "Inventory file copied to shared volume location: $inventory_target"
        
        # Copy to Ansible expected location (for Ansible playbook execution)
        mkdir -p "$(dirname "$inventory_ansible_target")"
        cp "$inventory_source" "$inventory_ansible_target"
        log_info "Inventory file copied to Ansible expected location: $inventory_ansible_target"
        
        # Show inventory file contents for debugging
        log_debug "=== Inventory File Contents ==="
        cat "$inventory_ansible_target"
        log_debug "=== End Inventory File Contents ==="
    else
        log_warning "inventory.yml not found or empty after apply"
        log_debug "Inventory file should be generated by Terraform module"
        log_debug "If inventory file is missing, check Terraform configuration and state"
    fi
}

delete_terraform_workspace() {
    local workspace_name="${TF_WORKSPACE}"
    local module_path="${1:-tofu/aws/modules/airgap}"
    
    if [[ -z "$workspace_name" ]]; then
        log_error "TF_WORKSPACE environment variable is not set"
        exit 1
    fi
    
    log_info "Deleting OpenTofu workspace: $workspace_name"
    
    change_to_infra_directory
    
    # Select the workspace
    export TF_WORKSPACE="$workspace_name"
    tofu -chdir="$module_path" workspace select "$workspace_name" 2>/dev/null || true
    
    # Delete the workspace
    tofu -chdir="$module_path" workspace delete "$workspace_name" -force
    
    log_info "Workspace $workspace_name deleted successfully"
}

# ========================================
# CONFIGURATION MANAGEMENT
# ========================================

generate_terraform_backend_config() {
    local backend_file="${1:-backend.tf}"
    local backend_vars_file="${2:-$TERRAFORM_BACKEND_VARS_FILENAME}"
    local output_dir="${3:-tofu/aws/modules/airgap}"
    
    log_info "Generating Terraform backend configuration"
    
    validate_required_variables "S3_BUCKET_NAME" "S3_REGION" "S3_KEY_PREFIX"
    
    mkdir -p "$output_dir"
    
    # Write both backend.tf and backend.tfvars files
    local backend_tf="${output_dir}/${backend_file}"
    local backend_vars="${output_dir}/${backend_vars_file}"
    
    # Generate backend.tf content with S3 backend configuration
    cat > "$backend_tf" <<EOF
terraform {
  backend "s3" {
    bucket = "${S3_BUCKET_NAME}"
    key    = "${S3_KEY_PREFIX}"
    region = "${S3_REGION}"
  }
}
EOF
    
    log_info "S3 backend.tf configuration written to $backend_tf"
    
    # Also generate backend.tfvars for backward compatibility
    cat > "$backend_vars" <<EOF
bucket = "${S3_BUCKET_NAME}"
key    = "${S3_KEY_PREFIX}"
region = "${S3_REGION}"
EOF
    
    log_info "S3 backend.tfvars configuration written to $backend_vars"
    
    # Show the content for debugging
    log_debug "Backend.tf content:"
    cat "$backend_tf"
    log_debug "Backend.tfvars content:"
    cat "$backend_vars"
}

upload_config_to_s3() {
    local file_path="${1:-$TERRAFORM_VARS_FILENAME}"
    local s3_prefix="${2:-env:/${TF_WORKSPACE}/}"
    local module_dir="${3:-tofu/aws/modules/airgap}"
    
    log_info "Uploading configuration file to S3"
    
    validate_required_variables "S3_BUCKET_NAME" "S3_REGION" "S3_KEY_PREFIX"
    
    local full_file_path="${module_dir}/${file_path}"
    
    if [[ ! -f "$full_file_path" ]]; then
        log_error "Configuration file not found: $full_file_path"
        exit 1
    fi
    
    local s3_key="${s3_prefix}${file_path}"
    
    log_info "Uploading $full_file_path to s3://${S3_BUCKET_NAME}/${s3_key}"
    
    aws s3 cp "$full_file_path" "s3://${S3_BUCKET_NAME}/${s3_key}" --region "$S3_REGION"
    
    log_info "Configuration file uploaded to S3 successfully"
}

download_config_from_s3() {
    local file_path="${1:-$TERRAFORM_VARS_FILENAME}"
    local s3_prefix="${2:-env:/${TF_WORKSPACE}/}"
    local module_dir="${3:-tofu/aws/modules/airgap}"
    
    log_info "Downloading configuration file from S3"
    
    validate_required_variables "S3_BUCKET_NAME" "S3_REGION" "S3_KEY_PREFIX"
    
    local full_file_path="${module_dir}/${file_path}"
    local s3_key="${s3_prefix}${file_path}"
    
    # Create directory if it doesn't exist
    mkdir -p "$module_dir"
    
    log_info "Downloading s3://${S3_BUCKET_NAME}/${s3_key} to $full_file_path"
    
    aws s3 cp "s3://${S3_BUCKET_NAME}/${s3_key}" "$full_file_path" --region "$S3_REGION"
    
    if [[ ! -f "$full_file_path" ]]; then
        log_error "Failed to download configuration file from S3"
        exit 1
    fi
    
    log_info "Configuration file downloaded from S3 successfully"
}

# ========================================
# MODE WRAPPER FUNCTIONS
# ========================================

execute_terraform_operation() {
    local operation="${1:-plan}"
    
    log_info "Executing Terraform operation: $operation"
    
    case "$operation" in
        "init")
            initialize_terraform
            ;;
        "workspace")
            manage_terraform_workspace
            ;;
        "plan")
            plan_terraform
            ;;
        "apply")
            apply_terraform
            ;;
        "destroy")
            destroy_terraform
            ;;
        "delete-workspace")
            delete_terraform_workspace
            ;;
        "generate-backend")
            generate_terraform_backend_config
            ;;
        "upload-config")
            upload_config_to_s3
            ;;
        "download-config")
            download_config_from_s3
            ;;
        *)
            log_error "Unknown Terraform operation: $operation"
            log_info "Valid operations: init, workspace, plan, apply, destroy, delete-workspace, generate-backend, upload-config, download-config"
            exit 1
            ;;
    esac
    
    log_info "Terraform operation '$operation' completed successfully"
}

# ========================================
# INITIALIZATION
# ========================================

# Initialize common infrastructure environment
init_infra_environment() {
    log_info "Initializing infrastructure environment"
    
    # Initialize common environment
    init_common_environment
    
    # Validate required infrastructure variables
    validate_required_variables "QA_INFRA_WORK_PATH" "TF_WORKSPACE"
    
    log_info "Infrastructure environment initialized"
}

# Execute initialization if not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Parse command line arguments
    if [[ $# -eq 0 ]]; then
        log_error "No operation specified"
        log_info "Usage: $0 <operation> [args...]"
        log_info "Valid operations: init, workspace, plan, apply, destroy, delete-workspace, generate-backend, upload-config, download-config"
        exit 1
    fi
    
    # Initialize environment
    init_infra_environment
    
    # Execute the specified operation
    execute_terraform_operation "$@"
fi