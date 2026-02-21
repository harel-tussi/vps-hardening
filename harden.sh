#!/bin/bash
#
# VPS Hardening Script
# ====================
#
# INSTALLATION:
# -------------
# curl -sL https://raw.githubusercontent.com/harel-tussi/vps-hardening/main/harden.sh -o harden.sh
# chmod +x harden.sh
# ./harden.sh username
#
# BEFORE RUNNING THIS SCRIPT:
# ---------------------------
# You must set up SSH keys or you will be LOCKED OUT!
#
# 1. On your LOCAL machine, generate a key (if you don't have one):
#
#    ssh-keygen -t ed25519 -C "your-email@example.com"
#
# 2. Copy your public key to the VPS:
#
#    ssh-copy-id root@your-vps-ip
#
#    Or manually:
#    cat ~/.ssh/id_ed25519.pub | ssh root@your-vps-ip "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
#
# 3. Test SSH key login works (should not ask for password):
#
#    ssh root@your-vps-ip
#
# 4. Now run this script:
#
#    ./harden.sh username
#
# ====================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root"
    exit 1
fi

# Check for SSH keys
echo ""
echo "============================================"
echo -e "${YELLOW}SSH KEY CHECK${NC}"
echo "============================================"
if [[ -f /root/.ssh/authorized_keys ]] && [[ -s /root/.ssh/authorized_keys ]]; then
    # Fix permissions (common issue that prevents key auth from working)
    chmod 700 /root/.ssh
    chmod 600 /root/.ssh/authorized_keys
    log_info "Fixed SSH directory permissions"

    log_info "Found SSH authorized_keys with $(wc -l < /root/.ssh/authorized_keys) key(s)"
    echo ""
    echo "Keys found:"
    cat /root/.ssh/authorized_keys | while read -r line; do
        # Show key type and comment (last two fields)
        echo "  - $(echo "$line" | awk '{print $1, $NF}')"
    done
    echo ""
else
    log_error "No SSH keys found in /root/.ssh/authorized_keys!"
    echo ""
    echo "You MUST set up SSH keys before running this script."
    echo "Otherwise you will be LOCKED OUT when password auth is disabled."
    echo ""
    echo "On your LOCAL machine, run:"
    echo "  ssh-copy-id root@$(hostname -I | awk '{print $1}')"
    echo ""
    echo "Then run this script again."
    exit 1
fi

read -p "Are your SSH keys set up correctly? Test in another terminal first! [y/N]: " CONFIRM_KEYS
if [[ ! "$CONFIRM_KEYS" =~ ^[Yy]$ ]]; then
    log_warn "Aborted. Please set up SSH keys and try again."
    exit 0
fi
echo ""

# Get new username from argument or prompt
NEW_USER="${1:-}"
if [[ -z "$NEW_USER" ]]; then
    read -p "Enter new username: " NEW_USER
fi

if [[ -z "$NEW_USER" ]]; then
    log_error "Username cannot be empty"
    exit 1
fi

# Step 1: Update all packages
log_info "Updating package lists..."
apt-get update -y

log_info "Upgrading installed packages..."
apt-get upgrade -y

log_info "Removing unused packages..."
apt-get autoremove -y

# Step 2: Create non-root user
if id "$NEW_USER" &>/dev/null; then
    log_warn "User '$NEW_USER' already exists, skipping creation"
else
    log_info "Creating user '$NEW_USER'..."
    adduser --gecos "" "$NEW_USER"

    log_info "Adding '$NEW_USER' to sudo group..."
    usermod -aG sudo "$NEW_USER"
fi

# Copy SSH keys from root to new user if they exist
if [[ -f /root/.ssh/authorized_keys ]]; then
    log_info "Copying SSH authorized_keys to new user..."
    mkdir -p /home/"$NEW_USER"/.ssh
    cp /root/.ssh/authorized_keys /home/"$NEW_USER"/.ssh/
    chown -R "$NEW_USER":"$NEW_USER" /home/"$NEW_USER"/.ssh
    chmod 700 /home/"$NEW_USER"/.ssh
    chmod 600 /home/"$NEW_USER"/.ssh/authorized_keys
fi

# Step 3: Harden SSH configuration
log_info "Hardening SSH configuration..."

SSH_CONFIG="/etc/ssh/sshd_config"
SSH_BACKUP="/etc/ssh/sshd_config.backup.$(date +%Y%m%d%H%M%S)"

# Backup original config
cp "$SSH_CONFIG" "$SSH_BACKUP"
log_info "SSH config backed up to $SSH_BACKUP"

