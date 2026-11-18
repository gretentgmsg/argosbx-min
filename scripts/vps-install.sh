#!/usr/bin/env bash
# Bare-metal installer for the full argosbx-min stack on a VPS (no Docker, ~110 MB RAM total):
#   1) Hysteria2                  sing-box, UDP  $PORT    (default 443)
#   2) VLESS+xhttp+Encryption     xray,      TCP  $XH_PORT (default 8443), self-signed TLS + post-quantum VLESS Encryption
#   3) Argo fixed tunnel          cloudflared -> second vless-xhttp inbound (optional: ARGO=1 + ARGO_TOKEN/ARGO_DOMAIN)
# Same pinned binaries, SHA256 verification, secrets, configs and share-link formats as the container.
# Idempotent: re-running keeps all secrets/links. Non-root systemd services with hardening.
#
# Usage (root):  bash vps-install.sh
#                ARGO=1 ARGO_TOKEN=eyJ... ARGO_DOMAIN=x.example.com bash vps-install.sh
# Overrides:     PORT=443 XH_PORT=8443 SNI=www.bing.com OBFS=1 ARGO_ADDRESS=1.2.3.4 SB_VERSION=... (and *_SHA256_*)
set -euo pipefail

# ---------- knobs & pinned versions (keep in sync with the Dockerfile) ----------
PORT="${PORT:-443}"            # Hysteria2 UDP
XH_PORT="${XH_PORT:-8443}"     # VLESS-XHTTP TCP (443/tcp often taken by nginx)
SNI="${SNI:-www.bing.com}"
OBFS="${OBFS:-1}"
# Camouflage mode: set DOMAIN (A record -> this VPS, DNS-only!) to obtain a Let's Encrypt cert
# via acme.sh. This forces obfs OFF (it would hide the real cert), enables HTTP/3 masquerade,
# and upgrades the direct XHTTP channel to real TLS. Renewals auto-restart the services.
DOMAIN="${DOMAIN:-}"
CF_TOKEN="${CF_TOKEN:-}"       # Cloudflare API token (Zone.DNS Edit) -> DNS-01 issuance;
                                # empty -> HTTP-01 standalone, requires a free TCP 80
ARGO="${ARGO:-0}"; ARG0_UNUSED=0
ARGO_TOKEN="${ARGO_TOKEN:-}"
ARGO_DOMAIN="${ARGO_DOMAIN:-}"
ARGO_ADDRESS="${ARGO_ADDRESS:-}"
ARGO_PROTOCOL="${ARGO_PROTOCOL:-http2}"
DIR="${DIR:-/opt/argosbx}"
NAME=argosbx
ARGO_IN_PORT=18080

SB_VERSION="${SB_VERSION:-1.14.4}"
XRAY_VERSION="${XRAY_VERSION:-26.10.21}"
CF_VERSION="${CF_VERSION:-2026.10.5}"
SB_SHA256_AMD64="${SB_SHA256_AMD64:-231e57c18378f780a08de832844a1ca9716e17a7bcf82964b350844d243c03ac}"
SB_SHA256_ARM64="${SB_SHA256_ARM64:-241cb4ccbf1a003235f8a969cc25d28cc74487df52721f6de28be7e37eae2ae9}"
XR_SHA256_AMD64="${XR_SHA256_AMD64:-0eec3ed4163c273d8c8bf821f7d219e257921cf584aa3fb970715e458e631978}"
XR_SHA256_ARM64="${XR_SHA256_ARM64:-d1304946c486d98e6b886e9b931eaaaebb23835b30e217638037b7f2721d4e9c}"
CF_SHA256_AMD64="${CF_SHA256_AMD64:-e1bc0cf084fd9e590554fe769a86b1db46701c3f847a43d902f7b974a4e16298}"
CF_SHA256_ARM64="${CF_SHA256_ARM64:-72e0d05a67e09da87cf495e409a28c3cc5994dd23fc66a982eebea6a55923b7d}"

[ "$(id -u)" = 0 ] || { echo "[error] run as root" >&2; exit 1; }
case "$(uname -m)" in
  x86_64)  SB_SHA="$SB_SHA256_AMD64"; XR_SHA="$XR_SHA256_AMD64"; CF_SHA="$CF_SHA256_AMD64"; SB_ARCH=amd64; XR_ARCH=64; CF_ARCH=amd64 ;;
  aarch64) SB_SHA="$SB_SHA256_ARM64"; XR_SHA="$XR_SHA256_ARM64"; CF_SHA="$CF_SHA256_ARM64"; SB_ARCH=arm64; XR_ARCH=arm64-v8a; CF_ARCH=arm64 ;;
  *) echo "[error] unsupported arch $(uname -m)" >&2; exit 1 ;;
