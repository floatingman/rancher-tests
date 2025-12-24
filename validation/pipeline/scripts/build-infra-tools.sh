#!/bin/bash
set -e

# Build the infrastructure tools Docker image (Tofu, Ansible, AWS CLI)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

DOCKERFILE_PATH="${REPO_ROOT}/validation/pipeline/Dockerfile.infra"

docker build --platform linux/amd64 -t rancher-infra-tools:latest \
  -f "${DOCKERFILE_PATH}" "${REPO_ROOT}"
