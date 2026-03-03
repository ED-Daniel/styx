#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed. Please install Docker first."
        echo "  curl -fsSL https://get.docker.com | sh"
        exit 1
    fi

    if ! docker compose version &> /dev/null; then
        log_error "Docker Compose V2 is not available. Please install Docker Compose plugin."
        exit 1
    fi

    log_info "Docker and Docker Compose are available."
}

# Generate UUID using xray or fallback
generate_uuid() {
    if docker image inspect ghcr.io/xtls/xray-core:latest &> /dev/null; then
        docker run --rm ghcr.io/xtls/xray-core:latest uuid
    else
        log_info "Pulling XRay image for key generation..."
        docker pull ghcr.io/xtls/xray-core:latest
        docker run --rm ghcr.io/xtls/xray-core:latest uuid
    fi
}

# Generate Reality x25519 keypair
# Handles both old format ("Private key: X" / "Public key: X")
# and new format ("PrivateKey: X") where public key must be derived via -i flag
generate_reality_keys() {
    local keys_output private_key public_key
    keys_output=$(docker run --rm ghcr.io/xtls/xray-core:latest x25519)

    private_key=$(echo "$keys_output" | grep -iE "^private.?key:" | awk '{print $NF}')
    public_key=$(echo "$keys_output" | grep -iE "^public.?key:" | awk '{print $NF}')

    if [[ -z "$public_key" ]] && [[ -n "$private_key" ]]; then
        local derived
        derived=$(docker run --rm ghcr.io/xtls/xray-core:latest x25519 -i "$private_key")
        public_key=$(echo "$derived" | grep -iE "^public.?key:" | awk '{print $NF}')
        if [[ -z "$public_key" ]]; then
            public_key=$(echo "$derived" | grep -iE "^password:" | awk '{print $NF}')
        fi
    fi

    echo "Private key: $private_key"
    echo "Public key: $public_key"
}

main() {
    echo ""
    echo "======================================"
    echo "  Styx VPN Setup"
    echo "======================================"
    echo ""

    check_prerequisites

    # Check if .env already exists
    if [[ -f "$PROJECT_DIR/.env" ]]; then
        log_warn ".env file already exists."
        read -rp "Overwrite? (y/N): " overwrite
        if [[ "$overwrite" != "y" && "$overwrite" != "Y" ]]; then
            log_info "Keeping existing .env file."
            exit 0
        fi
    fi

    log_info "Generating VLESS UUID..."
    XRAY_UUID=$(generate_uuid)
    log_info "UUID: $XRAY_UUID"

    log_info "Generating Reality x25519 keypair..."
    KEYS_OUTPUT=$(generate_reality_keys)
    PRIVATE_KEY=$(echo "$KEYS_OUTPUT" | grep "Private key:" | awk '{print $3}')
    PUBLIC_KEY=$(echo "$KEYS_OUTPUT" | grep "Public key:" | awk '{print $3}')
    log_info "Private key: $PRIVATE_KEY"
    log_info "Public key:  $PUBLIC_KEY"

    # Generate short ID (8 hex chars)
    SHORT_ID=$(openssl rand -hex 4)
    log_info "Short ID: $SHORT_ID"

    # Ask for server IP
    read -rp "Enter your server's public IP address: " SERVER_IP
    if [[ -z "$SERVER_IP" ]]; then
        log_error "Server IP is required."
        exit 1
    fi

    # Ask for bridge IP
    read -rp "Enter bridge server IP (or press Enter to skip): " BRIDGE_IP

    # Ask for Telegram settings
    read -rp "Enter Telegram Bot Token (or press Enter to skip): " TG_BOT_TOKEN
    read -rp "Enter Telegram Chat ID (or press Enter to skip): " TG_CHAT_ID

    # Ask for Grafana password
    read -rp "Enter Grafana admin password [admin]: " GF_PASSWORD
    GF_PASSWORD=${GF_PASSWORD:-admin}

    # Create .env
    cat > "$PROJECT_DIR/.env" << EOF
# === XRay ===
XRAY_PORT=443
XRAY_UUID=${XRAY_UUID}
XRAY_REALITY_PRIVATE_KEY=${PRIVATE_KEY}
XRAY_REALITY_PUBLIC_KEY=${PUBLIC_KEY}
XRAY_REALITY_SHORT_ID=${SHORT_ID}
XRAY_REALITY_DEST=www.google.com:443
XRAY_REALITY_SNI=www.google.com

# === Grafana ===
GRAFANA_PORT=3000
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=${GF_PASSWORD}

# === Bridge ===
BRIDGE_IP=${BRIDGE_IP}

# === Telegram Alerts ===
TELEGRAM_BOT_TOKEN=${TG_BOT_TOKEN}
TELEGRAM_CHAT_ID=${TG_CHAT_ID}

# === Server ===
SERVER_IP=${SERVER_IP}
SERVER_NAME=styx
EOF

    log_info ".env file created successfully."

    # Generate xray config with actual values
    log_info "Updating XRay config with generated values..."
    sed -i.bak \
        -e "s/\${XRAY_UUID}/${XRAY_UUID}/g" \
        -e "s/\${XRAY_REALITY_PRIVATE_KEY}/${PRIVATE_KEY}/g" \
        -e "s/\${XRAY_REALITY_SHORT_ID}/${SHORT_ID}/g" \
        -e "s/\${XRAY_REALITY_DEST}/www.google.com:443/g" \
        -e "s/\${XRAY_REALITY_SNI}/www.google.com/g" \
        "$PROJECT_DIR/xray/config.json"
    rm -f "$PROJECT_DIR/xray/config.json.bak"

    if [[ -n "$BRIDGE_IP" ]]; then
        log_info "Updating bridge client config..."
        sed -i.bak \
            -e "s/\${BRIDGE_IP}/${BRIDGE_IP}/g" \
            -e "s/\${XRAY_UUID}/${XRAY_UUID}/g" \
            -e "s/\${XRAY_REALITY_PUBLIC_KEY}/${PUBLIC_KEY}/g" \
            -e "s/\${XRAY_REALITY_SHORT_ID}/${SHORT_ID}/g" \
            -e "s/\${XRAY_REALITY_SNI}/www.google.com/g" \
            "$PROJECT_DIR/xray/bridge-client.json"
        rm -f "$PROJECT_DIR/xray/bridge-client.json.bak"
    fi

    # Update alertmanager config with Telegram token
    if [[ -n "$TG_BOT_TOKEN" ]]; then
        sed -i.bak \
            -e "s/\${TELEGRAM_BOT_TOKEN}/${TG_BOT_TOKEN}/g" \
            "$PROJECT_DIR/alertmanager/alertmanager.yml"
        rm -f "$PROJECT_DIR/alertmanager/alertmanager.yml.bak"
    fi

    echo ""
    echo "======================================"
    echo "  Styx Setup Complete!"
    echo "======================================"
    echo ""
    log_info "To start Styx:"
    echo "  cd $PROJECT_DIR"
    echo "  docker compose up -d"
    echo ""
    log_info "Your VLESS connection URI:"
    echo ""
    echo "  vless://${XRAY_UUID}@${SERVER_IP}:443?type=tcp&security=reality&fp=chrome&pbk=${PUBLIC_KEY}&sni=www.google.com&sid=${SHORT_ID}&flow=xtls-rprx-vision#styx-default"
    echo ""
    log_info "Grafana will be available at: http://${SERVER_IP}:3000"
    echo ""
}

main "$@"
