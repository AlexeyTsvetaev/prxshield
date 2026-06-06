#!/bin/bash
#
# Remnawave Node Shield Installer v4 (honest edition)
# Ubuntu 22.04 / 24.04
# - L4 anti-DDoS via nf hashlimit/connlimit (survives reboot, ufw-friendly)
# - Kernel hardening (syncookies, conntrack, BBR)
# - SSH open (Fail2Ban protects), 443 open, 8443 only from PANEL_IP
# - Docker + /opt/remnanode/docker-compose.yml + logrotate
# NOTE: volumetric L3 (bandwidth saturation) CANNOT be stopped on the host.
#       For that you need a provider/scrubber with DDoS protection.
#

set +e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# ===== CONFIG =====
PANEL_IP="185.239.51.193"
NODE_API_PORT="8443"
VPN_PORT="443"
ENABLE_SYNPROXY="false"   # advanced; turn "true" only if you understand it
# ==================

LOG_FILE="/var/log/node-shield-install.log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

step(){ echo -e "${GREEN}======== $1 ========${NC}"; }
ok(){ echo -e "${GREEN}[✓] $1${NC}"; }
warn(){ echo -e "${YELLOW}[!] $1${NC}"; }
err(){ echo -e "${RED}[✗] $1${NC}"; }

echo "========================================"
echo "Node Shield v4 | Panel: $PANEL_IP | $(date)"
echo "========================================"
echo -e "${YELLOW}Reminder: host-side rules stop SYN/PPS/state floods, NOT bandwidth saturation."
echo -e "For volumetric L3 use a DDoS-protected provider/scrubber.${NC}"

# ---- detect node IP / iface ----
NODE_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$NODE_IP" ] && NODE_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+')
[ -z "$NODE_IP" ] && NODE_IP=$(curl -s -4 ifconfig.me 2>/dev/null)
[ -z "$NODE_IP" ] && read -rp "Enter node IP: " NODE_IP
IFACE=$(ip route | awk '/^default/{print $5; exit}')
ok "Node IP: $NODE_IP | Interface: $IFACE"

# =========================================================
step "STEP 1: Dependencies"
# free apt locks if stuck
for i in $(seq 1 30); do
  fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break
  echo -n "."; sleep 2
done
if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
  warn "apt lock busy, killing holder"
  fuser -k /var/lib/dpkg/lock-frontend 2>/dev/null; sleep 2
fi
rm -f /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null
dpkg --configure -a 2>/dev/null

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && ok "apt update" || warn "apt update failed"

PACKAGES="curl wget ca-certificates gnupg htop iftop mc net-tools ethtool conntrack fail2ban ufw logrotate cron"
for pkg in $PACKAGES; do
  echo -n "  - $pkg: "
  if apt-get install -y "$pkg" >>"$LOG_FILE" 2>&1; then echo -e "${GREEN}OK${NC}"; else echo -e "${YELLOW}FAIL${NC}"; fi
done

# =========================================================
step "STEP 2: Docker"
install_docker(){
  command -v docker >/dev/null 2>&1 && { ok "Docker already present"; return 0; }
  for a in 1 2 3; do
    rm -f /var/lib/dpkg/lock-frontend 2>/dev/null
    if curl -fsSL https://get.docker.com | sh >>"$LOG_FILE" 2>&1 && command -v docker >/dev/null 2>&1; then
      ok "Docker installed (get.docker.com)"; return 0
    fi
    warn "Docker install attempt $a failed, retrying..."; sleep 5
  done
  warn "Falling back to distro docker.io"
  apt-get install -y docker.io docker-compose-v2 >>"$LOG_FILE" 2>&1 || apt-get install -y docker.io >>"$LOG_FILE" 2>&1
  command -v docker >/dev/null 2>&1 && ok "Docker installed (docker.io)" || err "Docker NOT installed - install manually"
}
install_docker
systemctl enable --now docker >>"$LOG_FILE" 2>&1 || true

# =========================================================
step "STEP 3: Kernel hardening (sysctl)"
cat > /etc/sysctl.d/99-node-shield.conf <<'EOF'
# Buffers / throughput
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# SYN flood
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1

# Conntrack
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_buckets = 262144
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 15
net.netfilter.nf_conntrack_tcp_timeout_established = 600

# Anti-spoof / ICMP hygiene
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
EOF
echo "nf_conntrack" > /etc/modules-load.d/conntrack.conf
modprobe nf_conntrack 2>/dev/null
sysctl --system >>"$LOG_FILE" 2>&1 && ok "sysctl applied" || warn "some sysctl keys skipped (apply after reboot)"

