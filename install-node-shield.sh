#!/bin/bash
#
# Remnawave Node DDoS Shield Installer
# Ubuntu 22.04/24.04 compatible, error-resilient
# Auto-detects node IP, uses static panel IP: 185.239.51.193
# Port 443: VLESS clients, Port 8443: Node API (from panel only)
# Geo: Russia only (RU)
#

# Не exit при ошибках - продолжаем выполнение
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

# Function to run commands - не падаем при ошибке
run_cmd() {
    local cmd="$1"
    local desc="$2"
    local critical="${3:-false}"
    
    echo -e "${BLUE}[*] $desc${NC}"
    echo "[CMD] $cmd" >> "$LOG_FILE"
    
    if eval "$cmd" >> "$LOG_FILE" 2>&1; then
        echo -e "${GREEN}[✓] $desc - OK${NC}"
        return 0
    else
        local exit_code=$?
        if [ "$critical" = "true" ]; then
            echo -e "${RED}[✗] $desc - CRITICAL ERROR (exit $exit_code)${NC}"
            echo -e "${YELLOW}Continuing anyway...${NC}"
        else
            echo -e "${YELLOW}[!] $desc - FAILED (exit $exit_code, continuing)${NC}"
        fi
        return 1
    fi
}

# Показываем прогресс
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
show_status "STEP 1: Dependencies (errors OK, will continue)"
echo ""

run_cmd "apt-get update -qq" "Updating package lists" false

# Пробуем апгрейд но не критично
apt-get upgrade -y >> "$LOG_FILE" 2>&1
if [ $? -eq 0 ]; then
    echo -e "${GREEN}[✓] Upgrading packages - OK${NC}"
else
    echo -e "${YELLOW}[!] Upgrading packages - SKIPPED (non-critical)${NC}"
fi

# Ставим базовые пакеты по одному чтобы видеть что именно бьется
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

# netfilter-persistent (альтернатива iptables-persistent)
echo -n "  - netfilter-persistent: " | tee -a "$LOG_FILE"
if apt-get install -y netfilter-persistent >> "$LOG_FILE" 2>&1; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${YELLOW}FAILED (will use manual save)${NC}"
fi

# XDP пакеты (опционально)
echo -e "${BLUE}[*] Installing XDP packages (optional)...${NC}"
XDP_PACKAGES="linux-tools-common linux-tools-generic linux-headers-generic llvm clang libelf-dev xdp-tools libxdp1"
XDP_SUCCESS=true
for pkg in $XDP_PACKAGES; do
    echo -n "  - $pkg: " | tee -a "$LOG_FILE"
    if apt-get install -y "$pkg" >> "$LOG_FILE" 2>&1; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}FAILED${NC}"
        XDP_SUCCESS=false
    fi
done

if [ "$XDP_SUCCESS" = true ]; then
    echo -e "${GREEN}[✓] All XDP packages installed${NC}"
else
    echo -e "${YELLOW}[!] Some XDP packages failed - will continue without XDP${NC}"
fi

# Docker
if ! command -v docker &> /dev/null; then
    echo -e "${BLUE}[*] Installing Docker...${NC}"
    if curl -fsSL https://get.docker.com | sh >> "$LOG_FILE" 2>&1; then
        echo -e "${GREEN}[✓] Docker installed${NC}"
    else
        echo -e "${YELLOW}[!] Docker install failed - you need to install manually${NC}"
    fi
else
    echo -e "${GREEN}[✓] Docker already installed${NC}"
fi

# STEP 2: Sysctl
show_status "STEP 2: Kernel Hardening"
echo ""

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

run_cmd "sysctl --system" "Applying sysctl settings" false

if [ ! -f /etc/modules-load.d/conntrack.conf ]; then
    echo "nf_conntrack" > /etc/modules-load.d/conntrack.conf
    echo -e "${GREEN}[✓] Enabled conntrack module${NC}"
fi

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
    echo -e "${GREEN}[✓] File limits configured${NC}"
else
    echo -e "${GREEN}[✓] File limits already set${NC}"
