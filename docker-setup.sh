#!/bin/bash

# Docker Installation Script
# ==========================================

set -euo pipefail

# ============================================================================
# CONFIGURATION & CONSTANTS
# ============================================================================

readonly SCRIPT_VERSION="2.1.5"
readonly SCRIPT_NAME="docker-install"
readonly LOG_FILE="/tmp/${SCRIPT_NAME}-$(date +%Y%m%d-%H%M%S).log"

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_INVALID_ARGS=1
readonly EXIT_UNSUPPORTED_DISTRO=2
readonly EXIT_NETWORK_ERROR=3
readonly EXIT_PERMISSION_ERROR=4
readonly EXIT_INSTALLATION_ERROR=5
readonly EXIT_MISSING_DEPS=6

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Progress tracking
readonly TOTAL_STEPS=11
CURRENT_STEP=0

# Script options (set by command line flags)
DRY_RUN=false
VERBOSE=false
FORCE_YES=false

# ============================================================================
# LOGGING & OUTPUT UTILITIES
# ============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

print_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    local message="$1"
    echo -e "${BLUE}[${CURRENT_STEP}/${TOTAL_STEPS}]${NC} ${message}"
    log "STEP ${CURRENT_STEP}/${TOTAL_STEPS}: ${message}"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
    log "SUCCESS: $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
    log "WARNING: $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    log "ERROR: $1"
}

print_info() {
    echo -e "${CYAN}[INFO]${NC} $1"
    log "INFO: $1"
}

print_verbose() {
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${PURPLE}[VERBOSE]${NC} $1"
    fi
    log "VERBOSE: $1"
}

progress_bar() {
    local current=$1
    local total=$2
    local width=50
    local percentage=$((current * 100 / total))
    local completed=$((current * width / total))
    local remaining=$((width - completed))
    
    printf "\rProgress: ["
    printf "%*s" $completed | tr ' ' '='
    printf "%*s" $remaining | tr ' ' '-'
    printf "] %d%%" $percentage
    
    if [ $current -eq $total ]; then
        echo
    fi
}

# ============================================================================
# VALIDATION & SAFETY CHECKS
# ============================================================================

install_curl_if_missing() {
    # Check if curl is already installed
    if command -v curl >/dev/null 2>&1; then
        return 0
    fi
    
    print_warning "curl is not installed - attempting to install it..."
    print_verbose "Installing curl as a prerequisite"
    
    # Try to get sudo access first
    if ! sudo -n true 2>/dev/null; then
        print_info "Need sudo privileges to install curl..."
        if ! sudo -v; then
            print_error "Cannot install curl without sudo access"
            print_info "Please install curl manually: sudo apt install curl (or equivalent)"
            exit $EXIT_MISSING_DEPS
        fi
    fi
    
    # Detect package manager and install curl
    local install_success=false
    
    if command -v apt-get >/dev/null 2>&1; then
        print_info "Using apt-get to install curl..."
        if sudo apt-get update -qq 2>/dev/null && sudo apt-get install -y curl 2>/dev/null; then
            install_success=true
        fi
    elif command -v dnf >/dev/null 2>&1; then
        print_info "Using dnf to install curl..."
        if sudo dnf install -y curl 2>/dev/null; then
            install_success=true
        fi
    elif command -v yum >/dev/null 2>&1; then
        print_info "Using yum to install curl..."
        if sudo yum install -y curl 2>/dev/null; then
            install_success=true
        fi
    elif command -v zypper >/dev/null 2>&1; then
        print_info "Using zypper to install curl..."
        if sudo zypper install -y curl 2>/dev/null; then
            install_success=true
        fi
    elif command -v pacman >/dev/null 2>&1; then
        print_info "Using pacman to install curl..."
        if sudo pacman -Sy --noconfirm curl 2>/dev/null; then
            install_success=true
        fi
    else
        print_error "Cannot determine package manager to install curl"
        print_info "Please install curl manually:"
        print_info "  Ubuntu/Debian: sudo apt install curl"
        print_info "  RHEL/CentOS:   sudo dnf install curl"
        print_info "  Arch:          sudo pacman -S curl"
        exit $EXIT_MISSING_DEPS
    fi
    
    # Verify curl installation
    if [[ "$install_success" == true ]] && command -v curl >/dev/null 2>&1; then
        print_success "curl installed successfully"
        return 0
    else
        print_error "Failed to install curl"
        print_info "Please install curl manually and run this script again"
        exit $EXIT_MISSING_DEPS
    fi
}

