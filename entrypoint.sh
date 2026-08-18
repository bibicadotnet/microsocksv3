#!/bin/bash
# MicroSocks v2 + WARP integration entrypoint
set -eu

# ==========================================
# Defaults
# ==========================================
WG_CONF="${WG_CONF:-/etc/wireguard/wg0.conf}"
WG_DIR="$(dirname "$WG_CONF")"
WG_IFACE="${WG_IFACE:-wg0}"
WG_MTU="${MTU:-1280}"

TUNNEL_PROTOCOL="${TUNNEL_PROTOCOL:-none}" # wireguard | masque | none (default)

LISTEN_ADDR="${BIND_ADDR:-0.0.0.0}"
LISTEN_PORT="${PORT:-${BIND_PORT:-1080}}"
SOCKS_USER="${USERNAME:-${SOCKS_USER:-}}"
SOCKS_PASS="${PASSWORD:-${SOCKS_PASS:-}}"

# Bandwidth settings (MicroSocks v2)
DOWNLOAD_RATE="${DOWNLOAD_RATE:-}"
UPLOAD_RATE="${UPLOAD_RATE:-}"
AUTH_ONCE="${AUTH_ONCE:-}"
QUIET="${QUIET:-}"

# Redirect output if QUIET is explicitly enabled
if [ "${QUIET}" = "true" ]; then
    exec >/dev/null 2>&1
fi

ENABLE_IPV6="${ENABLE_IPV6:-1}"
TAILSCALE_CIDR="${TAILSCALE_CIDR:-100.64.0.0/10}"
TAILSCALE_CIDR_V6="${TAILSCALE_CIDR_V6:-fd7a:115c:a1e0::/48}"
KEEPALIVE="${KEEPALIVE:-15}"
WGCF_FALLBACK_VER="${WGCF_FALLBACK_VER:-2.2.29}"
CURL_TIMEOUT="${CURL_TIMEOUT:-15}"
TRACE_TIMEOUT="${TRACE_TIMEOUT:-3}"
TRACE_CONNECT_TIMEOUT="${TRACE_CONNECT_TIMEOUT:-2}"

# MASQUE / usque defaults
USQUE_CONFIG="${USQUE_CONFIG:-/etc/wireguard/masque-config.json}"
MASQUE_PROXY_MODE="${MASQUE_PROXY_MODE:-l4-socks}"
MASQUE_HTTP2="${MASQUE_HTTP2:-0}"
MASQUE_SNI="${MASQUE_SNI:-}"
MASQUE_MTU="${MASQUE_MTU:-}"
WARP_JWT="${WARP_JWT:-}"
WARP_LICENSE="${WARP_LICENSE:-}"
USQUE_DEVICE_NAME="${USQUE_DEVICE_NAME:-MicroWARP}"
GOMEMLIMIT="${GOMEMLIMIT:-512MiB}"

# ==========================================
# Logging helpers
# ==========================================
log()  { printf '%s\n' "==> [MicroSocksV2] $*"; }
warn() { printf '%s\n' "==> [MicroSocksV2] ⚠️  $*" >&2; }
die()  { printf '%s\n' "==> [MicroSocksV2] ❌ $*" >&2; exit 1; }

# ==========================================
# Bandwidth Logic (MicroSocks v2)
# ==========================================
get_interface() {
    local interface
    
    # Method 1: Default route interface
    interface=$(ip route show default | head -n1 | awk '{print $5}' 2>/dev/null || echo "")
    if [ -n "$interface" ] && ip link show "$interface" >/dev/null 2>&1; then
        echo "$interface"
        return 0
    fi
    
    # Method 2: First non-loopback interface with IP
    interface=$(ip -4 route show | grep -E '^[0-9]' | head -n1 | awk '{print $3}' 2>/dev/null || echo "")
    if [ -n "$interface" ] && ip link show "$interface" >/dev/null 2>&1; then
        echo "$interface"
        return 0
    fi
    
    # Method 3: Find interface with docker network
    for iface in $(ip link show | grep -E '^[0-9]+:' | awk -F': ' '{print $2}' | grep -E '^(eth|ens|enp|docker|veth)'); do
        if ip addr show "$iface" | grep -q 'inet ' 2>/dev/null; then
            echo "$iface"
            return 0
        fi
    done
    
    # Method 4: Fallback to eth0
    if ip link show eth0 >/dev/null 2>&1; then
        echo "eth0"
        return 0
    fi
    
    return 1
}

