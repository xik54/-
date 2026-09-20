#!/usr/bin/env bash
# sing-box VPS installer -- systemd-based Debian/Ubuntu, RHEL-family, and Arch Linux.
# Installs the current stable sing-box build from official package sources and creates
# VLESS+REALITY, Hysteria2+Salamander, and ShadowTLS v3 + Shadowsocks 2022 inbounds.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

APP_NAME='sing-box-vps'
CONFIG_DIR='/etc/sing-box'
CONFIG_FILE="$CONFIG_DIR/config.json"
STATE_FILE="$CONFIG_DIR/credentials.env"
SERVICE_FILE='/etc/systemd/system/sing-box.service'
QR_DIR='/etc/sing-box/qr'
CLIENT_DIR='/etc/sing-box/client-profiles'
WARP_HEALTH_PORT=18080
WARP_PROXY_PORT=40000
WARP_APT_KEYRING='/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg'
WARP_APT_REPO='/etc/apt/sources.list.d/cloudflare-client.list'
SINGBOX_APT_KEYRING='/etc/apt/keyrings/sagernet.asc'
SINGBOX_APT_REPO='/etc/apt/sources.list.d/sagernet.sources'
SINGBOX_RPM_REPO='/etc/yum.repos.d/sing-box.repo'
FAIL2BAN_JAIL_NAME='sing-box-vps-sshd'
FAIL2BAN_JAIL_FILE="/etc/fail2ban/jail.d/$FAIL2BAN_JAIL_NAME.conf"
HEALTHCHECK_FILE='/usr/local/sbin/sing-box-vps-healthcheck'
HEALTH_SERVICE_FILE='/etc/systemd/system/sing-box-vps-health.service'
HEALTH_TIMER_FILE='/etc/systemd/system/sing-box-vps-health.timer'
WITH_WARP_UPSTREAM=0
VLESS_PORT=443
HY2_PORT=443
SS_PORT=8443
SS_INNER_PORT=8444
VPS_IP=''
SNI='www.speedtest.net'
REALITY_SHORT_ID=''
HY2_CERT=''
HY2_KEY=''
HY2_SNI=''
HY2_INSECURE=1
# Salamander is the broadly interoperable Hysteria2 obfuscator for QR imports.
# Gecko remains available through --hy2-obfs gecko for clients that explicitly support it.
HY2_OBFS_TYPE='salamander'
SKIP_SINGBOX_UPDATE=0
FORCE=0
ACTION='install'
ROLLBACK_ENABLED=0
ROLLBACK_CONFIG_BACKUP=''
ROLLBACK_STATE_BACKUP=''
ROLLBACK_SERVICE_BACKUP=''
ROLLBACK_CONFIG_FILE_EXISTED=0
ROLLBACK_STATE_FILE_EXISTED=0
ROLLBACK_SERVICE_FILE_EXISTED=0

color() { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
info() { color '1;34' "[INFO] $*"; }
warn() { color '1;33' "[WARN] $*" >&2; }
die() { color '1;31' "[ERROR] $*" >&2; exit 1; }

restore_previous_service_on_failure() {
  local exit_status=$?
  local backup_dir=''
  if (( exit_status != 0 && ROLLBACK_ENABLED )); then
    backup_dir="$(dirname "$ROLLBACK_CONFIG_BACKUP")"
    if (( ROLLBACK_CONFIG_FILE_EXISTED )); then
      warn 'Installation did not complete; restoring the prior sing-box configuration and service.'
      [[ -f $ROLLBACK_CONFIG_BACKUP ]] \
        && cp -af "$ROLLBACK_CONFIG_BACKUP" "$CONFIG_FILE" \
        || warn 'Could not restore the prior sing-box configuration.'
    else
      warn 'Installation did not complete; removing the incomplete first-install configuration.'
      rm -f "$CONFIG_FILE"
    fi
    if (( ROLLBACK_STATE_FILE_EXISTED )); then
      [[ -f $ROLLBACK_STATE_BACKUP ]] \
        && cp -af "$ROLLBACK_STATE_BACKUP" "$STATE_FILE" \
        || warn 'Could not restore the prior credentials file.'
    else
      rm -f "$STATE_FILE"
    fi
    if (( ROLLBACK_SERVICE_FILE_EXISTED )); then
      [[ -f $ROLLBACK_SERVICE_BACKUP ]] \
        && cp -af "$ROLLBACK_SERVICE_BACKUP" "$SERVICE_FILE" \
        || warn 'Could not restore the prior sing-box service unit.'
    else
      rm -f "$SERVICE_FILE"
    fi
    systemctl daemon-reload || true
    if (( ROLLBACK_CONFIG_FILE_EXISTED )); then
      systemctl restart sing-box || warn 'Could not restart the prior sing-box service automatically.'
    else
      systemctl disable --now sing-box >/dev/null 2>&1 || true
    fi
    rm -f "$ROLLBACK_CONFIG_BACKUP" "$ROLLBACK_STATE_BACKUP" "$ROLLBACK_SERVICE_BACKUP"
    rmdir "$backup_dir" 2>/dev/null || true
  fi
  trap - EXIT
  exit "$exit_status"
}
trap restore_previous_service_on_failure EXIT

begin_force_rollback() {
  local backup_dir
  # check_target_is_safe has already required --force for any existing installer
  # artifact. Keep a transaction even for a first install so a failed start does
  # not leave a configuration that blocks the next normal run.
  backup_dir="$(mktemp -d /tmp/sing-box-vps-rollback.XXXXXX)"
  ROLLBACK_CONFIG_BACKUP="$backup_dir/config.json"
  ROLLBACK_STATE_BACKUP="$backup_dir/credentials.env"
  ROLLBACK_SERVICE_BACKUP="$backup_dir/sing-box.service"
  if [[ -e $CONFIG_FILE ]]; then
    cp -a "$CONFIG_FILE" "$ROLLBACK_CONFIG_BACKUP"
    ROLLBACK_CONFIG_FILE_EXISTED=1
  else
    ROLLBACK_CONFIG_FILE_EXISTED=0
  fi
  if [[ -e $STATE_FILE ]]; then
    cp -a "$STATE_FILE" "$ROLLBACK_STATE_BACKUP"
    ROLLBACK_STATE_FILE_EXISTED=1
  else
    ROLLBACK_STATE_FILE_EXISTED=0
  fi
  if [[ -e $SERVICE_FILE ]]; then
    cp -a "$SERVICE_FILE" "$ROLLBACK_SERVICE_BACKUP"
    ROLLBACK_SERVICE_FILE_EXISTED=1
  else
    ROLLBACK_SERVICE_FILE_EXISTED=0
  fi
  ROLLBACK_ENABLED=1
  systemctl stop sing-box 2>/dev/null || true
}

commit_force_rollback() {
  local backup_dir=''
  if [[ -n $ROLLBACK_CONFIG_BACKUP ]]; then backup_dir="$(dirname "$ROLLBACK_CONFIG_BACKUP")"; fi
  ROLLBACK_ENABLED=0
  rm -f "$ROLLBACK_CONFIG_BACKUP" "$ROLLBACK_STATE_BACKUP" "$ROLLBACK_SERVICE_BACKUP"
  [[ -z $backup_dir ]] || rmdir "$backup_dir" 2>/dev/null || true
  ROLLBACK_CONFIG_BACKUP=''
  ROLLBACK_STATE_BACKUP=''
  ROLLBACK_SERVICE_BACKUP=''
  ROLLBACK_CONFIG_FILE_EXISTED=0
  ROLLBACK_STATE_FILE_EXISTED=0
  ROLLBACK_SERVICE_FILE_EXISTED=0
}
usage() {
  cat <<'EOF'
Usage: sudo bash install.sh [options]

Options:
  --ip ADDRESS        Public IPv4/IPv6 or DNS name placed into client links.
  --sni DOMAIN        REALITY/ShadowTLS camouflage domain (default: www.speedtest.net).
  --vless-port PORT   VLESS+REALITY TCP port (default: 443).
  --hy2-port PORT     Hysteria2 UDP port (default: 443).
  --hy2-cert PATH     Existing PEM certificate for Hysteria2 (requires --hy2-key and --hy2-sni).
  --hy2-key PATH      Existing PEM private key for Hysteria2.
  --hy2-sni DOMAIN    Certificate hostname used by Hysteria2 clients.
  --hy2-obfs TYPE     Hysteria2 obfuscation: salamander (default) or gecko.
  --skip-singbox-update  Keep an already-installed sing-box binary; useful for offline testing only.
  --ss-port PORT      ShadowTLS v3 + Shadowsocks 2022 TCP port (default: 8443).
  --with-warp-upstream  Route proxy clients through the official warp-cli WARP
                      client in loopback-only SOCKS5 mode; this does not alter
                      the VPS default route or SSH traffic.
  --upgrade-core       Update sing-box and restart it without replacing nodes or credentials.
  --status             Show service, configuration, and WARP monitor status.
  --health-check       Verify the configuration, service, and enabled WARP upstream.
  --export-client-profile  Rebuild sing-box client JSON files only; server nodes stay unchanged.
  --force             Replace an existing /etc/sing-box/config.json (a timestamped
                      backup is still made).
  -h, --help          Show this help.

Requirements: a Linux VPS with a public address, root/sudo, outbound HTTPS access,
and inbound TCP 443, UDP 443, and TCP 8443 permitted at the provider firewall.
The optional WARP upstream needs outbound access to Cloudflare; it opens only a
loopback SOCKS5 listener on 127.0.0.1:40000, never an inbound public port.
EOF
}

while (($#)); do
  case "$1" in
    --ip) [[ ${2:-} ]] || die '--ip needs an address'; VPS_IP="$2"; shift 2 ;;
    --sni) [[ ${2:-} ]] || die '--sni needs a domain'; SNI="$2"; shift 2 ;;
    --vless-port) [[ ${2:-} ]] || die '--vless-port needs a port'; VLESS_PORT="$2"; shift 2 ;;
    --hy2-port) [[ ${2:-} ]] || die '--hy2-port needs a port'; HY2_PORT="$2"; shift 2 ;;
    --hy2-cert) [[ ${2:-} ]] || die '--hy2-cert needs a path'; HY2_CERT="$2"; shift 2 ;;
    --hy2-key) [[ ${2:-} ]] || die '--hy2-key needs a path'; HY2_KEY="$2"; shift 2 ;;
    --hy2-sni) [[ ${2:-} ]] || die '--hy2-sni needs a domain'; HY2_SNI="$2"; shift 2 ;;
    --hy2-obfs) [[ ${2:-} ]] || die '--hy2-obfs needs a type'; HY2_OBFS_TYPE="$2"; shift 2 ;;
    --skip-singbox-update) SKIP_SINGBOX_UPDATE=1; shift ;;
    --ss-port) [[ ${2:-} ]] || die '--ss-port needs a port'; SS_PORT="$2"; shift 2 ;;
    --with-warp-upstream|--with-warp) WITH_WARP_UPSTREAM=1; shift ;;

    --upgrade-core) ACTION='upgrade-core'; shift ;;
    --status) ACTION='status'; shift ;;
    --health-check) ACTION='health-check'; shift ;;
    --export-client-profile) ACTION='export-client-profile'; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die 'Run as root: sudo bash install.sh'
[[ $(uname -s) == Linux ]] || die 'This installer supports Linux VPS hosts only.'
command -v systemctl >/dev/null || die 'systemd is required by this installer.'
[[ -d /run/systemd/system ]] || die 'systemd is not running (containers are unsupported).'

valid_host() {
  [[ $1 =~ ^[A-Za-z0-9._:-]+$ ]]
}
valid_domain() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]] && [[ $1 != *..* ]]
}
valid_port() {
  [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

install_prerequisites() {
  local pm=''
  if command -v apt-get >/dev/null; then pm=apt
  elif command -v dnf >/dev/null; then pm=dnf
  elif command -v yum >/dev/null; then pm=yum
  elif command -v pacman >/dev/null; then pm=pacman
  else die 'Supported package manager not found (apt, dnf, yum, or pacman).'; fi

  info "Installing prerequisite tools with $pm"
  case "$pm" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get update -y; DEBIAN_FRONTEND=noninteractive apt-get install -y curl openssl ca-certificates iproute2 ;;
    dnf) dnf install -y curl openssl ca-certificates iproute ;;
    yum) yum install -y curl openssl ca-certificates iproute ;;
    pacman) pacman -S --needed --noconfirm curl openssl ca-certificates iproute2 ;;
  esac
  # Optional: do not make a deployment fail merely because a minimal distro has
  # no fail2ban package repository enabled.
  case "$pm" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban >/dev/null 2>&1 || warn 'fail2ban was not installed (optional).';;
    dnf) dnf install -y fail2ban >/dev/null 2>&1 || warn 'fail2ban was not installed (optional).';;
    yum) yum install -y fail2ban >/dev/null 2>&1 || warn 'fail2ban was not installed (optional).';;
    pacman) pacman -S --noconfirm fail2ban >/dev/null 2>&1 || warn 'fail2ban was not installed (optional).';;
  esac
}

