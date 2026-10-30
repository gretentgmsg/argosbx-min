#!/usr/bin/env bash
# Minimal launcher: Hysteria2 (sing-box) + VLESS-Reality (Xray) + optional Cloudflare Argo tunnel (VLESS Encryption + XHTTP via Xray).
# Secrets are generated locally on first start and persisted in $DATA_DIR (mode 600).
set -euo pipefail
umask 077

DATA_DIR="${DATA_DIR:-/data}"
BIN_DIR="${BIN_DIR:-/opt/bin}"

HY2_PORT="${HY2_PORT:-443}"              # UDP; 0 = disable Hysteria2
HY2_SNI="${HY2_SNI:-www.bing.com}"       # SNI/SAN of the cert (use your real domain if you mount a real cert)
HY2_OBFS="${HY2_OBFS:-1}"                # 1 = salamander obfuscation, 0 = off (then masquerade is used)
MASQ_URL="${MASQ_URL:-https://www.bing.com}"
REALITY_PORT="${REALITY_PORT:-443}"      # TCP; 0 = disable Reality
REALITY_SNI="${REALITY_SNI:-addons.mozilla.org}"
ARGO="${ARGO:-0}"                        # 1 = enable Cloudflare Argo tunnel (works without a reachable public IP)
ARGO_PORT="${ARGO_PORT:-18080}"          # local-only (127.0.0.1) VLESS-XHTTP port that cloudflared forwards to
ARGO_LISTEN="${ARGO_LISTEN:-127.0.0.1}"  # bind address of that port; set 0.0.0.0 when a reverse proxy (e.g. a PaaS HTTPS endpoint) reaches it via the pod IP
ARGO_DOMAIN="${ARGO_DOMAIN:-}"           # fixed tunnel: the public hostname configured in the Cloudflare dashboard
ARGO_PUBLIC_DOMAIN="${ARGO_PUBLIC_DOMAIN:-}"  # optional: domain of an HTTPS reverse proxy in front of the XHTTP port -> emits an extra direct vless link
ARGO_ADDRESS="${ARGO_ADDRESS:-}"         # optional: preferred Cloudflare IP/domain for the client to connect to
ARGO_PROTOCOL="${ARGO_PROTOCOL:-auto}"   # auto | http2 | quic
NODE_NAME="${NODE_NAME:-node}"
SERVER_HOST="${SERVER_HOST:-}"           # public IP/domain; auto-detected over HTTPS if empty
METRICS_ADDR="127.0.0.1:20241"

# The tunnel token never needs to be visible to child processes or `ps`: take it out of the environment now.
CF_TOKEN="${ARGO_TOKEN:-}"; unset ARGO_TOKEN

die() { echo "[error] $*" >&2; exit 1; }