setup_bandwidth() {
    local interface
    interface=$(get_interface)
    
    [ -z "$interface" ] && return 1
    
    # Load ifb module
    modprobe ifb 2>/dev/null || true
    
    # Remove existing ifb0 if exists
    ip link del ifb0 2>/dev/null || true
    
    # Create and bring up ifb0
    ip link add ifb0 type ifb
    ip link set dev ifb0 up
    
    # Clear existing qdiscs
    tc qdisc del dev $interface root 2>/dev/null || true
    tc qdisc del dev $interface ingress 2>/dev/null || true
    tc qdisc del dev ifb0 root 2>/dev/null || true
    
    # Setup download limit (ingress)
    if [ -n "$DOWNLOAD_RATE" ]; then
        local download_rate=$(echo $DOWNLOAD_RATE | sed 's/Mbps//g')
        tc qdisc add dev $interface handle ffff: ingress
        tc filter add dev $interface parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb0
        tc qdisc add dev ifb0 root handle 1: htb default 10
        tc class add dev ifb0 parent 1: classid 1:1 htb rate ${download_rate}mbit ceil ${download_rate}mbit
        tc filter add dev ifb0 parent 1: protocol ip prio 1 u32 match ip src 0.0.0.0/0 flowid 1:1
    fi
    
    # Setup upload limit (egress)
    if [ -n "$UPLOAD_RATE" ]; then
        local upload_rate=$(echo $UPLOAD_RATE | sed 's/Mbps//g')
        tc qdisc add dev $interface root handle 2: htb default 10
        tc class add dev $interface parent 2: classid 2:1 htb rate ${upload_rate}mbit ceil ${upload_rate}mbit
        tc filter add dev $interface parent 2: protocol ip prio 1 u32 match ip dst 0.0.0.0/0 flowid 2:1
    fi
}

cleanup() {
    local interface
    interface=$(get_interface 2>/dev/null) || interface=""
    
    if [ -n "$interface" ]; then
        tc qdisc del dev $interface root 2>/dev/null || true
        tc qdisc del dev $interface ingress 2>/dev/null || true
    fi
    tc qdisc del dev ifb0 root 2>/dev/null || true
    ip link del ifb0 2>/dev/null || true
    
    # Also stop wireguard if running
    if [ "${TUNNEL_PROTOCOL}" = "wireguard" ]; then
        wg-quick down "$WG_IFACE" >/dev/null 2>&1 || true
    fi
}

trap cleanup EXIT INT TERM

# ==========================================
# Utility
# ==========================================
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

run_with_timeout() {
    secs="$1"
    shift
    if command_exists timeout; then
        timeout "$secs" "$@" 2>/dev/null && return 0
        timeout -t "$secs" "$@" 2>/dev/null && return 0
        return 1
    fi
    "$@"
}

github_auth_header() {
    token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
    if [ -n "$token" ]; then
        printf 'Authorization: Bearer %s' "$token"
    fi
}

detect_arch() {
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)  printf 'amd64' ;;
        aarch64|arm64) printf 'arm64' ;;
        armv7l|armhf)  printf 'armv7' ;;
        *) die "Unsupported architecture: $arch" ;;
    esac
}

build_wgcf_download_url() {
    ver="$1"
    arch="$2"
    raw="https://github.com/ViRb3/wgcf/releases/download/v${ver}/wgcf_${ver}_linux_${arch}"
    if [ -n "${GH_PROXY:-}" ]; then
        printf '%s/%s' "${GH_PROXY%/}" "$raw"
    else
        printf '%s' "$raw"
    fi
}

fetch_latest_wgcf_version() {
    api="https://api.github.com/repos/ViRb3/wgcf/releases/latest"
    auth="$(github_auth_header)"
    body=""

    if [ -n "$auth" ]; then
        body="$(curl -fsSL -m "$CURL_TIMEOUT" -H "$auth" "$api" 2>/dev/null || true)"
    else
        body="$(curl -fsSL -m "$CURL_TIMEOUT" "$api" 2>/dev/null || true)"
    fi

    ver="$(printf '%s' "$body" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\([^"]*\)".*/\1/p' | head -n 1)"
    if [ -z "$ver" ]; then
        warn "Could not fetch wgcf version from GitHub API, falling back to v${WGCF_FALLBACK_VER}"
        printf '%s' "$WGCF_FALLBACK_VER"
        return 0
    fi
    printf '%s' "$ver"
}

