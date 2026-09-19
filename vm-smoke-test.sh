#!/usr/bin/env bash
# Run this only inside a disposable Linux VM or VPS after install.sh succeeds.
# It does not install, change, restart, or delete anything.
set -Eeuo pipefail

CONFIG='/etc/sing-box/config.json'
VLESS_PORT=443
HY2_PORT=443
SS_PORT=8443
WG_PORT=51820
WITH_WIREGUARD=0

while (($#)); do
  case "$1" in
    --vless-port) VLESS_PORT="${2:?--vless-port needs a port}"; shift 2 ;;
    --hy2-port) HY2_PORT="${2:?--hy2-port needs a port}"; shift 2 ;;
    --ss-port) SS_PORT="${2:?--ss-port needs a port}"; shift 2 ;;
    --with-wireguard) WITH_WIREGUARD=1; shift ;;
    --wg-port) WG_PORT="${2:?--wg-port needs a port}"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
command -v sing-box >/dev/null || { echo 'sing-box is not installed.' >&2; exit 1; }
[[ -r $CONFIG ]] || { echo "Missing $CONFIG" >&2; exit 1; }

sing-box check -c "$CONFIG"
systemctl is-active --quiet sing-box

tcp_vless="$(ss -H -ltn "sport = :$VLESS_PORT" || true)"
udp_hy2="$(ss -H -lun "sport = :$HY2_PORT" || true)"
tcp_ss="$(ss -H -ltn "sport = :$SS_PORT" || true)"
udp_ss="$(ss -H -lun "sport = :$SS_PORT" || true)"
udp_wg=''
if (( WITH_WIREGUARD )); then udp_wg="$(ss -H -lun "sport = :$WG_PORT" || true)"; fi

[[ -n $tcp_vless ]] || { echo "Missing TCP listener on $VLESS_PORT." >&2; exit 1; }
[[ -n $udp_hy2 ]] || { echo "Missing UDP listener on $HY2_PORT." >&2; exit 1; }
[[ -n $tcp_ss ]] || { echo "Missing TCP listener on $SS_PORT." >&2; exit 1; }
[[ -n $udp_ss ]] || { echo "Missing UDP listener on $SS_PORT." >&2; exit 1; }
if (( WITH_WIREGUARD )); then
  systemctl is-active --quiet wg-quick@wg0
  [[ -n $udp_wg ]] || { echo "Missing WireGuard UDP listener on $WG_PORT." >&2; exit 1; }
  [[ -r /etc/wireguard/wg0-client.conf ]] || { echo 'Missing WireGuard client profile.' >&2; exit 1; }
fi

echo "PASS: configuration is valid; service is active; TCP $VLESS_PORT, UDP $HY2_PORT, and TCP/UDP $SS_PORT listeners exist."
(( WITH_WIREGUARD )) && echo "PASS: WireGuard is active and listening on UDP $WG_PORT."
echo 'Next: import each printed URI into a client from a different network to test provider firewall reachability.'