get_public_ip() {
  local candidate=''
  for endpoint in 'https://api.ipify.org' 'https://ifconfig.me/ip' 'https://ipv4.icanhazip.com'; do
    candidate="$(curl -4fsS --connect-timeout 5 --max-time 10 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ $candidate =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then printf '%s' "$candidate"; return 0; fi
  done
  return 1
}

install_sing_box() {
  local pm=''
  if (( SKIP_SINGBOX_UPDATE )); then
    command -v sing-box >/dev/null || die '--skip-singbox-update requires an already-installed sing-box binary.'
    warn 'Skipping sing-box update by request; this is intended only for an offline test or a controlled maintenance run.'
    return
  fi
  if command -v sing-box >/dev/null; then
    info "Updating sing-box from its official signed package source: $(sing-box version | head -n1)"
  else
    info 'Installing current stable sing-box from its official signed package source'
  fi
  if command -v apt-get >/dev/null; then pm='apt'
  elif command -v dnf >/dev/null; then pm='dnf'
  elif command -v yum >/dev/null; then pm='yum'
  elif command -v pacman >/dev/null; then pm='pacman'
  else die 'Supported package manager not found for sing-box.'; fi
  case "$pm" in
    apt)
      install -d -m 755 /etc/apt/keyrings
      curl -fsSL --proto '=https' --tlsv1.2 https://sing-box.app/gpg.key -o "$SINGBOX_APT_KEYRING" \
        || die 'Could not download the official sing-box package signing key.'
      chmod a+r "$SINGBOX_APT_KEYRING"
      cat > "$SINGBOX_APT_REPO" <<EOF
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: $SINGBOX_APT_KEYRING
EOF
      DEBIAN_FRONTEND=noninteractive apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y sing-box
      ;;
    dnf|yum)
      curl -fsSL --proto '=https' --tlsv1.2 https://sing-box.app/sing-box.repo -o "$SINGBOX_RPM_REPO" \
        || die 'Could not download the official sing-box RPM repository definition.'
      "$pm" install -y sing-box
      ;;
    pacman)
      # Do not use pacman -Sy here: refreshing databases without a full upgrade can
      # leave an Arch host in a partial-upgrade state.
      pacman -S --needed --noconfirm sing-box
      ;;
  esac
  command -v sing-box >/dev/null || die 'sing-box package installation completed but sing-box is not in PATH.'
}

install_qrencode() {
  local pm=''
  command -v qrencode >/dev/null && return 0
  if command -v apt-get >/dev/null; then pm=apt
  elif command -v dnf >/dev/null; then pm=dnf
  elif command -v yum >/dev/null; then pm=yum
  elif command -v pacman >/dev/null; then pm=pacman
  else warn 'qrencode was not installed: unsupported package manager.'; return 0; fi
  info "Installing qrencode with $pm"
  case "$pm" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y qrencode || warn 'qrencode installation failed; links will still be printed.' ;;
    dnf) dnf install -y qrencode || warn 'qrencode installation failed; links will still be printed.' ;;
    yum) yum install -y qrencode || warn 'qrencode installation failed; links will still be printed.' ;;
    pacman) pacman -S --needed --noconfirm qrencode || warn 'qrencode installation failed; links will still be printed.' ;;
  esac
}

install_warp_cli() {
  local pm='' codename='' key_tmp=''
  (( WITH_WARP_UPSTREAM )) || return 0
  if command -v warp-cli >/dev/null; then
    info "Using installed official warp-cli: $(warp-cli --version)"
    systemctl enable --now warp-svc
    return
  fi
  if command -v apt-get >/dev/null; then pm='apt'
  elif command -v dnf >/dev/null; then pm='dnf'
  elif command -v yum >/dev/null; then pm='yum'
  else die 'Official Cloudflare WARP packages are supported here only on apt, dnf, or yum hosts.'; fi

  info "Installing official Cloudflare WARP client with $pm"
  case "$pm" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get install -y gpg lsb-release
      command -v lsb_release >/dev/null || die 'lsb_release is required to configure the Cloudflare apt repository.'
      codename="$(lsb_release -cs)"
      [[ $codename =~ ^[a-z0-9]+$ ]] || die "Unsupported apt distribution codename: $codename"
      key_tmp="$(mktemp)"
      curl -fsSL --proto '=https' --tlsv1.2 https://pkg.cloudflareclient.com/pubkey.gpg -o "$key_tmp" || die 'Could not download the Cloudflare package signing key.'
      gpg --yes --dearmor --output "$WARP_APT_KEYRING" "$key_tmp" || die 'Could not install the Cloudflare package signing key.'
      # The installer uses umask 077, but apt verifies signatures as the _apt user.
      # Keep this public signing key world-readable while all node credentials stay 0600.
      chmod 644 "$WARP_APT_KEYRING" || die 'Could not make the Cloudflare package signing key readable by apt.'
      rm -f "$key_tmp"
      printf 'deb [signed-by=%s] https://pkg.cloudflareclient.com/ %s main\n' "$WARP_APT_KEYRING" "$codename" > "$WARP_APT_REPO"
      DEBIAN_FRONTEND=noninteractive apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y cloudflare-warp
      ;;
    dnf|yum)
      curl -fsSL --proto '=https' --tlsv1.2 https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo -o /etc/yum.repos.d/cloudflare-warp.repo || die 'Could not download the Cloudflare WARP repository definition.'
      "$pm" install -y cloudflare-warp
      ;;
  esac
  command -v warp-cli >/dev/null || die 'cloudflare-warp installation completed but warp-cli is not in PATH.'
  systemctl enable --now warp-svc
}