download_file() {
    url="$1"
    dest="$2"
    tries=0
    max_tries=3

    while [ "$tries" -lt "$max_tries" ]; do
        tries=$((tries + 1))
        if command_exists wget; then
            if wget --timeout=30 -qO "$dest" "$url" 2>/dev/null; then
                [ -s "$dest" ] && return 0
            fi
        fi
        if command_exists curl; then
            if curl -fsSL -m 30 -o "$dest" "$url" 2>/dev/null; then
                [ -s "$dest" ] && return 0
            fi
        fi
        warn "Download failed (attempt ${tries}/${max_tries}): $url"
        sleep $((tries * 2))
    done
    return 1
}

extract_ipv4_cidr() {
    printf '%s' "$1" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}' | head -n 1
}

extract_ipv6_cidr() {
    printf '%s' "$1" \
        | tr ',' '\n' \
        | tr ' ' '\n' \
        | grep -E '^[0-9a-fA-F:]+/[0-9]{1,3}$' \
        | grep -E ':' \
        | head -n 1
}

is_truthy() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

iface_has_global_ipv6() {
    dev="$1"
    ip -6 addr show dev "$dev" scope global 2>/dev/null | grep -q 'inet6 '
}

normalize_tunnel_protocol() {
    raw="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$raw" in
        wireguard|wg|wg0|kernel) printf 'wireguard' ;;
        masque|usque|h3|http3|quic) printf 'masque' ;;
        none|direct|"") printf 'none' ;;
        *) die "Unknown TUNNEL_PROTOCOL='$1' (supported: wireguard | masque | none)" ;;
    esac
}

normalize_masque_proxy_mode() {
    raw="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$raw" in
        l4|l4-socks|l4_socks|l4socks) printf 'l4-socks' ;;
        socks|full|gvisor|l3) printf 'socks' ;;
        *) die "Unknown MASQUE_PROXY_MODE='$1' (supported: l4-socks | socks)" ;;
    esac
}

# ==========================================
# WireGuard Registration & Control
# ==========================================
register_warp() {
    log "No configuration found, auto-registering Cloudflare WARP (WireGuard)..."

    arch="$(detect_arch)"
    ver="$(fetch_latest_wgcf_version)"
    log "Using wgcf version: v${ver} (${arch})"

    url="$(build_wgcf_download_url "$ver" "$arch")"
    workdir="$(mktemp -d /tmp/microsocksv2.XXXXXX)" || die "Could not create temp dir"
    # shellcheck disable=SC2064
    trap 'rm -rf "$workdir"' EXIT INT TERM

    if ! download_file "$url" "$workdir/wgcf"; then
        die "Failed to download wgcf binary: $url"
    fi
    chmod +x "$workdir/wgcf"

    log "Registering device with Cloudflare..."
    if ! (
        cd "$workdir"
        ./wgcf register --accept-tos >/dev/null 2>&1
        log "Generating WireGuard config..."
        ./wgcf generate >/dev/null 2>&1
    ); then
        die "wgcf register or generate failed"
    fi

    if [ ! -f "$workdir/wgcf-profile.conf" ]; then
        die "wgcf-profile.conf not found, registration failed"
    fi

    mv "$workdir/wgcf-profile.conf" "$WG_CONF"
    rm -rf "$workdir"
    trap - EXIT INT TERM
    log "WARP configuration generated successfully"
}

