#!/bin/bash
#
# Remnawave Node DDoS Shield Installer
# Ubuntu 22.04/24.04 compatible, error-resilient
# SSH open for all (Fail2Ban protects from brute force)
#

set +e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Static configuration
PANEL_IP="185.239.51.193"
NODE_API_PORT="8443"
VPN_PORT="443"

LOG_FILE="/var/log/node-shield-install.log"
mkdir -p "$(dirname $LOG_FILE)"
exec > >(tee -a "$LOG_FILE")
exec 2>&1

echo "========================================"
echo "Node Shield Installation"
echo "Panel IP: $PANEL_IP"
echo "Date: $(date)"
echo "========================================"

# Function to run commands
run_cmd() {
    local cmd="$1"
    local desc="$2"
    
    echo -e "${BLUE}[*] $desc${NC}"
    echo "[CMD] $cmd" >> "$LOG_FILE"
    
    if eval "$cmd" >> "$LOG_FILE" 2>&1; then
        echo -e "${GREEN}[✓] $desc - OK${NC}"
        return 0
    else
        echo -e "${YELLOW}[!] $desc - FAILED (continuing)${NC}"
        return 1
    fi
}

show_status() {
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}[PROGRESS] $1${NC}"
    echo -e "${GREEN}========================================${NC}"
}

# Auto-detect node IP
echo -e "${YELLOW}[!] Detecting node IP...${NC}"
NODE_IP=$(hostname -I | awk '{print $1}')
if [ -z "$NODE_IP" ]; then
    NODE_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+')
fi
if [ -z "$NODE_IP" ]; then
    NODE_IP=$(curl -s -4 ifconfig.me 2>/dev/null || echo "")
fi

if [ -z "$NODE_IP" ]; then
    echo -e "${RED}[✗] Could not detect node IP${NC}"
    read -p "Enter node IP manually: " NODE_IP
else
    echo -e "${GREEN}[✓] Detected node IP: $NODE_IP${NC}"
fi

IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
echo -e "${GREEN}[✓] Interface: $IFACE${NC}"

# STEP 1: Dependencies
show_status "STEP 1: Dependencies"
echo ""

run_cmd "apt-get update -qq" "Updating package lists"

apt-get upgrade -y >> "$LOG_FILE" 2>&1 && echo -e "${GREEN}[✓] Upgrading packages - OK${NC}" || echo -e "${YELLOW}[!] Upgrading packages - SKIPPED${NC}"

# Install packages one by one
echo -e "${BLUE}[*] Installing packages one by one...${NC}"

PACKAGES="curl wget htop iftop mc net-tools ethtool fail2ban ufw logrotate cron conntrack"
for pkg in $PACKAGES; do
    echo -n "  - $pkg: " | tee -a "$LOG_FILE"
    if apt-get install -y "$pkg" >> "$LOG_FILE" 2>&1; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}FAILED (continuing)${NC}"
    fi
done

# XDP packages (optional)
echo -e "${BLUE}[*] Installing XDP packages (optional)...${NC}"
XDP_PACKAGES="linux-tools-common linux-tools-generic linux-headers-generic llvm clang libelf-dev xdp-tools libxdp1"
for pkg in $XDP_PACKAGES; do
    echo -n "  - $pkg: " | tee -a "$LOG_FILE"
    if apt-get install -y "$pkg" >> "$LOG_FILE" 2>&1; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}FAILED${NC}"
    fi
done

# Docker
if ! command -v docker &> /dev/null; then
    echo -e "${BLUE}[*] Installing Docker...${NC}"
    if curl -fsSL https://get.docker.com | sh >> "$LOG_FILE" 2>&1; then
        echo -e "${GREEN}[✓] Docker installed${NC}"
    else
        echo -e "${YELLOW}[!] Docker install failed - install manually${NC}"
    fi
else
    echo -e "${GREEN}[✓] Docker already installed${NC}"
fi

# STEP 2: Sysctl
show_status "STEP 2: Kernel Hardening"
echo ""