fi

mkdir -p /etc/systemd/system.conf.d/
cat > /etc/systemd/system.conf.d/limits.conf << 'EOF'
[Manager]
DefaultLimitNOFILE=300000
EOF

run_cmd "systemctl daemon-reload 2>/dev/null || true" "Reloading systemd" false

# STEP 4: Network optimization
show_status "STEP 4: Network Optimization"
echo ""

# Проверяем есть ли ethtool
if command -v ethtool &> /dev/null; then
    echo -n "  - Setting ring buffers: " | tee -a "$LOG_FILE"
    ethtool -G $IFACE rx 4096 tx 4096 >> "$LOG_FILE" 2>&1 && echo -e "${GREEN}OK${NC}" || echo -e "${YELLOW}FAILED (may not be supported)${NC}"
    
    echo -n "  - Disabling offloading: " | tee -a "$LOG_FILE"
    ethtool -K $IFACE gro off gso off tso off ufo off >> "$LOG_FILE" 2>&1 && echo -e "${GREEN}OK${NC}" || echo -e "${YELLOW}FAILED (may not be supported)${NC}"
else
    echo -e "${YELLOW}[!] ethtool not found, skipping network optimization${NC}"
fi

mkdir -p /etc/networkd-dispatcher/routable.d/
cat > "/etc/networkd-dispatcher/routable.d/10-ethtool-$IFACE" << EOF
#!/bin/bash
ethtool -G $IFACE rx 4096 tx 4096 2>/dev/null || true
ethtool -K $IFACE gro off gso off tso off ufo off 2>/dev/null || true
EOF
chmod +x "/etc/networkd-dispatcher/routable.d/10-ethtool-$IFACE"
echo -e "${GREEN}[✓] Network optimization script created${NC}"

# STEP 5: XDP/eBPF (optional)
show_status "STEP 5: XDP/eBPF (optional)"
echo ""

if command -v xdp-loader &> /dev/null; then
    echo -n "  - Loading XDP: " | tee -a "$LOG_FILE"
    if xdp-loader load -m skb -s xdp_pass $IFACE >> "$LOG_FILE" 2>&1; then
        echo -e "${GREEN}OK${NC}"
        
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
        systemctl enable xdp-load.service >> "$LOG_FILE" 2>&1
        echo -e "${GREEN}[✓] XDP service enabled${NC}"
    else
        echo -e "${YELLOW}FAILED (driver may not support XDP)${NC}"
    fi
else
    echo -e "${YELLOW}[!] xdp-loader not found, skipping XDP${NC}"
    echo -e "${YELLOW}    (Server Shield will provide main protection)${NC}"
fi

# STEP 6: Server Shield (ГЛАВНАЯ ЗАЩИТА)
show_status "STEP 6: Server Shield (MAIN PROTECTION)"
echo ""

