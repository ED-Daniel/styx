#!/usr/bin/env bash
set -euo pipefail

# Hysteria2 setup script
# Installs and configures Hysteria2 with Salamander obfuscation and port hopping
# Designed to run alongside XRay (VLESS+Reality) on the same server:
#   - XRay uses TCP:443
#   - Hysteria2 uses UDP:443

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

HY2_CONFIG="/etc/hysteria/config.yaml"
HY2_PORT="${HY2_PORT:-443}"
HY2_PORT_HOPPING="${HY2_PORT_HOPPING:-20000-50000}"

main() {
    echo ""
    echo "======================================"
    echo "  Hysteria2 Setup (Salamander + Port Hopping)"
    echo "======================================"
    echo ""

    # Check root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi

    # Ask for domain
    read -rp "Enter domain for Hysteria2 (must have A record pointing to this server): " HY2_DOMAIN
    if [[ -z "$HY2_DOMAIN" ]]; then
        log_error "Domain is required."
        exit 1
    fi

    # Ask for password or generate
    read -rp "Enter auth password (or press Enter to generate): " HY2_PASSWORD
    if [[ -z "$HY2_PASSWORD" ]]; then
        HY2_PASSWORD=$(openssl rand -base64 24)
        log_info "Generated password: $HY2_PASSWORD"
    fi

    # Step 1: Install Hysteria2
    if command -v hysteria &> /dev/null; then
        log_info "Hysteria2 is already installed: $(hysteria version 2>/dev/null | head -1)"
        read -rp "Reinstall? (y/N): " reinstall
        if [[ "$reinstall" == "y" || "$reinstall" == "Y" ]]; then
            bash <(curl -fsSL https://get.hy2.sh/)
        fi
    else
        log_info "Installing Hysteria2..."
        bash <(curl -fsSL https://get.hy2.sh/)
    fi

    # Step 2: Generate self-signed certificate
    log_info "Generating self-signed TLS certificate..."
    mkdir -p /etc/hysteria
    openssl ecparam -genkey -name prime256v1 -out /etc/hysteria/ca.key 2>/dev/null
    openssl req -new -x509 -days 3650 -key /etc/hysteria/ca.key -out /etc/hysteria/ca.crt \
        -subj "/CN=$HY2_DOMAIN" 2>/dev/null

    SHA256=$(openssl x509 -noout -fingerprint -sha256 -in /etc/hysteria/ca.crt | sed 's/.*=//;s/://g')
    log_info "SHA256 pin: $SHA256"

    # Step 3: Generate Salamander obfuscation password
    HY2_OBFS_PASSWORD=$(openssl rand -base64 24)
    log_info "Salamander obfs password: $HY2_OBFS_PASSWORD"

    # Step 4: Create config
    log_info "Creating Hysteria2 config..."
    cat > "$HY2_CONFIG" << YAML
# Hysteria2 Server Config
# Listens on UDP:${HY2_PORT} (XRay/VLESS uses TCP:${HY2_PORT} -- no conflict)
listen: :${HY2_PORT}

# Self-signed TLS (client verifies via SHA256 pin)
tls:
  cert: /etc/hysteria/ca.crt
  key: /etc/hysteria/ca.key

# Authentication
auth:
  type: password
  password: ${HY2_PASSWORD}

# Salamander obfuscation (hides QUIC from DPI)
obfs:
  type: salamander
  salamander:
    password: ${HY2_OBFS_PASSWORD}

# QUIC tuning
quic:
  initStreamReceiveWindow: 26843545
  maxStreamReceiveWindow: 26843545
  initConnReceiveWindow: 67108864
  maxConnReceiveWindow: 67108864
YAML

    # Step 5: Create systemd unit
    log_info "Configuring systemd service..."
    cat > /etc/systemd/system/hysteria-server.service << EOF
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload

    # Step 6: Setup port hopping via nftables
    log_info "Setting up port hopping (UDP ${HY2_PORT_HOPPING} -> ${HY2_PORT})..."
    apt-get install -y nftables > /dev/null 2>&1

    IFACE=$(ip route show default | awk '{print $5}' | head -1)
    HOP_START=$(echo "$HY2_PORT_HOPPING" | cut -d- -f1)
    HOP_END=$(echo "$HY2_PORT_HOPPING" | cut -d- -f2)

    # Remove existing table if present
    nft delete table inet hysteria_porthopping 2>/dev/null || true
    nft add table inet hysteria_porthopping
    nft add chain inet hysteria_porthopping prerouting '{ type nat hook prerouting priority dstnat; policy accept; }'
    nft add rule inet hysteria_porthopping prerouting iifname "$IFACE" udp dport "${HOP_START}-${HOP_END}" counter redirect to :"${HY2_PORT}"

    # Persist nftables rules
    nft list ruleset > /etc/nftables.conf
    systemctl enable nftables > /dev/null 2>&1

    log_info "Port hopping configured on interface $IFACE"

    # Step 7: Open firewall ports (if ufw is active)
    if ufw status 2>/dev/null | grep -q "active"; then
        log_info "Configuring UFW..."
        ufw allow "${HY2_PORT}/udp" comment "Hysteria2"
        ufw allow "${HOP_START}:${HOP_END}/udp" comment "Hysteria2 port hopping"
    fi

    # Step 8: Start service
    log_info "Starting Hysteria2..."
    systemctl enable hysteria-server
    systemctl start hysteria-server
    sleep 2

    if systemctl is-active --quiet hysteria-server; then
        log_info "Hysteria2 is running!"
    else
        log_error "Hysteria2 failed to start. Check: journalctl -u hysteria-server -f"
        exit 1
    fi

    # Print summary
    echo ""
    echo "======================================"
    echo "  Hysteria2 Setup Complete!"
    echo "======================================"
    echo ""
    log_info "Server:           ${HY2_DOMAIN}:${HY2_PORT} (UDP)"
    log_info "Auth password:    ${HY2_PASSWORD}"
    log_info "Obfs password:    ${HY2_OBFS_PASSWORD}"
    log_info "SHA256 pin:       ${SHA256}"
    log_info "Port hopping:     UDP ${HY2_PORT_HOPPING}"
    echo ""
    log_info "Client URI (with Salamander + port hopping):"
    echo ""
    echo "  hy2://${HY2_PASSWORD}@${HY2_DOMAIN}:${HOP_START}-${HOP_END}?obfs=salamander&obfs-password=${HY2_OBFS_PASSWORD}&sni=${HY2_DOMAIN}&insecure=1&pinSHA256=${SHA256}#Hysteria2"
    echo ""
    log_info "Client URI (without port hopping):"
    echo ""
    echo "  hy2://${HY2_PASSWORD}@${HY2_DOMAIN}:${HY2_PORT}?obfs=salamander&obfs-password=${HY2_OBFS_PASSWORD}&sni=${HY2_DOMAIN}&insecure=1&pinSHA256=${SHA256}#Hysteria2"
    echo ""
    log_info "Management:"
    echo "  Status:   systemctl status hysteria-server"
    echo "  Logs:     journalctl -u hysteria-server -f"
    echo "  Restart:  systemctl restart hysteria-server"
    echo "  Config:   nano ${HY2_CONFIG}"
    echo ""
}

main "$@"
