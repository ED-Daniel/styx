# Styx

Personal VPN service with dual protocols and full monitoring, logging, and alerting.

- **VLESS + Reality** (XRay) -- TCP:443, maximum stealth when UDP is blocked
- **Hysteria2** (standalone) -- UDP:443, maximum speed with Salamander obfuscation and port hopping

Both protocols run on the same server and port 443 without conflict (TCP vs UDP).

## Architecture

```
                      ┌──────────────────────────────────┐
                      │          VPS (single VM)          │
                      │                                   │
Client ──TCP:443────► │  XRay (VLESS+Reality) [Docker]    │
                      │                                   │
Client ──UDP:443────► │  Hysteria2 (Salamander) [systemd] │
                      │                                   │
                      │  Monitoring stack [Docker]        │
                      └──────────────────────────────────┘
```

| Service | Purpose | Port |
|---------|---------|------|
| **XRay** | VPN server (VLESS + Reality) | TCP 443 (external) |
| **Hysteria2** | VPN server (QUIC + Salamander) | UDP 443 (external) |
| **Grafana** | Dashboards and visualization | 3000 (external) |
| **Prometheus** | Metrics collection | 9090 (internal) |
| **Loki** | Log aggregation | 3100 (internal) |
| **Promtail** | Log collector | 9080 (internal) |
| **Alertmanager** | Alert routing to Telegram | 9093 (internal) |
| **Node Exporter** | System metrics | 9100 (internal) |
| **Blackbox Exporter** | Healthcheck probes | 9115 (internal) |
| **XRay Bridge Client** | VPN client via bridge for monitoring | 10809 (internal) |

## Quick Start

### Prerequisites

- Ubuntu 22.04/24.04 (or any Linux with Docker)
- Minimum 2GB RAM
- Docker and Docker Compose V2

### Setup

```bash
# Clone the repository
git clone <repo-url> styx
cd styx

# Run setup script
chmod +x scripts/setup.sh scripts/add-client.sh scripts/setup-hysteria2.sh
./scripts/setup.sh

# Start the monitoring + XRay stack
docker compose up -d
```

The setup script will:
- Check for Docker and Docker Compose
- Generate XRay UUID and Reality x25519 keypair
- Ask for server IP, bridge IP, Telegram bot token, and Grafana password
- Create `.env` file and update configs
- Print the VLESS connection URI

### Setup Hysteria2

Hysteria2 runs as a standalone systemd service (not in Docker), alongside the XRay stack.

```bash
# Run on the server as root
sudo ./scripts/setup-hysteria2.sh
```

The script will:
- Install Hysteria2 binary
- Generate self-signed TLS certificate with SHA256 pinning
- Generate Salamander obfuscation password
- Create config at `/etc/hysteria/config.yaml`
- Set up port hopping via nftables (UDP 20000-50000 -> 443)
- Start and enable the systemd service
- Print client connection URIs

### Add New Client (VLESS)

```bash
./scripts/add-client.sh "Client Name"
```

This generates a new UUID and prints the VLESS URI. You need to manually add the client to `xray/config.json` and restart XRay.

## Dashboards

### Styx / XRay Overview
- **Status panels**: UP/DOWN status for XRay TCP, HTTP-via-proxy, Bridge TCP, and Internet-via-bridge probes
- **Probe latency**: Graph of healthcheck probe duration over time
- **Traffic**: Inbound/outbound traffic rates and totals per user
- **Logs**: Live XRay logs from Loki (filtered by warning/error)

### Styx / System
- **Gauges**: CPU, Memory, Disk usage
- **Time series**: CPU per core, memory breakdown, disk I/O, network I/O
- **Filesystem table**: Usage per mount point

## Alerts

All alerts are sent to Telegram via Alertmanager.

| Alert | Condition | Severity |
|-------|-----------|----------|
| XRayDown | TCP probe fails > 2 min | Critical |
| NoInternetViaProxy | HTTP probe via proxy fails > 3 min | Critical |
| HighCPU | CPU > 85% for 5 min | Warning |
| HighMemory | RAM > 85% for 5 min | Warning |
| DiskSpaceLow | Disk > 90% | Critical |
| BridgeDown | Bridge TCP probe fails > 2 min | Critical |
| NoInternetViaBridge | HTTP probe via bridge fails > 3 min | Critical |

### Telegram Bot Setup

