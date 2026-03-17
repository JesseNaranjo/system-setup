#!/usr/bin/env bash

# kubernetes-setup.sh - Kubernetes cluster configuration and package management orchestrator
#
# Usage: sudo ./kubernetes-setup.sh
#
# This script orchestrates multiple focused configuration modules:
# - Kernel module loading (br_netfilter, overlay)
# - Kubernetes and CRI-O APT repository configuration
# - Kubernetes package installation (kubeadm, kubectl, kubelet, cri-o)
# - Network configuration (IP forwarding, bridge netfilter)
# - Swap disabling
# - CRI-O runtime configuration
# - Helm and Minikube installation (optional)
# - Cluster initialization and validation
# - Certificate management
# - KUBE_EDITOR configuration
#
# The script automatically detects the environment and configures appropriately.
# Linux only - Kubernetes is not supported on macOS natively.

set -euo pipefail

# Get the directory where this script is located
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source utilities
# shellcheck source=utils-k8s.sh
source "${SCRIPT_DIR}/utils-k8s.sh"

# Clean up any tracked temp files on exit
cleanup_temp_files() {
    for tmp in "${TEMP_FILES[@]+"${TEMP_FILES[@]}"}"; do
        rm -f "$tmp"
    done
}
trap cleanup_temp_files EXIT

readonly REMOTE_BASE="https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/kubernetes"
readonly K8S_VERSION="v1.35"

# List of obsolete scripts to clean up (renamed or removed from repository)
OBSOLETE_SCRIPTS=(
    "_download-k8s-scripts.sh"
    "update-k8s-repos.sh"
    "install-update-helm.sh"
    "install-update-minikube.sh"
    "utils.sh"
)

# Step result tracking for cross-module dependency validation
# When a step fails, dependent steps are skipped with a clear message
STEP_KERNEL_MODULES_OK=false
STEP_REPOS_OK=false
STEP_PACKAGES_OK=false
STEP_NETWORKING_OK=false
STEP_SWAP_OK=false

# List of module scripts to download/update (excludes kubernetes-setup.sh and utils-k8s.sh)
get_script_list() {
    echo "kubernetes-modules/configure-k8s-repos.sh"
    echo "kubernetes-modules/install-k8s-packages.sh"
    echo "kubernetes-modules/install-update-helm.sh"
    echo "kubernetes-modules/install-update-minikube.sh"
    echo "kubernetes-modules/configure-kernel-modules.sh"
    echo "kubernetes-modules/configure-networking.sh"
    echo "kubernetes-modules/configure-swap.sh"
    echo "kubernetes-modules/configure-crio.sh"
    echo "kubernetes-modules/initialize-cluster.sh"
    echo "kubernetes-modules/validate-cluster.sh"
    echo "kubernetes-modules/manage-certificates.sh"
    echo "kubernetes-modules/configure-kube-editor.sh"
    echo "start-k8s.sh"
    echo "stop-k8s.sh"
}

# ============================================================================
# Self-Update Functionality
# ============================================================================

# Detect available download command (curl or wget)
# Sets global DOWNLOAD_CMD variable
detect_download_cmd() {
    if command -v curl &>/dev/null; then
        DOWNLOAD_CMD="curl"
        return 0
    elif command -v wget &>/dev/null; then
        DOWNLOAD_CMD="wget"
        return 0
    else
        DOWNLOAD_CMD=""
        print_warning_box \
            "            UPDATES NOT AVAILABLE" \
            "" \
            "Neither 'curl' nor 'wget' is installed on this system." \
            "Self-updating functionality requires one of these tools." \
            "" \
            "To enable self-updating, please install one of the following:" \
            "  • curl  (recommended)" \
            "  • wget" \
            "" \
            "Installation commands:" \
            "  Debian:   apt install curl" \
            "  RHEL:     yum install curl" \
            "" \
            "Continuing with local version of the scripts..."
        return 1
    fi
}

