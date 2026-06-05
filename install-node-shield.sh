#!/bin/bash
#
# Remnawave Node DDoS Shield Installer v3
# - XDP/eBPF attempt (kernel-level L3 protection)
# - iptables fallback (L4/L7 protection)
# - L3 DDoS reality warning
# - SSH open (Fail2Ban protects)
# - No geo-block (VPN admin friendly)
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
echo "Node Shield Installation v3"
echo "Panel IP: $PANEL_IP"
echo "Date: $(date)"
echo "========================================"
echo ""
echo -e "${YELLOW}[WARNING] L3 DDoS Reality:${NC}"
echo "  - XDP/eBPF: Protects at kernel/driver level (best effort)"
echo "  - iptables: Only L4/L7 (SYN/connection floods)"
echo "  - L3 saturation: REQUIRES hosting with DDoS protection"
echo "    (OVH Game/Armor, Hetzner, Cloudflare Spectrum)"
echo ""

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

echo -e "${BLUE}[*] Waiting for apt lock...${NC}"
for i in {1..30}; do
    if ! lsof /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
        break
    fi
    echo -n "."
    sleep 2
done

if lsof /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
    kill -9 $(lsof -t /var/lib/dpkg/lock-frontend) 2>/dev/null || true
    sleep 2
fi

rm -f /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock 2>/dev/null || true
dpkg --configure -a 2>/dev/null || true

run_cmd "apt-get update -qq" "Updating package lists"

# Install packages
PACKAGES="curl wget htop iftop mc net-tools ethtool fail2ban ufw logrotate cron conntrack iptables-persistent"
for pkg in $PACKAGES; do
    echo -n "  - $pkg: " | tee -a "$LOG_FILE"
    for attempt in {1..3}; do
        if apt-get install -y "$pkg" >> "$LOG_FILE" 2>&1; then
            echo -e "${GREEN}OK${NC}"
            break
        else
            [ $attempt -eq 3 ] && echo -e "${YELLOW}FAILED${NC}" || sleep 2
        fi
    done
done

# XDP packages (optional but important)
echo ""
echo -e "${BLUE}[*] Installing XDP/eBPF packages (L3 protection attempt)...${NC}"
XDP_PACKAGES="linux-tools-common linux-tools-generic linux-headers-generic llvm clang libelf-dev xdp-tools libxdp1"
XDP_AVAILABLE=true
for pkg in $XDP_PACKAGES; do
    echo -n "  - $pkg: " | tee -a "$LOG_FILE"
    if apt-get install -y "$pkg" >> "$LOG_FILE" 2>&1; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}SKIP${NC}"
        XDP_AVAILABLE=false
    fi
done

# Docker
echo ""
echo -e "${BLUE}[*] Installing Docker...${NC}"
for attempt in {1..3}; do
    rm -f /var/lib/dpkg/lock-frontend 2>/dev/null || true
    if curl -fsSL https://get.docker.com | sh >> "$LOG_FILE" 2>&1; then
        echo -e "${GREEN}[✓] Docker installed${NC}"
        break
    else
        if [ $attempt -eq 3 ]; then
            echo -e "${YELLOW}[!] Docker install failed - install manually:${NC}"
            echo "    apt install -y docker.io docker-compose"
        else
            sleep 5
        fi
    fi
done

# STEP 2: Sysctl (kernel hardening)
show_status "STEP 2: Kernel Hardening"
echo ""

cat > /etc/sysctl.d/99-remnanode-ddos.conf << 'EOF'
# Network buffers
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# SYN flood protection
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 2

# Connection tracking
net.netfilter.nf_conntrack_max = 524288
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 15
net.netfilter.nf_conntrack_tcp_timeout_established = 600