1. Create a bot via [@BotFather](https://t.me/BotFather)
2. Get the bot token
3. Get your chat ID (send a message to the bot, then check `https://api.telegram.org/bot<TOKEN>/getUpdates`)
4. Enter both values during `setup.sh` or set them in `.env`

## Bridge (Relay) Setup

A bridge server acts as an intermediate relay between the client and the VPN server. The client connects to the bridge, and the bridge transparently forwards traffic to the actual VPN server. This hides the VPN server's IP from the ISP — the provider only sees a connection to a domestic server.

```
Client --> Bridge (e.g. Russia) --> VPN Server (e.g. Germany) --> Internet
```

The bridge does not decrypt traffic — it simply forwards the TCP stream. Reality/TLS encryption is end-to-end between the client and the VPN server.

### Prerequisites

- A separate server (Ubuntu 22.04/24.04) with a public IP
- `socat` installed on the bridge server
- Port 443 available (not occupied by other services)

### Setup

```bash
# Install socat
sudo apt-get install -y socat

# Start the relay (replace VPN_SERVER_IP with your VPN server's IP)
sudo socat TCP-LISTEN:443,fork,reuseaddr TCP:VPN_SERVER_IP:443
```

### Running as a systemd service

To keep the bridge running after reboot, create a systemd unit:

```bash
sudo tee /etc/systemd/system/styx-bridge.service > /dev/null <<EOF
[Unit]
Description=Styx VPN Bridge Relay
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:443,fork,reuseaddr TCP:VPN_SERVER_IP:443
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now styx-bridge.service
```

### Client connection

Use the same VLESS URI as for direct connection, but replace the VPN server IP with the bridge IP:

```
vless://UUID@BRIDGE_IP:443?type=tcp&security=reality&fp=chrome&pbk=PUBLIC_KEY&sni=www.google.com&sid=SHORT_ID&flow=xtls-rprx-vision#STYX-BRIDGE
```

### Bridge monitoring

If `BRIDGE_IP` is set in `.env`, the stack includes:
- **xray-bridge-client** container — connects to the VPN through the bridge and exposes a local SOCKS proxy
- **blackbox-exporter** probes — TCP check on the bridge port + HTTP request through the full chain (client -> bridge -> VPN -> internet)
- **Grafana panels** — "Bridge TCP" and "Internet via Bridge" status on the XRay Overview dashboard
- **Alerts** — `BridgeDown` (bridge port unreachable) and `NoInternetViaBridge` (full chain broken)

## Hysteria2

Hysteria2 provides a high-speed VPN tunnel over QUIC (UDP), running as a standalone systemd service alongside the Docker-based XRay stack.

### Features

- **Salamander obfuscation** -- disguises QUIC traffic to bypass DPI that blocks standard QUIC/HTTP3
- **Port hopping** -- client jumps across UDP port range (20000-50000), server redirects to 443 via nftables
- **Self-signed TLS with SHA256 pinning** -- no dependency on ACME/Let's Encrypt, client verifies server by certificate pin

### Config

Server config: `/etc/hysteria/config.yaml`

```yaml
listen: :443

tls:
  cert: /etc/hysteria/ca.crt
  key: /etc/hysteria/ca.key

auth:
  type: password
  password: YOUR_PASSWORD

obfs:
  type: salamander
  salamander:
    password: YOUR_OBFS_PASSWORD

quic:
  initStreamReceiveWindow: 26843545
  maxStreamReceiveWindow: 26843545
  initConnReceiveWindow: 67108864
  maxConnReceiveWindow: 67108864
```

### Client URI format

```
hy2://PASSWORD@DOMAIN:20000-50000?obfs=salamander&obfs-password=OBFS_PASSWORD&sni=DOMAIN&insecure=1&pinSHA256=SHA256_PIN#Hysteria2
```

### Management

```bash
systemctl status hysteria-server    # Status
journalctl -u hysteria-server -f    # Logs
systemctl restart hysteria-server   # Restart
nano /etc/hysteria/config.yaml      # Edit config
```

### Recommended clients

| Platform | Client | Notes |
|----------|--------|-------|
| Android | Hiddify | Import via hy2:// link |
| iOS | Hiddify / Shadowrocket | Shadowrocket supports hy2:// from v2.2.35 |
| Windows | Hiddify / NekoBox / v2rayN | |
| macOS | Hiddify / NekoBox | |
| Linux | Native `hysteria` CLI | Only client with port hopping support |

### When to use which protocol

- **Hysteria2** -- when you need speed and UDP is not blocked by the ISP
- **VLESS+Reality** -- when you need maximum stealth or UDP is blocked

## Client Subscriptions

Subscription links allow VPN clients to auto-import server configs and routing rules. Two endpoints are supported:

| Client | URL | Features |
|--------|-----|----------|
| **Happ** | `https://DOMAIN:8443/sub` | VLESS URIs + routing deeplink (`happ://routing/onadd/...`) |
| **v2RayTun** | `https://DOMAIN:8443/v2sub` | VLESS URIs + `routing` HTTP header with base64 JSON |

### Routing profiles

Routing profiles define which traffic goes through VPN (proxy), which is blocked, and which goes direct. Files are in `subscriptions/`:

| File | Description | Use case |
|------|-------------|----------|
| `routing-happ.json` | Happ format, `geosite:ru-blocked` only | Happ with runetfreedom geo database |
| `routing-happ-lite.json` | Happ format, individual services only | Happ on low-memory devices |
| `routing-v2raytun.json` | Standard v2ray format with rules array | v2RayTun (sent via HTTP header) |

**Lite profile** proxies: YouTube, TikTok, Instagram, Telegram, Facebook, Twitter, Discord, OpenAI.
**Full profile** uses [runetfreedom](https://github.com/runetfreedom/russia-v2ray-rules-dat) `geosite:ru-blocked` — all RKN-blocked domains.

### Setup subscriptions

**1. Generate subscription files:**

```bash
./scripts/generate-subscriptions.sh
```

This reads `.env` (UUID, keys, server/bridge IPs) and routing JSONs from `subscriptions/`, then generates base64-encoded files in `/var/www/styx-sub/`.

To use the lite Happ profile instead of the full one:
```bash
./scripts/generate-subscriptions.sh subscriptions/routing-happ-lite.json
```

**2. Configure nginx:**

Add an HTTPS server block (port 8443) with SSL certificate. See `subscriptions/nginx-subscriptions.conf` for the location blocks. The v2RayTun `/v2sub` location needs the `routing` header — the script prints the base64 string to paste into the nginx config.

Example nginx setup:

```bash
# Get SSL certificate (stop XRay temporarily if it holds port 443)
sudo certbot certonly --standalone -d your-domain.com

# Add the subscription locations to your nginx server block on port 8443
# See subscriptions/nginx-subscriptions.conf for the template
```

**3. Test:**

```bash
# Happ
curl -s https://your-domain.com:8443/sub | base64 -d

# v2RayTun (check headers)
curl -sI https://your-domain.com:8443/v2sub
```

### Updating subscriptions

After adding a new client or changing routing rules, re-run:

```bash
sudo ./scripts/generate-subscriptions.sh
```

Clients will pick up changes on next subscription refresh (v2RayTun: every 12 hours by default).

---

### Alternative: nginx stream

If nginx is already installed on the bridge, you can use it instead of socat:

```bash
sudo apt-get install -y libnginx-mod-stream
```

Add to `/etc/nginx/nginx.conf` (at the top level, outside the `http` block):

```nginx
stream {
    server {
        listen 443;
        proxy_pass VPN_SERVER_IP:443;
    }
}
```

```bash
sudo nginx -t && sudo systemctl restart nginx
```

## Configuration

All settings are in `.env`. See `.env.example` for available variables.

### XRay Config

The XRay config is in `xray/config.json`. Key sections:
- **vless-reality inbound**: Main VPN protocol on port 443
- **socks-in inbound**: SOCKS proxy on port 10808 (used by healthcheck)
- **metrics-in inbound**: Metrics endpoint on port 10085
- **stats + policy**: Traffic counting per user

### Customizing Reality Settings

Default destination is `www.google.com:443`. You can change it in `.env`:
```
XRAY_REALITY_DEST=www.microsoft.com:443
XRAY_REALITY_SNI=www.microsoft.com
```

## Maintenance

```bash
# View logs
docker compose logs -f xray        # XRay logs
docker compose logs -f prometheus   # Prometheus logs
journalctl -u hysteria-server -f   # Hysteria2 logs

# Restart services
docker compose restart xray
systemctl restart hysteria-server

# Update XRay + monitoring stack
docker compose pull && docker compose up -d

# Update Hysteria2
bash <(curl -fsSL https://get.hy2.sh/)
systemctl restart hysteria-server

# Check both VPN services
ss -tlnp | grep 443    # XRay (TCP)
ss -ulnp | grep 443    # Hysteria2 (UDP)

# Stop everything
docker compose down
systemctl stop hysteria-server

# Stop and remove volumes (data loss!)
docker compose down -v
```

## File Structure

```
.
├── docker-compose.yml
├── .env / .env.example
├── xray/config.json
├── xray/bridge-client.json
├── prometheus/
│   ├── prometheus.yml
│   └── alerts.yml
├── blackbox-exporter/config.yml
├── alertmanager/alertmanager.yml
├── loki/loki-config.yml
├── promtail/promtail-config.yml
├── grafana/provisioning/
│   ├── datasources/datasources.yml
│   └── dashboards/
│       ├── dashboards.yml
│       ├── xray-overview.json
│       └── system.json
├── subscriptions/
│   ├── routing-happ.json            # Happ routing (geosite:ru-blocked)
│   ├── routing-happ-lite.json       # Happ routing (individual services, low memory)
│   ├── routing-v2raytun.json        # v2RayTun routing (standard v2ray format)
│   └── nginx-subscriptions.conf     # nginx location blocks template
└── scripts/
    ├── setup.sh                     # Initial XRay + monitoring setup
    ├── setup-hysteria2.sh           # Hysteria2 setup (Salamander + port hopping)
    ├── add-client.sh                # Add VLESS client
    └── generate-subscriptions.sh    # Generate subscription files
```

### Hysteria2 files on server (created by setup-hysteria2.sh)

```
/etc/hysteria/
├── config.yaml          # Hysteria2 server config
├── ca.crt               # Self-signed TLS certificate
└── ca.key               # TLS private key

/etc/systemd/system/
└── hysteria-server.service

/etc/nftables.conf       # Port hopping rules (UDP 20000-50000 -> 443)
```