esac
is_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -le 65535 ]; }
is_host() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; }
is_port "$PORT" && is_port "$XH_PORT" || { echo "[error] bad port" >&2; exit 1; }
is_host "$SNI" || { echo "[error] bad SNI" >&2; exit 1; }
[[ "$OBFS" =~ ^[01]$ ]] || { echo "[error] OBFS must be 0/1" >&2; exit 1; }
if [ "$ARGO" = 1 ]; then
  [ -n "$ARGO_TOKEN" ] && [ -n "$ARGO_DOMAIN" ] || { echo "[error] ARGO=1 needs ARGO_TOKEN and ARGO_DOMAIN (fixed tunnel; quick tunnels are incompatible with XHTTP)" >&2; exit 1; }
  [[ "$ARGO_TOKEN" =~ ^[A-Za-z0-9=_+/-]{50,2000}$ ]] || { echo "[error] ARGO_TOKEN looks wrong" >&2; exit 1; }
  is_host "$ARGO_DOMAIN" || { echo "[error] bad ARGO_DOMAIN" >&2; exit 1; }
  [ -z "$ARGO_ADDRESS" ] || is_host "$ARGO_ADDRESS" || { echo "[error] bad ARGO_ADDRESS" >&2; exit 1; }
  [[ "$ARGO_PROTOCOL" =~ ^(auto|http2|quic)$ ]] || { echo "[error] bad ARGO_PROTOCOL" >&2; exit 1; }
else ARGO=0; fi
if [ -n "$DOMAIN" ]; then
  is_host "$DOMAIN" || { echo "[error] bad DOMAIN" >&2; exit 1; }
  SNI="$DOMAIN"
  [ "$OBFS" = 1 ] && echo "[info] DOMAIN mode: obfs forced off (it would hide the real cert); masquerade covers probing"
  OBFS=0
fi

echo "[1/7] prerequisites ..."
if ! command -v curl >/dev/null || ! command -v unzip >/dev/null || ! command -v openssl >/dev/null; then
  n=0
  until apt-get update -qq && apt-get install -y -qq curl ca-certificates openssl unzip >/dev/null 2>&1; do
    n=$((n+1))
    if [ "$n" -ge 12 ]; then
      echo "[error] apt stayed busy for 2 minutes (unattended-upgrades?). Wait for it or install manually:" >&2
      echo "        apt-get install -y curl ca-certificates openssl unzip" >&2
      exit 1
    fi
    echo "      apt busy (attempt $n/12), waiting 10s ..."
    sleep 10
  done
fi
command -v curl >/dev/null && command -v unzip >/dev/null && command -v openssl >/dev/null \
  || { echo "[error] prerequisites missing (curl/unzip/openssl)" >&2; exit 1; }
mkdir -p "$DIR/bin" "$DIR/etc" "$DIR/data"; chmod 700 "$DIR/data"

# ---------- binaries: official releases, SHA256-pinned ----------
fetch() { # url sha dest
  curl -fsSL -o "$3" "$1"
  echo "$2  $3" | sha256sum -c - >/dev/null || { echo "[error] SHA256 mismatch for $3" >&2; exit 1; }
}
echo "[2/7] binaries (pinned, verified) ..."
if [ ! -x "$DIR/bin/sing-box" ] || ! "$DIR/bin/sing-box" version 2>/dev/null | grep -q "$SB_VERSION"; then
  fetch "https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/sing-box-${SB_VERSION}-linux-${SB_ARCH}-glibc.tar.gz" "$SB_SHA" /tmp/sb.tgz
  tar -xzf /tmp/sb.tgz --wildcards '*/sing-box' -O > "$DIR/bin/sing-box"; chmod 0755 "$DIR/bin/sing-box"; rm -f /tmp/sb.tgz
fi
if [ ! -x "$DIR/bin/xray" ] || ! "$DIR/bin/xray" version 2>/dev/null | grep -q "$XRAY_VERSION"; then
  fetch "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-${XR_ARCH}.zip" "$XR_SHA" /tmp/xr.zip
  unzip -q -o /tmp/xr.zip xray -d "$DIR/bin"; chmod 0755 "$DIR/bin/xray"; rm -f /tmp/xr.zip
fi
if [ "$ARGO" = 1 ] && { [ ! -x "$DIR/bin/cloudflared" ] || ! "$DIR/bin/cloudflared" --version 2>/dev/null | grep -q "$CF_VERSION"; }; then
  fetch "https://github.com/cloudflare/cloudflared/releases/download/${CF_VERSION}/cloudflared-linux-${CF_ARCH}" "$CF_SHA" "$DIR/bin/cloudflared"
  chmod 0755 "$DIR/bin/cloudflared"
