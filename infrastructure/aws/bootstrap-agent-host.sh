#!/usr/bin/env bash

set -euo pipefail

if (( EUID != 0 )); then
  echo "This bootstrap must be run as root." >&2
  exit 1
fi

dnf install -y docker
systemctl enable --now docker

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker installation failed: docker binary was not found." >&2
  exit 1
fi

if ! systemctl is-active --quiet docker; then
  echo "Docker startup failed: docker service is not active." >&2
  exit 1
fi

if ! docker info >/dev/null; then
  echo "Docker verification failed: the daemon did not respond." >&2
  exit 1
fi

echo "Docker version: $(docker --version)"
echo "Docker service state: $(systemctl is-active docker)"
echo "Machine architecture: $(uname -m)"
