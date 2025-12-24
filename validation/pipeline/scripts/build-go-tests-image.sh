#!/bin/bash
set -euo pipefail

# Build the Go tests Docker image (includes Go toolchain + gotestsum + repo)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

DOCKERFILE_PATH="${REPO_ROOT}/validation/Dockerfile.validation"

docker build --platform linux/amd64 -t rancher-go-tests:latest \
  -f "${DOCKERFILE_PATH}" "${REPO_ROOT}"
