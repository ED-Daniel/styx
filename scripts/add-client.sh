#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [[ ! -f "$ENV_FILE" ]]; then
    log_error ".env file not found. Run setup.sh first."
    exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

# Get client name
CLIENT_NAME="${1:-}"
if [[ -z "$CLIENT_NAME" ]]; then
    read -rp "Enter client name: " CLIENT_NAME
    if [[ -z "$CLIENT_NAME" ]]; then
        log_error "Client name is required."
        exit 1
    fi
fi

# Sanitize client name for URI
CLIENT_NAME_SAFE=$(echo "$CLIENT_NAME" | tr ' ' '-' | tr -cd '[:alnum:]-_')

# Generate new UUID
log_info "Generating UUID for client '$CLIENT_NAME'..."
NEW_UUID=$(docker run --rm ghcr.io/xtls/xray-core:latest uuid)
log_info "UUID: $NEW_UUID"

# Read values from .env
SERVER_IP="${SERVER_IP:?SERVER_IP not set in .env}"
PUBLIC_KEY="${XRAY_REALITY_PUBLIC_KEY:?XRAY_REALITY_PUBLIC_KEY not set in .env}"
SHORT_ID="${XRAY_REALITY_SHORT_ID:?XRAY_REALITY_SHORT_ID not set in .env}"
SNI="${XRAY_REALITY_SNI:-www.google.com}"
PORT="${XRAY_PORT:-443}"

# Build VLESS URI
VLESS_URI="vless://${NEW_UUID}@${SERVER_IP}:${PORT}?type=tcp&security=reality&fp=chrome&pbk=${PUBLIC_KEY}&sni=${SNI}&sid=${SHORT_ID}&flow=xtls-rprx-vision#${CLIENT_NAME_SAFE}"

echo ""
echo "======================================"
echo "  New Client: $CLIENT_NAME"
echo "======================================"
echo ""
echo "UUID: $NEW_UUID"
echo "Email: ${CLIENT_NAME_SAFE}@styx"
echo ""
echo "VLESS URI (copy to client app):"
echo ""
echo "  $VLESS_URI"
echo ""
echo "--------------------------------------"
echo ""
log_info "To activate this client, add the following to xray/config.json"
log_info "in the 'clients' array of the vless-reality inbound:"
echo ""
echo "  {"
echo "    \"id\": \"${NEW_UUID}\","
echo "    \"email\": \"${CLIENT_NAME_SAFE}@styx\","
echo "    \"flow\": \"xtls-rprx-vision\""
echo "  }"
echo ""
log_info "Then restart Styx: docker compose restart xray"
echo ""
