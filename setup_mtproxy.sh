#!/usr/bin/env bash

# =============================================================================

# MTProxy — setup & run script for Ubuntu

# Source: https://github.com/TelegramMessenger/MTProxy

# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────

INSTALL_DIR=”/opt/MTProxy”
SERVICE_NAME=“MTProxy”
CLIENT_PORT=443              # Port clients connect to
STATS_PORT=8888              # Local stats port (wget localhost:8888/stats)
WORKERS=1                    # Increase on multi-core servers

# ─────────────────────────────────────────────────────────────────────────────

SECRET_FILE=”$INSTALL_DIR/.secret”
SECRET=””   # set by generate_secret(), consumed by setup_systemd()

# Only use colors when stdout is a real TTY
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''
fi

info()    { echo -e “${CYAN}[INFO]${NC}  $*”; }
success() { echo -e “${GREEN}[OK]${NC}    $*”; }
warn()    { echo -e “${YELLOW}[WARN]${NC}  $*”; }
error()   { echo -e “${RED}[ERROR]${NC} $*” >&2; exit 1; }

# ── Help ──────────────────────────────────────────────────────────────────────

show_help() {
cat <<EOF

${CYAN}MTProxy — setup & run script for Ubuntu${NC}
Source: https://github.com/TelegramMessenger/MTProxy

${CYAN}USAGE${NC}
sudo bash $(basename “$0”) [OPTIONS]

${CYAN}OPTIONS${NC}
-p, –port <port>       Client port to listen on         (default: 443)
-s, –stats-port <port> Local stats port                 (default: 8888)
-w, –workers <n>       Number of worker processes       (default: 1)
-d, –dir <path>        Installation directory           (default: /opt/MTProxy)
-h, –help              Show this help message and exit

${CYAN}EXAMPLES${NC}
sudo bash $(basename “$0”)
sudo bash $(basename “$0”) –port 8443
sudo bash $(basename “$0”) –port 8443 –workers 4
sudo bash $(basename “$0”) –port 2443 –dir /srv/mtproxy –workers 2

${CYAN}AFTER INSTALL${NC}
Stats  : wget -qO- localhost:${STATS_PORT}/stats
Logs   : journalctl -u ${SERVICE_NAME} -f
Restart: systemctl restart ${SERVICE_NAME}

EOF
exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────────

parse_args() {
while [[ $# -gt 0 ]]; do
case “$1” in
-p|–port)
[[ -n “${2:-}” ]] || error “Option $1 requires an argument.”
CLIENT_PORT=”$2”; shift 2 ;;
-s|–stats-port)
[[ -n “${2:-}” ]] || error “Option $1 requires an argument.”
STATS_PORT=”$2”; shift 2 ;;
-w|–workers)
[[ -n “${2:-}” ]] || error “Option $1 requires an argument.”
WORKERS=”$2”; shift 2 ;;
-d|–dir)
[[ -n “${2:-}” ]] || error “Option $1 requires an argument.”
INSTALL_DIR=”$2”
SECRET_FILE=”$INSTALL_DIR/.secret”
shift 2 ;;
-h|–help)
show_help ;;
*)
error “Unknown option: $1  Try –help for usage.” ;;
esac
done

# Validate numeric arguments

[[ “$CLIENT_PORT” =~ ^[0-9]+$ ]] && (( CLIENT_PORT >= 1 && CLIENT_PORT <= 65535 ))   
|| error “Invalid client port: ${CLIENT_PORT}. Must be 1–65535.”
[[ “$STATS_PORT”  =~ ^[0-9]+$ ]] && (( STATS_PORT  >= 1 && STATS_PORT  <= 65535 ))   
|| error “Invalid stats port: ${STATS_PORT}. Must be 1–65535.”
[[ “$WORKERS”     =~ ^[0-9]+$ ]] && (( WORKERS >= 1 ))   
|| error “Invalid workers value: ${WORKERS}. Must be >= 1.”
[[ “$CLIENT_PORT” -ne “$STATS_PORT” ]]   
|| error “Client port and stats port must be different.”
}

