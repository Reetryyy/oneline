#!/bin/bash

# Docker Installation Script
# ==========================================

set -euo pipefail

# ============================================================================
# CONFIGURATION & CONSTANTS
# ============================================================================

readonly SCRIPT_VERSION="2.2.3"
readonly SCRIPT_NAME="docker-install"
readonly SCRIPT_URL="https://raw.githubusercontent.com/Reetryyy/oneline/main/docker-setup.sh"
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
CREATE_USER_NAME=""

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
    echo -e "${GREEN}[OK]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    log "WARN: $1"
}

print_error() {
    echo -e "${RED}[ERR]${NC} $1"
    log "ERROR: $1"
}

print_info() {
    echo -e "${CYAN}·${NC} $1"
}

print_verbose() {
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${PURPLE}[verbose]${NC} $1"
    fi
}

progress_bar() {
    local current=$1
    local total=$2
    local width=44
    local percentage=$((current * 100 / total))
    local completed=$((current * width / total))
    local remaining=$((width - completed))
    local rows

    rows=$(tput lines 2>/dev/null) || rows=
    if [[ -t 1 ]] && [[ "$rows" =~ ^[0-9]+$ ]] && [[ "$rows" -ge 3 ]]; then
        # Pinned status line at bottom so scrolling apt/dpkg output does not erase it
        printf '\033[s'
        printf '\033[%s;1H' "$rows"
        printf '\033[2K'
        printf "%-12s [" "Progress"
        printf "%*s" $completed | tr ' ' '='
        printf "%*s" $remaining | tr ' ' '-'
        printf "] %3d%%" "$percentage"
        printf '\033[u'
    else
        printf "\r%-12s [" "Progress"
        printf "%*s" $completed | tr ' ' '='
        printf "%*s" $remaining | tr ' ' '-'
        printf "] %3d%%\n" $percentage
    fi
}

# Apt: non-verbose mode sends full output to LOG_FILE so the TTY stays clean for the pinned progress bar.
_apt() {
    local aptq=()
    [[ "$VERBOSE" != true ]] && aptq+=(-qq)
    if [[ "$VERBOSE" == true ]]; then
        sudo DEBIAN_FRONTEND=noninteractive apt-get "${aptq[@]}" "$@"
        return $?
    fi
    {
        echo "--- apt-get ${aptq[*]} $* @ $(date '+%Y-%m-%d %H:%M:%S') ---"
        sudo DEBIAN_FRONTEND=noninteractive apt-get "${aptq[@]}" "$@"
    } >>"$LOG_FILE" 2>&1 || {
        print_error "apt-get failed (details in $LOG_FILE). Recent lines:"
        tail -n 40 "$LOG_FILE" >&2 || true
        return 1
    }
    return 0
}

# Fixes: sudo: unable to resolve host <hostname> when /etc/hosts lacks 127.0.1.1 mapping
ensure_hosts_resolves_hostname() {
    local hn
    hn="$(hostname 2>/dev/null || true)"
    [[ -z "$hn" ]] && return 0
    if getent hosts "$hn" >/dev/null 2>&1; then
        return 0
    fi
    if grep "127.0.1.1" /etc/hosts 2>/dev/null | grep -qF "$hn"; then
        return 0
    fi
    if [[ "$DRY_RUN" == true ]]; then
        return 0
    fi
    printf '127.0.1.1\t%s\n' "$hn" | sudo tee -a /etc/hosts >/dev/null
    print_verbose "Mapped hostname $hn in /etc/hosts (fixes sudo DNS warning)"
}

# ============================================================================
# VALIDATION & SAFETY CHECKS
# ============================================================================

sudo_group_name() {
    if getent group sudo >/dev/null 2>&1; then
        echo sudo
    elif getent group wheel >/dev/null 2>&1; then
        echo wheel
    fi
}