check_required_commands() {
    print_verbose "Checking for required system commands"
    
    local required_commands=("grep" "cut" "tr" "tee" "usermod" "systemctl")
    local missing_commands=()
    
    # Check basic commands
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_commands+=("$cmd")
            print_verbose "Missing required command: $cmd"
        fi
    done
    
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        print_error "Missing required commands: ${missing_commands[*]}"
        print_info "These commands are necessary for the installation process"
        exit $EXIT_MISSING_DEPS
    fi
    
    # curl is checked and installed separately in main()
    print_success "All required commands are available"
}

validate_environment() {
    print_verbose "Validating script environment"
    
    # Check if running as root
    if [[ $EUID -eq 0 ]]; then
        print_error "This script should not be run as root for security reasons"
        print_info "Run as a regular user with sudo privileges"
        exit $EXIT_PERMISSION_ERROR
    fi
    
    # Validate sudo access
    if ! sudo -n true 2>/dev/null; then
        print_info "Checking sudo privileges..."
        if ! sudo -v; then
            print_error "Sudo access required but not available"
            exit $EXIT_PERMISSION_ERROR
        fi
    fi
    
    # Keep sudo alive in background
    (while true; do sudo -n true; sleep 50; done 2>/dev/null) &
    local sudo_pid=$!
    trap "kill $sudo_pid 2>/dev/null || true" EXIT
    
    # Check internet connectivity
    print_verbose "Testing internet connectivity"
    local connected=false
    if command -v curl >/dev/null 2>&1; then
        if curl -s --connect-timeout 5 https://download.docker.com >/dev/null; then
            connected=true
        fi
    elif command -v wget >/dev/null 2>&1; then
        if wget -q --spider --timeout=5 https://download.docker.com >/dev/null; then
            connected=true
        fi
    fi

    if [[ "$connected" == false ]]; then
        print_error "No internet connection or Docker servers unreachable"
        exit $EXIT_NETWORK_ERROR
    fi
    
    print_success "Environment validation passed"
}

detect_system() {
    print_verbose "Detecting system information"
    
    # Detect distribution
    if [[ ! -f /etc/os-release ]]; then
        print_error "Cannot detect Linux distribution - /etc/os-release not found"
        exit $EXIT_UNSUPPORTED_DISTRO
    fi
    
    # Source OS release info safely
    local os_id os_version os_codename
    os_id=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
    os_version=$(grep '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"' || echo "")
    os_codename=$(grep '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2 | tr -d '"' || echo "$os_version")
    
    # Handle Raspberry Pi OS detection
    if [[ "$os_id" == "raspbian" ]]; then
        print_verbose "Detected Raspberry Pi OS (based on Debian)"
        os_id="debian"
    fi
    
    # Set global variables
    readonly DISTRO="$os_id"
    readonly VERSION="$os_version"
    readonly CODENAME="$os_codename"
    
    # Detect architecture with fallback
    if command -v dpkg >/dev/null 2>&1; then
        readonly ARCH=$(dpkg --print-architecture)
    else
        local arch_raw
        arch_raw=$(uname -m)
        case "$arch_raw" in
            x86_64) readonly ARCH="amd64" ;;
            aarch64|arm64) readonly ARCH="arm64" ;;
            armv7l) readonly ARCH="armhf" ;;
            armv6l) readonly ARCH="armel" ;;
            *) readonly ARCH="$arch_raw" ;;
        esac
    fi
    
    print_verbose "Detected: $DISTRO $VERSION ($CODENAME) on $ARCH"
    
    # Validate supported distributions
    case "$DISTRO" in
        ubuntu|debian|centos|rhel|rocky|almalinux|fedora|opensuse*|sles|arch|manjaro)
            print_success "Supported distribution detected: $DISTRO $VERSION"
            ;;
        *)
            print_error "Unsupported distribution: $DISTRO"
            print_info "Supported: Ubuntu, Debian, Raspberry Pi OS, CentOS, RHEL, Rocky, AlmaLinux, Fedora, openSUSE, SLES, Arch, Manjaro"
            exit $EXIT_UNSUPPORTED_DISTRO
            ;;
    esac
}

