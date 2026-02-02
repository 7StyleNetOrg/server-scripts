#!/bin/bash
#
# Docker Cleanup Script
# Automatic cleanup with Slack reporting
#

set -e

# ═══════════════════════════════════════════════════════════════
# CONFIG
# ═══════════════════════════════════════════════════════════════
CONFIG_FILE="/etc/docker-cleanup.conf"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ═══════════════════════════════════════════════════════════════
# SETUP WIZARD
# ═══════════════════════════════════════════════════════════════

print_banner() {
    echo -e "${GREEN}"
    echo "╔═══════════════════════════════════════════════════╗"
    echo "║       DOCKER CLEANUP SCRIPT v1.0                  ║"
    echo "║       Automatic Cleanup with Slack Reports        ║"
    echo "╚═══════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

run_setup() {
    print_banner
    echo -e "${YELLOW}First time setup - please configure the following:${NC}"
    echo ""

    # Server name
    read -p "Server name (e.g., PROD-01): " INPUT_SERVER_NAME
    if [[ -z "$INPUT_SERVER_NAME" ]]; then
        INPUT_SERVER_NAME="$(hostname)"
        echo -e "${BLUE}Using hostname: ${INPUT_SERVER_NAME}${NC}"
    fi

    # Slack webhook
    echo ""
    echo -e "${BLUE}To get a Slack Webhook URL:${NC}"
    echo "  1. Go to https://api.slack.com/apps"
    echo "  2. Create/select an app → Incoming Webhooks → Add New Webhook"
    echo "  3. Copy the webhook URL"
    echo ""
    read -p "Slack Webhook URL (or press Enter to skip): " INPUT_SLACK_WEBHOOK

    # Disk threshold
    echo ""
    read -p "Disk usage warning threshold % [default: 80]: " INPUT_DISK_THRESHOLD
    INPUT_DISK_THRESHOLD=${INPUT_DISK_THRESHOLD:-80}

    # Enable prune
    echo ""
    read -p "Enable automatic docker prune? [Y/n]: " INPUT_ENABLE_PRUNE
    INPUT_ENABLE_PRUNE=${INPUT_ENABLE_PRUNE:-y}
    if [[ "$INPUT_ENABLE_PRUNE" =~ ^[Yy]$ ]]; then
        INPUT_ENABLE_PRUNE="true"
    else
        INPUT_ENABLE_PRUNE="false"
    fi

    # Save config
    echo ""
    echo -e "${BLUE}Saving configuration to ${CONFIG_FILE}...${NC}"

    cat > "$CONFIG_FILE" << EOF
# Docker Cleanup Configuration
# Generated on $(date '+%Y-%m-%d %H:%M:%S')

SLACK_WEBHOOK="${INPUT_SLACK_WEBHOOK}"
SERVER_NAME="${INPUT_SERVER_NAME}"
DISK_THRESHOLD=${INPUT_DISK_THRESHOLD}
ENABLE_PRUNE=${INPUT_ENABLE_PRUNE}
EOF

    chmod 600 "$CONFIG_FILE"
    echo -e "${GREEN}✅ Configuration saved!${NC}"
    echo ""

    # Ask to run now
    read -p "Run cleanup now? [Y/n]: " RUN_NOW
    RUN_NOW=${RUN_NOW:-y}
    if [[ ! "$RUN_NOW" =~ ^[Yy]$ ]]; then
        echo ""
        echo -e "${GREEN}Setup complete. Run the script again to perform cleanup.${NC}"
        exit 0
    fi
    echo ""
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        return 0
    fi
    return 1
}

show_help() {
    print_banner
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --setup      Run setup wizard (reconfigure settings)"
    echo "  --help       Show this help message"
    echo ""
    echo "Config file: $CONFIG_FILE"
    echo ""
    exit 0
}

# Parse arguments
case "${1:-}" in
    --setup|--reconfigure)
        run_setup
        load_config
        ;;
    --help|-h)
        show_help
        ;;
    *)
        # Check if config exists, if not run setup
        if ! load_config; then
            # Check if running interactively
            if [[ -t 0 ]]; then
                run_setup
                load_config
            else
                echo "ERROR: Config file not found: $CONFIG_FILE"
                echo "Run this script interactively first to configure."
                exit 1
            fi
        fi
        ;;
