#!/bin/bash
#
# SSL Domain Manager
# Nginx + Let's Encrypt automatic domain setup
#

set -e

# ═══════════════════════════════════════════════════════════════
# SETTINGS
# ═══════════════════════════════════════════════════════════════
WEB_ROOT="/var/www"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ═══════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════════

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

print_banner() {
    echo -e "${GREEN}"
    echo "╔═══════════════════════════════════════════════════╗"
    echo "║       SSL DOMAIN MANAGER v1.0                     ║"
    echo "║       Nginx + Let's Encrypt Setup                 ║"
    echo "╚═══════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ═══════════════════════════════════════════════════════════════
# MAIN FUNCTIONS
# ═══════════════════════════════════════════════════════════════

# Check and install nginx + certbot
check_dependencies() {
    log_info "Checking dependencies..."

    # Check root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root!"
        exit 1
    fi

    # Check nginx
    if ! command -v nginx &> /dev/null; then
        log_warning "Nginx not found. Installing..."
        apt update -y
        apt install -y nginx
        systemctl enable nginx
        systemctl start nginx
        log_success "Nginx installed"
    else
        log_success "Nginx is installed"
    fi

    # Make sure nginx is running
    if ! systemctl is-active --quiet nginx; then
        log_warning "Nginx is not running. Starting..."
        systemctl start nginx
    fi

    # Check certbot
    if ! command -v certbot &> /dev/null; then
        log_warning "Certbot not found. Installing..."
        apt install -y certbot python3-certbot-nginx
        log_success "Certbot installed"
    else
        log_success "Certbot is installed"
    fi
}

# Get email from user
get_email() {
    echo ""
    read -p "Enter email for Let's Encrypt notifications: " SSL_EMAIL
    if [[ -z "$SSL_EMAIL" ]]; then
        log_error "Email is required for Let's Encrypt!"
        exit 1
    fi
    # Basic email validation
    if [[ ! "$SSL_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        log_error "Invalid email format!"
        exit 1
    fi
}

# Create nginx configuration
create_nginx_conf() {
    local domain=$1
    local conf_file="/etc/nginx/sites-available/${domain}.conf"
    local enabled_link="/etc/nginx/sites-enabled/${domain}.conf"
    local web_dir="${WEB_ROOT}/${domain}"

    log_info "Setting up nginx for ${domain}..."

    # Check if conf already exists
    if [ -f "$conf_file" ]; then
        echo ""
        read -p "Config for ${domain} already exists. Override? [y/N]: " OVERRIDE
        if [[ ! "$OVERRIDE" =~ ^[Yy]$ ]]; then
            log_info "Keeping existing configuration"
            return 0
        fi
        log_warning "Overriding existing configuration..."
    fi

    # Create web directory
    if [ ! -d "$web_dir" ]; then
        mkdir -p "$web_dir"
        # Create default index.html
        cat > "${web_dir}/index.html" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Welcome to ${domain}</title>
</head>
<body>
    <h1>${domain} is working!</h1>
    <p>SSL will be configured shortly.</p>
</body>
</html>
EOF
        chown -R www-data:www-data "$web_dir"
        log_success "Created web directory: ${web_dir}"
    fi

    # Create nginx config (HTTP only, certbot will add SSL)
    cat > "$conf_file" << EOF
server {
    listen 80;
    listen [::]:80;

    server_name ${domain};
    root ${web_dir};

    index index.html index.htm index.php;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # PHP support (if php-fpm is installed)
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
}
EOF

    log_success "Created nginx config: ${conf_file}"

    # Enable site
    if [ ! -L "$enabled_link" ]; then
        ln -s "$conf_file" "$enabled_link"
        log_success "Enabled site: ${domain}"
    fi

    # Test nginx config
    if nginx -t 2>/dev/null; then
        systemctl reload nginx
        log_success "Nginx reloaded successfully"
    else
        log_error "Nginx configuration test failed!"
        rm -f "$enabled_link"
        exit 1
    fi
}

# Setup SSL with Let's Encrypt
setup_ssl() {
    local domain=$1

    log_info "Obtaining SSL certificate for ${domain}..."

    # Run certbot
    if certbot --nginx -d "$domain" \
        --non-interactive \
        --agree-tos \
        --email "$SSL_EMAIL" \
        --redirect; then
        log_success "SSL certificate obtained for ${domain}"
        return 0
    else
        log_error "Failed to obtain SSL certificate!"
        log_warning "Make sure:"
        echo "  - Domain DNS points to this server"
        echo "  - Port 80 and 443 are open"
        echo "  - Domain is accessible from internet"
        return 1
    fi
}

# Setup cron for SSL renewal
setup_cron() {
    log_info "Setting up SSL renewal cron..."

    local CRON_CMD="0 0,12 * * * certbot renew --quiet --post-hook \"systemctl reload nginx\""

    if crontab -l 2>/dev/null | grep -q "certbot renew"; then
        log_success "SSL renewal cron already exists"
        CRON_STATUS="Already registered"
    else
        (crontab -l 2>/dev/null; echo "$CRON_CMD") | crontab -
        if [ $? -eq 0 ]; then
            log_success "SSL renewal cron added (runs at 00:00 and 12:00)"
            CRON_STATUS="Just added"
        else
            log_error "Failed to add cron job!"
            CRON_STATUS="Failed"
        fi
    fi
}

# Print summary
print_summary() {
    local domain=$1
    local conf_file="/etc/nginx/sites-available/${domain}.conf"
    local web_dir="${WEB_ROOT}/${domain}"
    local cert_path="/etc/letsencrypt/live/${domain}/fullchain.pem"
    local key_path="/etc/letsencrypt/live/${domain}/privkey.pem"

    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  ✅ Domain setup completed: ${domain}${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BLUE}Nginx conf${NC}  : ${conf_file}"
    echo -e "  ${BLUE}Web root${NC}    : ${web_dir}"

    if [ -f "$cert_path" ]; then
        echo -e "  ${BLUE}SSL Cert${NC}    : ${cert_path}"
        echo -e "  ${BLUE}SSL Key${NC}     : ${key_path}"

        # Get expiry date
        local expiry=$(openssl x509 -enddate -noout -in "$cert_path" 2>/dev/null | cut -d= -f2)
        echo -e "  ${BLUE}Expires${NC}     : ${expiry}"
    fi

    echo -e "  ${BLUE}Renewal${NC}     : Cron (0 0,12 * * *) - ${CRON_STATUS}"
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${YELLOW}Test your site:${NC} https://${domain}"
    echo ""
}

# ═══════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════

main() {
    print_banner

    # Check arguments
    if [ $# -eq 0 ]; then
        echo "Usage: $0 <domain> [domain2] [domain3] ..."
        echo ""
        echo "Examples:"
        echo "  $0 example.com"
        echo "  $0 example.com www.example.com"
        exit 1
    fi

    # Get primary domain (first argument)
    PRIMARY_DOMAIN=$1

    # Check dependencies
    check_dependencies

    # Get email
    get_email

    # Process each domain
    for domain in "$@"; do
        echo ""
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${BLUE}  Processing: ${domain}${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

        # Create nginx config
        create_nginx_conf "$domain"

        # Setup SSL
        setup_ssl "$domain"
    done

    # Setup renewal cron (once for all domains)
    echo ""
    setup_cron

    # Print summary for primary domain
    print_summary "$PRIMARY_DOMAIN"
}

# Run
main "$@"