# =========================================================
step "STEP 4: File limits"
grep -q "node-shield nofile" /etc/security/limits.conf 2>/dev/null || cat >> /etc/security/limits.conf <<'EOF'
# node-shield nofile
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
mkdir -p /etc/systemd/system.conf.d/
cat > /etc/systemd/system.conf.d/limits.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF
systemctl daemon-reload 2>/dev/null
ok "limits configured"

# =========================================================
step "STEP 5: Anti-DDoS rules (L4) + NIC tuning"
# config consumed by the boot service
cat > /etc/default/node-shield <<EOF
PANEL_IP="$PANEL_IP"
VPN_PORT="$VPN_PORT"
NODE_API_PORT="$NODE_API_PORT"
ENABLE_SYNPROXY="$ENABLE_SYNPROXY"
EOF

cat > /usr/local/sbin/node-shield.sh <<'EOF'
#!/bin/bash
set -u
[ -f /etc/default/node-shield ] && . /etc/default/node-shield
PANEL_IP="${PANEL_IP:-}"; VPN_PORT="${VPN_PORT:-443}"
NODE_API_PORT="${NODE_API_PORT:-8443}"; ENABLE_SYNPROXY="${ENABLE_SYNPROXY:-false}"
IFACE="$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')"

# NIC ring buffers: fewer drops under load (safe; offloading left ON for throughput)
if [ -n "$IFACE" ] && command -v ethtool >/dev/null 2>&1; then
  ethtool -G "$IFACE" rx 4096 tx 4096 2>/dev/null || true
fi

ipt(){ iptables "$@"; }
ipt -N DDOS 2>/dev/null || ipt -F DDOS
[ -n "$PANEL_IP" ] && ipt -A DDOS -s "$PANEL_IP" -j RETURN          # never throttle panel
ipt -A DDOS -i lo -j RETURN
ipt -A DDOS -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
ipt -A DDOS -m conntrack --ctstate INVALID -j DROP
# malformed TCP flag combos
ipt -A DDOS -p tcp --tcp-flags ALL NONE -j DROP
ipt -A DDOS -p tcp --tcp-flags ALL ALL -j DROP
ipt -A DDOS -p tcp --tcp-flags SYN,FIN SYN,FIN -j DROP
ipt -A DDOS -p tcp --tcp-flags SYN,RST SYN,RST -j DROP
ipt -A DDOS -p tcp --tcp-flags FIN,RST FIN,RST -j DROP
ipt -A DDOS -p tcp --tcp-flags ALL FIN -j DROP
ipt -A DDOS -p tcp --tcp-flags ALL SYN,FIN -j DROP
# icmp echo flood (per source)
ipt -A DDOS -p icmp --icmp-type echo-request -m hashlimit \
    --hashlimit-name icmpflood --hashlimit-mode srcip \
    --hashlimit-above 5/sec --hashlimit-burst 10 -j DROP
# new TCP conns per source (SYN) rate limit
ipt -A DDOS -p tcp --syn -m hashlimit \
    --hashlimit-name synflood --hashlimit-mode srcip \
    --hashlimit-above 30/sec --hashlimit-burst 60 -j DROP
# parallel connections per source to VPN port
ipt -A DDOS -p tcp --dport "$VPN_PORT" -m connlimit \
    --connlimit-above 200 --connlimit-mask 32 -j DROP
ipt -A DDOS -j RETURN
# single jump at top of INPUT
while ipt -C INPUT -j DDOS 2>/dev/null; do ipt -D INPUT -j DDOS; done
ipt -I INPUT 1 -j DDOS

# optional SYNPROXY (advanced, off by default)
if [ "$ENABLE_SYNPROXY" = "true" ]; then
  iptables -t raw -C PREROUTING -p tcp --dport "$VPN_PORT" --syn -j CT --notrack 2>/dev/null || \
    iptables -t raw -A PREROUTING -p tcp --dport "$VPN_PORT" --syn -j CT --notrack
  iptables -C INPUT -p tcp --dport "$VPN_PORT" -m conntrack --ctstate INVALID,UNTRACKED \
    -j SYNPROXY --sack-perm --timestamp --wscale 7 --mss 1460 2>/dev/null || \
    iptables -A INPUT -p tcp --dport "$VPN_PORT" -m conntrack --ctstate INVALID,UNTRACKED \
    -j SYNPROXY --sack-perm --timestamp --wscale 7 --mss 1460
fi
exit 0
EOF
chmod +x /usr/local/sbin/node-shield.sh

cat > /etc/systemd/system/node-shield.service <<'EOF'
[Unit]
Description=Node Shield anti-DDoS rules
After=ufw.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/node-shield.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable node-shield.service >>"$LOG_FILE" 2>&1
/usr/local/sbin/node-shield.sh && ok "Anti-DDoS rules applied + persisted (boot service)" || warn "rule apply had issues"

