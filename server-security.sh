#!/bin/bash

#####################################################
#  SERVER SECURITY SCRIPT - Ubuntu/Debian
#  Version: 1.1
#  Features: UFW, fail2ban, auto-updates, sysctl, docker
#####################################################

set -e

# Prevent interactive prompts during apt operations (e.g., grub-pc config)
export DEBIAN_FRONTEND=noninteractive

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Read from /dev/tty to support curl | bash
ask() {
    read -p "$1" "$2" < /dev/tty
}

# Log functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_banner() {
    echo -e "${GREEN}"
    echo "╔═══════════════════════════════════════════════════╗"
    echo "║       SERVER SECURITY SCRIPT v1.1                 ║"
    echo "║       Basic Protection for Ubuntu/Debian          ║"
    echo "╚═══════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Root check
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root!"
        log_info "Usage: sudo $0"
        exit 1
    fi
}

# Debian/Ubuntu check
check_os() {
    if ! command -v apt &> /dev/null; then
        log_error "This script only works on Debian/Ubuntu systems!"
        exit 1
    fi
    log_success "Operating system is compatible"
}

#####################################################
# 1. SYSTEM UPDATE
#####################################################
update_system() {
    log_info "Updating system..."
    apt update -y
    apt upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
    log_success "System updated"
}

#####################################################
# 2. UFW FIREWALL
#####################################################
setup_ufw() {
    log_info "Installing UFW Firewall..."

    apt install -y ufw

    # Default policies
    ufw default deny incoming
    ufw default allow outgoing

    # Allow SSH port (default 22)
    echo ""
    ask "SSH port (default 22): " SSH_PORT
    SSH_PORT=${SSH_PORT:-22}
    ufw allow ${SSH_PORT}/tcp comment 'SSH'
    log_success "SSH port ${SSH_PORT} allowed"

    # HTTP/HTTPS question
    echo ""
    ask "Do you want to open HTTP (80) port? [Y/n]: " OPEN_HTTP
    OPEN_HTTP=${OPEN_HTTP:-y}
    if [[ "$OPEN_HTTP" =~ ^[Yy]$ ]]; then
        ufw allow 80/tcp comment 'HTTP'
        log_success "HTTP port 80 allowed"
    fi

    ask "Do you want to open HTTPS (443) port? [Y/n]: " OPEN_HTTPS
    OPEN_HTTPS=${OPEN_HTTPS:-y}
    if [[ "$OPEN_HTTPS" =~ ^[Yy]$ ]]; then
        ufw allow 443/tcp comment 'HTTPS'
        log_success "HTTPS port 443 allowed"
    fi

    # Additional ports
    echo ""
    ask "Any other ports to open? (comma-separated, press Enter to skip): " EXTRA_PORTS
    if [[ -n "$EXTRA_PORTS" ]]; then
        IFS=',' read -ra PORTS <<< "$EXTRA_PORTS"
        for port in "${PORTS[@]}"; do
            port=$(echo "$port" | tr -d ' ')
            if [[ "$port" =~ ^[0-9]+$ ]]; then
                ufw allow ${port}/tcp comment 'Custom'
                log_success "Port ${port} allowed"
            fi
        done
    fi

    # Enable UFW
    echo "y" | ufw enable
    log_success "UFW Firewall enabled"
}

#####################################################
# 3. FAIL2BAN
#####################################################
setup_fail2ban() {
    log_info "Installing fail2ban..."

    apt install -y fail2ban

    # Custom jail configuration
    cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
banaction = ufw

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 1h
EOF

    # Restart fail2ban
    systemctl enable fail2ban
    systemctl restart fail2ban

    log_success "fail2ban installed and enabled"
}

#####################################################
# 4. SSH HARDENING (Minimal)
#####################################################
setup_ssh_hardening() {
    log_info "Applying minimal SSH hardening..."

    # Backup
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

    # Only set MaxAuthTries and LoginGraceTime
    if grep -q "^MaxAuthTries" /etc/ssh/sshd_config; then
        sed -i 's/^MaxAuthTries.*/MaxAuthTries 3/' /etc/ssh/sshd_config
    else
        echo "MaxAuthTries 3" >> /etc/ssh/sshd_config
    fi

    if grep -q "^LoginGraceTime" /etc/ssh/sshd_config; then
        sed -i 's/^LoginGraceTime.*/LoginGraceTime 20/' /etc/ssh/sshd_config
    else
        echo "LoginGraceTime 20" >> /etc/ssh/sshd_config
    fi

    # Test configuration
    if sshd -t; then
        # Try sshd first, then ssh (Ubuntu uses ssh)
        if systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null; then
            log_success "SSH settings updated"
        else
            log_warning "Could not reload SSH service, changes will apply after reboot"
        fi
    else
        log_error "SSH configuration error! Restoring backup..."
        cp /etc/ssh/sshd_config.backup /etc/ssh/sshd_config
    fi
}

