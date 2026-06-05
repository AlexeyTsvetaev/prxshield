#!/bin/bash
#
# Remnawave Node DDoS Shield Installer
# Auto-detects node IP, uses static panel IP: 185.239.51.193
# Port 443: VLESS clients, Port 8443: Node API (from panel only)
# Geo: Russia only (RU)
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

# STEP 1: Dependencies
echo ""
echo "========================================"
echo "STEP 1: Dependencies"
echo "========================================"

run_cmd "apt-get update" "Updating packages" 
run_cmd "apt-get upgrade -y" "Upgrading packages"

PACKAGES="curl wget htop iftop mc net-tools ethtool fail2ban ufw logrotate cron iptables-persistent clang llvm libelf-dev bpftool linux-headers-$(uname -r) xdp-tools conntrack"
run_cmd "apt-get install -y $PACKAGES || apt-get install -y ${PACKAGES//$(uname -r)/generic}" "Installing packages"

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

# STEP 5: XDP
echo ""
echo "========================================"
echo "STEP 5: XDP/eBPF"
echo "========================================"

run_cmd "xdp-loader load -m skb -s xdp_pass $IFACE 2>/dev/null || echo 'XDP driver not supported, continuing'" "Loading XDP"

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

# STEP 6: Server Shield
echo ""
echo "========================================"
echo "STEP 6: Server Shield"
echo "========================================"

run_cmd "bash <(curl -fsSL https://raw.githubusercontent.com/wrx861/server-shield/main/install.sh)" "Installing Shield"

run_cmd "shield l7 backend nftables 2>/dev/null || true" "Setting nftables"
run_cmd "shield l7 enable 2>/dev/null || true" "Enabling L7"

# Limits
run_cmd "shield l7 limits syn 50 2>/dev/null || true" "SYN limit"
run_cmd "shield l7 limits conn 100 2>/dev/null || true" "Conn limit"
run_cmd "shield l7 limits rate 1000 2>/dev/null || true" "Rate limit"

# VPN ports
run_cmd "shield l7 vpn-ports add 443 2>/dev/null || true" "VPN port 443"
run_cmd "shield l7 vpn-ports add 8443 2>/dev/null || true" "API port 8443"

# Whitelist panel
run_cmd "shield l7 whitelist add $PANEL_IP 2>/dev/null || true" "Whitelisting panel"

# GEO: Russia only
echo -e "${BLUE}[*] Configuring GeoIP (Russia only)...${NC}"
run_cmd "shield l7 geo allow RU 2>/dev/null || true" "Allowing RU"
run_cmd "shield l7 geo deny all 2>/dev/null || true" "Deny all others"

# Extra protections
run_cmd "shield l7 tarpit enable 2>/dev/null || true" "Tarpit"
run_cmd "shield l7 autoban enable 2>/dev/null || true" "Autoban"

echo -e
