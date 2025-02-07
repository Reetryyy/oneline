#!/bin/bash

set -e  # Exit on error

echo "🚀 Starting Docker Installation on Ubuntu $(lsb_release -cs)..."

# Remove old versions
sudo apt-get remove -y docker docker-engine docker.io containerd runc || true

# Update system packages
sudo apt-get update

# Install required dependencies
sudo apt-get install -y ca-certificates curl gnupg lsb-release

# Remove old Docker key (if exists)
sudo rm -f /usr/share/keyrings/docker-archive-keyring.gpg

# Add Docker GPG key
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

# Add Docker repo
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update package lists again
sudo apt-get update

# Install Docker
sudo apt-get install -y docker-ce docker-ce-cli containerd.io

# Add user to Docker group (avoiding sudo for Docker commands)
sudo usermod -aG docker $USER
echo "⚠️  Please log out and log back in to apply Docker group changes."

# Install Docker Compose (latest stable version)
DOCKER_COMPOSE_VERSION="v2.2.2"
ARCH=$(uname -m)
sudo curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-${ARCH}" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# Verify installations
docker --version
docker-compose --version

echo "✅ Docker & Docker Compose installed successfully!"
echo "🔄 Please restart your session to apply group changes."