# ============================================================================
# DEPENDENCY INSTALLATION
# ============================================================================

install_dependencies_debian() {
    print_verbose "Checking and installing dependencies for Debian/Ubuntu/Raspberry Pi OS"
    
    local required_deps=(
        "ca-certificates"
        "curl"
        "gnupg"
        "lsb-release"
        "software-properties-common"
        "apt-transport-https"
    )
    
    local missing_deps=()
    
    # Check which dependencies are missing
    for dep in "${required_deps[@]}"; do
        if ! dpkg -l "$dep" 2>/dev/null | grep -q '^ii'; then
            missing_deps+=("$dep")
            print_verbose "Missing dependency: $dep"
        fi
    done
    
    if [[ ${#missing_deps[@]} -eq 0 ]]; then
        print_success "All dependencies already installed"
        return 0
    fi
    
    print_info "Installing missing dependencies: ${missing_deps[*]}"
    
    if [[ "$DRY_RUN" == false ]]; then
        retry_command 3 5 sudo apt-get update
        retry_command 3 5 sudo apt-get install -y "${missing_deps[@]}"
    fi
    
    print_success "Dependencies installed successfully"
}

install_dependencies_rhel() {
    print_verbose "Checking and installing dependencies for RHEL family"
    
    local pkg_manager="dnf"
    if ! command -v dnf >/dev/null 2>&1; then
        pkg_manager="yum"
        print_verbose "Using yum as package manager"
    fi
    
    local required_deps=(
        "${pkg_manager}-plugins-core"
        "ca-certificates"
        "curl"
    )
    
    print_info "Installing dependencies: ${required_deps[*]}"
    
    if [[ "$DRY_RUN" == false ]]; then
        retry_command 3 5 sudo "$pkg_manager" install -y "${required_deps[@]}"
    fi
    
    print_success "Dependencies installed successfully"
}

install_dependencies_opensuse() {
    print_verbose "Checking and installing dependencies for openSUSE/SLES"
    
    local required_deps=("ca-certificates" "curl")
    
    print_info "Installing dependencies: ${required_deps[*]}"
    
    if [[ "$DRY_RUN" == false ]]; then
        retry_command 3 5 sudo zypper install -y "${required_deps[@]}"
    fi
    
    print_success "Dependencies installed successfully"
}

install_dependencies_arch() {
    print_verbose "Checking and installing dependencies for Arch Linux"
    
    local required_deps=("ca-certificates" "curl")
    
    print_info "Installing dependencies: ${required_deps[*]}"
    
    if [[ "$DRY_RUN" == false ]]; then
        retry_command 3 5 sudo pacman -S --needed --noconfirm "${required_deps[@]}"
    fi
    
    print_success "Dependencies installed successfully"
}

install_dependencies() {
    print_verbose "Installing distribution-specific dependencies"
    
    case "$DISTRO" in
        ubuntu|debian)
            install_dependencies_debian
            ;;
        centos|rhel|rocky|almalinux|fedora)
            install_dependencies_rhel
            ;;
        opensuse*|sles)
            install_dependencies_opensuse
            ;;
        arch|manjaro)
            install_dependencies_arch
            ;;
        *)
            print_warning "No dependency installation defined for: $DISTRO"
            ;;
    esac
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

confirm_action() {
    local message="$1"
    
    if [[ "$FORCE_YES" == true ]]; then
        return 0
    fi
    
    local response=""
    # Print prompt to stderr to ensure visibility even if stdout is redirected
    echo -en "${YELLOW}[CONFIRM]${NC} $message (y/N): " >&2
    
    # Check if we have a controlling terminal
    if [[ -c /dev/tty ]]; then
        # Read directly from terminal, bypassing any pipes
        if ! read -r response < /dev/tty; then
            print_error "Failed to read confirmation from /dev/tty"
            return 1
        fi
    elif [[ -t 0 ]]; then
        # Standard interactive input
        read -r response
    else
        # No terminal detected
        print_error "Installation requires interactive confirmation but no terminal was detected."
        print_info "Run with --yes to bypass confirmation: $0 --yes"
        return 1
    fi

    # Convert to lowercase (Bash 4+)
    response=$(echo "$response" | tr '[:upper:]' '[:lower:]')
    
    case "$response" in
        y|yes)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