# ---------- input validation (values end up in JSON / URLs) ----------
is_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -le 65535 ]; }
is_host() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; }
is_port "$HY2_PORT"     || die "HY2_PORT must be 0-65535"
is_port "$REALITY_PORT" || die "REALITY_PORT must be 0-65535"
is_port "$ARGO_PORT" && [ "$ARGO_PORT" -ge 1024 ] || die "ARGO_PORT must be 1024-65535"
is_host "$HY2_SNI"      || die "invalid HY2_SNI"
is_host "$REALITY_SNI"  || die "invalid REALITY_SNI"
[[ "$MASQ_URL"  =~ ^https?://[A-Za-z0-9./:_-]+$ ]]   || die "invalid MASQ_URL"
[[ "$NODE_NAME" =~ ^[A-Za-z0-9._-]{1,32}$ ]]         || die "NODE_NAME: only A-Za-z0-9._- (max 32)"
[[ "$HY2_OBFS" =~ ^[01]$ ]] || die "HY2_OBFS must be 0 or 1"
[[ "$ARGO" =~ ^[01]$ ]]     || die "ARGO must be 0 or 1"
[[ "$ARGO_PROTOCOL" =~ ^(auto|http2|quic)$ ]] || die "ARGO_PROTOCOL must be auto, http2 or quic"
[ -z "$ARGO_DOMAIN" ]  || is_host "$ARGO_DOMAIN"  || die "invalid ARGO_DOMAIN"
[ -z "$ARGO_ADDRESS" ] || is_host "$ARGO_ADDRESS" || die "invalid ARGO_ADDRESS"
[[ "$ARGO_LISTEN" =~ ^(127\.0\.0\.1|0\.0\.0\.0)$ ]] || die "ARGO_LISTEN must be 127.0.0.1 or 0.0.0.0"
[ -z "$ARGO_PUBLIC_DOMAIN" ] || is_host "$ARGO_PUBLIC_DOMAIN" || die "invalid ARGO_PUBLIC_DOMAIN"
[ -z "$CF_TOKEN" ] || [[ "$CF_TOKEN" =~ ^[A-Za-z0-9=_+/-]{50,2000}$ ]] || die "ARGO_TOKEN has an unexpected format"
[ -z "$CF_TOKEN" ] || [ -n "$ARGO_DOMAIN" ] || die "ARGO_DOMAIN is required together with ARGO_TOKEN (fixed tunnel)"
[ -z "$CF_TOKEN" ] || [ "$ARGO" = 1 ] || die "ARGO_TOKEN is set but ARGO=0"
[ -z "$ARGO_DOMAIN" ] || [ -n "$CF_TOKEN" ] || die "ARGO_DOMAIN is only used with ARGO_TOKEN; leave it empty for a quick tunnel"
FIXED_TUNNEL=0; if [ -n "$CF_TOKEN" ]; then FIXED_TUNNEL=1; fi
if [ "$HY2_PORT" = 0 ] && [ "$REALITY_PORT" = 0 ] && [ "$ARGO" = 0 ]; then die "all protocols disabled"; fi
for v in HY2_PASSWORD HY2_OBFS_PASSWORD REALITY_UUID ARGO_UUID; do
  [ -z "${!v:-}" ] || [[ "${!v}" =~ ^[A-Za-z0-9-]{16,64}$ ]] || die "$v: 16-64 chars of A-Za-z0-9-"
done

mkdir -p "$DATA_DIR/secrets"; chmod 700 "$DATA_DIR" "$DATA_DIR/secrets"

# ---------- secrets: env override > persisted file > freshly generated ----------
secret() { # name bytes [override]
  local f="$DATA_DIR/secrets/$1"
  if [ -n "${3:-}" ]; then printf '%s' "$3"; return; fi
  [ -s "$f" ] || openssl rand -hex "$2" | tr -d '\n' > "$f"
  tr -d '\n' < "$f"
}
uuid_secret() { # name [override]
  local f="$DATA_DIR/secrets/$1"
  if [ -n "${2:-}" ]; then printf '%s' "$2"; return; fi
  [ -s "$f" ] || tr -d '\n' < /proc/sys/kernel/random/uuid > "$f"
  tr -d '\n' < "$f"
}
HY2_PW="$(secret hy2_password 24 "${HY2_PASSWORD:-}")"
OBFS_PW="$(secret hy2_obfs 24 "${HY2_OBFS_PASSWORD:-}")"
UUID="$(uuid_secret uuid "${REALITY_UUID:-}")"
ARGO_ID="$(uuid_secret argo_uuid "${ARGO_UUID:-}")"      # separate credential for the Argo path
unset HY2_PASSWORD HY2_OBFS_PASSWORD REALITY_UUID ARGO_UUID

# ---------- public address (only needed for the direct HY2 / Reality links) ----------
if [ "$HY2_PORT" != 0 ] || [ "$REALITY_PORT" != 0 ]; then
  if [ -z "$SERVER_HOST" ]; then
    for u in https://api.ipify.org https://icanhazip.com; do
      ip="$(curl -fsS --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]' || true)"
      if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || "$ip" =~ ^[0-9a-fA-F:]+:[0-9a-fA-F:]+$ ]]; then SERVER_HOST="$ip"; break; fi
    done
    [ -n "$SERVER_HOST" ] || { echo "[warn] cannot detect public IP; set SERVER_HOST" >&2; SERVER_HOST="YOUR_SERVER_IP"; }
  fi
  [[ "$SERVER_HOST" =~ ^[A-Za-z0-9.:-]+$ ]] || die "invalid SERVER_HOST"