prepare_warp_cli() {
  local trace='' attempt='' proxy_listener=''
  (( WITH_WARP_UPSTREAM )) || return 0
  # A pre-existing listener is safe only when it is the existing WARP daemon.
  # Never point sing-box at an unrelated local process by mistake.
  proxy_listener="$(ss -H -ltnp "sport = :$WARP_PROXY_PORT" 2>/dev/null || true)"
  if [[ -n $proxy_listener && $proxy_listener != *'"warp-svc"'* ]]; then
    die "TCP $WARP_PROXY_PORT is already owned by another process; it is reserved for warp-cli's loopback SOCKS5 listener."
  fi
  install_warp_cli
  systemctl is-active --quiet warp-svc || die 'warp-svc is not active after installation.'
  if ! warp-cli registration show >/dev/null 2>&1; then
    info 'Registering this VPS with the official Cloudflare WARP client'
    warp-cli --accept-tos registration new || die 'warp-cli could not register this VPS with Cloudflare WARP. Existing sing-box service was not changed.'
  else
    info 'Reusing the existing official warp-cli registration on this VPS'
  fi
  warp-cli disconnect >/dev/null 2>&1 || true
  warp-cli tunnel protocol set MASQUE || die 'Could not set the MASQUE tunnel protocol required by warp-cli proxy mode.'
  warp-cli proxy port "$WARP_PROXY_PORT" || die 'Could not set the warp-cli loopback SOCKS5 port.'
  warp-cli mode proxy || die 'Could not set warp-cli proxy mode.'
  warp-cli connect || die 'Could not connect warp-cli.'
  for ((attempt = 1; attempt <= 20; attempt++)); do
    proxy_listener="$(ss -H -ltnp "sport = :$WARP_PROXY_PORT" 2>/dev/null || true)"
    if [[ $proxy_listener == *'127.0.0.1:'* && $proxy_listener == *'"warp-svc"'* ]]; then break; fi
    sleep 1
  done
  [[ $proxy_listener == *'127.0.0.1:'* && $proxy_listener == *'"warp-svc"'* ]] \
    || die "warp-cli did not open its loopback SOCKS5 listener on 127.0.0.1:$WARP_PROXY_PORT."
  trace="$(curl -fsS --proxy "socks5h://127.0.0.1:$WARP_PROXY_PORT" --connect-timeout 8 --max-time 30 https://www.cloudflare.com/cdn-cgi/trace)" || die 'WARP connection test through the warp-cli SOCKS5 listener failed.'
  printf '%s\n' "$trace" | grep -Eq '^warp=(on|plus)$' || die 'warp-cli connected but Cloudflare did not report an active WARP tunnel.'
  info "Official warp-cli is connected in loopback-only SOCKS5 mode on 127.0.0.1:$WARP_PROXY_PORT."
}
validate_warp_reserved_ports() {
  (( WITH_WARP_UPSTREAM )) || return 0
  [[ $VLESS_PORT != "$WARP_HEALTH_PORT" && $SS_PORT != "$WARP_HEALTH_PORT" ]] \
    || die "TCP $WARP_HEALTH_PORT is reserved for the loopback-only WARP health checker; choose another VLESS/ShadowTLS port."
  [[ $VLESS_PORT != "$WARP_PROXY_PORT" && $SS_PORT != "$WARP_PROXY_PORT" ]] \
    || die "TCP $WARP_PROXY_PORT is reserved for warp-cli's loopback SOCKS5 listener; choose another VLESS/ShadowTLS port."
}

check_target_is_safe() {
  if (( FORCE != 1 )) && { [[ -e $CONFIG_FILE ]] || [[ -e $STATE_FILE ]] || [[ -e $SERVICE_FILE ]]; }; then
    die 'Existing sing-box installer artifacts were found. Nothing has been changed; re-run with --force only if you intend to replace them.'
  fi
}

check_ports() {
  command -v ss >/dev/null || die 'The ss command is required to check port conflicts.'
  local tcp udp
  tcp="$(ss -H -ltn "sport = :$VLESS_PORT" || true)"
  udp="$(ss -H -lun "sport = :$HY2_PORT" || true)"
  [[ -z $tcp ]] || die "TCP $VLESS_PORT is already in use. Free it or change the script before proceeding."
  [[ -z $udp ]] || die "UDP $HY2_PORT is already in use. Free it or change the script before proceeding."
  [[ -z "$(ss -H -ltn "sport = :$SS_PORT" || true)" ]] || die "TCP $SS_PORT is already in use."
  [[ -z "$(ss -H -ltn "sport = :$SS_INNER_PORT" || true)" ]] || die "TCP $SS_INNER_PORT is already in use; reserved for internal SS2022."
  if (( WITH_WARP_UPSTREAM )); then
    [[ -z "$(ss -H -ltn "sport = :$WARP_HEALTH_PORT" || true)" ]] || die "TCP $WARP_HEALTH_PORT is already in use; it is reserved for the local WARP health check."
  fi
}

open_firewall_if_active() {
  local provider_ports="TCP $VLESS_PORT, UDP $HY2_PORT, TCP $SS_PORT"
  if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    info 'Opening required ports in active UFW'
    ufw allow "$VLESS_PORT/tcp"; ufw allow "$HY2_PORT/udp"
    ufw allow "$SS_PORT/tcp"
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    info 'Opening required ports in active firewalld'
    firewall-cmd --permanent --add-port="$VLESS_PORT/tcp"
    firewall-cmd --permanent --add-port="$HY2_PORT/udp"
    firewall-cmd --permanent --add-port="$SS_PORT/tcp"
    firewall-cmd --reload
  else
    warn "No active host firewall was changed. Open $provider_ports in your VPS provider firewall/security group."
  fi
}

enable_bbr() {
  cat > /etc/sysctl.d/99-sing-box-vps.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null || warn 'Could not apply BBR settings; the VPS kernel may not include BBR.'
  if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    info 'BBR congestion control is enabled.'
  else
    warn 'BBR is unavailable in this kernel; sing-box will still operate normally.'
  fi
}