retry_command() {
    local max_attempts=$1
    local delay=$2
    shift 2
    local cmd=("$@")
    
    for ((i=1; i<=max_attempts; i++)); do
        print_verbose "Attempt $i/$max_attempts: ${cmd[*]}"
        
        if "${cmd[@]}"; then
            return 0
        else
            local exit_code=$?
            if [[ $i -lt $max_attempts ]]; then
                print_warning "Command failed (attempt $i/$max_attempts), retrying in ${delay}s..."
                sleep "$delay"
            else
                print_error "Command failed after $max_attempts attempts"
                return $exit_code
            fi
        fi
    done
}

# ============================================================================
# DOCKER REMOVAL FUNCTIONS
# ============================================================================

remove_old_docker_ubuntu_debian() {
    print_verbose "Removing old Docker packages (Ubuntu/Debian/Raspberry Pi OS)"
    
    local old_packages=(
        "docker" "docker-engine" "docker.io" "containerd" "runc"
        "docker-doc" "docker-compose" "podman-docker"
    )
    
    if [[ "$DRY_RUN" == true ]]; then
        print_info "DRY RUN: Would remove packages: ${old_packages[*]}"
        return 0
    fi
    
    # Check if any packages are installed before attempting removal
    local installed_packages=()
    for package in "${old_packages[@]}"; do
        if dpkg -l "$package" 2>/dev/null | grep -q '^ii'; then
            installed_packages+=("$package")
        fi
    done
    
    if [[ ${#installed_packages[@]} -gt 0 ]]; then
        print_info "Removing old Docker packages: ${installed_packages[*]}"
        retry_command 3 2 sudo apt-get remove -y "${installed_packages[@]}"
    else
        print_verbose "No old Docker packages found to remove"
    fi
}

remove_old_docker_rhel_family() {
    print_verbose "Removing old Docker packages (RHEL family)"
    
    local old_packages=(
        "docker" "docker-client" "docker-client-latest" "docker-common"
        "docker-latest" "docker-latest-logrotate" "docker-logrotate"
        "docker-selinux" "docker-engine-selinux" "docker-engine"
        "podman-docker"
    )
    
    if [[ "$DRY_RUN" == true ]]; then
        print_info "DRY RUN: Would remove packages: ${old_packages[*]}"
        return 0
    fi
    
    # Use dnf for modern systems, fallback to yum
    local pkg_manager="dnf"
    if ! command -v dnf >/dev/null 2>&1; then
        pkg_manager="yum"
        print_verbose "Using yum as package manager"
    fi
    
    retry_command 3 2 sudo "$pkg_manager" remove -y "${old_packages[@]}" 2>/dev/null || true
}

remove_old_docker_arch() {
    print_verbose "Removing old Docker packages (Arch)"
    
    if [[ "$DRY_RUN" == true ]]; then
        print_info "DRY RUN: Would remove old docker packages"
        return 0
    fi
    
    sudo pacman -Rns --noconfirm docker docker-compose 2>/dev/null || true
}

# ============================================================================
# DOCKER INSTALLATION FUNCTIONS
# ============================================================================

install_docker_ubuntu_debian() {
    print_verbose "Installing Docker on Ubuntu/Debian/Raspberry Pi OS"
    
    # Update package index
    print_info "Updating package index..."
    retry_command 3 5 sudo apt-get update
    
    # Setup Docker repository
    print_info "Setting up Docker repository..."
    if [[ "$DRY_RUN" == false ]]; then
        # Create keyrings directory with secure permissions
        sudo install -m 0755 -d /etc/apt/keyrings
        
        # Download and install GPG key with error handling
        if ! curl -fsSL "https://download.docker.com/linux/${DISTRO}/gpg" | \
            sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg 2>/dev/null; then
            print_error "Failed to download Docker GPG key"
            exit $EXIT_INSTALLATION_ERROR
        fi
        
        # Set proper permissions (readable by all)
        sudo chmod a+r /etc/apt/keyrings/docker.gpg
        
        # Add repository
        local repo_line="deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${DISTRO} ${CODENAME} stable"
        echo "$repo_line" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
        
        # Update package index with new repository
        retry_command 3 5 sudo apt-get update
    fi
    
    # Install Docker packages
    local docker_packages=(
        "docker-ce" "docker-ce-cli" "containerd.io"
        "docker-buildx-plugin" "docker-compose-plugin"
    )
    
    print_info "Installing Docker packages: ${docker_packages[*]}"
    if [[ "$DRY_RUN" == false ]]; then
        retry_command 3 5 sudo apt-get install -y "${docker_packages[@]}"
    fi
}

install_docker_rhel_family() {
    print_verbose "Installing Docker on RHEL family"
    
    # Determine package manager
    local pkg_manager="dnf"
    if ! command -v dnf >/dev/null 2>&1; then
        pkg_manager="yum"
        print_verbose "Falling back to yum package manager"
    fi
    
    # Add Docker repository
    print_info "Adding Docker repository..."
    if [[ "$DRY_RUN" == false ]]; then
        local repo_url
        case "$DISTRO" in
            fedora)
                repo_url="https://download.docker.com/linux/fedora/docker-ce.repo"
                ;;
            centos|rhel|rocky|almalinux)
                repo_url="https://download.docker.com/linux/centos/docker-ce.repo"
                ;;
        esac
        
        retry_command 3 5 sudo "$pkg_manager" config-manager --add-repo "$repo_url"
    fi
    
    # Install Docker packages
    local docker_packages=(
        "docker-ce" "docker-ce-cli" "containerd.io"
        "docker-buildx-plugin" "docker-compose-plugin"
    )
    
    print_info "Installing Docker packages: ${docker_packages[*]}"
    if [[ "$DRY_RUN" == false ]]; then
        retry_command 3 5 sudo "$pkg_manager" install -y "${docker_packages[@]}"
    fi
}

install_docker_opensuse() {
    print_verbose "Installing Docker on openSUSE/SLES"
    
    print_info "Adding Docker repository..."
    if [[ "$DRY_RUN" == false ]]; then
        retry_command 3 5 sudo zypper addrepo https://download.docker.com/linux/sles/docker-ce.repo
        retry_command 3 5 sudo zypper refresh
    fi
    
    # Install Docker packages
    local docker_packages=(
        "docker-ce" "docker-ce-cli" "containerd.io"
        "docker-buildx-plugin" "docker-compose-plugin"
    )
    
    print_info "Installing Docker packages: ${docker_packages[*]}"
    if [[ "$DRY_RUN" == false ]]; then
        retry_command 3 5 sudo zypper install -y "${docker_packages[@]}"
    fi
}

install_docker_arch() {
    print_verbose "Installing Docker on Arch Linux"
    
    # Update package database
    print_info "Updating package database..."
    if [[ "$DRY_RUN" == false ]]; then
        retry_command 3 5 sudo pacman -Sy
    fi
    
    # Install Docker packages
    local docker_packages=("docker" "docker-compose")
    
    print_info "Installing Docker packages: ${docker_packages[*]}"
    if [[ "$DRY_RUN" == false ]]; then
        retry_command 3 5 sudo pacman -S --noconfirm "${docker_packages[@]}"
    fi
}

# ============================================================================
# MAIN INSTALLATION LOGIC
# ============================================================================

remove_old_docker() {
    if ! confirm_action "Remove old Docker installations?"; then
        print_info "Skipping removal of old Docker installations"
        return 0
    fi
    
    case "$DISTRO" in
        ubuntu|debian)
            remove_old_docker_ubuntu_debian
            ;;
        centos|rhel|rocky|almalinux|fedora)
            remove_old_docker_rhel_family
            ;;
        opensuse*|sles)
            # openSUSE handles this during installation
            print_verbose "openSUSE will handle old package removal automatically"
            ;;
        arch|manjaro)
            remove_old_docker_arch
            ;;
    esac
    
    print_success "Old Docker packages removed"
}

