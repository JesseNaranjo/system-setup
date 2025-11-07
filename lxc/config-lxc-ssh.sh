#!/usr/bin/env bash

# config-lxc-ssh.sh - Configure SSH keys for LXC containers
#
# Usage: sudo ./config-lxc-ssh.sh <username>
#
# This script configures SSH authentication for a user across all LXC containers by:
# - Generating a shared SSH key pair for LXC container access (if it doesn't exist)
# - Deploying the public key to all LXC containers (running or stopped)
# - Setting proper permissions for SSH directories and key files
# - Verifying SSH is installed in each container
# - Creating authorized_keys entries for passwordless authentication
#
# Requirements:
# - Must be run as root (to access container rootfs)
# - Target user must exist on the host system
# - Target user cannot be root
# - Containers do not need to be running (direct rootfs access)
#
# The script is idempotent - it can be run multiple times safely.
# Existing keys and configurations are preserved and backed up when modified.

set -euo pipefail

# Colors for output
readonly BLUE='\033[0;34m'
readonly GRAY='\033[0;90m'
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# Global variables
BACKED_UP_FILES=""
TARGET_USER=""
TARGET_USER_HOME=""
SSH_KEY_NAME="id_local-lxc-access"
CONTAINERS_CONFIGURED=0
CONTAINERS_SKIPPED=0

# Print colored output
print_info() {
    echo -e "${BLUE}[   INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[  ERROR]${NC} $1"
}

print_backup() {
    echo -e "${GRAY}[ BACKUP] $1${NC}"
}

# Prompt user for yes/no confirmation
# Usage: prompt_yes_no "message" [default]
#   default: "y" or "n" (optional, defaults to "n")
# Returns: 0 for yes, 1 for no
prompt_yes_no() {
    local prompt_message="$1"
    local default="${2:-n}"
    local prompt_suffix
    local user_reply

    # Set the prompt suffix based on default
    if [[ "${default,,}" == "y" ]]; then
        prompt_suffix="(Y/n)"
    else
        prompt_suffix="(y/N)"
    fi

    # Read from /dev/tty to work correctly in while-read loops
    read -p "$prompt_message $prompt_suffix: " -r user_reply </dev/tty

    # If user just pressed Enter (empty reply), use default
    if [[ -z "$user_reply" ]]; then
        [[ "${default,,}" == "y" ]]
    else
        [[ $user_reply =~ ^[Yy]$ ]]
    fi
}

# Backup file if it exists (only once per session)
backup_file() {
    local file="$1"

    # Check if already backed up in this session
    if [[ "$BACKED_UP_FILES" == *"$file"* ]]; then
        return 0
    fi

    if [[ -f "$file" ]]; then
        local backup="${file}.backup.$(date +%Y%m%d_%H%M%S)"

        # Copy file with preserved permissions (-p flag)
        cp -p "$file" "$backup"

        # Preserve ownership (requires appropriate permissions)
        # Get the owner and group of the original file
        local owner=$(stat -c "%u:%g" "$file")
        chown "$owner" "$backup" 2>/dev/null || true

        print_backup "- Created backup: $backup"
        BACKED_UP_FILES="${BACKED_UP_FILES} ${file}"
    fi
}

# Check if script is run as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        echo ""
        echo "Please run: sudo $0 $*"
        exit 1
    fi
}

# Validate target user
validate_user() {
    local username="$1"

    # Check if user is root
    if [[ "$username" == "root" ]]; then
        print_error "Target user cannot be root"
        exit 1
    fi

    # Check if user exists
    if ! id "$username" &>/dev/null; then
        print_error "User '$username' does not exist on this system"
        exit 1
    fi

    # Get user's home directory
    TARGET_USER_HOME=$(eval echo "~$username")

    if [[ ! -d "$TARGET_USER_HOME" ]]; then
        print_error "Home directory for user '$username' does not exist: $TARGET_USER_HOME"
        exit 1
    fi

    TARGET_USER="$username"
    print_success "Target user validated: $TARGET_USER (home: $TARGET_USER_HOME)"
}