fi
URL_HOST="$SERVER_HOST"; [[ "$SERVER_HOST" == *:* ]] && URL_HOST="[$SERVER_HOST]"

LINKS="$DATA_DIR/links.txt"; : > "$LINKS"
PIDS=()
export XRAY_LOCATION_ASSET="${XRAY_LOCATION_ASSET:-$BIN_DIR}"

# ======================= Hysteria2 (sing-box) =======================
if [ "$HY2_PORT" != 0 ]; then
  CERT="$DATA_DIR/cert.pem"; KEY="$DATA_DIR/key.pem"; MARK="$DATA_DIR/cert.selfsigned"
  if [ -s "$CERT" ] && [ -s "$KEY" ] && [ ! -f "$MARK" ]; then
    CERT_MODE=custom                       # operator supplied a real certificate
  else
    CERT_MODE=selfsigned
    if [ ! -s "$CERT" ] || [ ! -s "$KEY" ] || [ "$(cat "$MARK" 2>/dev/null)" != "$HY2_SNI" ]; then
      rm -f "$CERT" "$KEY"
      openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -sha256 -days 3650 \
        -keyout "$KEY" -out "$CERT" -subj "/CN=$HY2_SNI" -addext "subjectAltName=DNS:$HY2_SNI" 2>/dev/null
      printf '%s' "$HY2_SNI" > "$MARK"
    fi
  fi

  OBFS_JSON=""; MASQ_JSON=""
  if [ "$HY2_OBFS" = 1 ]; then OBFS_JSON="\"obfs\": {\"type\": \"salamander\", \"password\": \"$OBFS_PW\"},"
  else MASQ_JSON="\"masquerade\": \"$MASQ_URL\","; fi

  cat > "$DATA_DIR/sing-box.json" <<JSON
{
  "log": { "level": "warn", "timestamp": true },
  "dns": { "servers": [ { "type": "local", "tag": "local" } ] },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": $HY2_PORT,
      "users": [ { "password": "$HY2_PW" } ],
      $OBFS_JSON
      $MASQ_JSON
      "tls": {
        "enabled": true,
        "server_name": "$HY2_SNI",
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
  "$BIN_DIR/sing-box" check -c "$DATA_DIR/sing-box.json"

  Q="sni=$HY2_SNI&alpn=h3&insecure=0"
  if [ "$CERT_MODE" = selfsigned ]; then
    # hex DER fingerprint, no colons (format used by mainstream hysteria2 clients)
    PIN="$(openssl x509 -in "$CERT" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f')"
    Q="$Q&pinSHA256=$PIN"
  fi
  [ "$HY2_OBFS" = 1 ] && Q="$Q&obfs=salamander&obfs-password=$OBFS_PW"
  echo "hysteria2://$HY2_PW@$URL_HOST:$HY2_PORT/?$Q#$NODE_NAME-hy2" >> "$LINKS"
fi

# ======================= Xray: VLESS-Reality and/or VLESS-Encryption+XHTTP (Argo origin) =======================
XRAY_INBOUNDS=""
if [ "$REALITY_PORT" != 0 ]; then
  PRIV_FILE="$DATA_DIR/secrets/reality_private"
  if [ ! -s "$PRIV_FILE" ]; then
    "$BIN_DIR/xray" x25519 | awk -F': *' 'tolower($0) ~ /^private/ {printf "%s",$2}' > "$PRIV_FILE"
  fi
  R_PRIV="$(tr -d '\n' < "$PRIV_FILE")"
  R_PUB="$("$BIN_DIR/xray" x25519 -i "$R_PRIV" | awk -F': *' 'tolower($1) ~ /^(password|public)/ {printf "%s",$2; exit}')"
  [ -n "$R_PRIV" ] && [ -n "$R_PUB" ] || die "failed to derive Reality keys"
  SID="$(secret reality_sid 8)"
  XRAY_INBOUNDS="$(cat <<JSON
    {
      "tag": "reality-in",
      "listen": "::",
      "port": $REALITY_PORT,
      "protocol": "vless",
      "settings": { "clients": [ { "id": "$UUID", "flow": "xtls-rprx-vision" } ], "decryption": "none" },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "$REALITY_SNI:443",
          "xver": 0,
          "serverNames": [ "$REALITY_SNI" ],
          "privateKey": "$R_PRIV",
          "shortIds": [ "$SID" ]
        }
      }
    }