cat > /etc/sysctl.d/99-remnanode-ddos.conf << 'EOF'
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 2
net.netfilter.nf_conntrack_max = 524288
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 15
net.ipv4.conf.all.rp_filter = 1
EOF

run_cmd "sysctl --system" "Applying sysctl settings"
echo "nf_conntrack" > /etc/modules-load.d/conntrack.conf

# STEP 3: File limits
show_status "STEP 3: File Limits"
echo ""

if ! grep -q "nofile 300000" /etc/security/limits.conf 2>/dev/null; then
    cat >> /etc/security/limits.conf << EOF
* soft nofile 300000
* hard nofile 300000
root soft nofile 300000
root hard nofile 300000
EOF
fi

mkdir -p /etc/systemd/system.conf.d/
cat > /etc/systemd/system.conf.d/limits.conf << 'EOF'
[Manager]
DefaultLimitNOFILE=300000
EOF
run_cmd "systemctl daemon-reload" "Reloading systemd"

# STEP 4: Network optimization
show_status "STEP 4: Network Optimization"
echo ""

if command -v ethtool &> /dev/null; then
    ethtool -G $IFACE rx 4096 tx 4096 2>/dev/null || true
    ethtool -K $IFACE gro off 2>/dev/null || true
fi

mkdir -p /etc/networkd-dispatcher/routable.d/
cat > "/etc/networkd-dispatcher/routable.d/10-ethtool-$IFACE" << EOF
#!/bin/bash
ethtool -G $IFACE rx 4096 tx 4096 2>/dev/null || true
ethtool -K $IFACE gro off gso off tso off ufo off 2>/dev/null || true
EOF
chmod +x "/etc/networkd-dispatcher/routable.d/10-ethtool-$IFACE"
echo -e "${GREEN}[✓] Network optimization configured${NC}"

# STEP 5: XDP (optional)
show_status "STEP 5: XDP/eBPF (optional)"
echo ""

if command -v xdp-loader &> /dev/null; then
    xdp-loader load -m skb -s xdp_pass $IFACE 2>/dev/null && echo -e "${GREEN}[✓] XDP loaded${NC}" || echo -e "${YELLOW}[!] XDP load failed${NC}"
    
    cat > /etc/systemd/system/xdp-load.service << EOF
[Unit]
Description=XDP Load
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/sbin/xdp-loader load -m skb -s xdp_pass $IFACE || true
ExecStop=/usr/sbin/xdp-loader unload $IFACE || true
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    systemctl enable xdp-load.service 2>/dev/null || true
else
    echo -e "${YELLOW}[!] XDP not available, skipping${NC}"
fi

# STEP 6: Server Shield
show_status "STEP 6: Server Shield (MAIN PROTECTION)"
echo ""