install_docker() {
    print_verbose "Starting Docker installation for $DISTRO"
    
    case "$DISTRO" in
        ubuntu|debian)
            install_docker_ubuntu_debian
            ;;
        centos|rhel|rocky|almalinux|fedora)
            install_docker_rhel_family
            ;;
        opensuse*|sles)
            install_docker_opensuse
            ;;
        arch|manjaro)
            install_docker_arch
            ;;
        *)
            print_error "Installation method not implemented for: $DISTRO"
            exit $EXIT_UNSUPPORTED_DISTRO
            ;;
    esac
    
    print_success "Docker packages installed successfully"
}

configure_docker_service() {
    print_verbose "Configuring Docker service"
    
    if [[ "$DRY_RUN" == true ]]; then
        print_info "DRY RUN: Would configure Docker service and add user to docker group"
        return 0
    fi
    
    # Add user to docker group
    print_info "Adding user '$USER' to docker group..."
    sudo usermod -aG docker "$USER"
    
    # Start and enable Docker service
    print_info "Starting Docker service..."
    sudo systemctl start docker
    
    print_info "Enabling Docker service for auto-start..."
    sudo systemctl enable docker
    
    # Wait for service to be ready
    local max_wait=30
    local wait_time=0
    while ! sudo systemctl is-active --quiet docker && [[ $wait_time -lt $max_wait ]]; do
        sleep 1
        wait_time=$((wait_time + 1))
    done
    
    if ! sudo systemctl is-active --quiet docker; then
        print_error "Docker service failed to start within ${max_wait}s"
        return 1
    fi
    
    print_success "Docker service configured and running"
}

