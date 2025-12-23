#!/bin/bash
set -e

# Build the infrastructure tools Docker image
# Script is executed from the Jenkins workspace root
docker build --platform linux/amd64 -t rancher-infra-tools:latest \
  -f tests/validation/Dockerfile.validation .
