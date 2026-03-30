#!/bin/bash
set -Eeuo pipefail

# JDK Installation Script (CentOS 7)
# Supports JDK 11, 17, 21 with environment variable configuration

trap 'echo "[ERROR] Script failed on line $LINENO" >&2' ERR

# --- Constants ---
JDK_INSTALL_DIR="/usr/local/java"

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

# --- Dependency Check ---
check_dependencies() {
    local -a missing_deps=()

    for cmd in curl tar; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing_deps[*]}"
        log_error "Install them: yum install -y ${missing_deps[*]}"
        exit 1
    fi
}

# --- Usage ---
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Install JDK and configure environment variables on CentOS 7.

Options:
    -v, --version VERSION   JDK version to install (11, 17, 21)
    -h, --help              Show this help message

Interactive mode: run without arguments to select version interactively.

Supported versions:
    11   - Eclipse Temurin OpenJDK 11 (LTS)
    17   - Eclipse Temurin OpenJDK 17 (LTS)
    21   - Eclipse Temurin OpenJDK 21 (LTS)

Note: Requires root privileges. JDK is installed to ${JDK_INSTALL_DIR}.
EOF
    exit "${1:-0}"
}

# --- Version Selection ---
select_version() {
    local version="$1"

    case "$version" in
        11|17|21)
            echo "$version"
            ;;
        *)
            log_error "Unsupported JDK version: $version (supported: 11, 17, 21)"
            exit 1
            ;;
    esac
}

interactive_select() {
    echo "========================================" >&2
    echo "  JDK Installation - Version Selection" >&2
    echo "========================================" >&2
    echo "" >&2
    echo "  1) OpenJDK 11 (LTS)" >&2
    echo "  2) OpenJDK 17 (LTS)" >&2
    echo "  3) OpenJDK 21 (LTS)" >&2
    echo "" >&2
    read -rp "Please select a version [1-3]: " choice >&2

    case "$choice" in
        1) echo "11" ;;
        2) echo "17" ;;
        3) echo "21" ;;
        *)
            log_error "Invalid selection: $choice"
            exit 1
            ;;
    esac
}

# --- Download URLs ---
get_download_url() {
    local version="$1"
    local arch="x64"
    local os="linux"

    case "$version" in
        11)
            echo "https://github.com/adoptium/temurin11-binaries/releases/download/jdk-11.0.22%2B7/OpenJDK11U-jdk_${arch}_${os}_hotspot_11.0.22_7.tar.gz"
            ;;
        17)
            echo "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.10%2B7/OpenJDK17U-jdk_${arch}_${os}_hotspot_17.0.10_7.tar.gz"
            ;;
        21)
            echo "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.2%2B13/OpenJDK21U-jdk_${arch}_${os}_hotspot_21.0.2_13.tar.gz"
            ;;
    esac
}

# --- Check Existing JDK ---
check_existing_jdk() {
    if command -v java &>/dev/null; then
        local current_version
        current_version=$(java -version 2>&1 | head -1)
        log_info "Java is already installed: $current_version"
        log_info "Location: $(command -v java)"
        return 0
    fi
    return 1
}

# --- Install JDK ---
install_jdk() {
    local version="$1"
    local download_url
    download_url=$(get_download_url "$version")
    local tarball="jdk-${version}.tar.gz"
    local tmpdir

    tmpdir=$(mktemp -d) || { log_error "Failed to create temp directory"; exit 1; }
    trap 'rm -rf -- "$tmpdir"' RETURN

    log_info "Downloading OpenJDK ${version}..."
    if ! curl -fSL --progress-bar -o "${tmpdir}/${tarball}" "$download_url"; then
        log_error "Failed to download OpenJDK ${version}"
        log_error "URL: $download_url"
        log_error "Please check your network connection or download manually."
        exit 1
    fi

    log_info "Extracting OpenJDK ${version}..."
    mkdir -p "$JDK_INSTALL_DIR"
    tar -xzf "${tmpdir}/${tarball}" -C "$JDK_INSTALL_DIR" || {
        log_error "Failed to extract JDK archive"
        exit 1
    }

    # Find the extracted directory
    local jdk_dir
    jdk_dir=$(find "$JDK_INSTALL_DIR" -maxdepth 1 -type d -name "jdk-${version}*" | head -1)

    if [[ -z "$jdk_dir" ]]; then
        log_error "Could not find extracted JDK directory"
        exit 1
    fi

    log_info "JDK ${version} installed to: $jdk_dir"
    echo "$jdk_dir"
}

