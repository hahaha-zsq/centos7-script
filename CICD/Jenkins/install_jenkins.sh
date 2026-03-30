#!/bin/bash
set -Eeuo pipefail

# Jenkins Installation Script (CentOS 7)
# Installs Jenkins LTS via yum repo, auto-detects JDK version

trap 'echo "[ERROR] Script failed on line $LINENO" >&2' ERR

# --- Constants ---
JENKINS_DEFAULT_PORT=8080
JENKINS_HOME_DIR="/var/lib/jenkins"
JENKINS_MIN_JAVA=11

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

Install Jenkins LTS on CentOS 7 via yum.
Automatically detects your JDK version and selects a compatible Jenkins release.

Options:
    -p, --port PORT       Jenkins web port (default: ${JENKINS_DEFAULT_PORT})
    -h, --help            Show this help message

Prerequisites:
    - Root privileges required
    - JDK 11, 17, or 21 must be installed (JAVA_HOME configured)
    - Install JDK first using: ../java/install_jdk.sh
EOF
    exit "${1:-0}"
}

# --- Detect JDK ---
detect_java_version() {
    local java_bin=""

    # Source /etc/profile.d/java.sh if exists
    if [[ -f /etc/profile.d/java.sh ]]; then
        # shellcheck disable=SC1091
        source /etc/profile.d/java.sh 2>/dev/null || true
    fi

    # Prefer JAVA_HOME
    if [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/java" ]]; then
        java_bin="${JAVA_HOME}/bin/java"
    elif command -v java &>/dev/null; then
        java_bin="$(command -v java)"
    else
        return 1
    fi

    # Extract major version from java -version output
    local version_output
    version_output=$("$java_bin" -version 2>&1 | head -1)

    local major=""
    # Match "1.8.x" pattern (legacy Java 8)
    if [[ "$version_output" =~ \"1\.([0-9]+)\. ]]; then
        major="${BASH_REMATCH[1]}"
    # Match "11.x", "17.x", "21.x" pattern (modern)
    elif [[ "$version_output" =~ \"([0-9]+)[.\"] ]]; then
        major="${BASH_REMATCH[1]}"
    fi

    if [[ -z "$major" ]]; then
        return 1
    fi

    echo "$major"
}

get_java_home() {
    # Source /etc/profile.d/java.sh if exists
    if [[ -f /etc/profile.d/java.sh ]]; then
        # shellcheck disable=SC1091
        source /etc/profile.d/java.sh 2>/dev/null || true
    fi

    if [[ -n "${JAVA_HOME:-}" ]]; then
        echo "$JAVA_HOME"
    elif command -v java &>/dev/null; then
        local java_bin
        java_bin=$(command -v java)
        local java_home
        java_home=$(dirname "$(dirname "$(readlink -f "$java_bin" 2>/dev/null || echo "$java_bin")")")
        echo "$java_home"
    else
        return 1
    fi
}

check_java() {
    log_info "Checking Java installation..."

    local java_version
    if ! java_version=$(detect_java_version); then
        log_error "Java is not installed or could not be detected."
        log_error ""
        log_error "Please install a JDK first using:"
        log_error "  ../java/install_jdk.sh"
        log_error ""
        log_error "Jenkins LTS requires JDK 11 or higher (11, 17, 21)."
        exit 1
    fi

    local java_home
    java_home=$(get_java_home || echo "unknown")

    log_info "Detected JDK version: $java_version"
    log_info "JAVA_HOME: $java_home"

    if [[ "$java_version" -lt "$JENKINS_MIN_JAVA" ]]; then
        log_error "Jenkins requires JDK $JENKINS_MIN_JAVA or higher."
        log_error "Your current JDK version is: $java_version"
        log_error ""
        log_error "Please upgrade your JDK using:"
        log_error "  ../java/install_jdk.sh"
        exit 1
    fi

    echo "$java_version"
}

# --- Dependency Check ---
check_dependencies() {
    local -a missing_deps=()

    for cmd in curl wget; do
        if command -v "$cmd" &>/dev/null; then
            return 0
        fi
    done

    log_error "curl or wget is required"
    exit 1
}

# --- Port Check ---
check_port_available() {
    local port="$1"

    if ss -tlnp | grep -q ":${port} "; then
        log_error "Port ${port} is already in use"
        log_error "Use -p/--port to specify a different port"
        exit 1
    fi
}

# --- Install Jenkins ---
install_jenkins() {
    local port="$1"
    local java_version="$2"
    local java_home="$3"

    log_info "Adding Jenkins yum repository..."

    # Import Jenkins GPG key
    if [[ ! -f /etc/yum.repos.d/jenkins.repo ]]; then
        if command -v curl &>/dev/null; then
            curl -fsSL https://pkg.jenkins.io/redhat-stable/jenkins.repo -o /etc/yum.repos.d/jenkins.repo || {
                log_error "Failed to download Jenkins repo file"
                exit 1
            }
        else
            wget -O /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat-stable/jenkins.repo || {
                log_error "Failed to download Jenkins repo file"
                exit 1
            }
        fi
    fi

    # Import GPG key
    rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key 2>/dev/null \
        || rpm --import https://pkg.jenkins.io/redhat-stable/jenkins-ci.org.key 2>/dev/null \
        || log_warn "Could not import Jenkins GPG key"

    # Install font dependency (required by Jenkins)
    log_info "Installing dependencies..."
    yum install -y fontconfig || {
        log_error "Failed to install fontconfig"
        exit 1
    }

    # Check if Jenkins is already installed
    if rpm -q jenkins &>/dev/null; then
        log_info "Jenkins is already installed, checking for updates..."
        yum update -y jenkins 2>/dev/null || log_info "Jenkins is up to date"
    else
        log_info "Installing Jenkins..."
        yum install -y jenkins || {
            log_error "Failed to install Jenkins"
            exit 1
        }
        log_info "Jenkins installed successfully"
    fi

    # Configure JAVA_HOME for Jenkins
    local sysconfig_file="/etc/sysconfig/jenkins"
    if [[ -f "$sysconfig_file" ]]; then
        log_info "Configuring Jenkins to use JDK ${java_version}..."

        # Backup
        cp "$sysconfig_file" "${sysconfig_file}.bak.$(date +%Y%m%d%H%M%S)"

        # Set JAVA_HOME in sysconfig
        if grep -q "^JENKINS_JAVA_HOME=" "$sysconfig_file"; then
            sed -i "s|^JENKINS_JAVA_HOME=.*|JENKINS_JAVA_HOME=\"${java_home}\"|" "$sysconfig_file"
        else
            echo "JENKINS_JAVA_HOME=\"${java_home}\"" >> "$sysconfig_file"
        fi

        # Configure port if different from default
        if [[ "$port" -ne "$JENKINS_DEFAULT_PORT" ]]; then
            log_info "Configuring Jenkins to use port ${port}..."
            if grep -q "^JENKINS_PORT=" "$sysconfig_file"; then
                sed -i "s|^JENKINS_PORT=.*|JENKINS_PORT=\"${port}\"|" "$sysconfig_file"
            else
                echo "JENKINS_PORT=\"${port}\"" >> "$sysconfig_file"
            fi
        fi
    fi

    # Start Jenkins service
    log_info "Starting Jenkins service..."
    systemctl daemon-reload
    systemctl enable jenkins || log_warn "Could not enable Jenkins service"
    systemctl restart jenkins || {
        log_error "Failed to start Jenkins service"
        log_error "Check logs: journalctl -u jenkins"
        exit 1
    }

    log_info "Jenkins started as a system service"
    log_info "Jenkins URL: http://$(hostname -I | awk '{print $1}'):${port}"
}

# --- Show Initial Password ---
show_initial_password() {
    echo ""
    log_info "Waiting for Jenkins to initialize (this may take a minute)..."

    local secret_file="${JENKINS_HOME_DIR}/secrets/initialAdminPassword"
    local password=""
    local attempts=0
    local max_attempts=12

    while [[ -z "$password" && $attempts -lt $max_attempts ]]; do
        if [[ -f "$secret_file" ]]; then
            password=$(<"$secret_file")
        fi

        if [[ -z "$password" ]]; then
            sleep 5
            ((attempts++))
        fi
    done

    if [[ -n "$password" ]]; then
        echo ""
        echo "========================================"
        echo "  Jenkins Initial Admin Password"
        echo "========================================"
        echo "  ${password}"
        echo "========================================"
        echo ""
        echo "Use this password to unlock Jenkins in the web UI."
    else
        log_warn "Could not retrieve initial admin password automatically."
        log_warn "Check manually: cat ${secret_file}"
        log_warn "Or check service status: systemctl status jenkins"
    fi
}

# --- Main ---
main() {
    local port="$JENKINS_DEFAULT_PORT"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--port)
                if [[ "$2" =~ ^[0-9]+$ ]] && [[ "$2" -ge 1 && "$2" -le 65535 ]]; then
                    port="$2"
                else
                    log_error "Invalid port: $2"
                    exit 1
                fi
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
    log_info "Starting Jenkins installation"

    # Check dependencies
    check_dependencies

    # Detect JDK
    local java_version
    java_version=$(check_java)

    local java_home
    java_home=$(get_java_home || echo "unknown")

    log_info "Jenkins will use JDK ${java_version}"

    # Check port availability
    check_port_available "$port"

    # Install
    install_jenkins "$port" "$java_version" "$java_home"

    # Show initial password
    show_initial_password

    log_info "Jenkins installation completed successfully!"
    echo ""
    echo "Summary:"
    echo "  JDK version:     $java_version"
    echo "  JAVA_HOME:       $java_home"
    echo "  Jenkins URL:     http://$(hostname -I | awk '{print $1}'):${port}"
    echo "  Jenkins home:    ${JENKINS_HOME_DIR}"
    echo "  Config file:     /etc/sysconfig/jenkins"
    echo "  Service control: systemctl {start|stop|restart} jenkins"
}

main "$@"
