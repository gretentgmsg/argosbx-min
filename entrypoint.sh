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
# UDP hole-punch mode (no public inbound port needed): a perl relay owns HY2_PORT, forwards to
# sing-box on loopback, keeps the NAT mapping alive with STUN probes, and reports the public
# mapping (plus the ready-to-import hysteria2 link) to a signaling server whenever it changes.
HY2_NAT="${HY2_NAT:-0}"                  # 1 = enable
SIGNAL_URL="${SIGNAL_URL:-}"             # e.g. https://vps.example:33443/report (POST ip/port/uri/time)
SIGNAL_TOKEN="${SIGNAL_TOKEN:-}"         # Bearer token of that API
STUN_SERVERS="${STUN_SERVERS:-stun.l.google.com:19302,stun.cloudflare.com:3478}"
HY2_NAT_INTERNAL=18081                   # loopback port sing-box listens on in NAT mode

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
[[ "$HY2_NAT" =~ ^[01]$ ]] || die "HY2_NAT must be 0 or 1"
[ "$HY2_NAT" = 0 ] || [ "$HY2_PORT" != 0 ] || die "HY2_NAT=1 requires HY2_PORT != 0"
[ "$HY2_PORT" != "$HY2_NAT_INTERNAL" ] || die "HY2_PORT conflicts with the internal NAT port $HY2_NAT_INTERNAL"
[ -z "$SIGNAL_URL" ] || [[ "$SIGNAL_URL" =~ ^https?://[A-Za-z0-9._:-]+(/[A-Za-z0-9._/-]*)?$ ]] || die "invalid SIGNAL_URL"
[ -z "$SIGNAL_TOKEN" ] || [[ "$SIGNAL_TOKEN" =~ ^[A-Za-z0-9._:=+-]{8,256}$ ]] || die "invalid SIGNAL_TOKEN"
[[ "$STUN_SERVERS" =~ ^[A-Za-z0-9.,:-]+$ ]] || die "invalid STUN_SERVERS"
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
# Stateless-mode secrets (env instead of persisted files; see README "无状态部署").
[ -z "${REALITY_PRIVATE_KEY:-}" ] || [[ "${REALITY_PRIVATE_KEY}" =~ ^[A-Za-z0-9_-]{40,48}$ ]] || die "invalid REALITY_PRIVATE_KEY (x25519 base64url from 'xray x25519')"
[ -z "${REALITY_SID:-}" ] || [[ "${REALITY_SID}" =~ ^[0-9a-f]{2,16}$ ]] || die "invalid REALITY_SID (even-length hex, max 16)"
[ -z "${ARGO_PATH:-}" ] || [[ "${ARGO_PATH}" =~ ^[0-9a-f]{4,32}$ ]] || die "invalid ARGO_PATH (hex, no leading slash)"
VE_KEY_RE='^mlkem768x25519plus\.(native|xorpub|random)\.[0-9a-z]+\.[A-Za-z0-9_-]+$'
[ -z "${ARGO_DEC_KEY:-}" ] || [[ "${ARGO_DEC_KEY}" =~ $VE_KEY_RE ]] || die "invalid ARGO_DEC_KEY (server value from 'xray vlessenc')"
[ -z "${ARGO_ENC_KEY:-}" ] || [[ "${ARGO_ENC_KEY}" =~ $VE_KEY_RE ]] || die "invalid ARGO_ENC_KEY (client value from 'xray vlessenc')"
if [ -n "${ARGO_DEC_KEY:-}" ] || [ -n "${ARGO_ENC_KEY:-}" ]; then
  { [ -n "${ARGO_DEC_KEY:-}" ] && [ -n "${ARGO_ENC_KEY:-}" ]; } || die "ARGO_DEC_KEY and ARGO_ENC_KEY must be set together"
  [[ "$ARGO_DEC_KEY" == *".600s."* ]] || die "ARGO_DEC_KEY must be the decryption (.600s.) value"
  [[ "$ARGO_ENC_KEY" == *".0rtt."* ]] || die "ARGO_ENC_KEY must be the encryption (.0rtt.) value"
fi

# ---------- data dir: prefer $DATA_DIR; fall back if the platform mounts it non-writable ----------
# PaaS volumes (Northflank etc.) are often owned by another uid, which makes chmod/mkdir fail for
# this non-root process; keep the container up by moving to an ephemeral writable dir instead of dying.
ORIG_DATA_DIR="$DATA_DIR"
mkdir -p "$DATA_DIR/secrets" 2>/dev/null || true
chmod 700 "$DATA_DIR" "$DATA_DIR/secrets" 2>/dev/null || true
if ! ( : > "$DATA_DIR/secrets/.writable" ) 2>/dev/null; then
  DATA_DIR="${TMPDIR:-/tmp}/argosbx-data"
  echo "[warn] $ORIG_DATA_DIR is not writable by uid $(id -u) (PaaS volume permissions?); falling back to $DATA_DIR" >&2
  echo "[warn] secrets and links will NOT survive restarts in fallback mode - fix the volume ownership or remount" >&2
  mkdir -p "$DATA_DIR/secrets"; chmod 700 "$DATA_DIR" "$DATA_DIR/secrets"
  : > "$DATA_DIR/secrets/.writable"
fi
rm -f "$DATA_DIR/secrets/.writable"

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

  # NAT mode: the perl relay owns the public UDP port; sing-box hides on loopback behind it.
  SB_HY2_LISTEN="::"; SB_HY2_PORTN=$HY2_PORT
  if [ "$HY2_NAT" = 1 ]; then SB_HY2_LISTEN="127.0.0.1"; SB_HY2_PORTN=$HY2_NAT_INTERNAL; fi

  cat > "$DATA_DIR/sing-box.json" <<JSON
{
  "log": { "level": "warn", "timestamp": true },
  "dns": { "servers": [ { "type": "local", "tag": "local" } ] },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "$SB_HY2_LISTEN",
      "listen_port": $SB_HY2_PORTN,
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

  if [ "$HY2_NAT" = 1 ]; then
    # hysteria2 link is emitted dynamically by the relay once the public mapping is known
    cat > "$DATA_DIR/hy2-nat.pl" <<'PERL'
use strict; use warnings;
use Socket;
$| = 1;   # autoflush: our log lines must reach docker logs immediately

my $PORT     = $ENV{NAT_PORT}     || die "[nat] NAT_PORT missing\n";
my $UP_PORT  = $ENV{NAT_UP_PORT}  || die "[nat] NAT_UP_PORT missing\n";
my $UP_IP    = "127.0.0.1";
my @STUN     = grep { length } split /\s*,\s*/, ($ENV{NAT_STUN} || "");
my $LINKS    = $ENV{NAT_LINKS}    || "";
my $URI      = $ENV{NAT_URI}      || "";
my $REPORT   = $ENV{NAT_REPORT}   || "";
my $TOKEN    = $ENV{NAT_TOKEN}    || "";
my $INTERVAL = 20;
my $IDLE     = 180;

sub ts { my @t = gmtime(time); sprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]) }
sub logm { print STDOUT "[nat] ", ts(), " @_\n"; }

socket(my $main, PF_INET, SOCK_DGRAM, 17) or die "[nat] socket: $!\n";
bind($main, sockaddr_in($PORT, INADDR_ANY)) or die "[nat] bind udp/$PORT: $!\n";
logm "relay udp/$PORT -> $UP_IP:$UP_PORT";

sub stun_servers {
  my @out;
  for my $s (@STUN) {
    my ($h, $p) = $s =~ /^([A-Za-z0-9.-]+)(?::(\d+))?$/ or next;
    my $ip = inet_aton($h) or next;
    push @out, [$ip, $p || 3478];
  }
  @out;
}
sub stun_send {
  my $pkt = "\x00\x01\x00\x00\x21\x12\xa4\x42\x11\x22\x33\x44\x55\x66\x77\x88\x99\xaa\xbb\xcc";
  for my $srv (stun_servers()) { send($main, $pkt, 0, sockaddr_in($srv->[1], $srv->[0])) }
}
sub stun_parse {
  my ($b) = @_;
  return undef unless defined $b && length($b) >= 20 && substr($b, 4, 4) eq "\x21\x12\xa4\x42";
  my $pos = 20;
  while ($pos + 4 <= length($b)) {
    my ($t, $l) = unpack("nn", substr($b, $pos, 4));
    last if $pos + 4 + $l > length($b);
    if ($t == 0x0020 || $t == 0x0001) {
      my $v = substr($b, $pos + 4, $l);
      next unless length($v) >= 7;
      my ($p, $i) = unpack("xnN", $v);
      if ($t == 0x0020) { $p ^= 0x2112; $i ^= 0x2112A442 }
      return inet_ntoa(pack("N", $i)) . ":" . $p;
    }
    $pos += 4 + (($l + 3) & ~3);
  }
  undef;
}
sub write_link {
  my ($uri) = @_;
  return unless length($LINKS) && length($uri);
  my @keep;
  if (open(my $fh, "<", $LINKS)) { @keep = grep { !/^hysteria2:\/\// } <$fh>; close $fh }
  if (open(my $o, ">", $LINKS))  { print $o @keep, "$uri\n"; close $o }
}
sub report {
  my ($addr) = @_;
  my ($ip, $p) = $addr =~ /^(\d+\.\d+\.\d+\.\d+):(\d+)$/ or return;
  my $uri = $URI; $uri =~ s/%s/$addr/g;
  logm "public mapping is now $addr";
  write_link($uri);
  return unless length $REPORT;
  my $j = sprintf('{"ip":"%s","port":"%s","uri":"%s","time":"%s"}', $ip, $p, $uri, ts());
  my @cmd = ("curl", "-fsS", "--max-time", "15", "-k", "-o", "/dev/null", "-X", "POST", $REPORT,
             "-H", "Content-Type: application/json",
             "-H", "Authorization: Bearer $TOKEN", "-d", $j);
  logm(system(@cmd) == 0 ? "reported to signaling server" : "report to signaling server FAILED");
}

$SIG{PIPE} = "IGNORE";
my %flows;      # "ip:port" -> { fh, ip, port, at }
my %stun_peer;  # "ip:port" of known STUN servers -> 1
$stun_peer{ inet_ntoa($_->[0]) . ":" . $_->[1] } = 1 for stun_servers();
my $mapped  = "";
my $pending = "";
my $last_probe = 0;
stun_send();
$last_probe = time;

while (1) {
  my $rin = "";
  vec($rin, fileno($main), 1) = 1;
  for my $ca (keys %flows) { vec($rin, fileno($flows{$ca}{fh}), 1) = 1 }
  my $timeout = $last_probe + $INTERVAL - time;
  $timeout = 0.5 if $timeout <= 0;
  my $n = select(my $rout = $rin, undef, undef, $timeout);
  if (time - $last_probe >= $INTERVAL) { stun_send(); $last_probe = time }
  if (!$n) {
    for my $ca (keys %flows) {
      if (time - $flows{$ca}{at} > $IDLE) {
        my $fh = delete $flows{$ca}{fh}; close $fh if $fh;
        delete $flows{$ca};
      }
    }
    next;
  }
  if (vec($rout, fileno($main), 1)) {
    my $from = recv($main, my $buf, 65535, 0);
    next unless defined $from;
    my ($cp, $ci) = sockaddr_in($from);
    my $peer = inet_ntoa($ci) . ":" . $cp;
    my $m = stun_parse($buf);
    if (defined $m && $stun_peer{$peer}) {
      # debounce: multi-line egress NATs can observe different mappings per STUN path;
      # only switch (and report) after the same value is seen twice in a row.
      if ($m ne $mapped) {
        if ($m eq $pending || $mapped eq "") { $mapped = $m; report($m) }
        else                                 { $pending = $m }
      }
      next;
    }
    next if $cp == $UP_PORT;                       # never relay loopback upstream chatter
    my $ca = inet_ntoa($ci) . ":" . $cp;
    my $f = $flows{$ca};
    unless ($f) {
      socket(my $tmp, PF_INET, SOCK_DGRAM, 17) or next;
      $f = { fh => $tmp, ip => $ci, port => $cp, at => time };
      $flows{$ca} = $f;
      logm "new flow from $ca";
    }
    $f->{at} = time;
    send($f->{fh}, $buf, 0, sockaddr_in($UP_PORT, inet_aton($UP_IP)));
  }
  for my $ca (keys %flows) {
    my $f = $flows{$ca};
    next unless vec($rout, fileno($f->{fh}), 1);
    my $from = recv($f->{fh}, my $b, 65535, 0);
    next unless defined $b && length $b;
    $f->{at} = time;
    send($main, $b, 0, sockaddr_in($f->{port}, $f->{ip}));
  }
}
PERL
    chmod 700 "$DATA_DIR/hy2-nat.pl"
  else
    echo "hysteria2://$HY2_PW@$URL_HOST:$HY2_PORT/?$Q#$NODE_NAME-hy2" >> "$LINKS"
  fi
fi

# ======================= Xray: VLESS-Reality and/or VLESS-Encryption+XHTTP (Argo origin) =======================
XRAY_INBOUNDS=""
if [ "$REALITY_PORT" != 0 ]; then
  if [ -n "${REALITY_PRIVATE_KEY:-}" ]; then
    R_PRIV="$REALITY_PRIVATE_KEY"
  else
    PRIV_FILE="$DATA_DIR/secrets/reality_private"
    if [ ! -s "$PRIV_FILE" ]; then
      "$BIN_DIR/xray" x25519 | awk -F': *' 'tolower($0) ~ /^private/ {printf "%s",$2}' > "$PRIV_FILE"
    fi
    R_PRIV="$(tr -d '\n' < "$PRIV_FILE")"
  fi
  unset REALITY_PRIVATE_KEY
  R_PUB="$("$BIN_DIR/xray" x25519 -i "$R_PRIV" | awk -F': *' 'tolower($1) ~ /^(password|public)/ {printf "%s",$2; exit}')"
  [ -n "$R_PRIV" ] && [ -n "$R_PUB" ] || die "failed to derive Reality keys"
  SID="$(secret reality_sid 8 "${REALITY_SID:-}")"; unset REALITY_SID
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
  XH_PATH="/$(secret argo_path 8 "${ARGO_PATH:-}")"; unset ARGO_PATH   # random path: only clients that know it reach the proxy
  # VLESS Encryption key pair (X25519 authentication + ML-KEM-768 post-quantum key exchange).
  # "decryption" is the server secret, "encryption" is the public client string. Env pair (stateless mode) wins.
  if [ -n "${ARGO_DEC_KEY:-}" ] && [ -n "${ARGO_ENC_KEY:-}" ]; then
    ARGO_DEC="$ARGO_DEC_KEY"; ARGO_ENC="$ARGO_ENC_KEY"
  else
    if [ ! -s "$DATA_DIR/secrets/argo_dec" ] || [ ! -s "$DATA_DIR/secrets/argo_enc" ]; then
      VE="$("$BIN_DIR/xray" vlessenc)"
      printf '%s\n' "$VE" | awk -F'"' '/^Authentication:/ {on = ($0 ~ /X25519/)} on && /"decryption"/ {printf "%s", $4; exit}' > "$DATA_DIR/secrets/argo_dec"
      printf '%s\n' "$VE" | awk -F'"' '/^Authentication:/ {on = ($0 ~ /X25519/)} on && /"encryption"/ {printf "%s", $4; exit}' > "$DATA_DIR/secrets/argo_enc"
    fi
    ARGO_DEC="$(tr -d '\n' < "$DATA_DIR/secrets/argo_dec")"; ARGO_ENC="$(tr -d '\n' < "$DATA_DIR/secrets/argo_enc")"
    RE='^mlkem768x25519plus\.(native|xorpub|random)\.[0-9a-z]+\.[A-Za-z0-9_-]+$'
    [[ "$ARGO_DEC" =~ $RE && "$ARGO_ENC" =~ $RE ]] || die "could not read VLESS Encryption keys from 'xray vlessenc' (delete $DATA_DIR/secrets/argo_dec and argo_enc to regenerate)"
  fi
  unset ARGO_DEC_KEY ARGO_ENC_KEY
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
          { "action": "block", "ip": [ "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24", "192.168.0.0/16", "198.18.0.0/15", "224.0.0.0/3", "::1/128", "fc00::/7", "fe80::/10" ] }
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
# Direct-only mode: XHTTP port served solely behind an HTTPS reverse proxy -> no tunnel needed.
RUN_CLOUDFLARED=1
if [ "$ARGO" = 1 ] && [ -z "$CF_TOKEN" ] && [ -n "$ARGO_PUBLIC_DOMAIN" ]; then
  RUN_CLOUDFLARED=0
  echo "[info] ARGO_PUBLIC_DOMAIN set without ARGO_TOKEN: skipping cloudflared, serving the reverse proxy only"
fi
if [ "$HY2_PORT" != 0 ]; then "$BIN_DIR/sing-box" run -c "$DATA_DIR/sing-box.json" & PIDS+=($!); fi
if [ "$HY2_PORT" != 0 ] && [ "$HY2_NAT" = 1 ]; then
  NAT_PORT="$HY2_PORT" NAT_UP_PORT="$HY2_NAT_INTERNAL" NAT_STUN="$STUN_SERVERS" \
  NAT_LINKS="$LINKS" NAT_URI="hysteria2://$HY2_PW@%s/?$Q#$NODE_NAME-hy2" \
  NAT_REPORT="$SIGNAL_URL" NAT_TOKEN="$SIGNAL_TOKEN" \
    perl "$DATA_DIR/hy2-nat.pl" & PIDS+=($!)
fi
if [ -n "$XRAY_INBOUNDS" ]; then "$BIN_DIR/xray" run -c "$DATA_DIR/xray.json" & PIDS+=($!); fi
if [ "$ARGO" = 1 ] && [ "$RUN_CLOUDFLARED" = 1 ]; then
  CF_ARGS=(tunnel --no-autoupdate --protocol "$ARGO_PROTOCOL" --metrics "$METRICS_ADDR" --loglevel warn)
  if [ -n "$CF_TOKEN" ]; then
    TUNNEL_TOKEN="$CF_TOKEN" "$BIN_DIR/cloudflared" "${CF_ARGS[@]}" run & CF_PID=$!      # token via env, not argv
  else
    "$BIN_DIR/cloudflared" "${CF_ARGS[@]}" --url "http://127.0.0.1:$ARGO_PORT" & CF_PID=$!   # quick tunnel (random trycloudflare.com host)
  fi
  PIDS+=("$CF_PID")
  unset CF_TOKEN
fi

# Quick tunnel: ask cloudflared for the hostname it was assigned, then publish the link.
if [ "$ARGO" = 1 ] && [ "$RUN_CLOUDFLARED" = 1 ] && [ "$FIXED_TUNNEL" = 0 ]; then
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

# Hand over to a fresh, minimal supervisor. exec replaces this setup shell, whose heap has
# ballooned (~40 MB observed) during config generation; the new image starts below 2 MB.
# The supervisor is perl, not bash: a post-exec shell has no job-table records for the
# children, so bash's `wait` would fail with "no such job"; perl's wait() is a raw syscall.
exec perl - "${PIDS[@]}" <<'SUPERVISOR'
my @pids = @ARGV;
my $stopping = 0;
$SIG{TERM} = $SIG{INT} = sub { $stopping = 1; kill 'TERM', @pids };
$SIG{ALRM} = sub { kill 'KILL', @pids };
my $rc = 0;
while (1) {
  my $p = wait();
  last if $p < 0;                       # all children gone
  $rc = ($? >> 8) unless $stopping;
  kill 'TERM', @pids; alarm 5;          # first death takes the rest down
}
1 while wait() >= 0;                     # reap stragglers
if ($stopping) { exit 0 }               # docker stop: clean exit
$rc = 1 unless $rc;                     # a proxy should never exit by itself -> non-zero so Docker restarts us
print STDERR "[error] a proxy process exited unexpectedly (rc=$rc)\n";
exit $rc;
SUPERVISOR