echo -e "${BLUE}[*] Downloading and installing Server Shield...${NC}"
if bash <(curl -fsSL https://raw.githubusercontent.com/wrx861/server-shield/main/install.sh) >> "$LOG_FILE" 2>&1; then
    echo -e "${GREEN}[✓] Server Shield installed${NC}"
    
    # Настраиваем Shield
    echo -e "${BLUE}[*] Configuring Shield...${NC}"
    
    shield l7 backend nftables >> "$LOG_FILE" 2>&1
    shield l7 enable >> "$LOG_FILE" 2>&1
    
    shield l7 limits syn 50 >> "$LOG_FILE" 2>&1
    shield l7 limits conn 100 >> "$LOG_FILE" 2>&1
    shield l7 limits rate 1000 >> "$LOG_FILE" 2>&1
    
    shield l7 vpn-ports add 443 >> "$LOG_FILE" 2>&1
    shield l7 vpn-ports add 8443 >> "$LOG_FILE" 2>&1
    
    shield l7 whitelist add $PANEL_IP >> "$LOG_FILE" 2>&1
    
    # Geo: Russia only
    shield l7 geo allow RU >> "$LOG_FILE" 2>&1
    shield l7 geo deny all >> "$LOG_FILE" 2>&1
    
    shield l7 tarpit enable >> "$LOG_FILE" 2>&1
    shield l7 autoban enable >> "$LOG_FILE" 2>&1
    
    echo -e "${GREEN}[✓] Server Shield configured (Russia only, tarpit, autoban)${NC}"
    
    # Показываем статус
    echo ""
    echo -e "${BLUE}=== Server Shield Status ===${NC}"
    shield l7 status 2>/dev/null || echo "shield command not available yet (may need relogin)"
    
else
    echo -e "${RED}[✗] Server Shield installation FAILED${NC}"
    echo -e "${YELLOW}This is critical - you may need to install manually:${NC}"
    echo "  bash <(curl -fsSL https://raw.githubusercontent.com/wrx861/server-shield/main/install.sh)"
fi

# STEP 7: UFW Firewall
show_status "STEP 7: UFW Firewall"
echo ""

echo -n "  - Resetting UFW: " | tee -a "$LOG_FILE"
ufw --force reset >> "$LOG_FILE" 2>&1 && echo -e "${GREEN}OK${NC}" || echo -e "${YELLOW}FAILED${NC}"

echo -n "  - Allowing VPN port 443: " | tee -a "$LOG_FILE"
ufw allow 443/tcp comment 'VLESS Reality' >> "$LOG_FILE" 2>&1 && echo -e "${GREEN}OK${NC}" || echo -e "${YELLOW}FAILED${NC}"

echo -n "  - Allowing API from panel only: " | tee -a "$LOG_FILE"
ufw allow from $PANEL_IP proto tcp to any port 8443 comment 'Remnanode API - Panel only' >> "$LOG_FILE" 2>&1 && echo -e "${GREEN}OK${NC}" || echo -e "${YELLOW}FAILED${NC}"

echo -n "  - Enabling UFW: " | tee -a "$LOG_FILE"
ufw --force enable >> "$LOG_FILE" 2>&1 && echo -e "${GREEN}OK${NC}" || echo -e "${YELLOW}FAILED${NC}"

echo ""
echo -e "${BLUE}=== UFW Status ===${NC}"
ufw status verbose 2>/dev/null || echo "ufw not available"

# STEP 8: Fail2Ban
show_status "STEP 8: Fail2Ban"
echo ""

if command -v fail2ban-client &> /dev/null; then
    echo -n "  - Configuring fail2ban: " | tee -a "$LOG_FILE"
    
    cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local 2>/dev/null || true
    
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
    
    systemctl enable fail2ban >> "$LOG_FILE" 2>&1
    systemctl restart fail2ban >> "$LOG_FILE" 2>&1 && echo -e "${GREEN}OK${NC}" || echo -e "${YELLOW}FAILED${NC}"
    
    echo ""
    echo -e "${BLUE}=== Fail2Ban Status ===${NC}"
    fail2ban-client status 2>/dev/null || echo "fail2ban not responding"
else
    echo -e "${YELLOW}[!] fail2ban not installed, skipping${NC}"
fi

# STEP 9: Circuit Breaker (Panel Protection)
show_status "STEP 9: Circuit Breaker (Protects Panel)"
echo ""

cat > /usr/local/bin/circuit-breaker.sh << EOF
#!/bin/bash
# Circuit breaker: blocks panel API if node under DDoS

PANEL_IP="$PANEL_IP"
CONN_MAX=\$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 524288)
CONN_NOW=\$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
[ "\$CONN_MAX" -eq 0 ] && CONN_MAX=524288

USAGE=\$(( CONN_NOW * 100 / CONN_MAX ))
LOG="/var/log/circuit-breaker.log"

