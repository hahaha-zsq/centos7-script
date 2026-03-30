#!/bin/bash
set -Eeuo pipefail

# Git Installation Script (CentOS 7)
# Installs or upgrades Git via yum or from source

trap 'echo "[ERROR] Script failed on line $LINENO" >&2' ERR

# --- Constants ---
GIT_SOURCE_VERSION="2.43.0"
GIT_SOURCE_DIR="/usr/local/src/git"

# --- Logging ---
log_info()  { echo "[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $*" >&2; }
log_warn()  { echo "[$(date +'%Y-%m-%d %H:%M:%S')] WARN: $*" >&2; }
log_error() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

# --- Root Check ---
check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# --- Usage ---
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Install or upgrade Git on CentOS 7.

Options:
    -m, --method METHOD   Installation method: yum, source (default: yum)
    -c, --config          Configure Git user name and email after install
    -h, --help            Show this help message

Installation methods:
    yum     - Install Git via yum (version 1.8.x on CentOS 7)
    source  - Compile and install latest Git from source (${GIT_SOURCE_VERSION})

Interactive mode: run without arguments to select options interactively.

Note: Requires root privileges.
EOF
    exit "${1:-0}"
}

# --- Check Existing Installation ---
check_existing_git() {
    if command -v git &>/dev/null; then
        local current_version
        current_version=$(git --version 2>&1)
        log_info "Git is already installed: $current_version"
        log_info "Location: $(command -v git)"
        return 0
    fi
    return 1
}

# --- Interactive Selection ---
interactive_select() {
    echo "========================================" >&2
    echo "  Git Installation" >&2
    echo "========================================" >&2
    echo "" >&2
    echo "  1) yum (Git 1.8.x, simple install)" >&2
    echo "  2) Source (Git ${GIT_SOURCE_VERSION}, latest features)" >&2
    echo "" >&2
    read -rp "Please select installation method [1-2]: " choice >&2

    case "$choice" in
        1) echo "yum" ;;
        2) echo "source" ;;
        *)
            log_error "Invalid selection: $choice"
            exit 1
            ;;
    esac
}

# --- Install via Yum ---
install_yum() {
    log_info "Installing Git via yum..."

    if rpm -q git &>/dev/null; then
        log_info "Git is already installed via yum"
        log_info "Version: $(git --version)"
        log_info "Tip: Use 'source' method to install a newer version"
        return 0
    fi

    yum install -y git || {
        log_error "Failed to install Git via yum"
        exit 1
    }

    log_info "Git installed successfully via yum"
}

# --- Install from Source ---
install_source() {
    log_info "Installing Git ${GIT_SOURCE_VERSION} from source..."

    # Install build dependencies
    log_info "Installing build dependencies..."
    yum groupinstall -y "Development Tools" || {
        log_error "Failed to install Development Tools"
        exit 1
    }
    yum install -y curl-devel expat-devel gettext-devel openssl-devel zlib-devel perl-ExtUtils-MakeMaker || {
        log_error "Failed to install Git build dependencies"
        exit 1
    }

    # Remove old git if installed via yum
    if rpm -q git &>/dev/null; then
        log_info "Removing old Git package..."
        yum remove -y git || true
    fi

    local tmpdir
    tmpdir=$(mktemp -d) || { log_error "Failed to create temp directory"; exit 1; }
    trap 'rm -rf -- "$tmpdir"' RETURN

    # Download source
    local tarball="git-${GIT_SOURCE_VERSION}.tar.gz"
    local download_url="https://www.kernel.org/pub/software/scm/git/${tarball}"

    log_info "Downloading Git ${GIT_SOURCE_VERSION}..."
    if ! curl -fSL --progress-bar -o "${tmpdir}/${tarball}" "$download_url"; then
        log_error "Failed to download Git source"
        log_error "URL: $download_url"
        exit 1
    fi

    # Extract
    log_info "Extracting source..."
    tar -xzf "${tmpdir}/${tarball}" -C "$tmpdir"

    local src_dir="${tmpdir}/git-${GIT_SOURCE_VERSION}"
    if [[ ! -d "$src_dir" ]]; then
        log_error "Source directory not found after extraction"
        exit 1
    fi

    # Compile and install
    log_info "Compiling Git (this may take a few minutes)..."
    pushd "$src_dir" > /dev/null

    make prefix=/usr/local/git all || {
        log_error "Failed to compile Git"
        popd > /dev/null
        exit 1
    }

    make prefix=/usr/local/git install || {
        log_error "Failed to install Git"
        popd > /dev/null
        exit 1
    }

    popd > /dev/null

    # Create symlink
    ln -sf /usr/local/git/bin/git /usr/bin/git
    ln -sf /usr/local/git/bin/git-shell /usr/bin/git-shell
    ln -sf /usr/local/git/bin/git-cvsserver /usr/bin/git-cvsserver

    # Add to PATH via profile
    local profile_file="/etc/profile.d/git.sh"
    cat > "$profile_file" <<'EOF'
#!/bin/bash
export PATH="/usr/local/git/bin:${PATH}"
EOF
    chmod 644 "$profile_file"

    # Apply to current session
    export PATH="/usr/local/git/bin:${PATH}"

    log_info "Git ${GIT_SOURCE_VERSION} installed successfully from source"
}