# Download a script file from the remote repository
# Args: $1 = script filename (relative path), $2 = output file path
# Returns: 0 on success, 1 on failure
download_script() {
    local script_file="$1"
    local output_file="$2"
    local http_status=""

    print_info "Fetching ${script_file}..."
    echo "            ▶ ${REMOTE_BASE}/${script_file}..."

    if [[ "$DOWNLOAD_CMD" == "curl" ]]; then
        http_status=$(curl -H 'Cache-Control: no-cache, no-store' -o "${output_file}" -w "%{http_code}" -fsSL "${REMOTE_BASE}/${script_file}" 2>/dev/null || echo "000")
        if [[ "$http_status" == "200" ]]; then
            # Validate that we got a script, not an error page
            # Check first 10 lines for shebang to handle files with leading comments/blank lines
            if head -n 10 "${output_file}" | grep -q "^#!/"; then
                return 0
            else
                print_error "✖ Invalid content received (not a script)"
                return 1
            fi
        elif [[ "$http_status" == "429" ]]; then
            print_error "✖ Rate limited by GitHub (HTTP 429)"
            return 1
        elif [[ "$http_status" != "000" ]]; then
            print_error "✖ HTTP ${http_status} error"
            return 1
        else
            print_error "✖ Download failed"
            return 1
        fi
    elif [[ "$DOWNLOAD_CMD" == "wget" ]]; then
        if wget --no-cache --no-cookies -O "${output_file}" -q "${REMOTE_BASE}/${script_file}" 2>/dev/null; then
            # Validate that we got a script, not an error page
            # Check first 10 lines for shebang to handle files with leading comments/blank lines
            if head -n 10 "${output_file}" | grep -q "^#!/"; then
                return 0
            else
                print_error "✖ Invalid content received (not a script)"
                return 1
            fi
        else
            print_error "✖ Download failed"
            return 1
        fi
    fi

    return 1
}

# Check for updates to kubernetes-setup.sh and utils-k8s.sh
# Will restart kubernetes-setup.sh if either file is updated
self_update() {
    local setup_updated=false
    local utils_updated=false
    local any_updated=false

    # Check kubernetes-setup.sh
    local SETUP_FILE="kubernetes-setup.sh"
    local LOCAL_SETUP="${SCRIPT_DIR}/${SETUP_FILE}"
    local TEMP_SETUP="$(make_temp_file)"

    if download_script "${SETUP_FILE}" "${TEMP_SETUP}"; then
        if diff -u "${LOCAL_SETUP}" "${TEMP_SETUP}" > /dev/null 2>&1; then
            print_success "- ${SETUP_FILE} is already up-to-date"
            rm -f "${TEMP_SETUP}"
            echo ""
        else
            echo ""
            echo -e "${CYAN}╭────────────────────────────────────────────────── Δ detected in ${SETUP_FILE} ──────────────────────────────────────────────────╮${NC}"
            diff -u --color "${LOCAL_SETUP}" "${TEMP_SETUP}" || true
            echo -e "${CYAN}╰───────────────────────────────────────────────────────── ${SETUP_FILE} ─────────────────────────────────────────────────────────╯${NC}"
            echo ""

            if prompt_yes_no "→ Overwrite ${SETUP_FILE} with updated version?" "y"; then
                echo ""
                chmod +x "${TEMP_SETUP}"
                mv -f "${TEMP_SETUP}" "${LOCAL_SETUP}"
                print_success "✓ Updated ${SETUP_FILE}"
                setup_updated=true
                any_updated=true
            else
                print_warning "⚠ Skipped ${SETUP_FILE} update"
                rm -f "${TEMP_SETUP}"
            fi
            echo ""
        fi
    else
        rm -f "${TEMP_SETUP}"
        echo ""
    fi

    # Check utils-k8s.sh
    local UTILS_FILE="utils-k8s.sh"
    local LOCAL_UTILS="${SCRIPT_DIR}/${UTILS_FILE}"
    local TEMP_UTILS="$(make_temp_file)"

    if download_script "${UTILS_FILE}" "${TEMP_UTILS}"; then
        if diff -u "${LOCAL_UTILS}" "${TEMP_UTILS}" > /dev/null 2>&1; then
            print_success "- ${UTILS_FILE} is already up-to-date"
            rm -f "${TEMP_UTILS}"
            echo ""
        else
            echo ""
            echo -e "${CYAN}╭────────────────────────────────────────────────── Δ detected in ${UTILS_FILE} ──────────────────────────────────────────────────╮${NC}"
            diff -u --color "${LOCAL_UTILS}" "${TEMP_UTILS}" || true
            echo -e "${CYAN}╰───────────────────────────────────────────────────────── ${UTILS_FILE} ─────────────────────────────────────────────────────────╯${NC}"
            echo ""

            if prompt_yes_no "→ Overwrite ${UTILS_FILE} with updated version?" "y"; then
                echo ""
                mv -f "${TEMP_UTILS}" "${LOCAL_UTILS}"
                print_success "✓ Updated ${UTILS_FILE}"
                utils_updated=true
                any_updated=true
            else
                print_warning "⚠ Skipped ${UTILS_FILE} update"
                rm -f "${TEMP_UTILS}"
            fi
            echo ""
        fi
    else
        rm -f "${TEMP_UTILS}"
        echo ""
    fi

    # Restart if either file was updated
    if [[ "$any_updated" == true ]]; then
        if [[ "$setup_updated" == true && "$utils_updated" == true ]]; then
            print_success "✓ Both ${SETUP_FILE} and ${UTILS_FILE} were updated - restarting..."
        elif [[ "$setup_updated" == true ]]; then
            print_success "✓ ${SETUP_FILE} was updated - restarting..."
        else
            print_success "✓ ${UTILS_FILE} was updated - restarting..."
        fi
        echo ""
        export scriptUpdated=1
        exec "${LOCAL_SETUP}" "$@"
        exit 0
    fi
}