if bash <(curl -fsSL https://raw.githubusercontent.com/wrx861/server-shield/main/install.sh) >> "$LOG_FILE" 2>&1; then
    echo -e "${GREEN}[✓] Server Shield installed${NC}"
    
    shield l7 backend nftables 2>/dev/null || true
    shield l7 enable 2>/dev/null || true
    shield l7 limits syn 50 2>/dev/null || true
    shield l7 limits conn 100 2>/dev/null || true
    shield l7 limits rate 1000 2>/dev/null || true
    shield l7 vpn-ports add 443 2>/dev/null || true
    shield l7 vpn-ports add 8443 2>/dev/null || true
    shield l7 whitelist add $PANEL_IP 2>/dev/null || true
    shield l7 geo allow RU 2>/dev/null || true
    shield l7 geo deny all 2>/dev/null || true
    shield l7 tarpit enable 2>/dev/null || true
    shield l7 autoban enable 2>/dev/null || true
    
    echo -e "${GREEN}[✓] Server Shield configured (Russia only)${NC}"
else
    echo -e "${RED}[✗] Server Shield FAILED - install manually${NC}"
fi

# STEP 7: UFW Firewall (SSH открыт, Fail2Ban защищает)
show_status "STEP 7: UFW Firewall"
echo ""

ufw --force reset >> "$LOG_FILE" 2>&1 && echo -e "${GREEN}[✓] UFW reset${NC}" || echo -e "${YELLOW}[!] UFW reset failed${NC}"

# SSH открыт для всех (Fail2Ban с bantime=24h защищает от брута)
echo -n "  - SSH port 22: " | tee -a "$LOG_FILE"
ufw allow 22/tcp comment 'SSH - Fail2Ban protects from brute force' >> "$LOG_FILE" 2>&1 && echo -e "${GREEN}OK${NC}" || echo -e "${YELLOW}FAILED${NC}"

echo -n "  - VPN port 443: " | tee -a "$LOG_FILE"
ufw allow 443/tcp comment 'VLESS Reality' >> "$LOG_FILE" 2>&1 && echo -e "${GREEN}OK${NC}" || echo -e "${YELLOW}FAILED${NC}"

echo -n "  - API from panel ($PANEL_IP): " | tee -a "$LOG_FILE"
ufw allow from $PANEL_IP proto tcp to any port 8443 comment 'Remnanode API' >> "$LOG_FILE" 2>&1 && echo -e "${GREEN}OK${NC}" || echo -e "${YELLOW}FAILED${NC}"

echo -n "  - Enabling UFW: " | tee -a "$LOG_FILE"
ufw --force enable >> "$LOG_FILE" 2>&1 && echo -e "${GREEN}OK${NC}" || echo -e "${YELLOW}FAILED${NC}"

echo ""
echo -e "${BLUE}=== UFW Status ===${NC}"
ufw status verbose 2>/dev/null || echo "ufw status unavailable"

# STEP 8: Fail2Ban
show_status "STEP 8: Fail2Ban"
echo ""

if command -v fail2ban-client &> /dev/null; then
    cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local 2>/dev/null || true
    
    cat >> /etc/fail2ban/jail.local 2>/dev/null << 'EOF'

[sshd]
enabled = true
backend = systemd
maxretry = 2
findtime = 60
bantime = 86400
EOF
    
    systemctl enable fail2ban 2>/dev/null || true
    systemctl restart fail2ban 2>/dev/null && echo -e "${GREEN}[✓] Fail2Ban configured (bantime=24h)${NC}" || echo -e "${YELLOW}[!] Fail2Ban start failed${NC}"
else
    echo -e "${YELLOW}[!] Fail2Ban not installed${NC}"
fi

# STEP 9: Circuit Breaker
show_status "STEP 9: Circuit Breaker (Protects Panel)"
echo ""

cat > /usr/local/bin/circuit-breaker.sh << EOF
#!/bin/bash
PANEL_IP="$PANEL_IP"
CONN_MAX=\$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 524288)
CONN_NOW=\$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
[ "\$CONN_MAX" -eq 0 ] && CONN_MAX=524288
USAGE=\$(( CONN_NOW * 100 / CONN_MAX ))
LOG="/var/log/circuit-breaker.log"

if [ \$USAGE -gt 85 ]; then
    echo "\$(date): DDoS detected! Conntrack \$CONN_NOW/\$CONN_MAX (\$USAGE%). Blocking panel API 90s" >> \$LOG
    iptables -C OUTPUT -d \$PANEL_IP -p tcp --dport 8443 -j DROP 2>/dev/null || iptables -I OUTPUT -d \$PANEL_IP -p tcp --dport 8443 -j DROP
    sleep 90
    iptables -D OUTPUT -d \$PANEL_IP -p tcp --dport 8443 -j DROP 2>/dev/null || true
    echo "\$(date): Restored panel API" >> \$LOG
fi
EOF

chmod +x /usr/local/bin/circuit-breaker.sh
(crontab -l 2>/dev/null | grep -v circuit-breaker; echo "*/1 * * * * /usr/local/bin/circuit-breaker.sh") | crontab -
echo -e "${GREEN}[✓] Circuit breaker installed (runs every minute)${NC}"