fi
export XRAY_LOCATION_ASSET="$DIR/bin"

id "$NAME" >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$NAME"

# ---------- secrets & certificate (persisted across re-runs) ----------
echo "[3/7] secrets / certificate ..."
store() { [ -s "$DIR/data/$1" ] || openssl rand -hex "$2" > "$DIR/data/$1"; tr -d '\n' < "$DIR/data/$1"; }
HY2_PW="$(store hy2_password 24)"
OBFS_PW="$(store hy2_obfs 24)"
UUID="$( [ -s "$DIR/data/uuid" ] || tr -d '\n' < /proc/sys/kernel/random/uuid > "$DIR/data/uuid"; tr -d '\n' < "$DIR/data/uuid")"
XH_PATH="/$(store xh_path 8)"
CERT="$DIR/data/cert.pem"; KEY="$DIR/data/key.pem"
cert_valid() {
  [ -s "$CERT" ] && [ -s "$KEY" ] \
    && openssl x509 -checkend 2592000 -noout -in "$CERT" >/dev/null 2>&1 \
    && openssl x509 -in "$CERT" -noout -text 2>/dev/null | grep -qE "DNS:${DOMAIN//./\\.}([, ]|$)"
}
if [ -n "$DOMAIN" ] && ! cert_valid; then
  echo "      obtaining a Let's Encrypt certificate for $DOMAIN ..."
  RIP="$(curl -fsS --max-time 5 https://api.ipify.org || true)"
  DIP="$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1; exit}')"
  { [ -z "$RIP" ] || [ -z "$DIP" ] || [ "$RIP" = "$DIP" ]; } || \
    echo "[warn] $DOMAIN resolves to $DIP but this host looks like $RIP - the A record must point here, DNS-only" >&2
  ACME="$HOME/.acme.sh/acme.sh"
  [ -x "$ACME" ] || curl -fsSL https://get.acme.sh | sh -s "admin@${DOMAIN#*.}" >/dev/null 2>&1
  [ -x "$ACME" ] || { echo "[error] acme.sh installation failed" >&2; exit 1; }
  if [ -n "$CF_TOKEN" ]; then
    CF_Token="$CF_TOKEN" "$ACME" --issue --server letsencrypt --dns dns_cf -d "$DOMAIN" \
      || { echo "[error] DNS-01 issuance failed (check CF_TOKEN / zone)" >&2; exit 1; }
  else
    ss -ltn 2>/dev/null | grep -q ':80 ' && { echo "[error] TCP 80 busy - free it or use CF_TOKEN (DNS-01)" >&2; exit 1; }
    "$ACME" --issue --server letsencrypt --standalone -d "$DOMAIN" \
      || { echo "[error] HTTP-01 issuance failed (A record direct/DNS-only? port 80 reachable?)" >&2; exit 1; }
  fi
  "$ACME" --install-cert -d "$DOMAIN" --ecc \
    --fullchain-file "$CERT" --key-file "$KEY" \
    --reloadcmd "chown $NAME: '$CERT' '$KEY'; chmod 600 '$KEY'; systemctl restart $NAME-hy2 $NAME-xh 2>/dev/null || true" \
    || { echo "[error] certificate installation failed" >&2; exit 1; }
elif [ -z "$DOMAIN" ] && { [ ! -s "$CERT" ] || [ ! -s "$KEY" ]; }; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -sha256 -days 3650 \
    -keyout "$KEY" -out "$CERT" -subj "/CN=$SNI" -addext "subjectAltName=DNS:$SNI" 2>/dev/null
fi
if [ ! -s "$DIR/data/argo_dec" ] || [ ! -s "$DIR/data/argo_enc" ]; then
  VE="$("$DIR/bin/xray" vlessenc)"
  printf '%s\n' "$VE" | awk -F'"' '/^Authentication:/ {on = ($0 ~ /X25519/)} on && /"decryption"/ {printf "%s", $4; exit}' > "$DIR/data/argo_dec"
  printf '%s\n' "$VE" | awk -F'"' '/^Authentication:/ {on = ($0 ~ /X25519/)} on && /"encryption"/ {printf "%s", $4; exit}' > "$DIR/data/argo_enc"