# Update all module scripts (kubernetes-modules/*)
# Downloads each module script and prompts user to replace if different
# Continues processing all modules even if some downloads fail
# Returns: 1 if any downloads failed, 0 otherwise
update_modules() {
    local uptodate_count=0
    local updated_count=0
    local skipped_count=0
    local failed_count=0

    print_info "Checking for module updates..."
    echo ""

    # Check each module script for updates
    while IFS= read -r script_path; do
        local SCRIPT_FILE="$script_path"
        local LOCAL_SCRIPT="${SCRIPT_DIR}/${SCRIPT_FILE}"
        local TEMP_SCRIPT_FILE="$(make_temp_file)"

        # Ensure the local directory exists
        local script_dir="$(dirname "$LOCAL_SCRIPT")"
        mkdir -p "$script_dir"

        if ! download_script "${SCRIPT_FILE}" "${TEMP_SCRIPT_FILE}"; then
            echo "            (skipping ${SCRIPT_FILE})"
            ((failed_count++)) || true
            rm -f "${TEMP_SCRIPT_FILE}"
            echo ""
            continue
        fi

        # Create file if it doesn't exist
        if [[ ! -f "${LOCAL_SCRIPT}" ]]; then
            create_config_file "${LOCAL_SCRIPT}" 755 # -rwxr-xr-x
        fi

        # Compare and handle differences
        if diff -u "${LOCAL_SCRIPT}" "${TEMP_SCRIPT_FILE}" > /dev/null 2>&1; then
            print_success "- ${SCRIPT_FILE} is already up-to-date"
            ((uptodate_count++)) || true
            rm -f "${TEMP_SCRIPT_FILE}"
            echo ""
        else
            echo ""
            echo -e "${CYAN}╭────────────────────────────────────────────────── Δ detected in ${SCRIPT_FILE} ──────────────────────────────────────────────────╮${NC}"
            diff -u --color "${LOCAL_SCRIPT}" "${TEMP_SCRIPT_FILE}" || true
            echo -e "${CYAN}╰───────────────────────────────────────────────────────── ${SCRIPT_FILE} ─────────────────────────────────────────────────────────╯${NC}"
            echo ""

            if prompt_yes_no "→ Overwrite local ${SCRIPT_FILE} with remote copy?" "y"; then
                echo ""
                chmod +x "${TEMP_SCRIPT_FILE}"
                mv -f "${TEMP_SCRIPT_FILE}" "${LOCAL_SCRIPT}"
                print_success "✓ Replaced ${SCRIPT_FILE}"
                ((updated_count++)) || true
            else
                print_warning "⚠ Skipped ${SCRIPT_FILE}"
                ((skipped_count++)) || true
                rm -f "${TEMP_SCRIPT_FILE}"
            fi
            echo ""
        fi
    done < <(get_script_list)

    # Display final statistics
    echo ""
    echo "============================================================================"
    print_info "Module Update Summary"
    echo "============================================================================"
    echo -e "${BLUE}Up-to-date:${NC}  ${uptodate_count} file(s)"
    echo -e "${GREEN}Updated:${NC}     ${updated_count} file(s)"
    echo -e "${YELLOW}Skipped:${NC}     ${skipped_count} file(s)"
    echo -e "${RED}Failed:${NC}      ${failed_count} file(s)"
    echo "============================================================================"
    echo ""

    if [[ $failed_count -gt 0 ]]; then
        return 1
    fi
}