esac

# Validate required settings
if [[ -z "$SERVER_NAME" ]]; then
    SERVER_NAME="$(hostname)"
fi
DISK_THRESHOLD=${DISK_THRESHOLD:-80}
ENABLE_PRUNE=${ENABLE_PRUNE:-true}

# ═══════════════════════════════════════════════════════════════
# FUNCTIONS
# ═══════════════════════════════════════════════════════════════

get_disk_usage() {
    local disk_info=$(df -h / | tail -1)
    DISK_TOTAL=$(echo "$disk_info" | awk '{print $2}')
    DISK_USED=$(echo "$disk_info" | awk '{print $3}')
    DISK_AVAIL=$(echo "$disk_info" | awk '{print $4}')
    DISK_PERCENT=$(echo "$disk_info" | awk '{print $5}' | tr -d '%')
}

get_docker_stats() {
    DOCKER_IMAGES=$(docker images -q 2>/dev/null | wc -l)
    DOCKER_CONTAINERS=$(docker ps -aq 2>/dev/null | wc -l)
    DOCKER_VOLUMES=$(docker volume ls -q 2>/dev/null | wc -l)
}

get_system_stats() {
    CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
    RAM_INFO=$(free -h | grep Mem)
    RAM_TOTAL=$(echo "$RAM_INFO" | awk '{print $2}')
    RAM_USED=$(echo "$RAM_INFO" | awk '{print $3}')
    RAM_PERCENT=$(free | grep Mem | awk '{printf "%.0f", $3/$2 * 100}')
}