is_valid_unix_username() {
    local name="$1"
    [[ "$name" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

handle_running_as_root() {
    local new_user=""
    local script_dir script_path filtered_args

    if [[ "$DRY_RUN" == true ]]; then
        print_warning "As root: omit --dry-run to create a sudo user, or run this script as a non-root user."
        exit $EXIT_PERMISSION_ERROR
    fi

    echo ""
    echo -e "${YELLOW}[root]${NC} Docker installs should run as a ${GREEN}sudo user${NC}, not root."
    if [[ -n "$CREATE_USER_NAME" ]]; then
        new_user="$CREATE_USER_NAME"
        if ! is_valid_unix_username "$new_user"; then
            print_error "Invalid username: 1–32 chars, [a-z0-9_-], must start with letter or _"
            exit $EXIT_INVALID_ARGS
        fi
    elif [[ "$FORCE_YES" == true ]]; then
        print_error "Root + --yes needs --create-user USER (example: $0 --yes --create-user myuser)"
        exit $EXIT_PERMISSION_ERROR
    elif confirm_action "Create a sudo user and continue as them?"; then
        local response=""
        echo -en "${YELLOW}?${NC} Username [dockeruser]: " >&2
        if [[ -c /dev/tty ]] && read -r response < /dev/tty; then
            :
        elif [[ -t 0 ]]; then
            read -r response
        else
            print_error "No TTY: pass --create-user NAME when running as root"
            exit $EXIT_PERMISSION_ERROR
        fi
        new_user="${response:-dockeruser}"
        if ! is_valid_unix_username "$new_user"; then
            print_error "Invalid username: 1–32 chars, [a-z0-9_-], must start with letter or _"
            exit $EXIT_INVALID_ARGS
        fi
    else
        echo "  Exit, log in as a sudo-capable user, and run this script again (or: $0 --create-user NAME)."
        exit $EXIT_PERMISSION_ERROR
    fi

    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd)" || script_dir=""
    script_path="${script_dir}/$(basename "${BASH_SOURCE[0]:-}")"

    if [[ ! -f "$script_path" ]]; then
        # Piped execution (curl/wget | bash): the script never existed on disk,
        # so fetch a copy to hand off to the new user.
        print_info "Piped execution detected — fetching script copy for user handoff"
        script_path="$(mktemp "/tmp/${SCRIPT_NAME}-handoff-XXXXXX.sh")"
        if command -v curl >/dev/null 2>&1; then
            if ! curl -fsSL "$SCRIPT_URL" -o "$script_path"; then
                print_error "Failed to download script from $SCRIPT_URL"
                exit $EXIT_NETWORK_ERROR
            fi
        elif command -v wget >/dev/null 2>&1; then
            if ! wget -qO "$script_path" "$SCRIPT_URL"; then
                print_error "Failed to download script from $SCRIPT_URL"
                exit $EXIT_NETWORK_ERROR
            fi
        else
            print_error "Cannot resolve script path and neither curl nor wget is available"
            exit $EXIT_MISSING_DEPS
        fi
        chmod 644 "$script_path"
    fi

    local grp
    grp="$(sudo_group_name)"
    if [[ -z "$grp" ]]; then
        print_error "Neither 'sudo' nor 'wheel' group found; cannot grant the new user admin privileges."
        exit $EXIT_PERMISSION_ERROR
    fi

    if id "$new_user" &>/dev/null; then
        if ! confirm_action "User '$new_user' exists — switch to them and continue?"; then
            exit $EXIT_PERMISSION_ERROR
        fi
    else
        print_verbose "useradd -m -G $grp $new_user"
        if ! useradd -m -s /bin/bash -G "$grp" "$new_user"; then
            print_error "useradd failed for '$new_user'"
            exit $EXIT_PERMISSION_ERROR
        fi
        if [[ "$FORCE_YES" == true ]]; then
            print_warning "No password set (--yes); run: passwd $new_user"
        else
            echo -e "${CYAN}·${NC} Password for ${GREEN}$new_user${NC}:"
            if ! passwd "$new_user" </dev/tty; then
                print_error "passwd failed; cleanup: userdel -r $new_user"
                exit $EXIT_PERMISSION_ERROR
            fi
        fi
    fi

    filtered_args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --create-user)
                shift
                [[ $# -gt 0 ]] && shift
                ;;
            *)
                filtered_args+=("$1")
                shift
                ;;
        esac
    done

    print_success "Continuing as ${GREEN}$new_user${NC} → re-running script"
    exec sudo -H -u "$new_user" -- bash "$script_path" "${filtered_args[@]}"
}

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
        print_verbose "apt install curl"
        if _apt update && _apt install -y curl; then
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
    
    # Non-root: refuse continuing as root (root flow should have re-exec'd before this)
    if [[ $EUID -eq 0 ]]; then
        print_error "Still running as root after user handoff — this should not happen"
        exit $EXIT_PERMISSION_ERROR
    fi
    
    # Validate sudo access
    if ! sudo -n true 2>/dev/null; then
        print_verbose "sudo credentials"
        if ! sudo -v; then
            print_error "Sudo access required but not available"
            exit $EXIT_PERMISSION_ERROR
        fi
    fi

    ensure_hosts_resolves_hostname
    
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
    print_verbose "apt dependencies ($DISTRO)"
    
    # software-properties-common is Ubuntu-centric; Docker repo here uses signed sources.list (no add-apt-repository).
    local required_deps=(
        "ca-certificates"
        "curl"
        "gnupg"
        "lsb-release"
    )
    if [[ "$DISTRO" == "ubuntu" ]]; then
        required_deps+=("apt-transport-https")
    fi
    
    local missing_deps=()
    
    for dep in "${required_deps[@]}"; do
        if ! dpkg -l "$dep" 2>/dev/null | grep -q '^ii'; then
            missing_deps+=("$dep")
            print_verbose "missing: $dep"
        fi
    done
    
    if [[ ${#missing_deps[@]} -eq 0 ]]; then
        print_success "Dependencies OK"
        return 0
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        print_verbose "dry-run: would install ${missing_deps[*]}"
        return 0
    fi
    
    echo -e "${CYAN}·${NC} Installing: ${missing_deps[*]} (details -> log unless ${CYAN}--verbose${NC})"
    progress_bar "$CURRENT_STEP" "$TOTAL_STEPS"
    retry_command 3 5 _apt update
    progress_bar "$CURRENT_STEP" "$TOTAL_STEPS"
    retry_command 3 5 _apt install -y "${missing_deps[@]}"
    print_success "Dependencies installed"
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
    echo -en "${YELLOW}?${NC} $message ${CYAN}[y/N]${NC}: " >&2
    
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
        if [[ "$VERBOSE" == true ]]; then
            print_verbose "Attempt $i/$max_attempts: ${cmd[*]}"
        fi
        
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
        retry_command 3 2 _apt remove -y "${installed_packages[@]}"
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
    print_verbose "install_docker_ubuntu_debian"
    
    if [[ "$DRY_RUN" == true ]]; then
        print_verbose "dry-run: skip docker install"
        return 0
    fi
    
    progress_bar "$CURRENT_STEP" "$TOTAL_STEPS"
    retry_command 3 5 _apt update
    
    print_verbose "docker.list + keyring"
    {
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
        
        retry_command 3 5 _apt update
    }
    
    local docker_packages=(
        "docker-ce" "docker-ce-cli" "containerd.io"
        "docker-buildx-plugin" "docker-compose-plugin"
    )
    
    echo -e "${CYAN}·${NC} docker-ce, compose plugin, buildx… (apt -> log unless ${CYAN}--verbose${NC})"
    progress_bar "$CURRENT_STEP" "$TOTAL_STEPS"
    retry_command 3 5 _apt install -y "${docker_packages[@]}"
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
    
    if [[ "$DRY_RUN" == false ]]; then
        print_success "Docker installed"
    fi
}

configure_docker_service() {
    print_verbose "systemd + docker group"
    
    if [[ "$DRY_RUN" == true ]]; then
        print_verbose "DRY RUN: usermod + systemctl"
        return 0
    fi
    
    echo -e "${CYAN}·${NC} group docker <- ${GREEN}$USER${NC}; systemctl enable --now docker"
    sudo usermod -aG docker "$USER"
    sudo systemctl start docker
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
    print_verbose "hello-world"
    
    if [[ "$DRY_RUN" == true ]]; then
        return 0
    fi
    
    echo -e "${CYAN}·${NC} docker run hello-world (quick check)…"
    if timeout 60 sudo docker run --rm hello-world >/dev/null 2>&1; then
        print_success "hello-world OK"
    else
        print_warning "hello-world failed — try ${CYAN}newgrp docker${NC} or re-login"
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
    --create-user USER
                    When run as root (with --yes): create or use USER, then re-run as that user
    --help          Show this help message

EXAMPLES:
    $0                    # Interactive installation
    $0 --verbose          # Installation with detailed output
    $0 --dry-run          # Preview what will be installed
    $0 --yes --verbose    # Automated verbose installation
    sudo $0 --yes --create-user deploy   # As root: ensure user 'deploy', then install as deploy

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
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --yes)
                FORCE_YES=true
                shift
                ;;
            --create-user)
                shift
                if [[ $# -lt 1 || "$1" == -* ]]; then
                    print_error "--create-user requires a username"
                    exit $EXIT_INVALID_ARGS
                fi
                CREATE_USER_NAME="$1"
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
    
    if [[ $EUID -ne 0 && -n "$CREATE_USER_NAME" ]]; then
        print_error "--create-user is only valid when running this script as root"
        exit $EXIT_INVALID_ARGS
    fi
}

show_summary() {
    echo
    echo -e "${BLUE}── Done ──${NC}"
    
    if [[ "$DRY_RUN" == false ]]; then
        docker --version 2>/dev/null || echo "Docker: n/a"
        docker compose version 2>/dev/null || echo "Compose: n/a"
        echo -e "  ${DISTRO} ${VERSION} · ${ARCH} · ${USER}"
        if [[ "$VERBOSE" == true ]]; then
            echo "  Log: $LOG_FILE"
        fi
    else
        echo "  (dry run — no changes)"
    fi
    
    echo
    if [[ "$DRY_RUN" == false ]]; then
        print_success "Docker is installed"
        print_warning "Re-login (or ${CYAN}newgrp docker${NC}) to use Docker without sudo"
    fi
}

main() {
    echo "Docker setup v${SCRIPT_VERSION} · ${LOG_FILE}" > "$LOG_FILE"

    # Step 0: Ensure curl is present (must run after log exists — _apt appends there when not verbose)
    install_curl_if_missing
    
    echo -e "${BLUE}Docker setup${NC} v${SCRIPT_VERSION}"
    echo
    
    # Step 1: Parse command line arguments
    print_step "Parsing command line arguments"
    parse_arguments "$@"
    progress_bar $CURRENT_STEP $TOTAL_STEPS
    
    
    # Step 2: Check required commands
    print_step "Checking required system commands"
    check_required_commands
    progress_bar $CURRENT_STEP $TOTAL_STEPS
    
    # Step 3: If running as root, offer/create a non-root user and re-exec (or exit)
    if [[ $EUID -eq 0 ]]; then
        handle_running_as_root "$@"
    fi
    
    # Step 3b: Environment validation (non-root)
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
    print_step "Installation plan"
    echo -e "  ${DISTRO} ${VERSION} (${ARCH}) · $([ "$DRY_RUN" == true ] && echo "dry-run" || echo "live")"
    progress_bar $CURRENT_STEP $TOTAL_STEPS
    
    # Step 7: Confirm installation
    print_step "Confirming installation"
    if ! confirm_action "Proceed with Docker installation on $DISTRO $VERSION?"; then
        echo "Cancelled."
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
