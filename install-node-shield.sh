#!/bin/bash
#
# Remnawave Node DDoS Shield Installer
# Auto-detects node IP, uses static panel IP: 185.239.51.193
# Port 443: VLESS clients, Port 8443: Node API (from panel only)
# Geo: Russia only (RU)
# Fixed for Ubuntu 22.04/24.04
#

set -e

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
    if eval "$cmd" >> "$LOG_FILE" 2>&1; then
        echo -e "${GREEN}[✓] $desc - OK${NC}"
        return 0
    else
        echo -e "${YELLOW}[!] $desc - FAILED (continuing)${NC}"
        return 1
    fi
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

# STEP 1: Dependencies (Ubuntu 22.04/24.04 compatible)
echo ""
echo "========================================"
echo "STEP 1: Dependencies"
echo "========================================"

run_cmd "apt-get update" "Updating packages" 
run_cmd "apt-get upgrade -y" "Upgrading packages"

# Base packages (always required)
BASE_PACKAGES="curl wget htop iftop mc net-tools ethtool fail2ban ufw logrotate cron iptables-persistent conntrack"
run_cmd "apt-get install -y $BASE_PACKAGES" "Installing base packages"

# Optional packages for XDP/eBPF (may fail on some VPS, not critical)
echo -e "${BLUE}[*] Installing XDP packages (optional)...${NC}"
XDP_PACKAGES="linux-tools-common linux-tools-generic linux-headers-generic llvm clang libelf-dev xdp-tools libxdp1"
apt-get install -y $XDP_PACKAGES >> "$LOG_FILE" 2>&1 && echo -e "${GREEN}[✓] XDP packages installed${NC}" || echo -e "${YELLOW}[!] XDP packages failed (non-critical, continuing)${NC}"

# Docker if not present
if ! command -v docker &> /dev/null; then
    run_cmd "curl -fsSL https://get.docker.com | sh" "Installing Docker"
fi

# STEP 2: Sysctl
echo ""
echo "========================================"
echo "STEP 2: Kernel Hardening"
echo "========================================"

cat > /etc/sysctl.d/99-remnanode-ddos.conf << 'EOF'
# VPN Performance
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1

# DDoS Protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 2
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 15

# ICMP hardening
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.send_redirects = 0

# Spoofing protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Connection tracking
net.netfilter.nf_conntrack_max = 524288
net.netfilter.nf_conntrack_tcp_timeout_established = 600
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 10
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 10
EOF

run_cmd "sysctl --system" "Applying sysctl"
run_cmd "echo 'nf_conntrack' >> /etc/modules-load.d/conntrack.conf" "Enabling conntrack"

# STEP 3: File limits
echo ""
echo "========================================"
echo "STEP 3: File Limits"
echo "========================================"

cat >> /etc/security/limits.conf << EOF
* soft nofile 300000
* hard nofile 300000
root soft nofile 300000
root hard nofile 300000
EOF

mkdir -p /etc/systemd/system.conf.d/
cat > /etc/systemd/system.conf.d/limits.conf << 'EOF'
[Manager]
DefaultLimitNOFILE=300000
EOF
run_cmd "systemctl daemon-reload" "Reloading systemd"

# STEP 4: Network optimization
echo ""
echo "========================================"
echo "STEP 4: Network Optimization"
echo "========================================"

run_cmd "ethtool -G $IFACE rx 4096 tx 4096 2>/dev/null || true" "Ring buffers"
run_cmd "ethtool -K $IFACE gro off gso off tso off ufo off 2>/dev/null || true" "Offloading"

mkdir -p /etc/networkd-dispatcher/routable.d/
cat > "/etc/networkd-dispatcher/routable.d/10-ethtool-$IFACE" << EOF
#!/bin/bash
ethtool -G $IFACE rx 4096 tx 4096 2>/dev/null || true
ethtool -K $IFACE gro off gso off tso off ufo off 2>/dev/null || true
EOF
chmod +x "/etc/networkd-dispatcher/routable.d/10-ethtool-$IFACE"

# STEP 5: XDP/eBPF (optional, may not work on all VPS)
echo ""
echo "========================================"
echo "STEP 5: XDP/eBPF (optional)"
echo "========================================"

if command -v xdp-loader &> /dev/null; then
    run_cmd "xdp-loader load -m skb -s xdp_pass $IFACE 2>/dev/null || echo 'XDP load failed, continuing'" "Loading XDP"
    
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
    run_cmd "systemctl enable xdp-load.service 2>/dev/null || true" "Enabling XDP service"
else
    echo -e "${YELLOW}[!] XDP not available, skipping (Server Shield will handle protection)${NC}"
fi

# STEP 6: Server Shield
echo ""
echo "========================================"
echo "STEP 6: Server Shield"
echo "========================================"

run_cmd "bash <(curl -fsSL https://raw.githubusercontent.com/wrx861/server-shield/main/install.sh)" "Installing Shield"

run_cmd "shield l7 backend nftables 2>/dev/null || true" "Setting nftables"
run_cmd "shield l7 enable 2>/dev/null || true" "Enabling L7"

run_cmd "shield l7 limits syn 50 2>/dev/null || true" "SYN limit"
run_cmd "shield l7 limits conn 100 2>/dev/null || true" "Conn limit"
run_cmd "shield l7 limits rate 1000 2>/dev/null || true" "Rate limit"

run_cmd "shield l7 vpn-ports add 443 2>/dev/null || true" "VPN port 443"
run_cmd "shield l7 vpn-ports add 8443 2>/dev/null || true" "API port 8443"

run_cmd "shield l7 whitelist add $PANEL_IP 2>/dev/null || true" "Whitelisting panel"