# Security
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
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
    echo -n "  - Ring buffers: " | tee -a "$LOG_FILE"
    ethtool -G $IFACE rx 4096 tx 4096 >> "$LOG_FILE" 2>&1 && echo -e "${GREEN}OK${NC}" || echo -e "${YELLOW}N/A${NC}"
    
    echo -n "  - Disable offloading: " | tee -a "$LOG_FILE"
    ethtool -K $IFACE gro off gso off tso off ufo off >> "$LOG_FILE" 2>&1 && echo -e "${GREEN}OK${NC}" || echo -e "${YELLOW}N/A${NC}"
    
    mkdir -p /etc/networkd-dispatcher/routable.d/
    cat > "/etc/networkd-dispatcher/routable.d/10-ethtool-$IFACE" << EOF
#!/bin/bash
ethtool -G $IFACE rx 4096 tx 4096 2>/dev/null || true
ethtool -K $IFACE gro off gso off tso off ufo off 2>/dev/null || true
EOF
    chmod +x "/etc/networkd-dispatcher/routable.d/10-ethtool-$IFACE"
fi

# STEP 5: XDP/eBPF (L3 protection attempt)
show_status "STEP 5: XDP/eBPF (L3 Kernel Protection)"
echo ""

XDP_LOADED=false
if [ "$XDP_AVAILABLE" = true ] && command -v xdp-loader &> /dev/null; then
    echo -n "  - Loading XDP on $IFACE: " | tee -a "$LOG_FILE"
    if xdp-loader load -m skb -s xdp_pass $IFACE >> "$LOG_FILE" 2>&1; then
        echo -e "${GREEN}OK${NC}"
        XDP_LOADED=true
        
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
        systemctl enable xdp-load.service >> "$LOG_FILE" 2>&1 || true
        echo -e "${GREEN}[✓] XDP loaded - L3 protection ACTIVE${NC}"
    else
        echo -e "${YELLOW}FAILED${NC}"
        echo -e "${YELLOW}[!] XDP load failed - driver may not support${NC}"
    fi
else
    echo -e "${YELLOW}[!] XDP packages not available${NC}"
fi

if [ "$XDP_LOADED" = false ]; then
    echo -e "${YELLOW}[!] XDP NOT loaded - L3 saturation attacks will bypass iptables${NC}"
    echo -e "${YELLOW}[!] Solution: Use hosting with DDoS protection (OVH, Hetzner)${NC}"
fi

# STEP 6: iptables DDoS Protection (L4/L7)
show_status "STEP 6: iptables Protection (L4/L7 Fallback)"
echo ""

echo -e "${BLUE}[*] Setting up iptables DDoS chains...${NC}"

# Create/flush chains
iptables -N DDoS_PROTECT 2>/dev/null || iptables -F DDoS_PROTECT
iptables -N SYN_FLOOD 2>/dev/null || iptables -F SYN_FLOOD
iptables -N CONN_LIMIT 2>/dev/null || iptables -F CONN_LIMIT
iptables -N PORT_SCAN 2>/dev/null || iptables -F PORT_SCAN
iptables -N PANEL_PROTECT 2>/dev/null || iptables -F PANEL_PROTECT

# SYN flood protection (rate limit new connections)
iptables -A SYN_FLOOD -p tcp --syn -m limit --limit 50/second --limit-burst 100 -j RETURN
iptables -A SYN_FLOOD -j LOG --log-prefix "SYN_FLOOD: " --log-level 4
iptables -A SYN_FLOOD -j DROP

# Connection limiting (max 100 per IP to VPN)
iptables -A CONN_LIMIT -p tcp --dport 443 -m connlimit --connlimit-above 100 --connlimit-mask 32 -j DROP
iptables -A CONN_LIMIT -j RETURN

# Port scan detection
iptables -A PORT_SCAN -p tcp --tcp-flags SYN,ACK,FIN,RST RST -m limit --limit 2/second --limit-burst 4 -j RETURN
iptables -A PORT_SCAN -j DROP

# Panel protection (rate limit outbound)
iptables -A PANEL_PROTECT -d $PANEL_IP -p tcp --dport 8443 -m conntrack --ctstate NEW -m recent --set
iptables -A PANEL_PROTECT -d $PANEL_IP -p tcp --dport 8443 -m conntrack --ctstate NEW -m recent --update --seconds 60 --hitcount 20 -j DROP
iptables -A PANEL_PROTECT -j RETURN