# --- Configure Environment ---
configure_env() {
    local version="$1"
    local jdk_home="$2"
    local profile_file="/etc/profile.d/java.sh"

    log_info "Configuring environment variables in $profile_file"

    # Remove existing config
    if [[ -f "$profile_file" ]]; then
        cp "$profile_file" "${profile_file}.bak.$(date +%Y%m%d%H%M%S)"
        log_info "Backed up $profile_file"
    fi

    # Write new configuration
    cat > "$profile_file" <<EOF
#!/bin/bash
# JAVA_HOME configuration (JDK ${version})
export JAVA_HOME="${jdk_home}"
export PATH="\${JAVA_HOME}/bin:\${PATH}"
EOF

    chmod 644 "$profile_file"

    log_info "Environment variables configured"
    log_info "  JAVA_HOME=$jdk_home"

    # Apply to current session
    export JAVA_HOME="$jdk_home"
    export PATH="${JAVA_HOME}/bin:${PATH}"
}

# --- Configure Alternatives ---
configure_alternatives() {
    local jdk_home="$1"

    log_info "Configuring system alternatives..."

    for cmd in java javac jar; do
        if [[ -x "${jdk_home}/bin/${cmd}" ]]; then
            alternatives --install "/usr/bin/${cmd}" "${cmd}" "${jdk_home}/bin/${cmd}" 200 2>/dev/null \
                || update-alternatives --install "/usr/bin/${cmd}" "${cmd}" "${jdk_home}/bin/${cmd}" 200 2>/dev/null \
                || log_warn "Could not register ${cmd} in alternatives"
        fi
    done
}

# --- Verify Installation ---
verify_installation() {
    log_info "Verifying JDK installation..."

    # Source profile if java not in PATH yet
    if ! command -v java &>/dev/null && [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/java" ]]; then
        log_info "Sourcing environment..."
        source /etc/profile.d/java.sh 2>/dev/null || true
    fi

    if ! command -v java &>/dev/null; then
        # Try JAVA_HOME directly
        if [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/java" ]]; then
            export PATH="${JAVA_HOME}/bin:${PATH}"
        else
            log_error "java command not found after installation"
            exit 1
        fi
    fi

    local java_version
    java_version=$(java -version 2>&1 | head -1)
    log_info "Java version: $java_version"

    if ! command -v javac &>/dev/null; then
        log_warn "javac command not found - checking JAVA_HOME"
        if [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/javac" ]]; then
            log_info "javac found at ${JAVA_HOME}/bin/javac"
        else
            log_warn "javac not found"
        fi
    else
        local javac_version
        javac_version=$(javac -version 2>&1)
        log_info "Javac version: $javac_version"
    fi
}

# --- Main ---
main() {
    local version=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v|--version)
                version=$(select_version "$2")
                shift 2
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

    # Interactive selection if no version specified
    if [[ -z "$version" ]]; then
        version=$(interactive_select)
    fi

    log_info "Starting JDK ${version} installation"

    # Check dependencies
    check_dependencies

    # Check existing JDK
    if check_existing_jdk; then
        echo ""
        read -rp "Java is already installed. Reinstall? [y/N]: " reinstall
        if [[ ! "$reinstall" =~ ^[Yy]$ ]]; then
            log_info "No changes made."
            exit 0
        fi
    fi

    # Install JDK
    local jdk_home
    jdk_home=$(install_jdk "$version")
    log_info "JDK home: $jdk_home"

    # Configure environment
    configure_env "$version" "$jdk_home"

    # Configure alternatives
    configure_alternatives "$jdk_home"

    # Verify
    verify_installation

    log_info "JDK ${version} installation completed successfully!"
    echo ""
    echo "To apply environment variables in the current session, run:"
    echo "  source /etc/profile.d/java.sh"
}

main "$@"
