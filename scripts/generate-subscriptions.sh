#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"
SUB_DIR="$PROJECT_DIR/subscriptions"
OUT_DIR="${SUB_OUTPUT_DIR:-/var/www/styx-sub}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [[ ! -f "$ENV_FILE" ]]; then
    log_error ".env file not found. Run setup.sh first."
    exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

SERVER_IP="${SERVER_IP:?SERVER_IP not set in .env}"
PUBLIC_KEY="${XRAY_REALITY_PUBLIC_KEY:?XRAY_REALITY_PUBLIC_KEY not set in .env}"
SHORT_ID="${XRAY_REALITY_SHORT_ID:?XRAY_REALITY_SHORT_ID not set in .env}"
SNI="${XRAY_REALITY_SNI:-www.google.com}"
PORT="${XRAY_PORT:-443}"
BRIDGE_IP="${BRIDGE_IP:-}"

# Hysteria2 settings (optional)
HY2_DOMAIN="${HY2_DOMAIN:-}"
HY2_PASSWORD="${HY2_PASSWORD:-}"
HY2_OBFS_PASSWORD="${HY2_OBFS_PASSWORD:-}"
HY2_PORT="${HY2_PORT:-443}"
HY2_PORT_HOPPING="${HY2_PORT_HOPPING:-}"
HY2_SHA256_PIN="${HY2_SHA256_PIN:-}"

ROUTING_HAPP="${1:-$SUB_DIR/routing-happ.json}"
ROUTING_V2RAYTUN="${2:-$SUB_DIR/routing-v2raytun.json}"

mkdir -p "$OUT_DIR"

URI_LINES=""

if [[ -n "$BRIDGE_IP" ]]; then
    URI_LINES+="vless://${XRAY_UUID}@${BRIDGE_IP}:${PORT}?type=tcp&security=reality&fp=chrome&pbk=${PUBLIC_KEY}&sni=${SNI}&sid=${SHORT_ID}&flow=xtls-rprx-vision#CHARON"
    URI_LINES+=$'\n'
fi

URI_LINES+="vless://${XRAY_UUID}@${SERVER_IP}:${PORT}?type=tcp&security=reality&fp=chrome&pbk=${PUBLIC_KEY}&sni=${SNI}&sid=${SHORT_ID}&flow=xtls-rprx-vision#STYX"

# Add Hysteria2 URI if configured
if [[ -n "$HY2_DOMAIN" && -n "$HY2_PASSWORD" ]]; then
    HY2_URI="hy2://${HY2_PASSWORD}@${HY2_DOMAIN}"

    if [[ -n "$HY2_PORT_HOPPING" ]]; then
        HY2_URI+=":${HY2_PORT_HOPPING}"
    else
        HY2_URI+=":${HY2_PORT}"
    fi

    HY2_PARAMS="sni=${HY2_DOMAIN}"

    if [[ -n "$HY2_OBFS_PASSWORD" ]]; then
        HY2_PARAMS+="&obfs=salamander&obfs-password=${HY2_OBFS_PASSWORD}"
    fi

    if [[ -n "$HY2_SHA256_PIN" ]]; then
        HY2_PARAMS+="&insecure=1&pinSHA256=${HY2_SHA256_PIN}"
    fi

    HY2_URI+="?${HY2_PARAMS}#STYX-HY2"

    URI_LINES+=$'\n'
    URI_LINES+="$HY2_URI"
    log_info "Hysteria2 URI added to subscriptions"
fi

# --- Happ subscription (/sub) ---
if [[ -f "$ROUTING_HAPP" ]]; then
    ROUTING_B64=$(base64 -w 0 < "$ROUTING_HAPP" 2>/dev/null || base64 -i "$ROUTING_HAPP")
    DEEPLINK="happ://routing/onadd/${ROUTING_B64}"
    printf "%s\n%s" "$DEEPLINK" "$URI_LINES" | base64 -w 0 > "$OUT_DIR/sub" 2>/dev/null || \
    printf "%s\n%s" "$DEEPLINK" "$URI_LINES" | base64 > "$OUT_DIR/sub"
    log_info "Happ subscription written to $OUT_DIR/sub"
else
    printf "%s" "$URI_LINES" | base64 -w 0 > "$OUT_DIR/sub" 2>/dev/null || \
    printf "%s" "$URI_LINES" | base64 > "$OUT_DIR/sub"
    log_info "Happ subscription written to $OUT_DIR/sub (no routing — $ROUTING_HAPP not found)"
fi

# --- v2RayTun subscription (/v2sub) ---
printf "%s" "$URI_LINES" | base64 -w 0 > "$OUT_DIR/v2sub" 2>/dev/null || \
printf "%s" "$URI_LINES" | base64 > "$OUT_DIR/v2sub"
log_info "v2RayTun subscription written to $OUT_DIR/v2sub"

if [[ -f "$ROUTING_V2RAYTUN" ]]; then
    ROUTING_V2_B64=$(base64 -w 0 < "$ROUTING_V2RAYTUN" 2>/dev/null || base64 -i "$ROUTING_V2RAYTUN")
    log_info "v2RayTun routing base64 (for nginx header):"
    echo ""
    echo "  $ROUTING_V2_B64"
    echo ""
    log_info "Add this to your nginx config as:"
    echo "  add_header routing '<base64 string above>';"
else
    log_warn "v2RayTun routing file not found: $ROUTING_V2RAYTUN"
fi

echo ""
log_info "Subscription URLs (replace DOMAIN with your domain):"
echo "  Happ:      https://DOMAIN:8443/sub"
echo "  v2RayTun:  https://DOMAIN:8443/v2sub"
echo ""