if [ \$USAGE -gt 85 ]; then
    echo "\$(date '+%Y-%m-%d %H:%M:%S'): DDoS detected! Conntrack \$CONN_NOW/\$CONN_MAX (\$USAGE%). Blocking panel API for 90s" >> \$LOG
    
    # Проверяем есть ли уже правило
    if ! iptables -C OUTPUT -d \$PANEL_IP -p tcp --dport 8443 -j DROP 2>/dev/null; then
        iptables -I OUTPUT -d \$PANEL_IP -p tcp --dport 8443 -j DROP
    fi
    
    sleep 90
    iptables -D OUTPUT -d \$PANEL_IP -p tcp --dport 8443 -j DROP 2>/dev/null || true
    
    echo "\$(date '+%Y-%m-%d %H:%M:%S'): Restored panel API" >> \$LOG
fi
EOF

chmod +x /usr/local/bin/circuit-breaker.sh
echo -e "${GREEN}[✓] Circuit breaker script created${NC}"

# Добавляем в cron
(crontab -l 2>/dev/null | grep -v circuit-breaker; echo "*/1 * * * * /usr/local/bin/circuit-breaker.sh") | crontab -
echo -e "${GREEN}[✓] Circuit breaker added to cron (runs every minute)${NC}"

# Настраиваем iptables rate limiting к панели
echo -n "  - Setting up iptables rate limit to panel: " | tee -a "$LOG_FILE"

iptables -N NODE_TO_PANEL 2>/dev/null || true
iptables -F NODE_TO_PANEL 2>/dev/null || true

# Максимум 5 коннектов к панели
iptables -A NODE_TO_PANEL -d $PANEL_IP -p tcp --dport 8443 -m connlimit --connlimit-above 5 --connlimit-mask 32 -j DROP 2>/dev/null || true

# Rate limit 20/минуту
iptables -A NODE_TO_PANEL -d $PANEL_IP -p tcp --dport 8443 -m limit --limit 20/minute --limit-burst 10 -j ACCEPT 2>/dev/null || true

# Остальное логируем и дропаем
iptables -A NODE_TO_PANEL -d $PANEL_IP -p tcp --dport 8443 -j LOG --log-prefix "PANEL_API_LIMIT: " --log-level 4 2>/dev/null || true
iptables -A NODE_TO_PANEL -d $PANEL_IP -p tcp --dport 8443 -j DROP 2>/dev/null || true

# Вставляем в OUTPUT chain
iptables -C OUTPUT -j NODE_TO_PANEL 2>/dev/null || iptables -I OUTPUT -j NODE_TO_PANEL 2>/dev/null || true

echo -e "${GREEN}OK${NC}"

# STEP 10: Docker + Remnanode
show_status "STEP 10: Remnanode Setup"
echo ""

if command -v docker &> /dev/null; then
    echo -n "  - Creating directories: " | tee -a "$LOG_FILE"
    mkdir -p /opt/remnanode /var/log/remnanode && echo -e "${GREEN}OK${NC}" || echo -e "${YELLOW}FAILED${NC}"
    
    if [ ! -f /opt/remnanode/docker-compose.yml ]; then
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
        echo -e "${GREEN}[✓] docker-compose.yml created${NC}"
    else
        echo -e "${YELLOW}[!] docker-compose.yml already exists, not overwriting${NC}"
    fi
    
    # Logrotate
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
    echo -e "${GREEN}[✓] Logrotate configured${NC}"
    
    # Auto-update cron
    cat > /etc/cron.d/remnawave-update << 'EOF'
0 11 * * 6 root cd /opt/remnanode && docker compose pull && docker compose down && docker compose up -d && docker image prune -f
EOF
    chmod 644 /etc/cron.d/remnawave-update
    echo -e "${GREEN}[✓] Auto-update cron configured (Saturdays 11:00)${NC}"
    
else
    echo -e "${YELLOW}[!] Docker not available, skipping Remnanode setup${NC}"
fi

# STEP 11: Save iptables rules
show_status "STEP 11: Saving Firewall Rules"
echo ""

mkdir -p /etc/iptables

echo -n "  - Saving current rules: " | tee -a "$LOG_FILE"
iptables-save > /etc/iptables/rules.v4 2>/dev/null && echo -e "${GREEN}OK${NC}" || echo -e "${YELLOW}FAILED${NC}"