# ============================================================================
# Status Display
# ============================================================================

# Show status overview of Kubernetes components
show_status_overview() {
    print_info "Kubernetes Component Status"
    echo "            ======================================================="

    # Check kernel modules (loaded or built into kernel)
    if is_module_available "br_netfilter" && is_module_available "overlay"; then
        print_success "- Kernel modules (br_netfilter, overlay) available"
    else
        print_warning "⚠ Kernel modules not fully available"
    fi

    # Check packages
    while IFS=':' read -r display_name package_name; do
        if is_package_installed "$package_name"; then
            print_success "- $display_name is installed"
            track_special_packages "$package_name"
        else
            print_warning "⚠ $display_name is not installed"
        fi
    done < <(get_package_list)

    # Check networking
    local ip_forward
    ip_forward=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "0")
    if [[ "$ip_forward" == "1" ]]; then
        print_success "- IPv4 forwarding enabled"
    else
        print_warning "⚠ IPv4 forwarding disabled"
    fi

    # Check swap
    if [[ -z "$(swapon --show --noheadings 2>/dev/null)" ]]; then
        print_success "- Swap disabled"
    else
        print_warning "⚠ Swap is active"
    fi

    # Check Helm
    if command -v helm &>/dev/null; then
        print_success "- Helm installed ($(helm version --short 2>/dev/null || echo 'unknown version'))"
    else
        print_warning "⚠ Helm not installed"
    fi

    # Check Minikube
    if command -v minikube &>/dev/null; then
        print_success "- Minikube installed ($(minikube version --short 2>/dev/null || echo 'unknown version'))"
    else
        print_warning "⚠ Minikube not installed"
    fi

    # Check cluster
    if [[ -f /etc/kubernetes/admin.conf ]] && kubectl cluster-info &>/dev/null; then
        print_success "- Cluster initialized"
    else
        print_warning "⚠ Cluster not initialized"
    fi

    echo ""
}

# ============================================================================
# Main Orchestration
# ============================================================================