configure_fail2ban() {
  command -v fail2ban-client >/dev/null || { warn 'fail2ban is unavailable; SSH brute-force protection was not configured.'; return 0; }
  install -d -m 755 /etc/fail2ban/jail.d
  # Use a dedicated jail name. Never overwrite the common sshd-local.conf file,
  # which may contain the VPS owner's existing SSH protection policy.
  cat > "$FAIL2BAN_JAIL_FILE" <<EOF
[$FAIL2BAN_JAIL_NAME]
enabled = true
filter = sshd
backend = systemd
port = ssh
maxretry = 5
findtime = 10m
bantime = 1h
EOF
  if systemctl is-active --quiet fail2ban; then
    fail2ban-client reload || warn 'Fail2Ban is active but could not reload the dedicated SSH jail.'
  else
    systemctl enable --now fail2ban || warn 'fail2ban could not be started.'
  fi
  fail2ban-client status "$FAIL2BAN_JAIL_NAME" >/dev/null 2>&1 \
    && info 'Dedicated Fail2Ban SSH jail is active.' \
    || warn 'Fail2Ban is running but the dedicated SSH jail is unavailable.'
}
write_config() {
  local timestamp private_key public_key reality_pair candidate_file
  local uuid hy2_password hy2_obfs hy2_obfs_options ss_password shadowtls_password cert_path key_path reality_short_id
  local warp_health_inbound route_section outbound_section warp_backend
  timestamp="$(date +%Y%m%d%H%M%S)"
  if [[ -e $CONFIG_FILE ]]; then
    cp -a "$CONFIG_FILE" "$CONFIG_FILE.backup-$timestamp"
    [[ ! -e $STATE_FILE ]] || cp -a "$STATE_FILE" "$STATE_FILE.backup-$timestamp"
    info "Existing configuration backed up with .$timestamp suffix."
  fi
  candidate_file="$CONFIG_DIR/config.json.new.$$"
  trap 'rm -f "$candidate_file"' RETURN
  install -d -m 700 "$CONFIG_DIR"
  if [[ -n $HY2_CERT || -n $HY2_KEY ]]; then
    [[ -n $HY2_CERT && -n $HY2_KEY ]] || die 'Provide both --hy2-cert and --hy2-key, or neither.'
    [[ -r $HY2_CERT && -r $HY2_KEY ]] || die 'Hysteria2 certificate or private key is not readable.'
    [[ -n $HY2_SNI ]] || die '--hy2-sni is required when using a supplied Hysteria2 certificate.'
    cert_path="$HY2_CERT"; key_path="$HY2_KEY"; HY2_INSECURE=0
  else
    cert_path="$CONFIG_DIR/hysteria2-cert.pem"
    key_path="$CONFIG_DIR/hysteria2-key.pem"
    HY2_SNI="$VPS_IP"; HY2_INSECURE=1
    if [[ ! -s $cert_path || ! -s $key_path ]]; then
      info 'Creating a self-signed ECDSA certificate for Hysteria2'
      openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -sha256 -days 825 \
        -keyout "$key_path" -out "$cert_path" -subj "/CN=$VPS_IP" >/dev/null 2>&1
      chmod 600 "$key_path"
    fi
  fi
  reality_pair="$(sing-box generate reality-keypair)"
  private_key="$(printf '%s\n' "$reality_pair" | sed -n 's/.*PrivateKey:[[:space:]]*//p' | head -n1)"
  public_key="$(printf '%s\n' "$reality_pair" | sed -n 's/.*PublicKey:[[:space:]]*//p' | head -n1)"
  [[ -n $private_key && -n $public_key ]] || die 'Could not parse sing-box REALITY keypair output.'
  uuid="$(cat /proc/sys/kernel/random/uuid)"
  reality_short_id="$(openssl rand -hex 4)"
  REALITY_SHORT_ID="$reality_short_id"
  hy2_password="$(openssl rand -hex 32)"
  hy2_obfs="$(openssl rand -hex 24)"
  hy2_obfs_options=''
  if [[ $HY2_OBFS_TYPE == gecko ]]; then
    hy2_obfs_options=', "min_packet_size": 512, "max_packet_size": 1200'
  fi
  ss_password="$(openssl rand -base64 32 | tr -d '\n')"
  shadowtls_password="$(openssl rand -base64 24 | tr -d '\n')"

  warp_health_inbound=''
  route_section=''
  outbound_section='{ "type": "direct", "tag": "direct" }'
  warp_backend='none'
  if (( WITH_WARP_UPSTREAM )); then
    warp_backend='warp-cli-socks5'
    # The official WARP client owns the tunnel. sing-box only sends proxy-client
    # traffic to its loopback-only SOCKS5 listener, leaving host routes and SSH alone.
    outbound_section=$(cat <<EOF
    {
      "type": "socks", "tag": "warp-cli",
      "server": "127.0.0.1", "server_port": $WARP_PROXY_PORT, "version": "5"
    },
    { "type": "direct", "tag": "direct" }
EOF
)
    route_section=',
  "route": { "final": "warp-cli" }'
    warp_health_inbound=$(cat <<EOF
    {
      "type": "mixed", "tag": "warp-health-local",
      "listen": "127.0.0.1", "listen_port": $WARP_HEALTH_PORT
    },
EOF
)
  fi
  cat > "$candidate_file" <<EOF
{
  "log": { "level": "warn", "timestamp": true },

  "inbounds": [
$warp_health_inbound
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": $VLESS_PORT,
      "users": [{ "name": "main", "uuid": "$uuid", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$SNI", "server_port": 443 },
          "private_key": "$private_key",
          "short_id": ["$reality_short_id"]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hysteria2-salamander",
      "listen": "::",
      "listen_port": $HY2_PORT,
      "users": [{ "name": "main", "password": "$hy2_password" }],
      "obfs": { "type": "$HY2_OBFS_TYPE", "password": "$hy2_obfs"$hy2_obfs_options },
      "ignore_client_bandwidth": true,
      "bbr_profile": "standard",
      "tls": {
        "enabled": true,
        "server_name": "$HY2_SNI",
        "certificate_path": "$cert_path",
        "key_path": "$key_path"
      },
      "masquerade": { "type": "string", "status_code": 404, "content": "Not Found" }
    },
    {
      "type": "shadowtls",
      "tag": "shadowtls-v3",
      "listen": "::",
      "listen_port": $SS_PORT,
      "version": 3,
      "users": [{ "name": "main", "password": "$shadowtls_password" }],
      "handshake": { "server": "$SNI", "server_port": 443 },
      "strict_mode": true,
      "detour": "shadowsocks-2022"
    },
    {
      "type": "shadowsocks",
      "tag": "shadowsocks-2022",
      "listen": "127.0.0.1",
      "listen_port": $SS_INNER_PORT,
      "network": "tcp",
      "method": "2022-blake3-aes-256-gcm",
      "password": "$ss_password"
    }
  ],
  "outbounds": [
$outbound_section
  ]$route_section
}
EOF
  chmod 600 "$candidate_file"
  sing-box check -c "$candidate_file"
  mv -f "$candidate_file" "$CONFIG_FILE"
  trap - RETURN

  cat > "$STATE_FILE" <<EOF
# Generated by $APP_NAME at $(date -Is). Keep this file secret.
VPS_IP='$VPS_IP'
REALITY_SNI='$SNI'
VLESS_UUID='$uuid'
REALITY_PUBLIC_KEY='$public_key'
REALITY_SHORT_ID='$reality_short_id'
VLESS_PORT='$VLESS_PORT'
HY2_PORT='$HY2_PORT'
SS_PORT='$SS_PORT'
SS_INNER_PORT='$SS_INNER_PORT'
HY2_PASSWORD='$hy2_password'
HY2_OBFS_PASSWORD='$hy2_obfs'
HY2_OBFS_TYPE='$HY2_OBFS_TYPE'
HY2_SNI='$HY2_SNI'
HY2_INSECURE='$HY2_INSECURE'
SS2022_PASSWORD='$ss_password'
SHADOWTLS_PASSWORD='$shadowtls_password'
WARP_UPSTREAM_ENABLED='$WITH_WARP_UPSTREAM'
WARP_BACKEND='$warp_backend'
WARP_PROXY_PORT='$WARP_PROXY_PORT'
EOF
  chmod 600 "$STATE_FILE"
}

write_service() {
  local sb_bin unit_dependencies
  sb_bin="$(command -v sing-box)"
  unit_dependencies=$(cat <<'EOF'
After=network-online.target
Wants=network-online.target
EOF
)
  if (( WITH_WARP_UPSTREAM )); then
    unit_dependencies=$(cat <<'EOF'
After=network-online.target warp-svc.service
Wants=network-online.target
Requires=warp-svc.service
EOF
)
  fi
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box universal proxy service
$unit_dependencies

[Service]
Type=simple
ExecStart=$sb_bin run -c $CONFIG_FILE
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}
generate_qr_codes() {
  local vless_uri="$1" hy2_uri="$2"
  command -v qrencode >/dev/null || { warn 'qrencode is unavailable; no VLESS or Hysteria2 QR images were created.'; return 0; }
  install -d -m 700 "$QR_DIR"
  qrencode -l L -s 8 -o "$QR_DIR/vless-reality.png" "$vless_uri" || { warn 'Could not create VLESS REALITY QR image.'; return 0; }
  qrencode -l L -s 8 -o "$QR_DIR/hysteria2.png" "$hy2_uri" || { warn 'Could not create Hysteria2 QR image.'; return 0; }
  chmod 600 "$QR_DIR/vless-reality.png" "$QR_DIR/hysteria2.png"
  cat <<EOF

VLESS + REALITY QR PNG for Shadowrocket / URI clients (copy securely; it contains credentials):
  $QR_DIR/vless-reality.png

Hysteria2 QR PNG (copy securely; it contains credentials):
  $QR_DIR/hysteria2.png
EOF
  printf '\nTerminal QR: VLESS + REALITY\n'
  qrencode -t ANSIUTF8 "$vless_uri" || warn 'Could not render terminal VLESS REALITY QR.'
  printf '\nTerminal QR: Hysteria2\n'
  qrencode -t ANSIUTF8 "$hy2_uri" || warn 'Could not render terminal Hysteria2 QR.'
}
generate_singbox_cn_bypass_profile() {
  local profile_path="$CLIENT_DIR/sing-box-vless-cn-bypass.json"
  install -d -m 700 "$CLIENT_DIR"
  cat > "$profile_path" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "dns": {
    "servers": [
      {
        "tag": "google", "type": "tls", "server": "8.8.8.8", "server_port": 853,
        "tls": { "enabled": true, "server_name": "dns.google" }, "detour": "proxy"
      },
      {
        "tag": "local", "type": "https", "server": "223.5.5.5", "server_port": 443,
        "tls": { "enabled": true, "server_name": "dns.alidns.com" }
      }
    ],
    "rules": [
      { "rule_set": "geosite-geolocation-cn", "action": "route", "server": "local" }
    ],
    "final": "google"
  },
  "inbounds": [
    {
      "type": "tun", "tag": "tun-in",
      "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
      "auto_route": true, "strict_route": true
    }
  ],
  "outbounds": [
    {
      "type": "vless", "tag": "proxy",
      "server": "$VPS_IP", "server_port": $VLESS_PORT,
      "uuid": "$VLESS_UUID", "flow": "xtls-rprx-vision", "network": "tcp",
      "tls": {
        "enabled": true, "server_name": "$REALITY_SNI",
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": {
          "enabled": true, "public_key": "$REALITY_PUBLIC_KEY",
          "short_id": "$REALITY_SHORT_ID"
        }
      }
    },
    { "type": "direct", "tag": "direct" }
  ],
  "http_clients": [{ "tag": "proxy-download", "detour": "proxy" }],
  "route": {
    "default_domain_resolver": "local",
    "default_http_client": "proxy-download",
    "auto_detect_interface": true,
    "rules": [
      { "action": "sniff" },
      {
        "type": "logical", "mode": "or",
        "rules": [{ "protocol": "dns" }, { "port": 53 }],
        "action": "hijack-dns"
      },
      { "ip_is_private": true, "action": "route", "outbound": "direct" },
      { "rule_set": "geosite-geolocation-cn", "action": "route", "outbound": "direct" },
      {
        "type": "logical", "mode": "and",
        "rules": [
          { "rule_set": "geoip-cn" },
          { "rule_set": "geosite-geolocation-!cn", "invert": true }
        ],
        "action": "route", "outbound": "direct"
      }
    ],
    "rule_set": [
      {
        "type": "remote", "tag": "geosite-geolocation-cn", "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-cn.srs",
        "http_client": "proxy-download", "update_interval": "7d"
      },
      {
        "type": "remote", "tag": "geosite-geolocation-!cn", "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-!cn.srs",
        "http_client": "proxy-download", "update_interval": "7d"
      },
      {
        "type": "remote", "tag": "geoip-cn", "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
        "http_client": "proxy-download", "update_interval": "7d"
      }
    ],
    "final": "proxy"
  },
  "experimental": { "cache_file": { "enabled": true } }
}
EOF
  chmod 600 "$profile_path"
  sing-box check -c "$profile_path" || die 'Generated VLESS China-bypass client profile failed sing-box validation.'
}