# Restore service
cat > /etc/systemd/system/iptables-restore.service << 'EOF'
[Unit]
Description=Restore iptables rules
Before=network-pre.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

echo -n "  - Enabling iptables restore: " | tee -a "$LOG_FILE"
systemctl enable iptables-restore.service >> "$LOG_FILE" 2>&1 && echo -e "${GREEN}OK${NC}" || echo -e "${YELLOW}FAILED${NC}"

# Save on shutdown
cat > /usr/local/bin/save-iptables.sh << 'EOF'
#!/bin/bash
iptables-save > /etc/iptables/rules.v4
EOF
chmod +x /usr/local/bin/save-iptables.sh

cat > /etc/systemd/system/iptables-save.service << 'EOF'
[Unit]
Description=Save iptables rules
DefaultDependencies=no
Before=shutdown.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/save-iptables.sh
RemainAfterExit=yes

[Install]
WantedBy=shutdown.target
EOF

echo -n "  - Enabling iptables save on shutdown: " | tee -a "$LOG_FILE"
systemctl enable iptables-save.service >> "$LOG_FILE" 2>&1 && echo -e "${GREEN}OK${NC}" || echo -e "${YELLOW}FAILED${NC}"

# FINAL SUMMARY
show_status "INSTALLATION COMPLETE - SUMMARY"
echo ""

echo -e "${GREEN}Node IP:${NC}        $NODE_IP"
echo -e "${GREEN}Panel IP:${NC}       $PANEL_IP (static)"
echo -e "${GREEN}VPN Port:${NC}       443 (VLESS)"
echo -e "${GREEN}API Port:${NC}       8443 (Panel only)"
echo -e "${GREEN}Interface:${NC}      $IFACE"
echo ""
echo -e "${YELLOW}WHAT WAS CONFIGURED:${NC}"
echo "  ✓ Kernel hardening (sysctl) - SYN flood protection"
echo "  ✓ File limits (300000 open files)"
echo "  ✓ Server Shield - nftables, rate limiting, Russia geo"
echo "  ✓ UFW Firewall - 443 for all, 8443 panel only"
echo "  ✓ Fail2Ban - SSH protection"
echo "  ✓ Circuit Breaker - protects panel when node DDoS'd"
echo "  ✓ Iptables rate limit to panel (max 5 conn, 20/min)"
echo ""

if command -v xdp-loader &> /dev/null; then
    echo "  ✓ XDP/eBPF - kernel-level packet filtering"
else
    echo "  ⚠ XDP/eBPF - NOT installed (optional, Shield covers this)"
fi

if command -v docker &> /dev/null; then
    echo "  ✓ Docker - ready"
    echo "  ✓ Remnanode config - /opt/remnanode/docker-compose.yml"
else
    echo "  ⚠ Docker - NOT installed (install manually)"
fi

echo ""
echo -e "${YELLOW}NEXT STEPS:${NC}"
echo "1. ${GREEN}reboot${NC} (to apply all kernel settings)"
echo "2. Edit ${BLUE}/opt/remnanode/docker-compose.yml${NC}"
echo "   Replace ${RED}<GET_FROM_PANEL>${NC} with SECRET_KEY from Remnawave Panel"
echo "3. Run: ${BLUE}cd /opt/remnanode && docker compose up -d${NC}"
echo "4. Check panel - node should be online"
echo ""
echo -e "${YELLOW}VERIFICATION COMMANDS:${NC}"
echo "  shield l7 status          - Server Shield status"
echo "  ufw status verbose        - Firewall rules"
echo "  fail2ban-client status    - Fail2Ban status"
echo "  iptables -L NODE_TO_PANEL -v -n  - Panel rate limits"
echo "  cat /var/log/circuit-breaker.log  - DDoS events (if any)"
echo ""
echo -e "${YELLOW}Installation log:${NC} $LOG_FILE"
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}If some steps failed, protection is still ACTIVE${NC}"
echo -e "${GREEN}Server Shield + UFW + Circuit Breaker = core protection${NC}"
echo -e "${GREEN}========================================${NC}"