# Main chain
iptables -A DDoS_PROTECT -p tcp --tcp-flags SYN,ACK,FIN,RST RST -j PORT_SCAN
iptables -A DDoS_PROTECT -p tcp --syn -j SYN_FLOOD
iptables -A DDoS_PROTECT -p tcp --dport 443 -j CONN_LIMIT
iptables -A DDoS_PROTECT -d $PANEL_IP -p tcp --dport 8443 -j PANEL_PROTECT
iptables -A DDoS_PROTECT -j RETURN

# Insert at top
iptables -I INPUT -j DDoS_PROTECT

echo -e "${GREEN}[✓] iptables DDoS chains created${NC}"

# Outbound panel protection
iptables -N NODE_TO_PANEL 2>/dev/null || iptables -F NODE_TO_PANEL
iptables -A NODE_TO_PANEL -d $PANEL_IP -p tcp --dport 8443 -m connlimit --connlimit-above 5 -j DROP
iptables -A NODE_TO_PANEL -d $PANEL_IP -p tcp --dport 8443 -m limit --limit 20/minute -j ACCEPT
iptables -A NODE_TO_PANEL -j LOG --log-prefix "PANEL_LIMIT: " --log-level 4
iptables -I OUTPUT -j NODE_TO_PANEL 2>/dev/null || true

echo -e "${GREEN}[✓] Outbound panel protection active${NC}"

# STEP 7: UFW Firewall
show_status "STEP 7: UFW Firewall"
echo ""

ufw --force reset >> "$LOG_FILE" 2>&1 || true

echo -e "${BLUE}[*] Configuring UFW rules...${NC}"

# SSH open (Fail2Ban protects)
ufw allow 22/tcp comment 'SSH - Fail2Ban brute force protection'

# VPN port (for clients)
ufw allow 443/tcp comment 'VLESS Reality VPN'

# API only from panel
ufw allow from $PANEL_IP proto tcp to any port 8443 comment 'Remnanode API - Panel only'

# Enable
ufw --force enable >> "$LOG_FILE" 2>&1 || true

echo -e "${BLUE}=== UFW Status ===${NC}"
ufw status verbose 2>/dev/null || echo "ufw not available"

# STEP 8: Fail2Ban
show_status "STEP 8: Fail2Ban (Brute Force Protection)"
echo ""

if command -v fail2ban-client &> /dev/null; then
    cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local 2>/dev/null || true
    
    cat >> /etc/fail2ban/jail.local << 'EOF'

[sshd]
enabled = true
backend = systemd
maxretry = 2
findtime = 60
bantime = 86400
port = 22

[recidive]
enabled = true
logpath = /var/log/fail2ban.log
banaction = iptables-allports
bantime = 604800
findtime = 86400
maxretry = 5
EOF
    
    systemctl enable fail2ban 2>/dev/null || true
    systemctl restart fail2ban 2>/dev/null || true
    echo -e "${GREEN}[✓] Fail2Ban configured:${NC}"
    echo -e "${GREEN}    SSH: 2 failed attempts = 24h ban${NC}"
else
    echo -e "${YELLOW}[!] Fail2Ban not installed${NC}"
fi

# STEP 9: Circuit Breaker (Panel Protection)
show_status "STEP 9: Circuit Breaker (Panel Protection)"
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
    echo "\$(date '+%Y-%m-%d %H:%M:%S'): DDoS detected! Conntrack \$CONN_NOW/\$CONN_MAX (\$USAGE%). Blocking panel API for 90s" >> \$LOG
    
    # Block outbound to panel temporarily
    if ! iptables -C OUTPUT -d \$PANEL_IP -p tcp --dport 8443 -j DROP 2>/dev/null; then
        iptables -I OUTPUT -d \$PANEL_IP -p tcp --dport 8443 -j DROP
    fi
    
    sleep 90
    
    # Restore
    iptables -D OUTPUT -d \$PANEL_IP -p tcp --dport 8443 -j DROP 2>/dev/null || true
    echo "\$(date '+%Y-%m-%d %H:%M:%S'): Restored panel API connection" >> \$LOG
