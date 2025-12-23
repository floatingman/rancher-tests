#!/bin/bash
set -e

# Build the infrastructure tools Docker image
# Script is executed from validation/pipeline/scripts directory via container.build()
# Need to go up two levels to reach tests directory from workspace root
docker build --platform linux/amd64 -t rancher-infra-tools:latest \
  -f ../../tests/validation/Dockerfile.validation .