# =========================================================
step "STEP 6: UFW (ports)"
ufw --force reset >>"$LOG_FILE" 2>&1
ufw allow 22/tcp comment 'SSH (Fail2Ban protects)'           >>"$LOG_FILE" 2>&1
ufw allow ${VPN_PORT}/tcp comment 'VLESS Reality'            >>"$LOG_FILE" 2>&1
ufw allow from ${PANEL_IP} proto tcp to any port ${NODE_API_PORT} comment 'Remnanode API panel-only' >>"$LOG_FILE" 2>&1
ufw --force enable >>"$LOG_FILE" 2>&1
ok "UFW: 22 open, ${VPN_PORT} open, ${NODE_API_PORT} only from ${PANEL_IP}"
ufw status verbose 2>/dev/null

# =========================================================
step "STEP 7: Fail2Ban"
if command -v fail2ban-client >/dev/null 2>&1; then
  [ -f /etc/fail2ban/jail.local ] || cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local 2>/dev/null
  cat > /etc/fail2ban/jail.d/node-shield.local <<'EOF'
[sshd]
enabled = true
backend = systemd
maxretry = 3
findtime = 300
bantime = 86400

[recidive]
enabled = true
bantime = 1209600
findtime = 86400
maxretry = 5
EOF
  systemctl enable fail2ban >>"$LOG_FILE" 2>&1
  systemctl restart fail2ban >>"$LOG_FILE" 2>&1 && ok "Fail2Ban active (SSH: 3 fails = 24h)" || warn "fail2ban restart failed"
else
  warn "fail2ban not installed"
fi

# =========================================================
step "STEP 8: Remnanode (Docker Compose) + logrotate"
mkdir -p /opt/remnanode /var/log/remnanode
if [ ! -f /opt/remnanode/docker-compose.yml ]; then
cat > /opt/remnanode/docker-compose.yml <<EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=${NODE_API_PORT}
      - SECRET_KEY="PASTE_SECRET_KEY_FROM_PANEL"
    volumes:
      - /var/log/remnanode:/var/log/remnanode
EOF
  ok "Created /opt/remnanode/docker-compose.yml (edit SECRET_KEY)"
else
  warn "/opt/remnanode/docker-compose.yml already exists - left untouched"
fi

# logrotate: config + enable timer + validate
cat > /etc/logrotate.d/remnanode <<'EOF'
/var/log/remnanode/*.log {
    size 50M
    rotate 5
    compress
    missingok
    notifempty
    copytruncate
}
EOF
chmod 644 /etc/logrotate.d/remnanode
systemctl enable --now logrotate.timer >>"$LOG_FILE" 2>&1 || true
if logrotate -d /etc/logrotate.d/remnanode >>"$LOG_FILE" 2>&1; then
  ok "logrotate installed, timer enabled, config valid"
else
  warn "logrotate config check had warnings (see log)"
fi

cat > /etc/cron.d/remnawave-update <<'EOF'
0 11 * * 6 root cd /opt/remnanode && docker compose pull && docker compose down && docker compose up -d && docker image prune -f
EOF
chmod 644 /etc/cron.d/remnawave-update
ok "weekly auto-update configured"

# =========================================================
step "DONE"
echo -e "${GREEN}Node IP:${NC} $NODE_IP   ${GREEN}Panel IP:${NC} $PANEL_IP"
echo -e "${GREEN}Open:${NC} 22 (SSH+Fail2Ban), ${VPN_PORT} (VPN)   ${GREEN}Panel-only:${NC} ${NODE_API_PORT}"
echo ""
echo -e "${YELLOW}NEXT STEPS:${NC}"
echo -e "  1) Edit compose & paste SECRET_KEY from panel:"
echo -e "       ${BLUE}mcedit /opt/remnanode/docker-compose.yml${NC}"
echo -e "  2) Start node:"
echo -e "       ${BLUE}cd /opt/remnanode && docker compose up -d && docker compose logs -f${NC}"
echo -e "  3) Reboot once to lock in limits/sysctl: ${BLUE}reboot${NC}"
echo ""
echo -e "${YELLOW}VERIFY:${NC}"
echo "  iptables -L DDOS -n -v               # anti-DDoS counters"
echo "  ufw status verbose                   # ports"
echo "  fail2ban-client status sshd          # ssh bans"
echo "  systemctl status logrotate.timer     # log rotation enabled"
echo "  sysctl net.ipv4.tcp_congestion_control   # should say bbr"
echo ""
echo -e "${RED}L3 volumetric (Gbps) still needs a DDoS-protected host/scrubber.${NC}"
echo "Install log: $LOG_FILE"
