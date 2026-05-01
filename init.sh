#!/bin/sh
set -e

log() { echo "[ts-init] $*"; }

# ========== Environment Variables ==========
DIRECT_GW="${DIRECT_GW:-}"          # Default gateway for tailscaled own traffic (keep existing if unset)
EXIT_GW="${EXIT_GW:-}"              # Gateway for exit-node forwarded traffic (required)
IFACE="${IFACE:-}"                  # Auto-detected if omitted; can be set explicitly
IFACE_EXIT="${IFACE_EXIT:-$IFACE}"  # Interface for exit-node gateway (defaults to IFACE)
LOCAL_REDIR_PORT="${LOCAL_REDIR_PORT:-}"  # Optional local transparent proxy port
HOST_IP="${HOST_IP:-}"              # Host IP to route via main gateway (macvlan isolation workaround)

# ========== Validation ==========
[ -z "$EXIT_GW" ] && { log "ERROR: EXIT_GW is required"; exit 1; }

# ========== Auto-detect Interface ==========
detect_iface() {
    ip -4 route show default | awk '/default/ {print $5; exit}'
}
[ -z "$IFACE" ] && IFACE=$(detect_iface)
[ -z "$IFACE" ] && { log "ERROR: Cannot detect interface. Set IFACE env."; exit 1; }
[ -z "$IFACE_EXIT" ] && IFACE_EXIT="$IFACE"
log "Using interface: $IFACE (exit: $IFACE_EXIT)"

# ========== Idempotent Cleanup ==========
while ip rule del fwmark 0x1 lookup 100 2>/dev/null; do :; done
ip route flush table 100 2>/dev/null || true

for cmd in iptables; do
    [ -x "$(command -v $cmd)" ] || continue
    while $cmd -t mangle -C PREROUTING -i tailscale0 -j MARK --set-mark 0x1 2>/dev/null; do
        $cmd -t mangle -D PREROUTING -i tailscale0 -j MARK --set-mark 0x1
    done
    if [ -n "$LOCAL_REDIR_PORT" ]; then
        while $cmd -t nat -C PREROUTING -i tailscale0 -p tcp -j REDIRECT --to-ports "$LOCAL_REDIR_PORT" 2>/dev/null; do
            $cmd -t nat -D PREROUTING -i tailscale0 -p tcp -j REDIRECT --to-ports "$LOCAL_REDIR_PORT"
        done
        while $cmd -t nat -C PREROUTING -p tcp --dport "$LOCAL_REDIR_PORT" -j RETURN 2>/dev/null; do
            $cmd -t nat -D PREROUTING -p tcp --dport "$LOCAL_REDIR_PORT" -j RETURN
        done
    fi
done

# ========== Policy Routing ==========

# 1. Copy local subnet to table 100 so next-hop addresses are reachable
LOCAL_SUBNET=$(ip route show dev "$IFACE" | awk '/kernel/ {print $1; exit}')
if [ -n "$LOCAL_SUBNET" ]; then
    ip route add "$LOCAL_SUBNET" dev "$IFACE" table 100 2>/dev/null || true
    log "Added local subnet $LOCAL_SUBNET to table 100"
fi

# 2. Resolve the main gateway IP BEFORE we modify the main table
MAIN_GW_IP=$(ip route show default dev "$IFACE" | awk '/default/ {print $3; exit}')

# 3. Route host IP via main gateway to bypass macvlan parent-child isolation
if [ -n "$HOST_IP" ] && [ -n "$MAIN_GW_IP" ]; then
    ip route add "$HOST_IP/32" via "$MAIN_GW_IP" dev "$IFACE" table 100
    log "Host $HOST_IP routed via $MAIN_GW_IP (table 100, macvlan isolation)"
fi

# 4. Exit-node default route in table 100
ip rule add fwmark 0x1 lookup 100
ip route add default via "$EXIT_GW" dev "$IFACE_EXIT" table 100
log "Route: table 100 default via $EXIT_GW dev $IFACE_EXIT"

# 5. Main routing table (tailscaled own traffic)
if [ -n "$DIRECT_GW" ]; then
    ip route replace default via "$DIRECT_GW" dev "$IFACE"
    log "Main route: default via $DIRECT_GW dev $IFACE"
fi

# ========== iptables ==========
iptables -t mangle -A PREROUTING -i tailscale0 -j MARK --set-mark 0x1
log "iptables: marked tailscale0 ingress with fwmark 0x1"

# MASQUERADE exit-node traffic on the exit interface
iptables -t nat -A POSTROUTING -o "$IFACE_EXIT" -m mark --mark 0x1 -j MASQUERADE
log "iptables: MASQUERADE exit-node traffic on $IFACE_EXIT"

if [ -n "$LOCAL_REDIR_PORT" ]; then
    iptables -t nat -A PREROUTING -i tailscale0 -p tcp -j REDIRECT --to-ports "$LOCAL_REDIR_PORT"
    iptables -t nat -A PREROUTING -i tailscale0 -p udp -j REDIRECT --to-ports "$LOCAL_REDIR_PORT"
    iptables -t nat -I PREROUTING -p tcp --dport "$LOCAL_REDIR_PORT" -j RETURN
    log "Transparent proxy REDIRECT to port $LOCAL_REDIR_PORT"
fi

# ========== Hand Over to Official Entrypoint ==========
log "Network ready. Handing over to official Tailscale entrypoint..."

if [ -x /usr/local/bin/containerboot ]; then
    exec /usr/local/bin/containerboot
else
    log "ERROR: /usr/local/bin/containerboot not found"
    exit 1
fi