# ── Guards ────────────────────────────────────────────────────────────────────

require_root() {
[[ $EUID -eq 0 ]] || error “Run this script as root: sudo $0”
}

check_port_free() {
info “Checking that port ${CLIENT_PORT} is available…”
if ss -tlnp | grep -q “:${CLIENT_PORT} “; then
error “Port ${CLIENT_PORT} is already in use. Pass a different port: sudo $0 <port>”
fi
success “Port ${CLIENT_PORT} is free.”
}

# ── 1. Install build dependencies ────────────────────────────────────────────

install_deps() {
info “Installing build dependencies…”
apt-get update -qq
apt-get install -y –no-install-recommends   
git curl build-essential libssl-dev zlib1g-dev openssl iproute2
success “Dependencies installed.”
}

# ── 2. Clone & build MTProxy ─────────────────────────────────────────────────

build_mtproxy() {
if [[ -d “$INSTALL_DIR” ]]; then
warn “Directory $INSTALL_DIR already exists — attempting to pull latest changes.”
# FIX: don’t swallow pull errors silently
git -C “$INSTALL_DIR” pull –ff-only   
|| warn “Could not pull latest changes (local modifications?) — building with existing source.”
else
info “Cloning MTProxy repository…”
git clone https://github.com/TelegramMessenger/MTProxy “$INSTALL_DIR”
fi

info “Building MTProxy (this may take a minute)…”

# FIX: use subshell to avoid changing PWD for the rest of the script

(
cd “$INSTALL_DIR”
make clean 2>/dev/null || true
make -j”$(nproc)”
)
success “Build complete → $INSTALL_DIR/objs/bin/mtproto-proxy”
}

# ── 3. Fetch Telegram config files ───────────────────────────────────────────

fetch_telegram_configs() {
info “Fetching Telegram proxy-secret…”

# FIX: download to tmp file first, replace only on success

curl -sSf –max-time 15 https://core.telegram.org/getProxySecret   
-o /tmp/proxy-secret.tmp   
&& mv /tmp/proxy-secret.tmp “$INSTALL_DIR/proxy-secret”   
|| error “Failed to download proxy-secret from Telegram.”

info “Fetching Telegram proxy config…”
curl -sSf –max-time 15 https://core.telegram.org/getProxyConfig   
-o /tmp/proxy-multi.conf.tmp   
&& mv /tmp/proxy-multi.conf.tmp “$INSTALL_DIR/proxy-multi.conf”   
|| error “Failed to download proxy-multi.conf from Telegram.”

success “Telegram config files downloaded.”
}

# ── 4. Generate or reuse secret ──────────────────────────────────────────────

generate_secret() {
if [[ -f “$SECRET_FILE” ]]; then
warn “Existing secret found — reusing it.”
SECRET=$(cat “$SECRET_FILE”)
else
info “Generating new proxy secret…”
# FIX: use openssl instead of xxd (more portable across Ubuntu versions)
SECRET=$(openssl rand -hex 16)
echo “$SECRET” > “$SECRET_FILE”
chmod 600 “$SECRET_FILE”
fi
success “Secret: ${SECRET}”
}

# ── 5. Create daily cron job to refresh Telegram config ──────────────────────

setup_cron() {
local cron_file=”/etc/cron.daily/mtproxy-update-config”
info “Installing daily config-refresh cron job…”
cat > “$cron_file” <<EOF
#!/bin/sh

# Refresh Telegram MTProxy config files daily.

# Downloads to tmp first — replaces live files only on success.

curl -sSf –max-time 15 https://core.telegram.org/getProxySecret   
-o /tmp/proxy-secret.tmp   
&& mv /tmp/proxy-secret.tmp ${INSTALL_DIR}/proxy-secret   
|| echo “[MTProxy cron] WARNING: failed to update proxy-secret” >&2

curl -sSf –max-time 15 https://core.telegram.org/getProxyConfig   
-o /tmp/proxy-multi.conf.tmp   
&& mv /tmp/proxy-multi.conf.tmp ${INSTALL_DIR}/proxy-multi.conf   
|| echo “[MTProxy cron] WARNING: failed to update proxy-multi.conf” >&2

systemctl restart ${SERVICE_NAME}.service 2>/dev/null || true
EOF
chmod +x “$cron_file”
success “Cron job created at $cron_file”
}