iptables -N NODE_TO_PANEL 2>/dev/null || true
iptables -A NODE_TO_PANEL -d $PANEL_IP -p tcp --dport 8443 -m connlimit --connlimit-above 5 -j DROP 2>/dev/null || true
iptables -A NODE_TO_PANEL -d $PANEL_IP -p tcp --dport 8443 -m limit --limit 20/minute -j ACCEPT 2>/dev/null || true
iptables -I OUTPUT -j NODE_TO_PANEL 2>/dev/null || true

# STEP 10: Docker + Remnanode
show_status "STEP 10: Remnanode Setup"
echo ""

if command -v docker &> /dev/null; then
    mkdir -p /opt/remnanode /var/log/remnanode
    
    cat > /opt/remnanode/docker-compose.yml << 'EOF'
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
      - NODE_PORT=8443
      - SECRET_KEY="<GET_FROM_PANEL>"
    volumes:
      - /var/log/remnanode:/var/log/remnanode
EOF
    
    cat > /etc/logrotate.d/remnanode << 'EOF'
/var/log/remnanode/*.log {
    size 50M
    rotate 5
    compress
    missingok
    notifempty
    copytruncate
}
EOF
    
    cat > /etc/cron.d/remnawave-update << 'EOF'
0 11 * * 6 root cd /opt/remnanode && docker compose pull && docker compose down && docker compose up -d && docker image prune -f
EOF
    chmod 644 /etc/cron.d/remnawave-update
    echo -e "${GREEN}[✓] Remnanode config created${NC}"
else
    echo -e "${YELLOW}[!] Docker not available${NC}"
fi

# STEP 11: Save iptables rules
show_status "STEP 11: Saving Firewall Rules"
echo ""

mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4 2>/dev/null && echo -e "${GREEN}[✓] Rules saved${NC}" || echo -e "${YELLOW}[!] Save failed${NC}"

cat > /etc/systemd/system/iptables-restore.service << 'EOF'
[Unit]
Description=Restore iptables
Before=network-pre.target
[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
systemctl enable iptables-restore.service 2>/dev/null || true

# FINAL SUMMARY
show_status "INSTALLATION COMPLETE!"
echo ""

echo -e "${GREEN}Node IP:${NC}        $NODE_IP"
echo -e "${GREEN}Panel IP:${NC}       $PANEL_IP"
echo -e "${GREEN}SSH Access:${NC}     OPEN (port 22, Fail2Ban protects)"
echo -e "${GREEN}VPN Port:${NC}       443 (VLESS)"
echo -e "${GREEN}API Port:${NC}       8443 (Panel: $PANEL_IP only)"
echo ""

echo -e "${YELLOW}WHAT WAS CONFIGURED:${NC}"
echo "  ✓ Kernel hardening (sysctl)"
echo "  ✓ Server Shield - nftables, rate limiting, Russia geo"
echo "  ✓ UFW - 22 (SSH), 443 (VPN), 8443 (Panel only)"
echo "  ✓ Fail2Ban - SSH brute force protection (2 fails = 24h ban)"
echo "  ✓ Circuit Breaker - protects panel when node DDoS'd"
echo ""

echo -e "${YELLOW}NEXT STEPS:${NC}"
echo "1. ${GREEN}reboot${NC}"
echo "2. Edit ${BLUE}/opt/remnanode/docker-compose.yml${NC}, add SECRET_KEY"
echo "3. Run: ${BLUE}cd /opt/remnanode && docker compose up -d${NC}"
echo ""

echo -e "${YELLOW}VERIFICATION:${NC}"
echo "  shield l7 status         - Server Shield"
echo "  ufw status verbose       - Firewall"
echo "  fail2ban-client status   - Fail2Ban"
echo "  cat /var/log/circuit-breaker.log - DDoS events"
echo ""
echo "Log: $LOG_FILE"