#####################################################
# 5. AUTOMATIC SECURITY UPDATES
#####################################################
setup_auto_updates() {
    log_info "Setting up automatic security updates..."

    apt install -y unattended-upgrades apt-listchanges

    # Configure automatic updates
    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

    # unattended-upgrades configuration
    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

    systemctl enable unattended-upgrades
    systemctl restart unattended-upgrades

    log_success "Automatic security updates enabled"
}

#####################################################
# 6. SYSCTL HARDENING
#####################################################
setup_sysctl_hardening() {
    log_info "Applying kernel security settings..."

    cat > /etc/sysctl.d/99-security.conf << 'EOF'
# IP Spoofing protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Disable ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Disable send redirects
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2

# Log martians
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Ignore ICMP broadcast
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Ignore bogus ICMP errors
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Disable IPv6 if not needed (optional - commented out)
# net.ipv6.conf.all.disable_ipv6 = 1
# net.ipv6.conf.default.disable_ipv6 = 1
EOF

    # Apply settings
    sysctl -p /etc/sysctl.d/99-security.conf

    log_success "Kernel security settings applied"
}

#####################################################
# 7. DOCKER (Optional)
#####################################################
setup_docker() {
    echo ""

    # Check if Docker is already installed
    if command -v docker &> /dev/null; then
        DOCKER_VERSION=$(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',')
        log_success "Docker is already installed (version: $DOCKER_VERSION)"
        DOCKER_INSTALLED=true
        return
    fi

    ask "Do you want to install Docker? [Y/n]: " INSTALL_DOCKER
    INSTALL_DOCKER=${INSTALL_DOCKER:-y}

    if [[ "$INSTALL_DOCKER" =~ ^[Yy]$ ]]; then
        log_info "Installing Docker..."

        # Download and run official Docker install script
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh
        rm /tmp/get-docker.sh

        # Enable and start Docker
        systemctl enable docker
        systemctl start docker

        DOCKER_INSTALLED=true
        log_success "Docker installed and running"
    else
        DOCKER_INSTALLED=false
        log_info "Skipping Docker installation"
    fi
}

#####################################################
# SUMMARY AND FINAL
#####################################################
print_summary() {
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║            INSTALLATION COMPLETE!                 ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BLUE}Active Protections:${NC}"
    echo "  [+] UFW Firewall"
    echo "  [+] fail2ban (SSH protection)"
    echo "  [+] Automatic security updates"
    echo "  [+] Kernel hardening (sysctl)"
    echo "  [+] SSH brute-force slowdown"
    if [[ "$DOCKER_INSTALLED" == "true" ]]; then
        echo "  [+] Docker"
    fi
    echo ""
    echo -e "${YELLOW}Check Commands:${NC}"
    echo "  ufw status              - Firewall status"
    echo "  fail2ban-client status  - fail2ban status"
    echo "  fail2ban-client status sshd - SSH jail status"
    if [[ "$DOCKER_INSTALLED" == "true" ]]; then
        echo "  docker --version        - Docker version"
    fi
    echo ""
    echo -e "${YELLOW}Useful Commands:${NC}"
    echo "  fail2ban-client set sshd unbanip <IP>  - Unban an IP"
    echo "  ufw allow <port>/tcp    - Open a new port"
    echo "  ufw delete allow <port> - Close a port"
    echo ""
    log_warning "Your current SSH session will remain active!"
    echo ""
}

#####################################################
# MAIN FUNCTION
#####################################################
main() {
    print_banner
    check_root
    check_os

    echo ""
    log_warning "This script will make the following changes:"
    echo "  - System update"
    echo "  - UFW Firewall installation and activation"
    echo "  - fail2ban installation"
    echo "  - SSH hardening (minimal - root login unchanged)"
    echo "  - Automatic security updates"
    echo "  - Kernel security settings"
    echo "  - Docker (optional)"
    echo ""

    ask "Do you want to continue? [Y/n]: " CONFIRM
    CONFIRM=${CONFIRM:-y}
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        log_info "Cancelled."
        exit 0
    fi

    echo ""
    update_system
    echo ""
    setup_ufw
    echo ""
    setup_fail2ban
    echo ""
    setup_ssh_hardening
    echo ""
    setup_auto_updates
    echo ""
    setup_sysctl_hardening
    setup_docker
    echo ""
    print_summary
}

# Run script
main "$@"