sanitize_config() {
    [ -f "$WG_CONF" ] || die "Configuration file does not exist: $WG_CONF"

    raw_address="$(grep -E '^[[:space:]]*Address[[:space:]]*=' "$WG_CONF" || true)"
    ipv4_addr="$(extract_ipv4_cidr "$raw_address")"
    ipv6_addr="$(extract_ipv6_cidr "$raw_address")"

    if [ -z "$ipv4_addr" ]; then
        ipv4_addr="$(extract_ipv4_cidr "$(cat "$WG_CONF")")"
    fi
    if [ -z "$ipv6_addr" ]; then
        ipv6_addr="$(extract_ipv6_cidr "$(cat "$WG_CONF")")"
    fi

    if [ -z "$ipv4_addr" ]; then
        die "Could not parse IPv4 Address from configuration"
    fi

    sed -i \
        -e '/^[[:space:]]*Address[[:space:]]*=/d' \
        -e '/^[[:space:]]*AllowedIPs[[:space:]]*=/d' \
        -e '/^[[:space:]]*DNS[[:space:]]*=/d' \
        -e '/^[[:space:]]*[Mm][Tt][Uu][[:space:]]*=/d' \
        "$WG_CONF"

    if is_truthy "$ENABLE_IPV6" && [ -n "$ipv6_addr" ]; then
        address_value="${ipv4_addr},${ipv6_addr}"
        log "Dual-stack Addresses: IPv4=${ipv4_addr}  IPv6=${ipv6_addr}"
    else
        address_value="$ipv4_addr"
        log "IPv4 Address: ${ipv4_addr}"
    fi

    if ! grep -q '^\[Interface\]' "$WG_CONF"; then
        die "Configuration is missing [Interface] section"
    fi
    sed -i "/^\[Interface\]/a Address = ${address_value}" "$WG_CONF"
    sed -i "/^\[Interface\]/a MTU = ${WG_MTU}" "$WG_CONF"

    if is_truthy "$ENABLE_IPV6" && [ -n "$ipv6_addr" ]; then
        allowed_ips="0.0.0.0/0, ::/0"
    else
        allowed_ips="0.0.0.0/0"
    fi

    if ! grep -q '^\[Peer\]' "$WG_CONF"; then
        die "Configuration is missing [Peer] section"
    fi
    sed -i "/^\[Peer\]/a AllowedIPs = ${allowed_ips}" "$WG_CONF"

    if grep -qi '^[[:space:]]*PersistentKeepalive[[:space:]]*=' "$WG_CONF"; then
        sed -i "s/^[[:space:]]*PersistentKeepalive[[:space:]]*=.*/PersistentKeepalive = ${KEEPALIVE}/g" "$WG_CONF"
    else
        sed -i "/^\[Peer\]/a PersistentKeepalive = ${KEEPALIVE}" "$WG_CONF"
    fi

    if [ -n "${ENDPOINT_IP:-}" ]; then
        log "Overriding Endpoint: ${ENDPOINT_IP}"
        if grep -qi '^[[:space:]]*Endpoint[[:space:]]*=' "$WG_CONF"; then
            sed -i "s|^[[:space:]]*Endpoint[[:space:]]*=.*|Endpoint = ${ENDPOINT_IP}|g" "$WG_CONF"
        else
            sed -i "/^\[Peer\]/a Endpoint = ${ENDPOINT_IP}" "$WG_CONF"
        fi
    fi
}

patch_wg_quick() {
    wg_quick_bin="$(command -v wg-quick || true)"
    if [ -n "$wg_quick_bin" ] && [ -f "$wg_quick_bin" ] && [ -w "$wg_quick_bin" ]; then
        sysctl -w net.ipv4.conf.all.src_valid_mark=1 >/dev/null 2>&1 || true
        if is_truthy "$ENABLE_IPV6"; then
            sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
            sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
            sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
            sysctl -w net.ipv6.conf.default.forwarding=1 >/dev/null 2>&1 || true
        fi
        sed -i '/src_valid_mark/d' "$wg_quick_bin" 2>/dev/null || true
    fi
}

capture_pre_warp_routes() {
    PRE_WARP_ROUTE_V4="$(ip -4 route get 100.64.0.1 2>/dev/null | head -n 1 || true)"
    PRE_WARP_GW_V4="$(printf '%s\n' "$PRE_WARP_ROUTE_V4" | awk '{for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}')"
    PRE_WARP_DEV_V4="$(printf '%s\n' "$PRE_WARP_ROUTE_V4" | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"

    PRE_WARP_GW_V6=""
    PRE_WARP_DEV_V6=""
    if is_truthy "$ENABLE_IPV6" && command_exists ip; then
        PRE_WARP_ROUTE_V6="$(ip -6 route get fd7a:115c:a1e0::1 2>/dev/null | head -n 1 || true)"
        PRE_WARP_GW_V6="$(printf '%s\n' "$PRE_WARP_ROUTE_V6" | awk '{for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}')"
        PRE_WARP_DEV_V6="$(printf '%s\n' "$PRE_WARP_ROUTE_V6" | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
    fi

    ORIG_GW_V4="$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')"
    ORIG_DEV_V4="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
    ORIG_IP_V4=""
    if [ -n "${ORIG_DEV_V4:-}" ]; then
        ORIG_IP_V4="$(ip -4 addr show dev "$ORIG_DEV_V4" 2>/dev/null | awk '/inet / {print $2; exit}' | cut -d/ -f1)"
    fi

    ORIG_GW_V6=""
    ORIG_DEV_V6=""
    ORIG_IP_V6=""
    if is_truthy "$ENABLE_IPV6"; then
        ORIG_GW_V6="$(ip -6 route show default 2>/dev/null | awk '{print $3; exit}')"
        ORIG_DEV_V6="$(ip -6 route show default 2>/dev/null | awk '{print $5; exit}')"
        if [ -n "${ORIG_DEV_V6:-}" ]; then
            ORIG_IP_V6="$(ip -6 addr show dev "$ORIG_DEV_V6" scope global 2>/dev/null | awk '/inet6 / {print $2; exit}' | cut -d/ -f1)"
        fi
    fi
}