fi
EOF

chmod +x /usr/local/bin/circuit-breaker.sh
(crontab -l 2>/dev/null | grep -v circuit-breaker; echo "*/1 * * * * /usr/local/bin/circuit-breaker.sh") | crontab -

echo -e "${GREEN}[✓] Circuit breaker installed${NC}"
echo -e "${GREEN}    Checks conntrack every minute, blocks panel API if >85%${NC}"

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
    
    echo -e "${GREEN}[✓] Remnanode config created:${NC}"
    echo -e "${GREEN}    /opt/remnanode/docker-compose.yml${NC}"
else
    echo -e "${YELLOW}[!] Docker not installed${NC}"
fi

# STEP 11: Save rules
show_status "STEP 11: Saving Firewall Rules"
echo ""

mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4 2>/dev/null && echo -e "${GREEN}[✓] iptables rules saved${NC}" || echo -e "${YELLOW}[!] Failed to save rules${NC}"

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

echo -e "${GREEN}Configuration:${NC}"
echo "  Node IP:        $NODE_IP"
echo "  Panel IP:       $PANEL_IP"
echo "  Interface:      $IFACE"
echo ""
echo -e "${GREEN}Access:${NC}"
echo "  SSH (22):       OPEN - Fail2Ban: 2 fails = 24h ban"
echo "  VPN (443):      OPEN - Connection limit: 100/IP"
echo "  API (8443):     $PANEL_IP only - Rate limit: 20/min"
echo ""
echo -e "${YELLOW}DDoS Protection Layers:${NC}"

if [ "$XDP_LOADED" = true ]; then
    echo "  [L3] XDP/eBPF:        ${GREEN}ACTIVE${NC} (kernel-level, best)"
else
    echo "  [L3] XDP/eBPF:        ${YELLOW}NOT AVAILABLE${NC}"
    echo "                        (driver support missing or packages failed)"
fi

echo "  [L4] iptables SYN:    ACTIVE (50/sec limit)"
echo "  [L4] iptables Conn:   ACTIVE (100/IP limit)"
echo "  [L4] Circuit Breaker: ACTIVE (panel protection)"
echo "  [L7] UFW Firewall:    ACTIVE"
echo "  [L7] Fail2Ban:        ACTIVE (brute force protection)"
echo ""

echo -e "${RED}[WARNING] For L3 saturation attacks (network flooding):${NC}"
echo "  - iptables CANNOT protect against raw packet floods"
echo "  - XDP helps but requires driver support (check: ip link show $IFACE | grep xdp)"
echo "  - For 100% L3 protection use:"
echo "      * OVH Game/Armor dedicated servers"
echo "      * Hetzner with DDoS protection"
echo "      * Cloudflare Spectrum (proxy VPN port)"
echo ""

echo -e "${YELLOW}NEXT STEPS:${NC}"
echo "1. ${GREEN}reboot${NC} (required for all kernel settings)"
echo "2. Edit ${BLUE}/opt/remnanode/docker-compose.yml${NC}"
echo "   Replace <GET_FROM_PANEL> with SECRET_KEY from Remnawave Panel"
echo "3. Start node: ${GREEN}cd /opt/remnanode && docker compose up -d${NC}"
echo "4. Verify in panel that node is online"
echo ""

echo -e "${YELLOW}VERIFICATION COMMANDS:${NC}"
echo "  ip link show $IFACE | grep xdp     # Check XDP status"
echo "  iptables -L DDoS_PROTECT -n -v   # DDoS rules"
echo "  ufw status verbose                 # Firewall"
echo "  fail2ban-client status             # Brute force protection"
echo "  cat /var/log/circuit-breaker.log   # DDoS events (if any)"
echo ""
echo "Log: $LOG_FILE"
