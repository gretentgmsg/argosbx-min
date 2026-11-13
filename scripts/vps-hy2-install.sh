#!/usr/bin/env bash
# Standalone Hysteria2 server (official sing-box binary, SHA256-pinned) for a bare VPS - no Docker.
# Mirrors the argosbx-min container's HY2 behavior: self-signed ECDSA cert + pinSHA256 link,
# salamander obfs, private/CGNAT egress blocking. Restarts via systemd; runs as a non-root user.
#
# Usage (as root):  bash vps-hy2-install.sh            # defaults: UDP 443, SNI www.bing.com, obfs on
# Overrides:        PORT=8443 SNI=your.domain OBFS=0 bash vps-hy2-install.sh
# Re-running is safe: existing passwords/certs/keys are kept.
set -euo pipefail

SB_VERSION="${SB_VERSION:-1.14.4}"
case "$(uname -m)" in
  x86_64) SB_SHA="${SB_SHA256_AMD64:-231e57c18378f780a08de832844a1ca9716e17a7bcf82964b350844d243c03ac}"; SB_ARCH=amd64 ;;
  aarch64) SB_SHA="${SB_SHA256_ARM64:-241cb4ccbf1a003235f8a969cc25d28cc74487df52721f6de28be7e37eae2ae9}"; SB_ARCH=arm64 ;;
  *) echo "[error] unsupported arch $(uname -m)" >&2; exit 1 ;;
esac
PORT="${PORT:-443}"
SNI="${SNI:-www.bing.com}"
OBFS="${OBFS:-1}"
DIR="${DIR:-/opt/hy2}"
NAME=hy2
[ "$(id -u)" = 0 ] || { echo "[error] run as root (installs to $DIR and systemd)" >&2; exit 1; }

# ---------- binary: official release + pinned SHA256 ----------
mkdir -p "$DIR/bin" "$DIR/etc" "$DIR/data"; chmod 700 "$DIR/data"
if [ ! -x "$DIR/bin/sing-box" ] || ! "$DIR/bin/sing-box" version 2>/dev/null | grep -q "$SB_VERSION"; then
  echo "[1/5] downloading sing-box $SB_VERSION ..."
  curl -fsSL -o /tmp/sb.tgz "https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/sing-box-${SB_VERSION}-linux-${SB_ARCH}-glibc.tar.gz"
  echo "$SB_SHA  /tmp/sb.tgz" | sha256sum -c -
  tar -xzf /tmp/sb.tgz --wildcards '*/sing-box' -O > "$DIR/bin/sing-box"
  chmod 0755 "$DIR/bin/sing-box"; rm -f /tmp/sb.tgz
fi

# ---------- non-root runtime user ----------
id "$NAME" >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$NAME"

# ---------- secrets + self-signed ECDSA cert (persisted; reused on re-run) ----------
echo "[2/5] generating secrets / certificate ..."
store() { # file bytes
  [ -s "$DIR/data/$1" ] || openssl rand -hex "$2" > "$DIR/data/$1"
  tr -d '\n' < "$DIR/data/$1"
}
PW="$(store password 24)"
OBFS_PW="$(store obfs_password 24)"
CERT="$DIR/data/cert.pem"; KEY="$DIR/data/key.pem"
if [ ! -s "$CERT" ] || [ ! -s "$KEY" ]; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -sha256 -days 3650 \
    -keyout "$KEY" -out "$CERT" -subj "/CN=$SNI" -addext "subjectAltName=DNS:$SNI" 2>/dev/null
fi
chmod 600 "$DIR/data"/*; chown -R "$NAME:" "$DIR"

# ---------- config: same shape as the container's ----------
echo "[3/5] writing config ..."
OBFS_JSON=""; MASQ_JSON=""
if [ "$OBFS" = 1 ]; then OBFS_JSON="\"obfs\": {\"type\": \"salamander\", \"password\": \"$OBFS_PW\"},"
else MASQ_JSON="\"masquerade\": \"https://www.bing.com\","; fi
cat > "$DIR/etc/config.json" <<JSON
{
  "log": { "level": "warn", "timestamp": true },
  "dns": { "servers": [ { "type": "local", "tag": "local" } ] },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": $PORT,
      "users": [ { "password": "$PW" } ],
      $OBFS_JSON
      $MASQ_JSON
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "alpn": ["h3"],
        "min_version": "1.3",
        "certificate_path": "$CERT",
        "key_path": "$KEY"
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct", "domain_resolver": "local" } ],
  "route": {
    "rules": [
      { "action": "resolve", "server": "local" },
      { "ip_is_private": true, "action": "reject" },
      { "ip_cidr": ["100.64.0.0/10", "192.0.0.0/24", "198.18.0.0/15"], "action": "reject" }
    ],
    "final": "direct",
    "default_domain_resolver": "local"
  }
}
JSON
"$DIR/bin/sing-box" check -c "$DIR/etc/config.json"

# ---------- systemd service (root only for <1024 ports via ambient capability) ----------
if [ -d /run/systemd/system ]; then
  echo "[4/5] installing systemd service ..."
  cat > "/etc/systemd/system/${NAME}.service" <<UNIT
[Unit]
Description=Hysteria2 (sing-box)
After=network-online.target
Wants=network-online.target

[Service]
User=$NAME
ExecStart=$DIR/bin/sing-box run -c $DIR/etc/config.json
Restart=always
RestartSec=5
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload && systemctl enable --now "$NAME"
  systemctl restart "$NAME"
  sleep 1
  systemctl is-active "$NAME" >/dev/null || { journalctl -u "$NAME" -n 20 --no-pager; exit 1; }
else
  echo "[4/5] systemd not present (container/test?); start manually:"
  echo "      $DIR/bin/sing-box run -c $DIR/etc/config.json"
fi

# ---------- share link (same pin format as the container) ----------
echo "[5/5] done. Share link:"
PIN="$(openssl x509 -in "$CERT" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f')"
Q="sni=$SNI&alpn=h3&insecure=0&pinSHA256=$PIN"
[ "$OBFS" = 1 ] && Q="$Q&obfs=salamander&obfs-password=$OBFS_PW"
IP="$(curl -fsS --max-time 5 https://api.ipify.org || echo YOUR_VPS_IP)"
echo "hysteria2://$PW@$IP:$PORT/?$Q#vps-hy2"
echo
echo "Firewall reminder: open UDP $PORT (ufw allow ${PORT}/udp + cloud security group)."
echo "Logs: journalctl -u $NAME -f"