bring_up_wg() {
    log "Starting WireGuard interface ${WG_IFACE}..."
    if ! wg_out="$(wg-quick up "$WG_IFACE" 2>&1)"; then
        printf '%s\n' "$wg_out" >&2
        warn "Attempting cleanup of half-initialized interface..."
        wg-quick down "$WG_IFACE" >/dev/null 2>&1 || true
        die "wg-quick up failed. Please check NET_ADMIN / WireGuard module."
    fi
}

install_policy_routes() {
    if [ -n "${ORIG_IP_V4:-}" ] && [ -n "${ORIG_GW_V4:-}" ] && [ -n "${ORIG_DEV_V4:-}" ]; then
        log "Injecting IPv4 policy route (from ${ORIG_IP_V4} via ${ORIG_GW_V4} dev ${ORIG_DEV_V4} table 128 priority 5)"
        ip rule del from "$ORIG_IP_V4" table 128 2>/dev/null || true
        ip rule del from "$ORIG_IP_V4" lookup main 2>/dev/null || true
        ip rule add from "$ORIG_IP_V4" table 128 priority 5 2>/dev/null || warn "IPv4 ip rule failed"
        ip route replace table 128 default via "$ORIG_GW_V4" dev "$ORIG_DEV_V4" 2>/dev/null || warn "IPv4 route replace failed"
    fi

    if is_truthy "$ENABLE_IPV6" && [ -n "${ORIG_IP_V6:-}" ] && [ -n "${ORIG_GW_V6:-}" ] && [ -n "${ORIG_DEV_V6:-}" ]; then
        log "Injecting IPv6 policy route (from ${ORIG_IP_V6} via ${ORIG_GW_V6} dev ${ORIG_DEV_V6} table 129 priority 5)"
        ip -6 rule del from "$ORIG_IP_V6" table 129 2>/dev/null || true
        ip -6 rule del from "$ORIG_IP_V6" lookup main 2>/dev/null || true
        ip -6 rule add from "$ORIG_IP_V6" table 129 priority 5 2>/dev/null || warn "IPv6 ip rule failed"
        ip -6 route replace table 129 default via "$ORIG_GW_V6" dev "$ORIG_DEV_V6" 2>/dev/null || warn "IPv6 route replace failed"
    fi

    if [ -n "${PRE_WARP_GW_V4:-}" ] && [ -n "${PRE_WARP_DEV_V4:-}" ]; then
        if ip route replace "$TAILSCALE_CIDR" via "$PRE_WARP_GW_V4" dev "$PRE_WARP_DEV_V4" 2>/dev/null; then
            log "Restored Tailscale v4 route via ${PRE_WARP_GW_V4} dev ${PRE_WARP_DEV_V4}"
        fi
    fi

    if is_truthy "$ENABLE_IPV6" && [ -n "${PRE_WARP_GW_V6:-}" ] && [ -n "${PRE_WARP_DEV_V6:-}" ]; then
        if ip -6 route replace "$TAILSCALE_CIDR_V6" via "$PRE_WARP_GW_V6" dev "$PRE_WARP_DEV_V6" 2>/dev/null; then
            log "Restored Tailscale v6 route via ${PRE_WARP_GW_V6} dev ${PRE_WARP_DEV_V6}"
        fi
    fi

    # Debug: Print current routing rules and tables
    log "--- DEBUG: ip rule show ---"
    ip rule show || true
    log "--- DEBUG: ip route show table 128 ---"
    ip route show table 128 || true
    log "--- DEBUG: ip route show table main ---"
    ip route show default || true
    log "---------------------------"
}