# Auto-register to cron if not already registered
setup_cron() {
    local SCRIPT_PATH=$(readlink -f "$0")
    local CRON_CMD="0 3 * * * ${SCRIPT_PATH} >> /var/log/docker-cleanup.log 2>&1"

    # Check if already in cron
    if crontab -l 2>/dev/null | grep -q "docker-cleanup.sh"; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cron job already exists."
        CRON_STATUS="✅ Registered"
    else
        # Add to cron
        (crontab -l 2>/dev/null; echo "$CRON_CMD") | crontab -
        if [ $? -eq 0 ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cron job added (daily at 03:00)."
            CRON_STATUS="✅ Just added"
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Failed to add cron job!"
            CRON_STATUS="❌ Failed to add"
        fi
    fi
}

# Check security packages from server-hardening.sh
check_security() {
    SECURITY_WARNINGS=""
    SECURITY_STATUS=""

    # UFW Check
    if command -v ufw &> /dev/null; then
        UFW_STATUS=$(ufw status 2>/dev/null | head -1)
        if [[ "$UFW_STATUS" == *"active"* ]]; then
            SECURITY_STATUS="${SECURITY_STATUS}UFW         ✅ Active\n"
        else
            SECURITY_STATUS="${SECURITY_STATUS}UFW         ⚠️  Inactive\n"
            SECURITY_WARNINGS="${SECURITY_WARNINGS}⚠️ UFW firewall is not active\n"
        fi
    else
        SECURITY_STATUS="${SECURITY_STATUS}UFW         ❌ Not installed\n"
        SECURITY_WARNINGS="${SECURITY_WARNINGS}❌ UFW is not installed\n"
    fi

    # fail2ban Check
    if command -v fail2ban-client &> /dev/null; then
        if systemctl is-active --quiet fail2ban 2>/dev/null; then
            F2B_JAILS=$(fail2ban-client status 2>/dev/null | grep "Number of jail" | awk '{print $NF}')
            SECURITY_STATUS="${SECURITY_STATUS}fail2ban    ✅ Running (${F2B_JAILS} jails)\n"
        else
            SECURITY_STATUS="${SECURITY_STATUS}fail2ban    ⚠️  Stopped\n"
            SECURITY_WARNINGS="${SECURITY_WARNINGS}⚠️ fail2ban is not running\n"
        fi
    else
        SECURITY_STATUS="${SECURITY_STATUS}fail2ban    ❌ Not installed\n"
        SECURITY_WARNINGS="${SECURITY_WARNINGS}❌ fail2ban is not installed\n"
    fi

    # unattended-upgrades Check
    if dpkg -l | grep -q "unattended-upgrades"; then
        if systemctl is-active --quiet unattended-upgrades 2>/dev/null; then
            SECURITY_STATUS="${SECURITY_STATUS}AutoUpdate  ✅ Enabled\n"
        else
            SECURITY_STATUS="${SECURITY_STATUS}AutoUpdate  ⚠️  Disabled\n"
            SECURITY_WARNINGS="${SECURITY_WARNINGS}⚠️ Auto-updates service is not running\n"
        fi
    else
        SECURITY_STATUS="${SECURITY_STATUS}AutoUpdate  ❌ Not installed\n"
        SECURITY_WARNINGS="${SECURITY_WARNINGS}❌ unattended-upgrades is not installed\n"
    fi

    # Sysctl hardening Check
    if [ -f "/etc/sysctl.d/99-security.conf" ]; then
        SECURITY_STATUS="${SECURITY_STATUS}Sysctl      ✅ Hardened\n"
    else
        SECURITY_STATUS="${SECURITY_STATUS}Sysctl      ⚠️  Default\n"
        SECURITY_WARNINGS="${SECURITY_WARNINGS}⚠️ Kernel hardening not applied\n"
    fi

    # Docker Check
    if command -v docker &> /dev/null; then
        if systemctl is-active --quiet docker 2>/dev/null; then
            SECURITY_STATUS="${SECURITY_STATUS}Docker      ✅ Running"
        else
            SECURITY_STATUS="${SECURITY_STATUS}Docker      ⚠️  Stopped"
            SECURITY_WARNINGS="${SECURITY_WARNINGS}⚠️ Docker service is not running\n"
        fi
    else
        SECURITY_STATUS="${SECURITY_STATUS}Docker      ❌ Not installed"
        SECURITY_WARNINGS="${SECURITY_WARNINGS}❌ Docker is not installed\n"
    fi
}

run_prune() {
    if [ "$ENABLE_PRUNE" = true ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting docker prune..."
        REMOVED_CONTAINERS=$(docker container prune -f 2>/dev/null | grep -oP 'Total reclaimed space: \K.*' || echo "0B")
        REMOVED_IMAGES=$(docker image prune -af 2>/dev/null | grep -oP 'Total reclaimed space: \K.*' || echo "0B")
        REMOVED_VOLUMES=$(docker volume prune -f 2>/dev/null | grep -oP 'Total reclaimed space: \K.*' || echo "0B")
        REMOVED_CACHE=$(docker builder prune -af 2>/dev/null | grep -oP 'Total reclaimed space: \K.*' || echo "0B")
        docker network prune -f 2>/dev/null
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Docker prune completed."
        PRUNE_STATUS="Done"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ENABLE_PRUNE=false, skipped."
        REMOVED_CONTAINERS="0B"
        REMOVED_IMAGES="0B"
        REMOVED_VOLUMES="0B"
        REMOVED_CACHE="0B"
        PRUNE_STATUS="Disabled"
    fi
}

send_slack() {
    # Skip if webhook not configured
    if [[ -z "$SLACK_WEBHOOK" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Slack webhook not configured, skipping notification."
        return 0
    fi

    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Disk status emoji
    local disk_emoji="✅"
    if [ "$DISK_PERCENT_AFTER" -ge "$DISK_THRESHOLD" ]; then
        disk_emoji="🚨"
    elif [ "$DISK_PERCENT_AFTER" -ge $((DISK_THRESHOLD - 10)) ]; then
        disk_emoji="⚠️"
    fi

    # Build warnings section if any
    local warnings_block=""
    if [ -n "$SECURITY_WARNINGS" ]; then
        warnings_block=",
        {
            \"type\": \"section\",
            \"text\": {
                \"type\": \"mrkdwn\",
                \"text\": \"*🚨 WARNINGS*\n${SECURITY_WARNINGS}\"
            }
        }"
    fi

    # Compact table format
    local payload=$(cat <<EOF
{
    "blocks": [
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": "*🐳 Docker Cleanup Report*\n\`${SERVER_NAME}\` • ${timestamp}"
            }
        },
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": "\`\`\`${disk_emoji} DISK          Before    After
────────────────────────────────
Usage         ${DISK_PERCENT_BEFORE}%        ${DISK_PERCENT_AFTER}%
Used          ${DISK_USED_BEFORE}       ${DISK_USED_AFTER}
Free          ${DISK_AVAIL_BEFORE}       ${DISK_AVAIL_AFTER}

🧹 CLEANED
────────────────────────────────
Containers    ${REMOVED_CONTAINERS}
Images        ${REMOVED_IMAGES}
Volumes       ${REMOVED_VOLUMES}
Cache         ${REMOVED_CACHE}

📊 DOCKER       Before    After
────────────────────────────────
Images        ${DOCKER_IMAGES_BEFORE}         ${DOCKER_IMAGES_AFTER}
Containers    ${DOCKER_CONTAINERS_BEFORE}         ${DOCKER_CONTAINERS_AFTER}
Volumes       ${DOCKER_VOLUMES_BEFORE}         ${DOCKER_VOLUMES_AFTER}

💻 SYSTEM
────────────────────────────────
CPU           ${CPU_USAGE}%
RAM           ${RAM_USED}/${RAM_TOTAL} (${RAM_PERCENT}%)

🛡️ SECURITY
────────────────────────────────
${SECURITY_STATUS}

⏰ CRON        ${CRON_STATUS}\`\`\`"
            }
        }${warnings_block}
    ]
}
EOF
)

    curl -s -X POST \
        -H 'Content-type: application/json' \
        --data "$payload" \
        "$SLACK_WEBHOOK" > /dev/null 2>&1

    if [ $? -eq 0 ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Slack message sent."
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Failed to send Slack message!"
    fi
}

# ═══════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════

echo "=============================================="
echo "Docker Cleanup Script Started"
echo "Server: $SERVER_NAME"
echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================="

# 1. Get before metrics
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Collecting before metrics..."
get_disk_usage
DISK_TOTAL_BEFORE=$DISK_TOTAL
DISK_USED_BEFORE=$DISK_USED
DISK_AVAIL_BEFORE=$DISK_AVAIL
DISK_PERCENT_BEFORE=$DISK_PERCENT

get_docker_stats
DOCKER_IMAGES_BEFORE=$DOCKER_IMAGES
DOCKER_CONTAINERS_BEFORE=$DOCKER_CONTAINERS
DOCKER_VOLUMES_BEFORE=$DOCKER_VOLUMES

# 2. Run prune
run_prune

# 3. Get after metrics
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Collecting after metrics..."
get_disk_usage
DISK_TOTAL_AFTER=$DISK_TOTAL
DISK_USED_AFTER=$DISK_USED
DISK_AVAIL_AFTER=$DISK_AVAIL
DISK_PERCENT_AFTER=$DISK_PERCENT

get_docker_stats
DOCKER_IMAGES_AFTER=$DOCKER_IMAGES
DOCKER_CONTAINERS_AFTER=$DOCKER_CONTAINERS
DOCKER_VOLUMES_AFTER=$DOCKER_VOLUMES

get_system_stats

# 4. Check security
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Checking security status..."
check_security

# 5. Setup cron (auto-register)
setup_cron

# 6. Summary
echo ""
echo "=== SUMMARY ==="
echo "Disk: ${DISK_PERCENT_BEFORE}% -> ${DISK_PERCENT_AFTER}%"
echo "Images: ${DOCKER_IMAGES_BEFORE} -> ${DOCKER_IMAGES_AFTER}"
echo "Containers: ${DOCKER_CONTAINERS_BEFORE} -> ${DOCKER_CONTAINERS_AFTER}"
echo "Volumes: ${DOCKER_VOLUMES_BEFORE} -> ${DOCKER_VOLUMES_AFTER}"
echo ""

# 7. Send to Slack
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Sending report to Slack..."
send_slack

echo ""
echo "=============================================="
echo "Docker Cleanup Script Completed"
echo "=============================================="