JSON
)"
  echo "vless://$UUID@$URL_HOST:$REALITY_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$REALITY_SNI&fp=chrome&pbk=$R_PUB&sid=$SID&type=tcp&headerType=none#$NODE_NAME-reality" >> "$LINKS"
fi

if [ "$ARGO" = 1 ]; then
  XH_PATH="/$(secret argo_path 8)"          # random path: only clients that know it reach the proxy
  # VLESS Encryption key pair (X25519 authentication + ML-KEM-768 post-quantum key exchange), generated once by Xray itself.
  # "decryption" is the server secret, "encryption" is the public client string.
  if [ ! -s "$DATA_DIR/secrets/argo_dec" ] || [ ! -s "$DATA_DIR/secrets/argo_enc" ]; then
    VE="$("$BIN_DIR/xray" vlessenc)"
    printf '%s\n' "$VE" | awk -F'"' '/^Authentication:/ {on = ($0 ~ /X25519/)} on && /"decryption"/ {printf "%s", $4; exit}' > "$DATA_DIR/secrets/argo_dec"
    printf '%s\n' "$VE" | awk -F'"' '/^Authentication:/ {on = ($0 ~ /X25519/)} on && /"encryption"/ {printf "%s", $4; exit}' > "$DATA_DIR/secrets/argo_enc"
  fi
  ARGO_DEC="$(tr -d '\n' < "$DATA_DIR/secrets/argo_dec")"; ARGO_ENC="$(tr -d '\n' < "$DATA_DIR/secrets/argo_enc")"
  RE='^mlkem768x25519plus\.(native|xorpub|random)\.[0-9a-z]+\.[A-Za-z0-9_-]+$'
  [[ "$ARGO_DEC" =~ $RE && "$ARGO_ENC" =~ $RE ]] || die "could not read VLESS Encryption keys from 'xray vlessenc' (delete $DATA_DIR/secrets/argo_dec and argo_enc to regenerate)"
  ARGO_IN="$(cat <<JSON
    {
      "tag": "argo-in",
      "listen": "$ARGO_LISTEN",
      "port": $ARGO_PORT,
      "protocol": "vless",
      "settings": { "clients": [ { "id": "$ARGO_ID" } ], "decryption": "$ARGO_DEC" },
      "streamSettings": { "network": "xhttp", "xhttpSettings": { "path": "$XH_PATH", "mode": "auto" } }
    }
JSON
)"
  XRAY_INBOUNDS="${XRAY_INBOUNDS:+$XRAY_INBOUNDS,
}$ARGO_IN"
fi

if [ -n "$XRAY_INBOUNDS" ]; then
  cat > "$DATA_DIR/xray.json" <<JSON
{
  "log": { "loglevel": "warning", "access": "none" },
  "dns": { "servers": [ "localhost" ] },
  "inbounds": [
$XRAY_INBOUNDS
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "finalRules": [
          { "action": "block", "ip": [ "geoip:private", "100.64.0.0/10", "192.0.0.0/24", "198.18.0.0/15" ] }
        ]
      },
      "streamSettings": { "sockopt": { "domainStrategy": "UseIP" } }
    }
  ],
  "routing": { "domainStrategy": "IPIfNonMatch", "rules": [] }
}
JSON
  "$BIN_DIR/xray" run -test -c "$DATA_DIR/xray.json" >/dev/null
fi

# VLESS link for the Argo path. VLESS Encryption is end to end (forward secret, post-quantum key exchange), so Cloudflare,
# which terminates TLS, only sees ciphertext. mode=packet-up is the XHTTP mode that works through a CDN / HTTP origin.
argo_link() { # tunnel-domain
  local d="$1" addr
  addr="${ARGO_ADDRESS:-$d}"
  echo "vless://$ARGO_ID@$addr:443?encryption=$ARGO_ENC&security=tls&sni=$d&fp=chrome&alpn=h2&type=xhttp&host=$d&path=%2F${XH_PATH#/}&mode=packet-up#$NODE_NAME-argo" >> "$LINKS"
}
[ "$ARGO" = 1 ] && [ -n "$CF_TOKEN" ] && argo_link "$ARGO_DOMAIN"