show_egress_ip() {
    log "Detecting Egress IP..."
    v4_ok=0
    if out="$(run_with_timeout "$((TRACE_TIMEOUT + 1))" \
        curl -4 -sS --connect-timeout "$TRACE_CONNECT_TIMEOUT" -m "$TRACE_TIMEOUT" \
        https://1.1.1.1/cdn-cgi/trace 2>/dev/null || true)"; then
        ip_line="$(printf '%s\n' "$out" | grep '^ip=' || true)"
        if [ -n "$ip_line" ]; then
            log "  IPv4 ${ip_line}"
            v4_ok=1
        fi
    fi
    if [ "$v4_ok" -eq 0 ]; then
        warn "IPv4 Egress detection timeout or blocked"
    fi

    if is_truthy "$ENABLE_IPV6"; then
        if [ "${TUNNEL_PROTOCOL}" = "wireguard" ] && ! iface_has_global_ipv6 "$WG_IFACE"; then
            warn "IPv6: ${WG_IFACE} has no global address, skipping detection"
            return 0
        fi
        v6_ok=0
        if out="$(run_with_timeout "$((TRACE_TIMEOUT + 1))" \
            curl -6 -sS --connect-timeout "$TRACE_CONNECT_TIMEOUT" -m "$TRACE_TIMEOUT" \
            --resolve www.cloudflare.com:443:2606:4700::0011 \
            https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"; then
            ip_line="$(printf '%s\n' "$out" | grep '^ip=' || true)"
            if [ -n "$ip_line" ]; then
                log "  IPv6 ${ip_line}"
                v6_ok=1
            fi
        fi
    fi
}

# ==========================================
# MASQUE Registration & Control
# ==========================================
register_masque() {
    command_exists usque || die "usque binary not found in container"

    conf_dir="$(dirname "$USQUE_CONFIG")"
    mkdir -p "$conf_dir"

    if [ -f "$USQUE_CONFIG" ] && [ -s "$USQUE_CONFIG" ]; then
        log "Existing MASQUE configuration found: ${USQUE_CONFIG}"
        return 0
    fi

    if [ -f "$USQUE_CONFIG" ] && [ ! -s "$USQUE_CONFIG" ]; then
        rm -f "$USQUE_CONFIG"
    fi

    log "No MASQUE configuration, registering Cloudflare WARP device..."

    set -- usque -c "$USQUE_CONFIG" register -a
    if [ -n "$USQUE_DEVICE_NAME" ]; then
        set -- "$@" -n "$USQUE_DEVICE_NAME"
    fi
    if [ -n "$WARP_JWT" ]; then
        log "Using Zero Trust JWT for registration"
        set -- "$@" --jwt "$WARP_JWT"
    fi

    reg_log="$(mktemp /tmp/usque-register.XXXXXX 2>/dev/null || echo /tmp/usque-register.log)"
    if ! (
        cd "$conf_dir" || exit 1
        "$@" >"$reg_log" 2>&1
    ); then
        warn "usque register output:"
        cat "$reg_log" 2>/dev/null || true
        rm -f "$reg_log"
        die "usque register failed"
    fi
    rm -f "$reg_log"

    if [ ! -f "$USQUE_CONFIG" ] || [ ! -s "$USQUE_CONFIG" ]; then
        if [ -f "$conf_dir/config.json" ] && [ -s "$conf_dir/config.json" ]; then
            mv -f "$conf_dir/config.json" "$USQUE_CONFIG"
        fi
    fi

    [ -f "$USQUE_CONFIG" ] && [ -s "$USQUE_CONFIG" ] || die "Failed to generate masque config"
    log "MASQUE device registered successfully"
}

maybe_apply_warp_license() {
    [ -n "$WARP_LICENSE" ] || return 0
    command_exists usque || return 0

    log "Applying WARP+ license..."
    if usque -c "$USQUE_CONFIG" license "$WARP_LICENSE" >/dev/null 2>&1; then
        log "WARP+ license applied (license subcmd)"
        return 0
    fi
    if usque -c "$USQUE_CONFIG" account license "$WARP_LICENSE" >/dev/null 2>&1; then
        log "WARP+ license applied (account license subcmd)"
        return 0
    fi
    warn "Failed to apply WARP+ license, continuing..."
}

