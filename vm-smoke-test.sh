#!/usr/bin/env bash
# Run this only inside a disposable Linux VM or VPS after install.sh succeeds.
# It does not install, change, restart, or delete anything.
set -Eeuo pipefail

CONFIG='/etc/sing-box/config.json'
STATE='/etc/sing-box/credentials.env'
CLIENT_DIR='/etc/sing-box/client-profiles'
QR_DIR='/etc/sing-box/qr'
VLESS_PORT=443
HY2_PORT=443
SS_PORT=8443
SS_INNER_PORT=8444
WITH_WARP_UPSTREAM=0

while (($#)); do
  case "$1" in
    --vless-port) (($# >= 2)) || { echo '--vless-port needs a port' >&2; exit 2; }; VLESS_PORT="$2"; shift 2 ;;
    --hy2-port) (($# >= 2)) || { echo '--hy2-port needs a port' >&2; exit 2; }; HY2_PORT="$2"; shift 2 ;;
    --ss-port) (($# >= 2)) || { echo '--ss-port needs a port' >&2; exit 2; }; SS_PORT="$2"; shift 2 ;;
    --with-warp-upstream) WITH_WARP_UPSTREAM=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
command -v sing-box >/dev/null || { echo 'sing-box is not installed.' >&2; exit 1; }
[[ -r $CONFIG ]] || { echo "Missing $CONFIG" >&2; exit 1; }
[[ -r $STATE ]] || { echo "Missing $STATE" >&2; exit 1; }

sing-box check -c "$CONFIG"
systemctl is-active --quiet sing-box
grep -Eq "^REALITY_SHORT_ID='[0-9a-f]{8}'$" "$STATE" || { echo 'Missing or invalid REALITY_SHORT_ID in credentials.' >&2; exit 1; }
grep -Eq "^SHADOWTLS_PASSWORD='.+$" "$STATE" || { echo 'Missing SHADOWTLS_PASSWORD in credentials.' >&2; exit 1; }

tcp_vless="$(ss -H -ltn "sport = :$VLESS_PORT" || true)"
udp_hy2="$(ss -H -lun "sport = :$HY2_PORT" || true)"
tcp_shadowtls="$(ss -H -ltn "sport = :$SS_PORT" || true)"
tcp_ss_inner="$(ss -H -ltn "sport = :$SS_INNER_PORT" || true)"

[[ -n $tcp_vless ]] || { echo "Missing VLESS TCP listener on $VLESS_PORT." >&2; exit 1; }
[[ -n $udp_hy2 ]] || { echo "Missing Hysteria2 UDP listener on $HY2_PORT." >&2; exit 1; }
[[ -n $tcp_shadowtls ]] || { echo "Missing ShadowTLS TCP listener on $SS_PORT." >&2; exit 1; }
[[ -n $tcp_ss_inner ]] || { echo "Missing loopback SS2022 TCP listener on $SS_INNER_PORT." >&2; exit 1; }

for profile in "$CLIENT_DIR/sing-box-vless-cn-bypass.json" "$CLIENT_DIR/sing-box-shadowtls-ss2022.json"; do
  [[ -s $profile ]] || { echo "Missing client profile: $profile" >&2; exit 1; }
  sing-box check -c "$profile"
done
[[ -s "$QR_DIR/hysteria2.png" ]] || { echo 'Missing Hysteria2 QR PNG.' >&2; exit 1; }

if (( WITH_WARP_UPSTREAM )); then
  grep -q "^WARP_UPSTREAM_ENABLED='1'" "$STATE" || { echo 'WARP was requested but is not enabled in credentials.' >&2; exit 1; }
  systemctl is-active --quiet sing-box-vps-health.timer
fi

echo "PASS: valid config and client profiles; active service; VLESS TCP $VLESS_PORT, Hysteria2 UDP $HY2_PORT, ShadowTLS TCP $SS_PORT, and loopback SS2022 TCP $SS_INNER_PORT are listening."
(( WITH_WARP_UPSTREAM )) && echo 'PASS: the WARP health timer is active.'
echo 'Next: use a client from a different network to test provider firewall reachability and live protocol connectivity.'