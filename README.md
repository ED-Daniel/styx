# Styx

Personal VPN service based on XRay (VLESS + Reality) with full monitoring, logging, and alerting.

## Architecture

| Service | Purpose | Port |
|---------|---------|------|
| **XRay** | VPN server (VLESS + Reality) | 443 (external) |
| **Grafana** | Dashboards and visualization | 3000 (external) |
| **Prometheus** | Metrics collection | 9090 (internal) |
| **Loki** | Log aggregation | 3100 (internal) |
| **Promtail** | Log collector | 9080 (internal) |
| **Alertmanager** | Alert routing to Telegram | 9093 (internal) |
| **Node Exporter** | System metrics | 9100 (internal) |
| **Blackbox Exporter** | Healthcheck probes | 9115 (internal) |

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
chmod +x scripts/setup.sh scripts/add-client.sh
./scripts/setup.sh

# Start the stack
docker compose up -d
```

The setup script will:
- Check for Docker and Docker Compose
- Generate XRay UUID and Reality x25519 keypair
- Ask for server IP, Telegram bot token, and Grafana password
- Create `.env` file and update configs
- Print the VLESS connection URI

### Add New Client

```bash
./scripts/add-client.sh "Client Name"
```

This generates a new UUID and prints the VLESS URI. You need to manually add the client to `xray/config.json` and restart XRay.

## Dashboards

### Styx / XRay Overview
- **Status panels**: UP/DOWN status for XRay TCP probe and HTTP-via-proxy probe
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

### Telegram Bot Setup

1. Create a bot via [@BotFather](https://t.me/BotFather)
2. Get the bot token
3. Get your chat ID (send a message to the bot, then check `https://api.telegram.org/bot<TOKEN>/getUpdates`)
4. Enter both values during `setup.sh` or set them in `.env`

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
docker compose logs -f xray        # Styx XRay logs
docker compose logs -f prometheus   # Styx Prometheus logs

# Restart a service
docker compose restart xray

# Update all images
docker compose pull && docker compose up -d

# Stop Styx
docker compose down

# Stop and remove volumes (data loss!)
docker compose down -v
```

## File Structure

```
.
├── docker-compose.yml
├── .env / .env.example
├── xray/config.json
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
└── scripts/
    ├── setup.sh
    └── add-client.sh
```