# ==========================================
# Run Paths
# ==========================================
run_direct_path() {
    log "Protocol: DIRECT (No WARP tunnel)"
    
    set -- microsocks -i "$LISTEN_ADDR" -p "$LISTEN_PORT"
    [ "$AUTH_ONCE" = "true" ] && set -- "$@" -1
    [ "$QUIET" = "true" ] && set -- "$@" -q
    if [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ]; then
        log "🔒 Authentication enabled (User: $SOCKS_USER)"
        set -- "$@" -u "$SOCKS_USER" -P "$SOCKS_PASS"
    else
        warn "No authentication configured"
    fi
    
    log "🚀 MicroSOCKS listening on ${LISTEN_ADDR}:${LISTEN_PORT}"
    exec "$@"
}

run_wireguard_path() {
    log "Protocol: WireGuard (kernel wg0)"

    mkdir -p "$WG_DIR"
    if [ ! -f "$WG_CONF" ]; then
        register_warp
    else
        log "Existing profile found, skipping registration"
    fi

    sanitize_config
    patch_wg_quick
    capture_pre_warp_routes
    bring_up_wg
    install_policy_routes

    show_egress_ip &
    
    # Run microsocks inside the routed network namespace
    set -- microsocks -i "$LISTEN_ADDR" -p "$LISTEN_PORT"
    [ "$AUTH_ONCE" = "true" ] && set -- "$@" -1
    [ "$QUIET" = "true" ] && set -- "$@" -q
    if [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ]; then
        log "🔒 Authentication enabled (User: $SOCKS_USER)"
        set -- "$@" -u "$SOCKS_USER" -P "$SOCKS_PASS"
    else
        warn "No authentication configured"
    fi

    log "🚀 MicroSOCKS (via WireGuard) listening on ${LISTEN_ADDR}:${LISTEN_PORT}"
    exec "$@"
}

run_masque_path() {
    log "Protocol: MASQUE (usque user-space)"
    
    register_masque
    maybe_apply_warp_license

    proxy_mode="$(normalize_masque_proxy_mode "$MASQUE_PROXY_MODE")"
    
    if [ -n "${GOMEMLIMIT:-}" ]; then
        export GOMEMLIMIT
    fi

    set -- usque -c "$USQUE_CONFIG" "$proxy_mode" -b "$LISTEN_ADDR" -p "$LISTEN_PORT"

    if [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ]; then
        log "🔒 Authentication enabled (User: $SOCKS_USER)"
        set -- "$@" -u "$SOCKS_USER" -w "$SOCKS_PASS"
    else
        warn "No authentication configured"
    fi

    if is_truthy "$MASQUE_HTTP2"; then
        if [ "$proxy_mode" = "l4-socks" ]; then
            warn "MASQUE_HTTP2=1 not supported in l4-socks, ignoring"
        else
            set -- "$@" --http2
        fi
    fi

    if [ -n "$MASQUE_SNI" ] && [ "$proxy_mode" != "l4-socks" ]; then
        set -- "$@" -s "$MASQUE_SNI"
    fi

    if [ -n "$MASQUE_MTU" ] && [ "$proxy_mode" != "l4-socks" ]; then
        set -- "$@" -m "$MASQUE_MTU"
    fi

    if [ "$proxy_mode" = "socks" ] && ! is_truthy "$ENABLE_IPV6"; then
        if usque socks --help 2>&1 | grep -q 'no-tunnel-ipv6'; then
            set -- "$@" --no-tunnel-ipv6
        fi
    fi

    log "🚀 usque ${proxy_mode} listening on ${LISTEN_ADDR}:${LISTEN_PORT}"
    show_egress_ip &
    exec "$@"
}

# ==========================================
# Main entrypoint
# ==========================================
main() {
    proto="$(normalize_tunnel_protocol "$TUNNEL_PROTOCOL")"
    log "TUNNEL_PROTOCOL=${proto}"

    # Setup bandwidth rate limits if specified (works for direct / wg / masque)
    if [ -n "$DOWNLOAD_RATE" ] || [ -n "$UPLOAD_RATE" ]; then
        log "Setting up bandwidth control: Download=${DOWNLOAD_RATE:-unlimited}, Upload=${UPLOAD_RATE:-unlimited}"
        setup_bandwidth
    fi

    case "$proto" in
        wireguard) run_wireguard_path ;;
        masque)    run_masque_path ;;
        none)      run_direct_path ;;
    esac
}

main "$@"