echo -e "${BLUE}[*] Configuring GeoIP (Russia only)...${NC}"
run_cmd "shield l7 geo allow RU 2>/dev/null || true" "Allowing RU"
run_cmd "shield l7 geo deny all 2>/dev/null || true" "Deny all others"

run_cmd "shield l7 tarpit enable 2>/dev/null || true" "Tarpit"
run_cmd "shield l7 autoban enable 2>/dev/null || true" "Autoban"

echo -e "${GREEN}[✓] Shield configured (Russia only)${NC}"

# STEP 7: UFW
echo ""
echo "========================================"
echo "STEP 7: UFW Firewall"
echo "========================================"

run_cmd "ufw --force reset 2>/dev/null || true" "Resetting UFW"
run_cmd "ufw allow $VPN_PORT/tcp comment 'VLESS Reality'" "VPN port $VPN_PORT"
run_cmd "ufw allow from $PANEL_IP proto tcp to any port $NODE_API_PORT comment 'Remnanode API - Panel only'" "API from panel only"
run_cmd "ufw --force enable" "Enabling UFW"
run_cmd "ufw status verbose" "UFW status"

# STEP 8: Fail2Ban
echo ""
echo "========================================"
echo "STEP 8: Fail2Ban"
echo "========================================"

run_cmd "cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local 2>/dev/null || true" "Copying jail config"

cat >> /etc/fail2ban/jail.local 2>/dev/null << 'EOF'

[sshd]
enabled = true
backend = systemd
maxretry = 2
findtime = 60
bantime = 86400

[recidive]
enabled = true
logpath = /var/log/fail2ban.log
banaction = iptables-allports
bantime = 604800
findtime = 86400
maxretry = 5
EOF

run_cmd "systemctl enable fail2ban 2>/dev/null || true" "Enabling fail2ban"
run_cmd "systemctl restart fail2ban 2>/dev/null || true" "Starting fail2ban"

# STEP 9: Circuit Breaker
echo ""
echo "========================================"
echo "STEP 9: Circuit Breaker"
echo "========================================"

cat > /usr/local/bin/circuit-breaker.sh << EOF
#!/bin/bash
PANEL_IP="$PANEL_IP"
CONN_MAX=\$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 524288)
CONN_NOW=\$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
USAGE=\$(( CONN_NOW * 100 / CONN_MAX ))
LOG="/var/log/circuit-breaker.log"

if [ \$USAGE -gt 85 ]; then
    echo "\$(date '+%Y-%m-%d %H:%M:%S'): DDoS detected! Conntrack \$CONN_NOW/\$CONN_MAX (\$USAGE%). Blocking panel API for 90s" >> \$LOG
    iptables -C OUTPUT -d \$PANEL_IP -p tcp --dport $NODE_API_PORT -j DROP 2>/dev/null || iptables -I OUTPUT -d \$PANEL_IP -p tcp --dport $NODE_API_PORT -j DROP
    sleep 90
    iptables -D OUTPUT -d \$PANEL_IP -p tcp --dport $NODE_API_PORT -j DROP 2>/dev/null || true
    echo "\$(date '+%Y-%m-%d %H:%M:%S'): Restored panel API" >> \$LOG
fi
EOF

chmod +x /usr/local/bin/circuit-breaker.sh
(crontab -l 2>/dev/null | grep -v circuit-breaker; echo "*/1 * * * * /usr/local/bin/circuit-breaker.sh") | crontab -

iptables -N NODE_TO_PANEL 2>/dev/null || true
iptables -C NODE_TO_PANEL -d $PANEL_IP -p tcp --dport $NODE_API_PORT -m connlimit --connlimit-above 5 -j DROP 2>/dev/null || \
    iptables -A NODE_TO_PANEL -d $PANEL_IP -p tcp --dport $NODE_API_PORT -m connlimit --connlimit-above 5 -j DROP 2>/dev/null || true
iptables -C NODE_TO_PANEL -d $PANEL_IP -p tcp --dport $NODE_API_PORT -m limit --limit 20/minute -j ACCEPT 2>/dev/null || \
    iptables -A NODE_TO_PANEL -d $PANEL_IP -p tcp --dport $NODE_API_PORT -m limit --limit 20/minute -j ACCEPT 2>/dev/null || true
iptables -C OUTPUT -j NODE_TO_PANEL 2>/dev/null || iptables -I OUTPUT -j NODE_TO_PANEL 2>/dev/null || true

echo -e "${GREEN}[✓] Circuit breaker installed${NC}"

# STEP 10: Docker + Remnanode
echo ""
echo "========================================"
echo "STEP 10: Remnanode Setup"
echo "========================================"

run_cmd "mkdir -p /opt/remnanode /var/log/remnanode" "Creating directories"

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

# STEP 11: Save rules
echo ""
echo "========================================"
echo "STEP 11: Saving Rules"
echo "========================================"

mkdir -p /etc/iptables
run_cmd "iptables-save > /etc/iptables/rules.v4" "Saving iptables"

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
run_cmd "systemctl enable iptables-restore.service 2>/dev/null || true" "Enabling iptables restore"

# DONE
echo ""
echo "========================================"
echo "INSTALLATION COMPLETE!"
echo "========================================"
echo "Node IP: $NODE_IP"
echo "Panel IP: $PANEL_IP"
echo ""
echo "NEXT STEPS:"
echo "1. reboot"
echo "2. Edit /opt/remnanode/docker-compose.yml, set SECRET_KEY from panel"
echo "3. cd /opt/remnanode && docker compose up -d"
echo "4. Check panel - node should be online"
echo ""
echo "Verify: shield l7 status"
echo "        ufw status verbose"
echo "Log: $LOG_FILE"
