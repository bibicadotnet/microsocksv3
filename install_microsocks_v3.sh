#!/bin/bash

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# Get terminal width
WIDTH=$(tput cols 2>/dev/null || echo 80)

# Function to strip ANSI color codes
strip_ansi() {
    echo -e "$1" | sed 's/\x1B\[[0-9;]*[JKmsu]//g'
}

# Function to validate positive integer (no decimals)
validate_positive_int() {
    local input="$1"
    if [[ -n "$input" && (! "$input" =~ ^[0-9]+$ || "$input" -le 0) ]]; then
        echo -e "\n${RED}Error: Value must be a positive integer (e.g. 10, 50, 100)${NC}"
        echo -e "${YELLOW}• Decimal values (like 10.5) are not allowed${NC}"
        echo -e "${YELLOW}• Value must be greater than 0${NC}\n"
        return 1
    fi
    return 0
}

# Function to center text
center_text() {
    local input="$1"
    local stripped=$(strip_ansi "$input")
    local text_length=${#stripped}
    local padding=$(( (WIDTH - text_length) / 2 ))
    [ $padding -lt 0 ] && padding=0
    printf "%*s%s\n" "$padding" "" "$input"
}

# Function to validate account name
validate_account() {
    local account="$1"
    if [[ ! "$account" =~ ^[a-z0-9_]+$ ]]; then
        echo -e "\n${RED}Error: Invalid account name format${NC}\n"
        echo -e "${YELLOW}Account name requirements:${NC}"
        echo -e "  - Only lowercase letters (a-z)"
        echo -e "  - Numbers (0-9)"
        echo -e "  - Underscore (_) allowed"
        return 1
    fi
    return 0
}

# Header
echo ""
printf "${GREEN}%s${NC}\n" "$(printf '%*s' "$WIDTH" '' | tr ' ' '#')"
center_text "$(printf "${GREEN}Telegram MicroSocks Proxy Installer${NC}")"
printf "${GREEN}%s${NC}\n" "$(printf '%*s' "$WIDTH" '' | tr ' ' '#')"
echo ""

# Account name input with detailed instructions
while true; do
    echo -e "\n${YELLOW}ACCOUNT NAME CONFIGURATION${NC}"
    echo -e "${YELLOW}• Only lowercase letters (a-z), numbers (0-9), and underscore (_)"
    echo -e "${YELLOW}• No spaces or special characters allowed"
    echo -e "${YELLOW}• Example: proxy123 or proxy_user1${NC}"
    echo -e "${WHITE}"
    read -p "Enter account name: " ACCOUNT_NAME
    echo -e "${NC}"
    validate_account "$ACCOUNT_NAME" && break
done

# Download rate input with enhanced validation
while true; do
    echo -e "\n${YELLOW}DOWNLOAD BANDWIDTH LIMIT${NC}"
    echo -e "${YELLOW}• Enter integer value in Mbps (e.g., 10 for 10Mbps)"
    echo -e "${YELLOW}• Only whole numbers allowed (no decimals)"
    echo -e "${YELLOW}• Press Enter to skip (no limit will be set)"
    echo -e "${YELLOW}• Example valid inputs: 5, 10, 50, 100${NC}"
    echo -e "${WHITE}"
    read -p "Enter download limit: " DOWNLOAD_RATE
    echo -e "${NC}"
    validate_positive_int "$DOWNLOAD_RATE" && break
done
[ -n "$DOWNLOAD_RATE" ] && DOWNLOAD_RATE="${DOWNLOAD_RATE}Mbps"

# Upload rate input with enhanced validation
while true; do
    echo -e "\n${YELLOW}UPLOAD BANDWIDTH LIMIT${NC}"
    echo -e "${YELLOW}• Enter integer value in Mbps (e.g., 5 for 5Mbps)"
    echo -e "${YELLOW}• Only whole numbers allowed (no decimals)"
    echo -e "${YELLOW}• Press Enter to skip (no limit will be set)"
    echo -e "${YELLOW}• Example valid inputs: 2, 5, 20, 50${NC}"
    echo -e "${WHITE}"
    read -p "Enter upload limit: " UPLOAD_RATE
    echo -e "${NC}"
    validate_positive_int "$UPLOAD_RATE" && break
done
[ -n "$UPLOAD_RATE" ] && UPLOAD_RATE="${UPLOAD_RATE}Mbps"

# Cloudflare WARP Configuration
TUNNEL_PROTOCOL="wireguard"
while true; do
    echo -e "\n${YELLOW}CLOUDFLARE WARP CONFIGURATION${NC}"
    echo -e "${YELLOW}• Route SOCKS5 traffic through Cloudflare WARP for privacy/unblocking"
    echo -e "${YELLOW}• Would you like to enable Cloudflare WARP? (y/n) [default: y]${NC}"
    echo -e "${WHITE}"
    read -p "Enable WARP?: " ENABLE_WARP
    echo -e "${NC}"
    ENABLE_WARP=$(echo "$ENABLE_WARP" | tr '[:upper:]' '[:lower:]')
    if [[ -z "$ENABLE_WARP" || "$ENABLE_WARP" == "y" || "$ENABLE_WARP" == "yes" ]]; then
        TUNNEL_PROTOCOL="wireguard"
        break
    elif [[ "$ENABLE_WARP" == "n" || "$ENABLE_WARP" == "no" ]]; then
        TUNNEL_PROTOCOL="none"
        break
    else
        echo -e "${RED}Invalid input. Please enter y or n.${NC}"
    fi
done

echo -e "\n${YELLOW}Preparing proxy container and configuration files...${NC}"

# Create working directory
WORKDIR="$HOME/microsocks_${ACCOUNT_NAME}"
mkdir -p "$WORKDIR"
cd "$WORKDIR" || exit

# Docker installation
if ! command -v docker &> /dev/null; then
    echo -e "\n${YELLOW}Installing Docker...${NC}"
    curl -fsSL https://get.docker.com   | sh >/dev/null 2>&1
    systemctl enable --now docker >/dev/null 2>&1
fi

# Generate random credentials and ports
PROXY_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
HOST_PORT=$((RANDOM%10000+10000))
CONTAINER_PORT=$((RANDOM%10000+10000))

# Get server IP
IP=$(curl -4 -s ip.sb)

# Remove old files if exist
rm -f compose.yml

# Create compose file
cat > compose.yml <<EOF
services:
  microsocks_${ACCOUNT_NAME}:
    image: bibica/microsocks-v3
    container_name: microsocks_${ACCOUNT_NAME}
    restart: always
    ports:
      - "$HOST_PORT:$CONTAINER_PORT"
    cap_add:
      - NET_ADMIN
EOF

# Add SYS_MODULE capability if WireGuard is selected
if [ "$TUNNEL_PROTOCOL" = "wireguard" ]; then
    cat >> compose.yml <<EOF
      - SYS_MODULE
EOF
fi

cat >> compose.yml <<EOF
    environment:
      - PORT=$CONTAINER_PORT
      - AUTH_ONCE=true
      - QUIET=true
      - USERNAME=${ACCOUNT_NAME}
      - PASSWORD=${PROXY_PASSWORD}
      - TUNNEL_PROTOCOL=${TUNNEL_PROTOCOL}
EOF

# Add rate limits if provided
[ -n "$DOWNLOAD_RATE" ] && echo "      - DOWNLOAD_RATE=$DOWNLOAD_RATE" >> compose.yml
[ -n "$UPLOAD_RATE" ] && echo "      - UPLOAD_RATE=$UPLOAD_RATE" >> compose.yml

# Add volumes if WARP is enabled
if [ "$TUNNEL_PROTOCOL" != "none" ]; then
    mkdir -p warp-data
    cat >> compose.yml <<EOF
    volumes:
      - ./warp-data:/etc/wireguard
EOF
fi

# Add sysctls if WireGuard is selected
if [ "$TUNNEL_PROTOCOL" = "wireguard" ]; then
    cat >> compose.yml <<EOF
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv6.conf.default.disable_ipv6=0
      - net.ipv6.conf.all.forwarding=1
EOF
fi

# Add logging configuration
cat >> compose.yml <<EOF
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

# Container management
docker compose down >/dev/null 2>&1
docker compose pull >/dev/null 2>&1

echo -e "\n${YELLOW}Starting MicroSocks service...${NC}"
docker compose up -d --remove-orphans --force-recreate >/dev/null 2>&1

# Check if SOCKS5 proxy is working
echo -e "\n${YELLOW}Validating SOCKS5 proxy connection (waiting up to 40s for initialization)...${NC}"
PROXY_URL="socks5h://$ACCOUNT_NAME:$PROXY_PASSWORD@$IP:$HOST_PORT"
CHECK_IP=""
for i in {1..20}; do
    CHECK_IP=$(curl -4 -s --connect-timeout 3 --max-time 5 --proxy $PROXY_URL https://ifconfig.me 2>/dev/null || echo "")
    if [[ -n "$CHECK_IP" && "$CHECK_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        break
    fi
    echo -n "."
    sleep 2
done
echo ""

if [[ -n "$CHECK_IP" && ( "$CHECK_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$CHECK_IP" =~ ^[0-9a-fA-F:]+$ ) ]]; then
    if [ "$TUNNEL_PROTOCOL" != "none" ]; then
        PROXY_STATUS="${GREEN}Active and working properly (WARP exit IP: $CHECK_IP)${NC}"
    else
        PROXY_STATUS="${GREEN}Active and working properly${NC}"
    fi
else
    PROXY_STATUS="${RED}Configured but not working${NC}"
    STATUS_MESSAGE="\n${YELLOW}✗ Troubleshooting Guide ✗${NC}\n"
    STATUS_MESSAGE+="The SOCKS5 proxy has been configured but the connection test failed.\n"
    STATUS_MESSAGE+="Raw test response: '${CHECK_IP}'\n\n"
    STATUS_MESSAGE+="Possible causes:\n"
    STATUS_MESSAGE+="  - Port ${YELLOW}$HOST_PORT${NC} is blocked by firewall\n"
    STATUS_MESSAGE+="  - Cloud provider firewall blocking the port\n"
    STATUS_MESSAGE+="  - Proxy service failed to start or WARP connection failed\n\n"
    STATUS_MESSAGE+="Recommended actions:\n"
    STATUS_MESSAGE+="  - Check firewall settings\n"
    STATUS_MESSAGE+="  - Open port ${YELLOW}$HOST_PORT${NC} in cloud provider console\n"
    STATUS_MESSAGE+="  - Check container status: ${YELLOW}docker ps${NC}\n"
    STATUS_MESSAGE+="  - View logs: ${YELLOW}docker logs microsocks_${ACCOUNT_NAME}${NC}\n"
fi

echo ""
printf "${YELLOW}%s${NC}\n" "$(printf '%*s' "$WIDTH" '' | tr ' ' '=')"
echo ""
center_text "$(printf "${GREEN}Telegram MicroSocks Proxy Information${NC}")"
echo ""
center_text "$(printf "${BLUE}tg://socks?server=$IP&port=$HOST_PORT&user=$ACCOUNT_NAME&pass=$PROXY_PASSWORD${NC}")"
echo ""
printf "${YELLOW}%s${NC}\n" "$(printf '%*s' "$WIDTH" '' | tr ' ' '=')"
echo ""
printf "${GREEN}MicroSocks Proxy Information:${NC}\n"
printf "  Server IP: ${BLUE}%s${NC}\n" "$IP"
printf "  Port: ${BLUE}%s${NC}\n" "$HOST_PORT"
printf "  Username: ${BLUE}%s${NC}\n" "$ACCOUNT_NAME"
printf "  Password: ${BLUE}%s${NC}\n" "$PROXY_PASSWORD"
printf "  Tunnel Protocol: ${BLUE}%s${NC}\n" "$TUNNEL_PROTOCOL"

# Add bandwidth limits if specified
[ -n "$DOWNLOAD_RATE" ] && printf "  Download Limit: ${BLUE}%s${NC}\n" "$DOWNLOAD_RATE"
[ -n "$UPLOAD_RATE" ] && printf "  Upload Limit: ${BLUE}%s${NC}\n" "$UPLOAD_RATE"

printf "  Status: %b\n" "$PROXY_STATUS"

if [[ ! ( "$CHECK_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$CHECK_IP" =~ ^[0-9a-fA-F:]+$ ) ]]; then
    echo -e "$STATUS_MESSAGE"
fi
printf "${YELLOW}%s${NC}\n" "$(printf '%*s' "$WIDTH" '' | tr ' ' '=')"
echo ""
printf "Configuration directory: ${YELLOW}%s${NC}\n" "$WORKDIR"
echo ""