# Function to set SSH config option
set_ssh_option() {
    local option="$1"
    local value="$2"

    if grep -q "^#*${option}" "$SSH_CONFIG"; then
        sed -i "s/^#*${option}.*/${option} ${value}/" "$SSH_CONFIG"
    else
        echo "${option} ${value}" >> "$SSH_CONFIG"
    fi
}

# Disable root login
set_ssh_option "PermitRootLogin" "no"
log_info "Disabled root login"

# Disable password authentication
set_ssh_option "PasswordAuthentication" "no"
log_info "Disabled password authentication"

# Additional SSH hardening
set_ssh_option "PubkeyAuthentication" "yes"
set_ssh_option "PermitEmptyPasswords" "no"
set_ssh_option "X11Forwarding" "no"
set_ssh_option "MaxAuthTries" "3"
set_ssh_option "ClientAliveInterval" "300"
set_ssh_option "ClientAliveCountMax" "2"

# Detect SSH service name (ssh on Ubuntu/Debian, sshd on RHEL/CentOS)
if [[ -f /lib/systemd/system/ssh.service ]] || [[ -f /etc/systemd/system/ssh.service ]]; then
    SSH_SERVICE="ssh"
elif [[ -f /lib/systemd/system/sshd.service ]] || [[ -f /etc/systemd/system/sshd.service ]]; then
    SSH_SERVICE="sshd"
else
    # Fallback: try to detect running service
    if systemctl is-active --quiet ssh 2>/dev/null; then
        SSH_SERVICE="ssh"
    else
        SSH_SERVICE="sshd"
    fi
fi
log_info "Detected SSH service: $SSH_SERVICE"

# Validate SSH config before restarting
if sshd -t; then
    log_info "SSH configuration is valid"
    systemctl restart "$SSH_SERVICE"
    log_info "SSH service restarted"
else
    log_error "SSH configuration is invalid! Restoring backup..."
    cp "$SSH_BACKUP" "$SSH_CONFIG"
    exit 1
fi

# Step 4: Configure automatic security updates
log_info "Installing unattended-upgrades..."
apt-get install -y unattended-upgrades apt-listchanges

cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};

Unattended-Upgrade::Package-Blacklist {
};

Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

log_info "Automatic security updates configured"

# Step 5: Restrict SSH to Tailscale interface (optional)
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || true)

if [[ -n "$TAILSCALE_IP" ]]; then
    read -p "Restrict SSH to Tailscale only? ($TAILSCALE_IP) [y/N]: " RESTRICT_SSH
    if [[ "$RESTRICT_SSH" =~ ^[Yy]$ ]]; then
        set_ssh_option "ListenAddress" "$TAILSCALE_IP"
        log_info "SSH restricted to Tailscale interface ($TAILSCALE_IP)"

        # Validate and restart SSH again
        if sshd -t; then
            systemctl restart "$SSH_SERVICE"
            log_info "SSH service restarted with Tailscale restriction"
        else
            log_error "SSH configuration invalid! Removing ListenAddress..."
            sed -i "/^ListenAddress/d" "$SSH_CONFIG"
        fi
    else
        log_info "Skipping Tailscale SSH restriction"
    fi
else
    log_warn "Tailscale not detected, skipping SSH restriction option"
fi

# Step 6: Install and configure fail2ban
log_info "Installing fail2ban..."
apt-get install -y fail2ban

# Create local jail configuration
log_info "Configuring fail2ban..."
cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
banaction = iptables-multiport
backend = systemd

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 1d
EOF

# Enable and start fail2ban
systemctl enable fail2ban
systemctl restart fail2ban
log_info "fail2ban installed and configured"

# Summary
echo ""
echo "============================================"
echo -e "${GREEN}VPS Hardening Complete!${NC}"
echo "============================================"
echo ""
echo "Changes made:"
echo "  ✓ System packages updated"
echo "  ✓ User '$NEW_USER' created with sudo access"
echo "  ✓ SSH root login disabled"
echo "  ✓ SSH password authentication disabled"
echo "  ✓ Automatic security updates enabled"
if [[ -n "$TAILSCALE_IP" && "$RESTRICT_SSH" =~ ^[Yy]$ ]]; then
echo "  ✓ SSH restricted to Tailscale ($TAILSCALE_IP)"
fi
echo "  ✓ fail2ban installed and configured"
echo ""
echo -e "${YELLOW}IMPORTANT:${NC}"
echo "  1. Make sure you have SSH key access for '$NEW_USER'"
echo "  2. Test SSH login as '$NEW_USER' in a NEW terminal before closing this session"
echo "  3. SSH config backup saved at: $SSH_BACKUP"
echo ""
echo "To test: ssh ${NEW_USER}@<your-server-ip>"
echo ""