# --- Configure Git ---
configure_git() {
    echo ""
    echo "========================================"
    echo "  Git Configuration"
    echo "========================================"
    echo ""

    # Check existing config
    local existing_name
    local existing_email
    existing_name=$(git config --global user.name 2>/dev/null || true)
    existing_email=$(git config --global user.email 2>/dev/null || true)

    if [[ -n "$existing_name" && -n "$existing_email" ]]; then
        log_info "Git is already configured:"
        log_info "  Name:  $existing_name"
        log_info "  Email: $existing_email"
        echo ""
        read -rp "Reconfigure? [y/N]: " reconfigure
        if [[ ! "$reconfigure" =~ ^[Yy]$ ]]; then
            return 0
        fi
    fi

    # Get user input
    read -rp "Enter your Git user name: " git_name
    read -rp "Enter your Git email: " git_email

    if [[ -z "$git_name" || -z "$git_email" ]]; then
        log_error "Name and email are required"
        return 1
    fi

    # Apply configuration
    git config --global user.name "$git_name"
    git config --global user.email "$git_email"

    # Set useful defaults
    git config --global init.defaultBranch main
    git config --global core.autocrlf input
    git config --global pull.rebase true

    log_info "Git configured successfully"
    log_info "  Name:  $git_name"
    log_info "  Email: $git_email"
}

# --- Verify Installation ---
verify_installation() {
    log_info "Verifying Git installation..."

    if ! command -v git &>/dev/null; then
        log_error "git command not found after installation"
        exit 1
    fi

    local version
    version=$(git --version 2>&1)
    local path
    path=$(command -v git)

    log_info "Git version: $version"
    log_info "Git path: $path"
}

# --- Main ---
main() {
    local method=""
    local do_config=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -m|--method)
                case "$2" in
                    yum|source) method="$2" ;;
                    *)
                        log_error "Invalid method: $2 (supported: yum, source)"
                        exit 1
                        ;;
                esac
                shift 2
                ;;
            -c|--config)
                do_config=true
                shift
                ;;
            -h|--help)
                usage 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage 1
                ;;
        esac
    done

    check_root

    # Check if Git is already installed
    if check_existing_git; then
        echo ""
        read -rp "Git is already installed. Reinstall/upgrade? [y/N]: " reinstall
        if [[ ! "$reinstall" =~ ^[Yy]$ ]]; then
            if [[ "$do_config" == "true" ]]; then
                configure_git
            fi
            verify_installation
            log_info "No changes made."
            exit 0
        fi
    fi

    # Interactive selection if no method specified
    if [[ -z "$method" ]]; then
        method=$(interactive_select)
    fi

    log_info "Starting Git installation (method: ${method})"

    # Install based on method
    case "$method" in
        yum)
            install_yum
            ;;
        source)
            install_source
            ;;
    esac

    # Verify installation
    verify_installation

    # Optional configuration
    if [[ "$do_config" == "true" ]]; then
        configure_git
    else
        echo ""
        read -rp "Configure Git user name and email now? [y/N]: " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            configure_git
        fi
    fi

    log_info "Git installation completed successfully!"
}

main "$@"