# Direct link for an HTTPS reverse proxy (e.g. a PaaS public HTTPS endpoint) in front of the XHTTP port
# (requires ARGO_LISTEN=0.0.0.0). The proxy terminates TLS; VLESS Encryption still protects the payload end to end.
if [ "$ARGO" = 1 ] && [ -n "$ARGO_PUBLIC_DOMAIN" ]; then
  echo "vless://$ARGO_ID@$ARGO_PUBLIC_DOMAIN:443?encryption=$ARGO_ENC&security=tls&sni=$ARGO_PUBLIC_DOMAIN&fp=chrome&alpn=h2&type=xhttp&host=$ARGO_PUBLIC_DOMAIN&path=%2F${XH_PATH#/}&mode=packet-up#$NODE_NAME-direct" >> "$LINKS"
fi

echo "[ok] configs generated. Share links (contain secrets, NOT printed to logs):"
echo "     docker exec <container> cat $LINKS"
[ "${GENERATE_ONLY:-0}" = 1 ] && exit 0

# ======================= run =======================
if [ "$HY2_PORT" != 0 ]; then "$BIN_DIR/sing-box" run -c "$DATA_DIR/sing-box.json" & PIDS+=($!); fi
if [ -n "$XRAY_INBOUNDS" ]; then "$BIN_DIR/xray" run -c "$DATA_DIR/xray.json" & PIDS+=($!); fi
if [ "$ARGO" = 1 ]; then
  CF_ARGS=(tunnel --no-autoupdate --protocol "$ARGO_PROTOCOL" --metrics "$METRICS_ADDR" --loglevel warn)
  if [ -n "$CF_TOKEN" ]; then
    TUNNEL_TOKEN="$CF_TOKEN" "$BIN_DIR/cloudflared" "${CF_ARGS[@]}" run & CF_PID=$!      # token via env, not argv
  else
    "$BIN_DIR/cloudflared" "${CF_ARGS[@]}" --url "http://127.0.0.1:$ARGO_PORT" & CF_PID=$!   # quick tunnel (random trycloudflare.com host)
  fi
  PIDS+=("$CF_PID")
  unset CF_TOKEN
fi

STOPPING=0
trap 'STOPPING=1; kill "${PIDS[@]}" 2>/dev/null' TERM INT

# Quick tunnel: ask cloudflared for the hostname it was assigned, then publish the link.
if [ "$ARGO" = 1 ] && [ "$FIXED_TUNNEL" = 0 ]; then
  QDOM=""
  for _ in $(seq 1 45); do
    kill -0 "$CF_PID" 2>/dev/null || break
    QDOM="$(curl -fsS --max-time 2 "http://$METRICS_ADDR/quicktunnel" 2>/dev/null | sed -n 's/.*"hostname" *: *"\([^"]*\)".*/\1/p' || true)"
    [[ "$QDOM" =~ ^[a-z0-9-]+\.trycloudflare\.com$ ]] && break
    QDOM=""; sleep 2
  done
  if [ -n "$QDOM" ]; then argo_link "$QDOM"; echo "[ok] Argo quick tunnel is up; link added to $LINKS (domain changes on every restart)"
  else echo "[warn] could not obtain a quick-tunnel hostname yet; check outbound access to Cloudflare" >&2; fi
  echo "[warn] quick tunnels (*.trycloudflare.com) are served through a Cloudflare Worker that breaks XHTTP's streaming download: requests reach this server but no data returns to the client. Use a fixed tunnel (ARGO_TOKEN + ARGO_DOMAIN)." >&2
fi

set +e
wait -n "${PIDS[@]}"; rc=$?
kill "${PIDS[@]}" 2>/dev/null; wait 2>/dev/null
[ "$STOPPING" = 1 ] && exit 0                      # docker stop: clean exit
[ "$rc" -ne 0 ] || rc=1                            # a proxy should never exit by itself -> non-zero so Docker restarts us
echo "[error] a proxy process exited unexpectedly (rc=$rc)" >&2
exit "$rc"
