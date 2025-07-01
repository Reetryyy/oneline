#!/bin/bash

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Progress tracking
TOTAL_STEPS=8
CURRENT_STEP=0

print_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    echo -e "${BLUE}[${CURRENT_STEP}/${TOTAL_STEPS}]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

progress_bar() {
    local current=$1
    local total=$2
    local width=50
    local percentage=$((current * 100 / total))
    local completed=$((current * width / total))
    local remaining=$((width - completed))
    
    printf "\rProgress: ["
    printf "%${completed}s" | tr ' ' '='
    printf "%${remaining}s" | tr ' ' '-'
    printf "] %d%%" $percentage
    
    if [ $current -eq $total ]; then
        echo
    fi
}

detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO=$ID
        VERSION=$VERSION_ID
        CODENAME=${VERSION_CODENAME:-$VERSION}
    else
        print_error "Cannot detect Linux distribution"
        exit 1
    fi
}

setup_ubuntu_debian() {
    # Remove old Docker packages
    sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    
    # Update package index
    sudo apt-get update
    
    # Install dependencies
    sudo apt-get install -y ca-certificates curl gnupg lsb-release
    
    # Add Docker GPG key
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$DISTRO/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    
    # Add Docker repository
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$DISTRO $CODENAME stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Update package index
    sudo apt-get update
    
    # Install Docker
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

setup_centos_rhel_fedora() {
    # Remove old Docker packages
    sudo dnf remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-selinux docker-engine-selinux docker-engine 2>/dev/null || true
    
    # Install dependencies
    sudo dnf install -y dnf-plugins-core
    
    # Add Docker repository
    if [[ "$DISTRO" == "fedora" ]]; then
        sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
    else
        sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    fi
    
    # Install Docker
    sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

setup_opensuse() {
    # Remove old Docker packages
    sudo zypper remove -y docker docker-runc 2>/dev/null || true
    
    # Add Docker repository
    sudo zypper addrepo https://download.docker.com/linux/sles/docker-ce.repo
    sudo zypper refresh
    
    # Install Docker
    sudo zypper install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

setup_arch() {
    # Update package database
    sudo pacman -Sy
    
    # Install Docker
    sudo pacman -S --noconfirm docker docker-compose
}

install_docker() {
    case "$DISTRO" in
        ubuntu|debian)
            setup_ubuntu_debian
            ;;
        centos|rhel|rocky|almalinux)
            setup_centos_rhel_fedora
            ;;
        fedora)
            setup_centos_rhel_fedora
            ;;
        opensuse*|sles)
            setup_opensuse
            ;;
        arch|manjaro)
            setup_arch
            ;;
        *)
            print_error "Unsupported distribution: $DISTRO"
            exit 1
            ;;
    esac
}

configure_docker() {
    # Add user to docker group
    sudo usermod -aG docker $USER
    
    # Start and enable Docker service
    sudo systemctl start docker
    sudo systemctl enable docker
}

verify_installation() {
    # Test Docker installation
    if docker --version >/dev/null 2>&1; then
        DOCKER_VERSION=$(docker --version | cut -d' ' -f3 | tr -d ',')
        print_success "Docker $DOCKER_VERSION installed successfully"
    else
        print_error "Docker installation failed"
        return 1
    fi
    
    # Test Docker Compose installation
    if docker compose version >/dev/null 2>&1; then
        COMPOSE_VERSION=$(docker compose version --short)
        print_success "Docker Compose $COMPOSE_VERSION installed successfully"
    else
        print_error "Docker Compose installation failed"
        return 1
    fi
}

main() {
    echo "Docker Installation Script"
    echo "=========================="
    
    print_step "Detecting Linux distribution"
    detect_distro
    print_success "Detected: $DISTRO $VERSION"
    progress_bar $CURRENT_STEP $TOTAL_STEPS
    
    print_step "Checking system requirements"
    if [[ $EUID -eq 0 ]]; then
        print_error "This script should not be run as root"
        exit 1
    fi
    print_success "System requirements check passed"
    progress_bar $CURRENT_STEP $TOTAL_STEPS
    
    print_step "Removing old Docker installations"
    progress_bar $CURRENT_STEP $TOTAL_STEPS
    
    print_step "Installing system dependencies"
    progress_bar $CURRENT_STEP $TOTAL_STEPS
    
    print_step "Adding Docker repository"
    progress_bar $CURRENT_STEP $TOTAL_STEPS
    
    print_step "Installing Docker and Docker Compose"
    install_docker
    print_success "Docker packages installed"
    progress_bar $CURRENT_STEP $TOTAL_STEPS
    
    print_step "Configuring Docker service"
    configure_docker
    print_success "Docker service configured and started"
    progress_bar $CURRENT_STEP $TOTAL_STEPS
    
    print_step "Verifying installation"
    verify_installation
    progress_bar $CURRENT_STEP $TOTAL_STEPS
    
    echo
    echo "Installation Summary:"
    echo "===================="
    docker --version
    docker compose version
    echo
    print_success "Docker installation completed successfully"
    print_warning "Please log out and log back in to use Docker without sudo"
    
    # Test Docker access
    if groups $USER | grep -q docker; then
        echo
        echo "Testing Docker access..."
        if newgrp docker <<< 'docker run --rm hello-world' 2>/dev/null; then
            print_success "Docker is working correctly"
        else
            print_warning "Docker test failed - you may need to restart your session"
        fi
    fi
}

# Check if running with bash
if [ -z "$BASH_VERSION" ]; then
    print_error "This script requires bash"
    exit 1
fi

# Run main function
main "$@"
