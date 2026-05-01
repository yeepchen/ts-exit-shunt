#!/bin/sh
set -e

log() { echo "[ts-init] $*"; }

# ========== Environment Variables ==========
DIRECT_GW="${DIRECT_GW:-}"          # Dedicated gateway for tailscaled own traffic (control/STUN/WireGuard)
EXIT_GW="${EXIT_GW:-}"              # Default gateway for everything else (exit-node, local subnet, container outbound)
IFACE="${IFACE:-}"                  # Auto-detected if omitted
IFACE_EXIT="${IFACE_EXIT:-$IFACE}"  # Interface for default gateway (defaults to IFACE)
LOCAL_REDIR_PORT="${LOCAL_REDIR_PORT:-}"  # Optional transparent proxy port

# ========== Validation ==========
[ -z "$EXIT_GW" ] && { log "ERROR: EXIT_GW is required"; exit 1; }

# ========== Auto-detect Interface ==========
detect_iface() {
    ip -4 route show default | awk '/default/ {print $5; exit}'
}
[ -z "$IFACE" ] && IFACE=$(detect_iface)
[ -z "$IFACE" ] && { log "ERROR: Cannot detect interface. Set IFACE env."; exit 1; }
[ -z "$IFACE_EXIT" ] && IFACE_EXIT="$IFACE"
log "Using interface: $IFACE (exit/default: $IFACE_EXIT)"

# ========== Idempotent Cleanup ==========
# Remove legacy forward-mode rules (table 100) if present from previous versions
while ip rule del fwmark 0x1 lookup 100 2>/dev/null; do :; done
ip route flush table 100 2>/dev/null || true

# Remove current reverse-mode rules (table 101)
while ip rule del fwmark 0x2 lookup 101 2>/dev/null; do :; done
ip route flush table 101 2>/dev/null || true

for cmd in iptables; do
    [ -x "$(command -v $cmd)" ] || continue

    # Clean legacy mangle rules
    while $cmd -t mangle -C PREROUTING -i tailscale0 -j MARK --set-mark 0x1 2>/dev/null; do
        $cmd -t mangle -D PREROUTING -i tailscale0 -j MARK --set-mark 0x1
    done
    while $cmd -t mangle -C OUTPUT -m owner --uid-owner 0 -j MARK --set-mark 0x2 2>/dev/null; do
        $cmd -t mangle -D OUTPUT -m owner --uid-owner 0 -j MARK --set-mark 0x2
    done

    # Clean legacy nat rules
    while $cmd -t nat -C POSTROUTING -o "$IFACE_EXIT" -m mark --mark 0x1 -j MASQUERADE 2>/dev/null; do
        $cmd -t nat -D POSTROUTING -o "$IFACE_EXIT" -m mark --mark 0x1 -j MASQUERADE
    done
    while $cmd -t nat -C POSTROUTING -m mark --mark 0x1 -j MASQUERADE 2>/dev/null; do
        $cmd -t nat -D POSTROUTING -m mark --mark 0x1 -j MASQUERADE
    done

    if [ -n "$LOCAL_REDIR_PORT" ]; then
        while $cmd -t nat -C PREROUTING -i tailscale0 -p tcp -j REDIRECT --to-ports "$LOCAL_REDIR_PORT" 2>/dev/null; do
            $cmd -t nat -D PREROUTING -i tailscale0 -p tcp -j REDIRECT --to-ports "$LOCAL_REDIR_PORT"
        done
        while $cmd -t nat -C PREROUTING -i tailscale0 -p udp -j REDIRECT --to-ports "$LOCAL_REDIR_PORT" 2>/dev/null; do
            $cmd -t nat -D PREROUTING -i tailscale0 -p udp -j REDIRECT --to-ports "$LOCAL_REDIR_PORT"
        done
        while $cmd -t nat -C PREROUTING -p tcp --dport "$LOCAL_REDIR_PORT" -j RETURN 2>/dev/null; do
            $cmd -t nat -D PREROUTING -p tcp --dport "$LOCAL_REDIR_PORT" -j RETURN
        done
    fi
done

# ========== Policy Routing (Reverse Mode) ==========

# 1. Default gateway for ALL unmarked traffic = EXIT_GW
ip route replace default via "$EXIT_GW" dev "$IFACE_EXIT"
log "Main route (default): via $EXIT_GW dev $IFACE_EXIT"

# 2. Table 101: dedicated route for tailscaled own traffic -> DIRECT_GW
if [ -n "$DIRECT_GW" ]; then
    ip route add default via "$DIRECT_GW" dev "$IFACE" table 101
    log "Table 101 (tailscaled): default via $DIRECT_GW dev $IFACE"
fi

# 3. ip rule: marked tailscaled traffic -> table 101
ip rule add fwmark 0x2 lookup 101
log "ip rule: fwmark 0x2 -> table 101"

# ========== iptables ==========

# Mark all tailscale0 ingress traffic for SNAT (exit-node forwarded clients)
# This mark is ONLY used in POSTROUTING for MASQUERADE, NOT for routing decisions.
iptables -t mangle -A PREROUTING -i tailscale0 -j MARK --set-mark 0x1
log "iptables: marked tailscale0 ingress with fwmark 0x1 (for SNAT)"

# Mark tailscaled own traffic so it routes via DIRECT_GW instead of EXIT_GW.
# In the official tailscale image, tailscaled runs as root (uid 0).
if [ -n "$DIRECT_GW" ]; then
    iptables -t mangle -A OUTPUT -m owner --uid-owner 0 -j MARK --set-mark 0x2
    log "iptables: marked root OUTPUT with fwmark 0x2 (tailscaled -> DIRECT_GW)"
fi

# SNAT for exit-node traffic: converts 100.x.x.x source to 192.168.1.x so replies return.
# Applies to all tailscale0-originated traffic regardless of final destination.
iptables -t nat -A POSTROUTING -m mark --mark 0x1 -j MASQUERADE
log "iptables: MASQUERADE fwmark 0x1 traffic"

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