fi
ARGO_DEC="$(tr -d '\n' < "$DIR/data/argo_dec")"; ARGO_ENC="$(tr -d '\n' < "$DIR/data/argo_enc")"
VE_RE='^mlkem768x25519plus\.(native|xorpub|random)\.[0-9a-z]+\.[A-Za-z0-9_-]+$'
[[ "$ARGO_DEC" =~ $VE_RE && "$ARGO_ENC" =~ $VE_RE ]] || { echo "[error] vlessenc key parse failed" >&2; exit 1; }
chmod 600 "$DIR/data"/*; chown -R "$NAME:" "$DIR"

# ---------- 1) Hysteria2 (sing-box) ----------
echo "[4/7] Hysteria2 config ..."
OBFS_JSON=""; MASQ_JSON=""
if [ "$OBFS" = 1 ]; then OBFS_JSON="\"obfs\": {\"type\": \"salamander\", \"password\": \"$OBFS_PW\"},"
else MASQ_JSON="\"masquerade\": \"https://www.bing.com\","; fi
cat > "$DIR/etc/sing-box.json" <<JSON
{
  "log": { "level": "warn", "timestamp": true },
  "dns": { "servers": [ { "type": "local", "tag": "local" } ] },
  "inbounds": [
    { "type": "hysteria2", "tag": "hy2-in", "listen": "::", "listen_port": $PORT,
      "users": [ { "password": "$HY2_PW" } ],
      $OBFS_JSON
      $MASQ_JSON
      "tls": { "enabled": true, "server_name": "$SNI", "alpn": ["h3"], "min_version": "1.3",
        "certificate_path": "$CERT", "key_path": "$KEY" } }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct", "domain_resolver": "local" } ],
  "route": { "rules": [
      { "action": "resolve", "server": "local" },
      { "ip_is_private": true, "action": "reject" },
      { "ip_cidr": ["100.64.0.0/10", "192.0.0.0/24", "198.18.0.0/15"], "action": "reject" } ],
    "final": "direct", "default_domain_resolver": "local" }
}
JSON
"$DIR/bin/sing-box" check -c "$DIR/etc/sing-box.json"

# ---------- 2) VLESS-XHTTP-Encryption direct (+ 3) Argo origin inbound) ----------
echo "[5/7] Xray config (VLESS-XHTTP + VLESS Encryption) ..."
# No TLS on the direct inbound without a domain: Xray removed allowInsecure (self-signed share
# links would break) and VLESS Encryption already provides authenticated end-to-end crypto.
# With DOMAIN set a real Let's Encrypt cert exists, so the inbound gets proper TLS for free.
XH_TLS=""
if [ -n "$DOMAIN" ]; then
  XH_TLS='"security": "tls",
        "tlsSettings": { "certificates": [ { "certificateFile": "'"$CERT"'", "keyFile": "'"$KEY"'" } ], "alpn": ["h2", "http/1.1"] },'
fi
ARGO_INBOUND=""
if [ "$ARGO" = 1 ]; then
  ARGO_INBOUND=',{
      "tag": "argo-in",
      "listen": "127.0.0.1",
      "port": '"$ARGO_IN_PORT"',
      "protocol": "vless",
      "settings": { "clients": [ { "id": "'"$UUID"'" } ], "decryption": "'"$ARGO_DEC"'" },
      "streamSettings": { "network": "xhttp", "xhttpSettings": { "path": "'"$XH_PATH"'", "mode": "auto" } }
    }'
fi
cat > "$DIR/etc/xray.json" <<JSON
{
  "log": { "loglevel": "warning", "access": "none" },
  "inbounds": [
    {
      "tag": "xh-in",
      "listen": "::",
      "port": $XH_PORT,
      "protocol": "vless",
      "settings": { "clients": [ { "id": "$UUID" } ], "decryption": "$ARGO_DEC" },
      "streamSettings": {
        "network": "xhttp",
        $XH_TLS
        "xhttpSettings": { "path": "$XH_PATH", "mode": "auto" }
      }
    }$ARGO_INBOUND
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom",
      "settings": { "finalRules": [ { "action": "block",
        "ip": [ "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24", "192.168.0.0/16", "198.18.0.0/15", "224.0.0.0/3", "::1/128", "fc00::/7", "fe80::/10" ] } ] },
      "streamSettings": { "sockopt": { "domainStrategy": "UseIP" } } }
  ],
  "routing": { "domainStrategy": "IPIfNonMatch", "rules": [] }
}
JSON
"$DIR/bin/xray" run -test -c "$DIR/etc/xray.json" >/dev/null

# ---------- systemd services ----------
echo "[6/7] systemd services ..."
unit() { # name cap cmd
  cat > "/etc/systemd/system/$1.service" <<UNIT
[Unit]
Description=$2 (argosbx)
After=network-online.target
Wants=network-online.target

[Service]
User=$NAME
ExecStart=$3
Restart=always
RestartSec=5
NoNewPrivileges=true
CapabilityBoundingSet=${4:-}
AmbientCapabilities=${4:-}
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ReadWritePaths=$DIR/data

[Install]
WantedBy=multi-user.target
UNIT
}
HAVE_SYSTEMD=0; [ -d /run/systemd/system ] && HAVE_SYSTEMD=1
if [ "$HAVE_SYSTEMD" = 1 ]; then
  unit "$NAME-hy2"  "Hysteria2"        "$DIR/bin/sing-box run -c $DIR/etc/sing-box.json" CAP_NET_BIND_SERVICE
  unit "$NAME-xh"   "VLESS-XHTTP"      "$DIR/bin/xray run -c $DIR/etc/xray.json"        CAP_NET_BIND_SERVICE
  if [ "$ARGO" = 1 ]; then
    unit "$NAME-argo" "Argo tunnel"    "$DIR/bin/cloudflared tunnel --no-autoupdate --protocol $ARGO_PROTOCOL --loglevel warn run" ""
    sed -i "/^\[Service\]/a Environment=TUNNEL_TOKEN=$ARGO_TOKEN" "/etc/systemd/system/${NAME}-argo.service"
    chmod 600 "/etc/systemd/system/${NAME}-argo.service"
  fi
  systemctl daemon-reload
  systemctl enable --now "$NAME-hy2" "$NAME-xh" >/dev/null 2>&1
  [ "$ARGO" = 1 ] && systemctl enable --now "$NAME-argo" >/dev/null 2>&1
  systemctl restart "$NAME-hy2" "$NAME-xh" $([ "$ARGO" = 1 ] && echo "$NAME-argo")
  sleep 1
  systemctl is-active "$NAME-hy2" "$NAME-xh" >/dev/null || { journalctl -u "$NAME-hy2" -n 10 --no-pager; journalctl -u "$NAME-xh" -n 10 --no-pager; exit 1; }
else
  echo "      (systemd absent - start manually:"
  echo "       $DIR/bin/sing-box run -c $DIR/etc/sing-box.json"
  echo "       $DIR/bin/xray run -c $DIR/etc/xray.json"
  [ "$ARGO" = 1 ] && echo "       TUNNEL_TOKEN=... $DIR/bin/cloudflared tunnel --no-autoupdate --protocol $ARGO_PROTOCOL run)"
fi

# ---------- share links ----------
echo "[7/7] done. Share links (also saved to $DIR/data/links.txt):"
IP="$(curl -fsS --max-time 5 https://api.ipify.org || echo YOUR_VPS_IP)"
PIN="$(openssl x509 -in "$CERT" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f')"
LINKS="$DIR/data/links.txt"; : > "$LINKS"
if [ -n "$DOMAIN" ]; then
  Q="sni=$DOMAIN&alpn=h3&insecure=0"                        # real cert: no pin (rotates on renewal)
  XH_TLS_Q="&security=tls&sni=$DOMAIN&fp=chrome"
else
  Q="sni=$SNI&alpn=h3&insecure=0&pinSHA256=$PIN"; [ "$OBFS" = 1 ] && Q="$Q&obfs=salamander&obfs-password=$OBFS_PW"
  XH_TLS_Q=""
fi
echo "hysteria2://$HY2_PW@$IP:$PORT/?$Q#$NAME-hy2" | tee -a "$LINKS"
echo "vless://$UUID@$IP:$XH_PORT?encryption=$ARGO_ENC$XH_TLS_Q&type=xhttp&path=%2F${XH_PATH#/}&mode=packet-up#$NAME-xh" | tee -a "$LINKS"
if [ "$ARGO" = 1 ]; then
  ADDR="${ARGO_ADDRESS:-$ARGO_DOMAIN}"
  echo "vless://$UUID@$ADDR:443?encryption=$ARGO_ENC&security=tls&sni=$ARGO_DOMAIN&fp=chrome&alpn=h2&type=xhttp&host=$ARGO_DOMAIN&path=%2F${XH_PATH#/}&mode=packet-up#$NAME-argo" | tee -a "$LINKS"
fi
chmod 600 "$LINKS"; chown "$NAME:" "$LINKS"
echo
echo "Firewall: ufw allow ${PORT}/udp (HY2), ufw allow ${XH_PORT}/tcp (VLESS-XHTTP); Argo needs no inbound."
echo "Logs: journalctl -u $NAME-hy2 -u $NAME-xh $([ "$ARGO" = 1 ] && echo "-u $NAME-argo") -f"