# ── 6. Create systemd service ─────────────────────────────────────────────────

setup_systemd() {

# FIX: guard against SECRET being empty (wrong call order)

[[ -n “${SECRET}” ]] || error “BUG: SECRET is empty — generate_secret() must run before setup_systemd().”

local service_path=”/etc/systemd/system/${SERVICE_NAME}.service”
info “Creating systemd service at $service_path…”

cat > “$service_path” <<EOF
[Unit]
Description=Telegram MTProxy

# FIX: network-online.target ensures the interface has an IP address

After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/objs/bin/mtproto-proxy \
-u nobody \
-p ${STATS_PORT} \
-H ${CLIENT_PORT} \
-S ${SECRET} \
–aes-pwd ${INSTALL_DIR}/proxy-secret \
${INSTALL_DIR}/proxy-multi.conf \
-M ${WORKERS}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable “${SERVICE_NAME}.service”
systemctl restart “${SERVICE_NAME}.service”

# FIX: actually verify the service came up, don’t just assume

sleep 2
if ! systemctl is-active –quiet “${SERVICE_NAME}.service”; then
error “Service failed to start. Check logs: journalctl -u ${SERVICE_NAME} -n 50”
fi

success “Service ${SERVICE_NAME} enabled and running.”
}

# ── 7. Open firewall port (ufw) ───────────────────────────────────────────────

open_firewall() {
if command -v ufw &>/dev/null && ufw status | grep -q “Status: active”; then
info “Opening port ${CLIENT_PORT}/tcp in ufw…”
ufw allow “${CLIENT_PORT}/tcp” comment “MTProxy”
success “ufw rule added.”
else
warn “ufw not active — make sure port ${CLIENT_PORT}/tcp is open in your firewall.”
fi
}

# ── 8. Print connection info ──────────────────────────────────────────────────

print_summary() {
local server_ip

# FIX: add –max-time to avoid hanging if ipify is unreachable

server_ip=$(curl -sSf –max-time 5 https://api.ipify.org 2>/dev/null || echo “<YOUR_SERVER_IP>”)

echo
echo -e “${GREEN}════════════════════════════════════════════════════════${NC}”
echo -e “${GREEN}  MTProxy is up and running!${NC}”
echo -e “${GREEN}════════════════════════════════════════════════════════${NC}”
echo -e “  Server IP   : ${CYAN}${server_ip}${NC}”
echo -e “  Port        : ${CYAN}${CLIENT_PORT}${NC}”
echo -e “  Secret      : ${CYAN}${SECRET}${NC}”
echo -e “  Secret (dd) : ${CYAN}dd${SECRET}${NC}  ← random padding (anti-DPI)”
echo
echo -e “  Telegram link:”
echo -e “  ${CYAN}tg://proxy?server=${server_ip}&port=${CLIENT_PORT}&secret=${SECRET}${NC}”
echo
echo -e “  Optional: register with @MTProxybot to get a tag, then add”
echo -e “    -P <proxy_tag>  to the ExecStart line in:”
echo -e “    /etc/systemd/system/${SERVICE_NAME}.service”
echo -e “  Then run: systemctl daemon-reload && systemctl restart ${SERVICE_NAME}”
echo
echo -e “  Stats  : wget -qO- localhost:${STATS_PORT}/stats”
echo -e “  Logs   : journalctl -u ${SERVICE_NAME} -f”
echo -e “  Restart: systemctl restart ${SERVICE_NAME}”
echo -e “${GREEN}════════════════════════════════════════════════════════${NC}”
echo
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
parse_args “$@”
require_root
check_port_free       # fail early if port is occupied
install_deps
build_mtproxy
fetch_telegram_configs
generate_secret
setup_cron
setup_systemd         # SECRET must be set before this call
open_firewall
print_summary
}

main “$@”