# Check if prerequisite steps succeeded before running a dependent step
# Usage: check_step_prerequisites "Step Name" "STEP_VAR1" "STEP_VAR2" ...
# Returns: 0 if all prerequisites passed, 1 if any failed (prints skip message)
check_step_prerequisites() {
    local step_name="$1"
    shift
    local failed_deps=()

    for dep_var in "$@"; do
        local dep_value="${!dep_var}"
        if [[ "$dep_value" != "true" ]]; then
            # Convert STEP_FOO_BAR_OK -> "foo bar" for readable output
            local readable="${dep_var#STEP_}"
            readable="${readable%_OK}"
            readable="${readable,,}"
            readable="${readable//_/ }"
            failed_deps+=("$readable")
        fi
    done

    if [[ ${#failed_deps[@]} -gt 0 ]]; then
        print_warning "⚠ Skipping ${step_name}: prerequisite(s) not met (${failed_deps[*]})"
        return 1
    fi
    return 0
}

main() {
    # Detect download command (curl or wget) for update functionality
    if detect_download_cmd; then
        # Only run self-update if not already updated in this session
        if [[ ${scriptUpdated:-0} -eq 0 ]]; then
            self_update "$@"
        fi

        # Always check for module updates (not skipped by scriptUpdated) if download cmd available
        update_modules

        # Clean up any obsolete scripts
        cleanup_obsolete_scripts "${OBSOLETE_SCRIPTS[@]+"${OBSOLETE_SCRIPTS[@]}"}"
    fi

    print_info "Kubernetes Setup and Configuration Script (Idempotent Mode)"
    echo "            ======================================================="

    if [[ $# -ne 0 && $1 == "--debug" ]]; then
        DEBUG_MODE=true
        print_debug "- DEBUG MODE ENABLED"
    fi

    detect_os
    echo "            - Detected OS: $DETECTED_OS"

    if [[ "$DETECTED_OS" != "linux" ]]; then
        print_error "✖ Kubernetes setup requires Linux. This script does not support $DETECTED_OS."
        echo ""
        exit 1
    fi

    # Detect if running in a container (sets RUNNING_IN_CONTAINER global variable)
    detect_container
    if [[ "$RUNNING_IN_CONTAINER" == true ]]; then
        echo "            - Running inside a container environment"
    fi
    echo ""

    # Root privilege check
    if ! check_privileges "system_config"; then
        print_error "✖ Kubernetes setup requires root privileges"
        print_info "Please re-run the script with: sudo $0"
        echo ""
        exit 1
    fi

    # Show status overview
    show_status_overview

    # Step 1: Configure kernel modules (must be before networking)
    print_info "Step 1: Kernel Modules"
    print_info "----------------------"
    source "${SCRIPT_DIR}/kubernetes-modules/configure-kernel-modules.sh"
    if main_configure_kernel_modules; then
        STEP_KERNEL_MODULES_OK=true
    else
        print_error "✖ Kernel module configuration failed. Continuing..."
    fi
    echo ""

    # Step 2: Configure APT repositories
    print_info "Step 2: APT Repositories"
    print_info "------------------------"
    source "${SCRIPT_DIR}/kubernetes-modules/configure-k8s-repos.sh"
    if main_configure_k8s_repos; then
        STEP_REPOS_OK=true
    else
        print_error "✖ Repository configuration failed. Continuing..."
    fi
    echo ""

    # Step 3: Install Kubernetes packages
    print_info "Step 3: Package Installation"
    print_info "----------------------------"
    if check_step_prerequisites "Package Installation" "STEP_REPOS_OK"; then
        source "${SCRIPT_DIR}/kubernetes-modules/install-k8s-packages.sh"
        if main_install_k8s_packages; then
            # Verify packages are actually available (check_and_install_packages always returns 0)
            if [[ "$KUBEADM_INSTALLED" == true || "$KUBELET_INSTALLED" == true ]]; then
                STEP_PACKAGES_OK=true
            else
                print_warning "⚠ No core Kubernetes packages available. Dependent steps will be skipped."
            fi
        else
            print_error "✖ Package installation failed. Continuing..."
        fi
    fi
    echo ""

    # Step 4: Configure networking (requires kernel modules from step 1)
    print_info "Step 4: Network Configuration"
    print_info "-----------------------------"
    if check_step_prerequisites "Network Configuration" "STEP_KERNEL_MODULES_OK"; then
        source "${SCRIPT_DIR}/kubernetes-modules/configure-networking.sh"
        if main_configure_networking; then
            STEP_NETWORKING_OK=true
        else
            print_error "✖ Network configuration failed. Continuing..."
        fi
    fi
    echo ""

    # Step 5: Configure swap
    print_info "Step 5: Swap Configuration"
    print_info "--------------------------"
    source "${SCRIPT_DIR}/kubernetes-modules/configure-swap.sh"
    if main_configure_swap; then
        STEP_SWAP_OK=true
    else
        print_error "✖ Swap configuration failed. Continuing..."
    fi
    echo ""

    # Step 6: Configure CRI-O (if installed)
    if [[ "$CRIO_INSTALLED" == true ]]; then
        print_info "Step 6: CRI-O Configuration"
        print_info "---------------------------"
        if check_step_prerequisites "CRI-O Configuration" "STEP_PACKAGES_OK"; then
            source "${SCRIPT_DIR}/kubernetes-modules/configure-crio.sh"
            if ! main_configure_crio; then
                print_error "✖ CRI-O configuration failed. Continuing..."
            fi
        fi
        echo ""
    else
        print_info "Step 6: Skipping CRI-O configuration (not installed)"
        echo ""
    fi

    # Step 7: Helm (optional)
    if prompt_yes_no "            Would you like to install/update Helm?" "n"; then
        source "${SCRIPT_DIR}/kubernetes-modules/install-update-helm.sh"
        if ! main_install_update_helm; then
            print_error "✖ Helm installation failed. Continuing..."
        fi
        echo ""
    else
        print_info "Skipping Helm installation"
        echo ""
    fi

    # Step 8: Minikube (optional)
    if prompt_yes_no "            Would you like to install/update Minikube?" "n"; then
        source "${SCRIPT_DIR}/kubernetes-modules/install-update-minikube.sh"
        if ! main_install_update_minikube; then
            print_error "✖ Minikube installation failed. Continuing..."
        fi
        echo ""
    else
        print_info "Skipping Minikube installation"
        echo ""
    fi

    # Step 9: Cluster initialization (optional, requires kubeadm)
    if ! command -v kubeadm &>/dev/null; then
        print_info "Step 9: Skipping cluster initialization (kubeadm not installed)"
        echo ""
    elif prompt_yes_no "            Would you like to initialize or join a cluster?" "n"; then
        if check_step_prerequisites "Cluster Initialization" "STEP_PACKAGES_OK" "STEP_NETWORKING_OK" "STEP_SWAP_OK"; then
            source "${SCRIPT_DIR}/kubernetes-modules/initialize-cluster.sh"
            if ! main_initialize_cluster; then
                print_error "✖ Cluster initialization failed. Continuing..."
            fi
        fi
        echo ""
    else
        print_info "Skipping cluster initialization"
        echo ""
    fi

    # Step 10: Validate cluster (if initialized)
    if [[ -f /etc/kubernetes/admin.conf ]] && kubectl cluster-info &>/dev/null; then
        print_info "Step 10: Cluster Validation"
        print_info "---------------------------"
        source "${SCRIPT_DIR}/kubernetes-modules/validate-cluster.sh"
        if ! main_validate_cluster; then
            print_error "✖ Cluster validation reported issues. Continuing..."
        fi
        echo ""

        # Step 11: Certificate management (if cluster initialized)
        print_info "Step 11: Certificate Management"
        print_info "-------------------------------"
        source "${SCRIPT_DIR}/kubernetes-modules/manage-certificates.sh"
        if ! main_manage_certificates; then
            print_error "✖ Certificate management failed. Continuing..."
        fi
        echo ""
    fi

    # Step 12: Configure KUBE_EDITOR
    print_info "Step 12: KUBE_EDITOR Configuration"
    print_info "----------------------------------"
    source "${SCRIPT_DIR}/kubernetes-modules/configure-kube-editor.sh"
    if ! main_configure_kube_editor; then
        print_error "✖ KUBE_EDITOR configuration failed. Continuing..."
    fi
    echo ""

    print_success "Kubernetes setup complete!"
    print_session_summary
    echo ""
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