# Generate SSH key pair for LXC access
generate_ssh_keypair() {
    local ssh_dir="${TARGET_USER_HOME}/.ssh"
    local private_key="${ssh_dir}/${SSH_KEY_NAME}.key"
    local public_key="${ssh_dir}/${SSH_KEY_NAME}.pub"

    # Create .ssh directory if it doesn't exist
    if [[ ! -d "$ssh_dir" ]]; then
        print_info "Creating SSH directory: $ssh_dir"
        mkdir -p "$ssh_dir"
        chown "${TARGET_USER}:${TARGET_USER}" "$ssh_dir"
        chmod 700 "$ssh_dir"
    fi

    # Check if key pair already exists
    if [[ -f "$private_key" && -f "$public_key" ]]; then
        print_info "SSH key pair already exists: $private_key"

        # Verify the key is valid
        if ssh-keygen -l -f "$private_key" &>/dev/null; then
            print_success "✓ Existing SSH key pair is valid"
            return 0
        else
            print_warning "Existing key appears invalid"
            if prompt_yes_no "Generate new key pair (existing will be backed up)?" "n"; then
                backup_file "$private_key"
                backup_file "$public_key"
            else
                print_error "Cannot proceed with invalid key"
                exit 1
            fi
        fi
    fi

    # Generate new key pair
    print_info "Generating SSH key pair: $private_key"
    ssh-keygen -t rsa -b 4096 -f "$private_key" -N "" -C "${TARGET_USER}@lxc-containers"
    mv -f "${private_key}.pub" "$public_key"

    # Set proper ownership and permissions
    chown "${TARGET_USER}:${TARGET_USER}" "$private_key" "$public_key"
    chmod 600 "$private_key"
    chmod 644 "$public_key"

    print_success "✓ SSH key pair generated successfully"
    print_info "Private key: $private_key"
    print_info "Public key: $public_key"
}

