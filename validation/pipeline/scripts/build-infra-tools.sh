#!/bin/bash
set -e

# Build the infrastructure tools Docker image
# Jenkins copies the script to a temporary directory before execution, so we need
# to reference the Dockerfile via a path relative to the original workspace root.
# When executed from the repo, `tests/validation/...` exists; when executed from
# the Jenkins temp directory (`@tmp/durable-*/script.sh.copy`), we must travel
# back up two levels to reference the actual workspace.

DOCKERFILE_PATH="tests/validation/Dockerfile.validation"

if [ ! -f "$DOCKERFILE_PATH" ]; then
  DOCKERFILE_PATH="../../tests/validation/Dockerfile.validation"
fi

docker build --platform linux/amd64 -t rancher-infra-tools:latest \
  -f "$DOCKERFILE_PATH" .