generate_singbox_shadowtls_ss2022_profile() {
  local profile_path="$CLIENT_DIR/sing-box-shadowtls-ss2022.json"
  if ! [[ -v SHADOWTLS_PASSWORD ]] || [[ -z "$SHADOWTLS_PASSWORD" ]]; then
    warn 'No ShadowTLS credential was found; skip the ShadowTLS + Shadowsocks client profile. Reinstall with --force to create it.'
    return 0
  fi
  install -d -m 700 "$CLIENT_DIR"
  cat > "$profile_path" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "dns": {
    "servers": [
      {
        "tag": "remote", "type": "tls", "server": "1.1.1.1", "server_port": 853,
        "tls": { "enabled": true, "server_name": "cloudflare-dns.com" },
        "detour": "ss2022-over-shadowtls"
      }
    ],
    "final": "remote"
  },
  "inbounds": [
    {
      "type": "tun", "tag": "tun-in",
      "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
      "auto_route": true, "strict_route": true
    }
  ],
  "outbounds": [
    {
      "type": "shadowsocks", "tag": "ss2022-over-shadowtls",
      "server": "$VPS_IP", "server_port": $SS_PORT,
      "method": "2022-blake3-aes-256-gcm", "password": "$SS2022_PASSWORD",
      "network": "tcp", "detour": "shadowtls"
    },
    {
      "type": "shadowtls", "tag": "shadowtls",
      "server": "$VPS_IP", "server_port": $SS_PORT,
      "version": 3, "password": "$SHADOWTLS_PASSWORD",
      "tls": {
        "enabled": true, "server_name": "$REALITY_SNI",
        "utls": { "enabled": true, "fingerprint": "chrome" }
      }
    },
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "auto_detect_interface": true,
    "rules": [
      { "action": "sniff" },
      {
        "type": "logical", "mode": "or",
        "rules": [{ "protocol": "dns" }, { "port": 53 }],
        "action": "hijack-dns"
      },
      { "ip_is_private": true, "action": "route", "outbound": "direct" }
    ],
    "final": "ss2022-over-shadowtls"
  }
}
EOF
  chmod 600 "$profile_path"
  sing-box check -c "$profile_path" || die 'Generated ShadowTLS + Shadowsocks client profile failed sing-box validation.'
}
print_links() {
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  local uri_host hy2_options vless_uri hy2_uri
  uri_host="$VPS_IP"
  # URI authorities require brackets around an IPv6 literal.
  [[ $uri_host == *:* ]] && uri_host="[$uri_host]"
  hy2_options="obfs=$HY2_OBFS_TYPE&obfs-password=$HY2_OBFS_PASSWORD"
  if [[ $HY2_INSECURE == 1 ]]; then hy2_options="insecure=1&$hy2_options"
  else hy2_options="sni=$HY2_SNI&$hy2_options"; fi
  vless_uri="vless://$VLESS_UUID@$uri_host:$VLESS_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$REALITY_SNI&fp=chrome&pbk=$REALITY_PUBLIC_KEY&sid=$REALITY_SHORT_ID&type=tcp&headerType=none#$APP_NAME-REALITY"
  # Keep the empty path slash before the query: it is the canonical Hysteria2
  # URI form and is accepted by stricter QR importers such as Shadowrocket.
  hy2_uri="hysteria2://$HY2_PASSWORD@$uri_host:$HY2_PORT/?$hy2_options#$APP_NAME-HY2"

  generate_singbox_cn_bypass_profile
  generate_singbox_shadowtls_ss2022_profile

  cat <<EOF

=================================================================
Installed and validated. Credentials were saved at: $STATE_FILE
=================================================================

VLESS + REALITY (TCP $VLESS_PORT; Vision):
$vless_uri
Use $CLIENT_DIR/sing-box-vless-cn-bypass.json in sing-box for China-direct
routing. The separate VLESS QR is for Shadowrocket / URI clients and does not
contain the sing-box routing rules.

Hysteria2 + $HY2_OBFS_TYPE (UDP $HY2_PORT):
$hy2_uri

ShadowTLS v3 + Shadowsocks 2022 (TCP $SS_PORT):
Use $CLIENT_DIR/sing-box-shadowtls-ss2022.json in a current sing-box client.
A normal ss:// URI and QR are intentionally not printed: they cannot represent
the required ShadowTLS v3 authentication layer and would be unusable.

Client profiles (each contains credentials; copy securely):
  $CLIENT_DIR/sing-box-vless-cn-bypass.json
  $CLIENT_DIR/sing-box-shadowtls-ss2022.json

Operations:
  systemctl status sing-box
  journalctl -u sing-box -f
  sing-box check -c $CONFIG_FILE
  Re-run the same downloaded installer with --export-client-profile

Important: provider-level firewalls/security groups are outside this VPS. Open
TCP $VLESS_PORT, UDP $HY2_PORT, and TCP $SS_PORT there. Keep $STATE_FILE private.
EOF
  if (( WITH_WARP_UPSTREAM )); then
    cat <<EOF

WARP upstream: sing-box forwards proxy-client traffic to the official warp-cli
loopback SOCKS5 listener at 127.0.0.1:$WARP_PROXY_PORT. The VPS host route and
SSH path are unchanged. The warp-svc registration is managed by Cloudflare.
WARP availability and the observed egress IP are controlled by Cloudflare and
may change.
EOF
  fi
  generate_qr_codes "$vless_uri" "$hy2_uri"
}
export_client_profile() {
  [[ -r $STATE_FILE ]] || die "Credentials not found: $STATE_FILE"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  [[ -n ${VLESS_UUID:-} && -n ${REALITY_PUBLIC_KEY:-} && -n ${REALITY_SNI:-} && -n ${VPS_IP:-} ]] \
    || die 'The saved VLESS credentials are incomplete.'
  [[ -n ${REALITY_SHORT_ID:-} ]] \
    || die 'The saved deployment predates REALITY short-id support. Reinstall with --force to generate a matched server and client configuration.'
  VLESS_PORT="${VLESS_PORT:-443}"
  SS_PORT="${SS_PORT:-8443}"
  generate_singbox_cn_bypass_profile
  generate_singbox_shadowtls_ss2022_profile
  info "Client profiles rebuilt without changing server nodes: $CLIENT_DIR"
}
warp_is_configured() {
  [[ -f $STATE_FILE ]] && grep -q "^WARP_UPSTREAM_ENABLED='1'" "$STATE_FILE"
}