verify_installation() {
    print_verbose "Verifying Docker installation"
    
    local verification_failed=false
    
    # Test Docker version
    if docker --version >/dev/null 2>&1; then
        local docker_version
        docker_version=$(docker --version | cut -d' ' -f3 | tr -d ',')
        print_success "Docker $docker_version installed and accessible"
    else
        print_error "Docker command not accessible"
        verification_failed=true
    fi
    
    # Test Docker Compose version
    if docker compose version >/dev/null 2>&1; then
        local compose_version
        compose_version=$(docker compose version --short 2>/dev/null || echo "unknown")
        print_success "Docker Compose $compose_version installed and accessible"
    else
        print_error "Docker Compose not accessible"
        verification_failed=true
    fi
    
    # Test Docker daemon connectivity
    if sudo docker info >/dev/null 2>&1; then
        print_success "Docker daemon is running and accessible"
    else
        print_warning "Docker daemon not accessible (may require logout/login)"
    fi
    
    if [[ "$verification_failed" == true ]]; then
        return 1
    fi
}

run_docker_test() {
    print_verbose "Running Docker functionality test"
    
    if [[ "$DRY_RUN" == true ]]; then
        print_info "DRY RUN: Would test Docker with hello-world container"
        return 0
    fi
    
    print_info "Testing Docker with hello-world container..."
    
    # Try to run hello-world container with sudo (since user may not be in docker group yet)
    if timeout 60 sudo docker run --rm hello-world >/dev/null 2>&1; then
        print_success "Docker test completed successfully"
    else
        print_warning "Docker test failed - you may need to logout and login again"
        print_info "Try running: newgrp docker"
    fi
}

# ============================================================================
# MAIN EXECUTION FLOW
# ============================================================================

show_usage() {
    cat << EOF
Docker Installation Script v${SCRIPT_VERSION}

Usage: $0 [OPTIONS]

OPTIONS:
    --dry-run       Show what would be done without executing
    --verbose       Enable verbose output
    --yes           Skip confirmation prompts
    --help          Show this help message

EXAMPLES:
    $0                    # Interactive installation
    $0 --verbose          # Installation with detailed output
    $0 --dry-run          # Preview what will be installed
    $0 --yes --verbose    # Automated verbose installation

SUPPORTED DISTRIBUTIONS:
    - Ubuntu 20.04+ (including 24.04 LTS)
    - Debian 11+
    - Raspberry Pi OS (Debian-based)
    - CentOS 8+, RHEL 8+
    - Rocky Linux 8+, AlmaLinux 8+
    - Fedora 36+
    - openSUSE Leap 15+, SLES 15+
    - Arch Linux, Manjaro

LOG FILE: $LOG_FILE
EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                print_info "Dry run mode enabled"
                shift
                ;;
            --verbose)
                VERBOSE=true
                print_info "Verbose mode enabled"
                shift
                ;;
            --yes)
                FORCE_YES=true
                print_info "Auto-confirmation enabled"
                shift
                ;;
            --help|-h)
                show_usage
                exit $EXIT_SUCCESS
                ;;
            *)
                print_error "Unknown option: $1"
                show_usage
                exit $EXIT_INVALID_ARGS
                ;;
        esac
    done
}