# Get list of all LXC containers for the user
get_all_containers() {
    local containers=()
    local lxc_path="${TARGET_USER_HOME}/.local/share/lxc"

    # Check if LXC directory exists
    if [[ ! -d "$lxc_path" ]]; then
        echo "${containers[@]}"
        return 0
    fi

    # Find all directories containing a config file
    for container_dir in "$lxc_path"/*; do
        if [[ -d "$container_dir" && -f "$container_dir/config" ]]; then
            local container_name=$(basename "$container_dir")
            containers+=("$container_name")
        fi
    done

    echo "${containers[@]}"
}

# Check if SSH is installed in container
check_ssh_in_container() {
    local container="$1"
    local rootfs="$2"

    # Check for sshd in common locations
    if [[ -f "${rootfs}/usr/sbin/sshd" ]] || [[ -f "${rootfs}/usr/bin/sshd" ]]; then
        return 0
    fi

    return 1
}

# Configure SSH access for a single container
configure_container_ssh() {
    local container="$1"
    local public_key_content="$2"

    print_info "Configuring container: $container"

    # Get container's rootfs path
    local config_path="${TARGET_USER_HOME}/.local/share/lxc/${container}/config"
    if [[ ! -f "$config_path" ]]; then
        print_warning "Container config not found: $config_path - skipping"
        ((CONTAINERS_SKIPPED++)) || true
        return 1
    fi

    local rootfs=$(grep "^lxc.rootfs.path" "$config_path" | awk '{print $NF}' | sed 's|^dir:||')
    if [[ ! -d "$rootfs" ]]; then
        print_warning "Container rootfs not found: $rootfs - skipping"
        ((CONTAINERS_SKIPPED++)) || true
        return 1
    fi

    # Check if SSH is installed in container
    if ! check_ssh_in_container "$container" "$rootfs"; then
        print_warning "SSH server not found in container $container - skipping"
        print_info "Install SSH in container: use system-setup.sh or apt install openssh-server"
        ((CONTAINERS_SKIPPED++)) || true
        return 1
    fi

    # Find the user's home directory in the container
    local container_home="${rootfs}/home/${TARGET_USER}"

    # Check if user exists in container
    if [[ ! -d "$container_home" ]]; then
        print_warning "User $TARGET_USER home directory not found in container $container"
        print_info "Create user in container: adduser $TARGET_USER"
        ((CONTAINERS_SKIPPED++)) || true
        return 1
    fi

    # Create .ssh directory in container
    local container_ssh_dir="${container_home}/.ssh"
    if [[ ! -d "$container_ssh_dir" ]]; then
        print_info "Creating .ssh directory in container: $container_ssh_dir"
        mkdir -p "$container_ssh_dir"
    fi

    # Get user's UID/GID from the container home directory (for proper filesystem ownership)
    local user_uid=$(stat -c "%u" "$container_home")
    local user_gid=$(stat -c "%g" "$container_home")

    if [[ -z "$user_uid" || -z "$user_gid" ]]; then
        print_warning "Could not determine UID/GID for user $TARGET_USER - skipping"
        ((CONTAINERS_SKIPPED++)) || true
        return 1
    fi

    # Setup authorized_keys file
    local authorized_keys="${container_ssh_dir}/authorized_keys"

    # Check if key is already in authorized_keys
    if [[ -f "$authorized_keys" ]] && grep -qF "$public_key_content" "$authorized_keys"; then
        print_success "SSH key already configured in container: $container"
    else
        # Backup existing authorized_keys if it exists (only if we're modifying it)
        if [[ -f "$authorized_keys" ]]; then
            backup_file "$authorized_keys"
        fi

        print_info "Adding SSH key to container: $container"
        echo "$public_key_content" >> "$authorized_keys"
    fi

    # Set proper permissions
    chmod 700 "$container_ssh_dir"
    chmod 600 "$authorized_keys"
    chown -R "${user_uid}:${user_gid}" "$container_ssh_dir"

    print_success "✓ Container $container configured successfully"
    ((CONTAINERS_CONFIGURED++)) || true
}

# Check if SSH config already has an entry for this key
check_ssh_config() {
    local ssh_config="${TARGET_USER_HOME}/.ssh/config"
    local key_path="${TARGET_USER_HOME}/.ssh/${SSH_KEY_NAME}.key"

    # Check if config file exists and contains reference to our key
    if [[ -f "$ssh_config" ]] && grep -q "$SSH_KEY_NAME.key" "$ssh_config"; then
        return 0  # Config exists
    fi

    return 1  # Config does not exist
}

# Configure SSH config file for easier access
configure_ssh_config() {
    local ssh_config="${TARGET_USER_HOME}/.ssh/config"
    local key_path="${TARGET_USER_HOME}/.ssh/${SSH_KEY_NAME}.key"

    echo ""
    print_info "SSH config setup for LXC containers"
    echo ""
    echo "          You can configure ~/.ssh/config to simplify SSH access to your containers."
    echo "          This allows you to use: ssh <hostname> instead of: ssh -i <key> user@<ip>"
    echo ""
    echo "          Enter the Host pattern for your LXC containers:"
    echo "            Examples:"
    echo "              - lxc-*           (matches: lxc-web, lxc-db, etc.)"
    echo "              - *.lxc           (matches: web.lxc, db.lxc, etc.)"
    echo "              - 192.168.64.*    (matches: any IP in 192.168.64.0/24 subnet)"
    echo "              - 10.0.3.*        (matches: any IP in 10.0.3.0/24 subnet)"
    echo "              - container01     (matches: specific hostname)"
    echo "              - web.example.com (matches: specific FQDN)"
    echo ""

    # Read from /dev/tty to work correctly in context
    read -p "Host pattern: " -r host_pattern </dev/tty

    if [[ -z "$host_pattern" ]]; then
        print_warning "No host pattern provided, skipping SSH config setup"
        return 1
    fi

    # Backup existing config
    if [[ -f "$ssh_config" ]]; then
        backup_file "$ssh_config"
    else
        # Create .ssh directory if it doesn't exist
        mkdir -p "${TARGET_USER_HOME}/.ssh"
        chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_USER_HOME}/.ssh"
        chmod 700 "${TARGET_USER_HOME}/.ssh"
    fi

    # Append configuration
    {
        echo ""
        echo "# LXC Container SSH Configuration - Added by config-lxc-ssh.sh"
        echo "Host $host_pattern"
        echo "    User ${TARGET_USER}"
        echo "    IdentityFile $key_path"
        echo "    StrictHostKeyChecking no"
        echo "    UserKnownHostsFile /dev/null"
    } >> "$ssh_config"

    # Set proper ownership and permissions
    chown "${TARGET_USER}:${TARGET_USER}" "$ssh_config"
    chmod 600 "$ssh_config"

    print_success "✓ SSH config updated: $ssh_config"

    return 0
}

# Main function
main() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                              ║"
    echo "║                    LXC Container SSH Configuration Script                    ║"
    echo "║                                                                              ║"
    echo "╚══════════════════════════════════════════════════════════════════════════════╝"
    echo ""

    # Check if user parameter is provided
    if [[ $# -lt 1 ]]; then
        print_error "Usage: sudo $0 <username>"
        echo ""
        echo "Example: sudo $0 myuser"
        exit 1
    fi

    # Check root privileges
    check_root "$@"

    # Validate target user
    validate_user "$1"
    echo ""

    # Check if LXC is installed
    if ! command -v lxc-ls &>/dev/null; then
        print_error "LXC is not installed on this system"
        exit 1
    fi

    # Generate or verify SSH key pair
    generate_ssh_keypair
    echo ""

    # Read public key content
    local public_key="${TARGET_USER_HOME}/.ssh/${SSH_KEY_NAME}.pub"
    local public_key_content=$(cat "$public_key")

    # Get list of all containers
    print_info "Detecting LXC containers for user $TARGET_USER..."
    local containers
    read -ra containers <<< "$(get_all_containers)"

    if [[ ${#containers[@]} -eq 0 ]]; then
        print_warning "No containers found for user $TARGET_USER"
        echo ""
        print_info "Create containers and run this script again to configure SSH access"
        exit 0
    fi

    print_info "Found ${#containers[@]} container(s): ${containers[*]}"
    echo ""

    # Configure each container
    for container in "${containers[@]}"; do
        configure_container_ssh "$container" "$public_key_content"
        echo ""
    done

    # Print summary
    echo "╔══════════════════════════════════════════════════════════════════════════════╗"
    echo "║                              Configuration Summary                           ║"
    echo "╚══════════════════════════════════════════════════════════════════════════════╝"
    echo ""
    print_info "Containers configured: $CONTAINERS_CONFIGURED"
    print_warning "Containers skipped: $CONTAINERS_SKIPPED"
    echo ""

    if [[ $CONTAINERS_CONFIGURED -gt 0 ]]; then
        print_success "SSH key deployment complete!"
        echo ""

        # Check if SSH config is already configured
        if check_ssh_config; then
            print_success "SSH config already contains entry for ${SSH_KEY_NAME}.key"
        else
            # Offer to configure SSH config
            if prompt_yes_no "Would you like to configure ~/.ssh/config for easier SSH access?" "y"; then
                configure_ssh_config
            else
                print_info "Skipping SSH config setup"
                echo ""
                print_info "To connect to a container via SSH:"
                echo "          - ssh -i ${TARGET_USER_HOME}/.ssh/${SSH_KEY_NAME}.key ${TARGET_USER}@<container-ip>"
                echo ""
                print_info "To get container IP addresses:"
                echo "          - lxc-ls -f"
            fi
        fi
        echo ""
    fi

    if [[ $CONTAINERS_SKIPPED -gt 0 ]]; then
        print_warning "Some containers were skipped. Check the output above for details."
        echo ""
    fi
}

# Run main function
main "$@"