run_health_check() {
  local trace
  [[ -f $CONFIG_FILE ]] || die "Configuration not found: $CONFIG_FILE"
  command -v sing-box >/dev/null || die 'sing-box is not installed.'
  sing-box check -c "$CONFIG_FILE" >/dev/null || die 'sing-box configuration validation failed.'
  systemctl is-active --quiet sing-box || die 'sing-box service is not active.'
  if warp_is_configured; then
    trace="$(curl -fsS --proxy "socks5h://127.0.0.1:$WARP_HEALTH_PORT" --connect-timeout 8 --max-time 20 https://www.cloudflare.com/cdn-cgi/trace)" \
      || die 'WARP upstream health request failed through the loopback-only checker.'
    printf '%s\n' "$trace" | grep -Eq '^warp=(on|plus)$' || die 'WARP upstream did not report an active WARP tunnel.'
    info 'Health check passed: sing-box is active and the WARP upstream reports active.'
  else
    info 'Health check passed: sing-box is active (WARP upstream is not enabled).'
  fi
}

install_warp_health_monitor() {
  if (( ! WITH_WARP_UPSTREAM )); then
    systemctl disable --now sing-box-vps-health.timer >/dev/null 2>&1 || true
    rm -f "$HEALTHCHECK_FILE" "$HEALTH_SERVICE_FILE" "$HEALTH_TIMER_FILE"
    systemctl daemon-reload
    return 0
  fi
  cat > "$HEALTHCHECK_FILE" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
trace="\$(curl -fsS --proxy 'socks5h://127.0.0.1:$WARP_HEALTH_PORT' --connect-timeout 8 --max-time 20 https://www.cloudflare.com/cdn-cgi/trace)"
printf '%s\\n' "\$trace" | grep -Eq '^warp=(on|plus)$'
EOF
  chmod 700 "$HEALTHCHECK_FILE"
  cat > "$HEALTH_SERVICE_FILE" <<'EOF'
[Unit]
Description=Check sing-box WARP upstream health
After=sing-box.service warp-svc.service
Requires=warp-svc.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sing-box-vps-healthcheck
EOF
  cat > "$HEALTH_TIMER_FILE" <<'EOF'
[Unit]
Description=Run sing-box WARP health checks every 10 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=10min
RandomizedDelaySec=90s
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now sing-box-vps-health.timer
  info 'Installed a WARP health monitor: every 10 minutes (journalctl -u sing-box-vps-health.service).'
}