show_summary() {
    echo
    echo "Installation Summary"
    echo "==================="
    
    if [[ "$DRY_RUN" == false ]]; then
        docker --version 2>/dev/null || echo "Docker: Not accessible"
        docker compose version 2>/dev/null || echo "Docker Compose: Not accessible"
        
        echo
        echo "System Information:"
        echo "  Distribution: $DISTRO $VERSION"
        echo "  Architecture: $ARCH"
        echo "  User: $USER"
        echo "  Log file: $LOG_FILE"
    else
        echo "DRY RUN completed - no changes made"
    fi
    
    echo
    if [[ "$DRY_RUN" == false ]]; then
        print_success "Docker installation completed successfully!"
        print_warning "IMPORTANT: Log out and log back in to use Docker without sudo"
        print_info "Or run: newgrp docker"
    fi
}

main() {
    # Step 0: Ensure curl is present (crucial for installation)
    # This must run before any other logic that might depend on curl
    install_curl_if_missing

    # Initialize logging
    echo "Docker Installation Script v${SCRIPT_VERSION} started at $(date)" > "$LOG_FILE"
    
    echo "Docker Installation Script"
    echo "=========================="
    echo
    
    # Step 1: Parse command line arguments
    print_step "Parsing command line arguments"
    parse_arguments "$@"
    progress_bar $CURRENT_STEP $TOTAL_STEPS
    
    
    # Step 2: Check required commands
    print_step "Checking required system commands"
    check_required_commands
    progress_bar $CURRENT_STEP $TOTAL_STEPS
    
    # Step 3: Environment validation
    print_step "Validating environment and permissions"
    validate_environment
    progress_bar $CURRENT_STEP $TOTAL_STEPS
    
    # Step 4: System detection
    print_step "Detecting system configuration"
    detect_system
    progress_bar $CURRENT_STEP $TOTAL_STEPS
    
    # Step 5: Install dependencies
    print_step "Installing required dependencies"
    install_dependencies
    progress_bar $CURRENT_STEP $TOTAL_STEPS
    
    # Step 6: Display installation plan
    print_step "Preparing installation plan"
    echo "  Target system: $DISTRO $VERSION ($ARCH)"
    echo "  Installation mode: $([ "$DRY_RUN" == true ] && echo "DRY RUN" || echo "LIVE")"
    echo "  Log file: $LOG_FILE"
    progress_bar $CURRENT_STEP $TOTAL_STEPS
    
    # Step 7: Confirm installation
    print_step "Confirming installation"
    if ! confirm_action "Proceed with Docker installation on $DISTRO $VERSION?"; then
        print_info "Installation cancelled by user"
        exit $EXIT_SUCCESS
    fi
    progress_bar $CURRENT_STEP $TOTAL_STEPS
    
    # Step 8: Remove old Docker installations
    print_step "Removing old Docker installations"
    remove_old_docker
    progress_bar $CURRENT_STEP $TOTAL_STEPS
    
    # Step 9: Install Docker
    print_step "Installing Docker and Docker Compose"
    install_docker
    progress_bar $CURRENT_STEP $TOTAL_STEPS
    
    # Step 10: Configure Docker service
    print_step "Configuring Docker service"
    configure_docker_service
    progress_bar $CURRENT_STEP $TOTAL_STEPS
    
    # Step 11: Verify installation
    print_step "Verifying installation"
    verify_installation
    progress_bar $CURRENT_STEP $TOTAL_STEPS
    
    # Step 12: Test Docker functionality
    print_step "Testing Docker functionality"
    run_docker_test
    progress_bar $CURRENT_STEP $TOTAL_STEPS
    
    # Show final summary
    show_summary
}

# ============================================================================
# SCRIPT ENTRY POINT
# ============================================================================

# Validate shell environment
if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "ERROR: This script requires bash" >&2
    exit $EXIT_INVALID_ARGS
fi

# Set up error handling
trap 'print_error "Script interrupted"; exit 130' INT TERM
trap 'if [[ $? -ne 0 ]]; then print_error "Script failed - check log: $LOG_FILE"; fi' EXIT

# Execute main function
main "$@"