show_status() {
  [[ -f $CONFIG_FILE ]] || die "Configuration not found: $CONFIG_FILE"
  printf 'sing-box: %s\n' "$(sing-box version | head -n1)"
  printf 'service: %s\n' "$(systemctl is-active sing-box || true)"
  if warp_is_configured; then
    printf 'WARP upstream: enabled through warp-cli SOCKS5 on 127.0.0.1:%s\n' "${WARP_PROXY_PORT:-40000}"
    printf 'warp-svc: %s\n' "$(systemctl is-active warp-svc || true)"
    printf 'WARP monitor: %s\n' "$(systemctl is-active sing-box-vps-health.timer || true)"
    printf 'Run a live WARP test: sudo bash install.sh --health-check\n'
  else
    printf 'WARP upstream: disabled\n'
  fi
}

upgrade_core() {
  [[ -f $CONFIG_FILE ]] || die "Configuration not found: $CONFIG_FILE"
  install_sing_box
  sing-box check -c "$CONFIG_FILE" >/dev/null || die 'Existing sing-box configuration did not validate after the update.'
  systemctl restart sing-box
  sleep 2
  systemctl is-active --quiet sing-box || { journalctl -u sing-box -n 80 --no-pager; die 'sing-box did not start after the core update.'; }
  info "sing-box core updated without changing node credentials: $(sing-box version | head -n1)"
}

main() {
  valid_domain "$SNI" || die 'The REALITY SNI must be a domain name, not a URL.'
  valid_port "$VLESS_PORT" || die 'Invalid --vless-port value (1-65535).'
  valid_port "$HY2_PORT" || die 'Invalid --hy2-port value (1-65535).'
  valid_port "$SS_PORT" || die 'Invalid --ss-port value (1-65535).'
  [[ $HY2_OBFS_TYPE == gecko || $HY2_OBFS_TYPE == salamander ]] || die '--hy2-obfs must be gecko or salamander.'
  if [[ -n $HY2_CERT || -n $HY2_KEY ]]; then
    [[ -n $HY2_CERT && -n $HY2_KEY && -n $HY2_SNI ]] || die 'Hysteria2 trusted-certificate mode requires --hy2-cert, --hy2-key, and --hy2-sni together.'
    valid_host "$HY2_SNI" || die 'Invalid --hy2-sni value.'
  elif [[ -n $HY2_SNI ]]; then
    die '--hy2-sni is only used together with --hy2-cert and --hy2-key.'
  fi
  [[ $SS_PORT != "$VLESS_PORT" && $SS_PORT != "$HY2_PORT" ]] || die 'The ShadowTLS port must differ from both VLESS and Hysteria2 ports.'
  [[ $SS_PORT != "$SS_INNER_PORT" && $VLESS_PORT != "$SS_INNER_PORT" ]]     || die "Port $SS_INNER_PORT is reserved for the loopback-only Shadowsocks backend; choose another VLESS/ShadowTLS port."
  validate_warp_reserved_ports
  check_target_is_safe
  install_prerequisites
  install_qrencode
  if [[ -z $VPS_IP ]]; then VPS_IP="$(get_public_ip || true)"; fi
  [[ -n $VPS_IP ]] || die 'Could not discover the public IPv4 address. Re-run with --ip YOUR_SERVER_IP.'
  valid_host "$VPS_IP" || die 'Invalid --ip value.'
  # A forced replacement can safely reclaim ports from this service only. Other
  # software is still treated as a conflict by check_ports.
  # Complete WARP registration before touching an existing live service.
  prepare_warp_cli
  begin_force_rollback
  check_ports
  install_sing_box
  write_config
  write_service

  # The upstream package may have started its own unit during an upgrade. Restart
  # after installing our unit so the checked, newly written configuration is the
  # one actually serving traffic.
  systemctl enable sing-box
  systemctl restart sing-box
  # The configured upstream may fail shortly after systemd reports the process as
  # started, so verify the service remains alive before printing any credentials.
  sleep 2
  systemctl is-active --quiet sing-box || { journalctl -u sing-box -n 80 --no-pager; die 'sing-box did not start.'; }
  commit_force_rollback

  # Apply host-level tuning only after the checked configuration is serving.
  open_firewall_if_active
  enable_bbr
  configure_fail2ban
  install_warp_health_monitor
  print_links
}

case "$ACTION" in
  install) main "$@" ;;
  status) show_status ;;
  health-check) run_health_check ;;
  export-client-profile) export_client_profile ;;
  upgrade-core) upgrade_core ;;
  *) die "Unknown action: $ACTION" ;;
esac
