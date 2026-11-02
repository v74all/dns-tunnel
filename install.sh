#!/usr/bin/env bash
#
# dns-tunnel - a DNS tunnel (dnstt) on your own server, for when only DNS gets out
# https://github.com/v74all/dns-tunnel
#
# Read it before you run it. Everything it touches is listed in README.md.

set -euo pipefail
umask 077

VERSION=1.0.0

DNSTT=dnstt-20260501
# sha256 of the release binaries, built by build-dnstt.sh from the signed $DNSTT.zip
SHA_AMD64=16c4df19255d7b63efcce8382d55d6da49272d9c5a4bfdf041c1f77c2cd17ad8
SHA_ARM64=45cee8cb7d959a69ac54014b40a68e72d7fc54b0d6f494d8de6075277447a788
RELEASE=https://github.com/v74all/dns-tunnel/releases/download/v$VERSION

BIN=/usr/local/bin/dnstt-server
ETC=/etc/dns-tunnel
STATE=$ETC/dns-tunnel.env
RULES=$ETC/rules.nft
UNIT=/etc/systemd/system/dns-tunnel.service
SSHD_DROPIN=/etc/ssh/sshd_config.d/60-dns-tunnel.conf
GROUP=dnstunnel
# dnstt runs as this user; it owns the private key and nothing else
SVC_USER=dnstt
# public resolvers for `check`, the same ones a phone would try first
RESOLVERS="1.1.1.1 8.8.8.8 9.9.9.9"

domain=
port=5300
mtu=1232
bin=
resolvers=

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { printf '[%s/5] %-8s %s\n' "$1" "$2" "$3"; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run it with sudo"; }
have() { command -v "$1" >/dev/null 2>&1; }
line() { printf '  %-5s %-8s %s\n' "$1" "$2" "$3"; }

valid_name() { [[ $1 =~ ^[a-z][a-z0-9_-]{0,30}$ ]] || die "names may use a-z 0-9 _ - and start with a letter (max 31): $1"; }

usage() {
	cat <<EOF
dns-tunnel $VERSION

usage: sudo bash install.sh [install] --domain t.example.com [options]
       sudo bash install.sh add NAME | del NAME | passwd NAME | users
       sudo bash install.sh show
       sudo bash install.sh check [--resolver IP]
       sudo bash install.sh status
       sudo bash install.sh uninstall

before install, add two records at your domain's DNS provider:
  A   tns.example.com  -> this server's IPv4
  NS  t.example.com    -> tns.example.com
(the NS name must not be inside the tunnel name; keep "t" short)

install options:
  --domain NAME      the tunnel name (the NS record above)
  --port N           local UDP port dnstt listens on (5300); udp/53 is redirected to it
  --mtu N            largest DNS answer (1232); try 512 if a resolver drops big answers
  --bin FILE         use this dnstt-server binary (still checked against the pinned sha256)

check options:
  --resolver IP      also test through this resolver (repeatable)
EOF
}

load_state() {
	[ -f "$STATE" ] || die "not installed yet"
	domain=$(sed -n 's/^DOMAIN=//p' "$STATE")
	port=$(sed -n 's/^PORT=//p' "$STATE")
	mtu=$(sed -n 's/^MTU=//p' "$STATE")
}

arch() {
	case $(uname -m) in
	x86_64 | amd64) echo amd64 ;;
	aarch64 | arm64) echo arm64 ;;
	*) die "unsupported cpu: $(uname -m)" ;;
	esac
}

ssh_port() {
	local p
	p=$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }')
	echo "${p:-22}"
}

apt_need() { # command package
	have "$1" && return 0
	have apt-get || die "$1 is missing and this is not Debian/Ubuntu; install $2 first"
	DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$2" >/dev/null 2>&1 ||
		{ apt-get update -qq >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$2" >/dev/null 2>&1; } ||
		die "could not install $2"
}

# a name dnstt answers like a client poll: 8-byte client id, then 3 bytes of padding (224 + 3)
poll_name() {
	{ head -c 8 /dev/urandom; printf '\343'; head -c 3 /dev/urandom; } | base32 | tr -d '=\n' | tr '[:upper:]' '[:lower:]'
	printf '.%s' "$1"
}

# --- install -----------------------------------------------------------------

get_binary() {
	local a want tmp
	a=$(arch)
	want=$SHA_AMD64
	[ "$a" = arm64 ] && want=$SHA_ARM64
	tmp=$(mktemp)
	if [ -n "$bin" ]; then
		cp "$bin" "$tmp"
	elif [ -f "./dnstt-server-linux-$a" ]; then
		cp "./dnstt-server-linux-$a" "$tmp"
	else
		have curl || apt_need curl curl
		curl -fsSL --retry 3 -o "$tmp" "$RELEASE/dnstt-server-linux-$a" || { rm -f "$tmp"; die "download failed: $RELEASE/dnstt-server-linux-$a"; }
	fi
	[ "$(sha256sum "$tmp" | cut -d' ' -f1)" = "$want" ] || { rm -f "$tmp"; die "sha256 mismatch for dnstt-server-linux-$a"; }
	install -m 755 "$tmp" "$BIN"
	rm -f "$tmp"
}

write_rules() {
	local gid
	gid=$(getent group "$GROUP" | cut -d: -f3)
	cat >"$RULES" <<EOF
# dns-tunnel $VERSION: udp/53 to this host goes to dnstt on :$port, and
# tunnel users can't reach this host's own services or private networks.
add table inet dns_tunnel
delete table inet dns_tunnel
table inet dns_tunnel {
	chain prerouting {
		type nat hook prerouting priority dstnat; policy accept;
		udp dport 53 fib daddr type local redirect to :$port
	}
	chain output {
		type filter hook output priority filter; policy accept;
		meta skgid $gid ip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16 } reject
		meta skgid $gid ip6 daddr { ::1, fc00::/7, fe80::/10 } reject
	}
}
EOF
	chmod 644 "$RULES"
}

write_sshd() {
	cat >"$SSHD_DROPIN" <<EOF
# dns-tunnel $VERSION: members of $GROUP may only forward ports, and only
# through the tunnel (dnstt connects from 127.0.0.1). From anywhere else they
# have no way to log in.
Match Group $GROUP Address 127.0.0.1,::1
	PasswordAuthentication yes
	KbdInteractiveAuthentication no
	AllowTcpForwarding local
	AllowStreamLocalForwarding no
	AllowAgentForwarding no
	X11Forwarding no
	PermitTunnel no
	PermitTTY no
Match Group $GROUP
	PasswordAuthentication no
	PubkeyAuthentication no
	KbdInteractiveAuthentication no
Match all
EOF
	chmod 644 "$SSHD_DROPIN"
	sshd -t || { rm -f "$SSHD_DROPIN"; die "sshd rejected the config; nothing changed in ssh"; }
	systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
}

write_unit() {
	cat >"$UNIT" <<EOF
[Unit]
Description=dns-tunnel (dnstt server) for $domain
After=network-online.target
Wants=network-online.target

[Service]
User=$SVC_USER
Group=$SVC_USER
ExecStartPre=+$(command -v nft) -f $RULES
ExecStart=$BIN -udp :$port -mtu $mtu -privkey-file $ETC/server.key $domain 127.0.0.1:$(ssh_port)
ExecStopPost=-+$(command -v nft) delete table inet dns_tunnel
Restart=on-failure
RestartSec=3
NoNewPrivileges=yes
CapabilityBoundingSet=
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6
RestrictNamespaces=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
EOF
	chmod 644 "$UNIT"
}

cmd_install() {
	need_root
	[ -n "$domain" ] || die "usage: install.sh --domain t.example.com (see --help)"
	[[ $domain =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || die "not a domain name: $domain"
	[ ${#domain} -le 40 ] || die "keep the tunnel name short (40 chars max): every query carries it"
	have systemctl || die "systemd is required"
	have sshd || die "openssh-server is required"
	# shellcheck source=/dev/null
	step 1 system "$(. /etc/os-release && echo "$ID ${VERSION_ID:-}"), $(uname -m), systemd"

	apt_need nft nftables
	get_binary
	step 2 dnstt "$DNSTT (v74all/dns-tunnel $VERSION release), sha256 ok"

	install -d -m 755 "$ETC"
	id "$SVC_USER" >/dev/null 2>&1 ||
		useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin --user-group "$SVC_USER"
	if [ ! -s "$ETC/server.key" ]; then
		"$BIN" -gen-key -privkey-file "$ETC/server.key" -pubkey-file "$ETC/server.pub" >/dev/null
	fi
	chown "$SVC_USER:$SVC_USER" "$ETC/server.key"
	chmod 600 "$ETC/server.key"
	chmod 644 "$ETC/server.pub"
	printf 'DOMAIN=%s\nPORT=%s\nMTU=%s\n' "$domain" "$port" "$mtu" >"$STATE"
	chmod 644 "$STATE"
	step 3 keys "$ETC/server.pub"

	getent group "$GROUP" >/dev/null || groupadd --system "$GROUP"
	write_sshd
	step 4 ssh "group $GROUP: forwarding only, password only inside the tunnel"

	write_rules
	write_unit
	systemctl daemon-reload
	systemctl enable dns-tunnel >/dev/null 2>&1
	systemctl restart dns-tunnel
	sleep 1
	systemctl is-active --quiet dns-tunnel || die "dns-tunnel.service did not start: journalctl -u dns-tunnel"
	if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
		ufw allow "$port/udp" comment 'dns-tunnel (udp/53 redirected)' >/dev/null
	fi
	step 5 service "dns-tunnel.service active, udp 53 -> $port"
	echo "done. next: sudo bash install.sh add NAME, then sudo bash install.sh check"
}

# --- users -------------------------------------------------------------------

is_ours() { id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -qx "$GROUP"; }

new_password() {
	local pw
	pw=$(tr -dc 'a-z0-9' </dev/urandom | head -c 14 || true)
	printf '%s:%s\n' "$1" "$pw" | chpasswd
	printf '%s\n' "$pw"
}

cmd_add() {
	need_root
	load_state
	local name=${1:-}
	[ -n "$name" ] || die "usage: install.sh add NAME"
	valid_name "$name"
	id "$name" >/dev/null 2>&1 && die "$name already exists on this server"
	useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin --gid "$GROUP" "$name"
	local pw
	pw=$(new_password "$name")
	echo "added $name"
	printf '  ssh user      %s\n  ssh password  %s\n' "$name" "$pw"
	echo "  (shown once; sudo bash install.sh passwd $name makes a new one)"
}

cmd_passwd() {
	need_root
	local name=${1:-}
	if [ -z "$name" ] || ! is_ours "$name"; then die "not a tunnel user: ${name:-?}"; fi
	printf '  ssh password  %s\n' "$(new_password "$name")"
}

cmd_del() {
	need_root
	local name=${1:-}
	if [ -z "$name" ] || ! is_ours "$name"; then die "not a tunnel user: ${name:-?}"; fi
	pkill -u "$name" 2>/dev/null || true
	userdel "$name"
	echo "removed $name (open sessions closed)"
}

cmd_users() {
	need_root
	getent group "$GROUP" >/dev/null || return 0
	local members
	members=$(getent group "$GROUP" | cut -d: -f4)
	# users whose primary group is ours don't show in the member list
	getent passwd | awk -F: -v g="$(getent group "$GROUP" | cut -d: -f3)" '$4 == g { print $1 }'
	[ -n "$members" ] && tr ',' '\n' <<<"$members"
	return 0
}

# --- show / check / status -----------------------------------------------------

cmd_show() {
	need_root
	load_state
	local pub
	pub=$(cat "$ETC/server.pub")
	cat <<EOF
dns-tunnel $VERSION on $(hostname)
  domain      $domain
  public key  $pub
  ssh user    one from: sudo bash install.sh users

phone (SlipNet, from github.com/anonvector/SlipNet only):
  new profile -> DNSTT + SSH: the domain, public key, user, password
  resolver: your network's DNS first; when it fails, a public one

computer (dnstt-client from this repo's release):
  dnstt-client -udp RESOLVER:53 -pubkey $pub $domain 127.0.0.1:7000
  ssh -N -D 1080 -p 7000 USER@127.0.0.1
  then use the SOCKS5 proxy 127.0.0.1:1080
EOF
}

cmd_check() {
	need_root
	load_state
	apt_need dig bind9-dnsutils
	printf 'dns-tunnel %s check: %s\n' "$VERSION" "$domain"
	local bad=0 r out status
	if systemctl is-active --quiet dns-tunnel && nft list table inet dns_tunnel >/dev/null 2>&1; then
		line ok service "active, udp 53 -> $port"
	else
		line fail service "not running: sudo systemctl status dns-tunnel"
		bad=1
	fi
	for r in $resolvers $RESOLVERS; do
		out=$(dig +tries=1 +time=4 +noall +comments +answer TXT "$(poll_name "$domain")" "@$r" 2>&1 || true)
		status=$(sed -n 's/.*status: \([A-Z]*\),.*/\1/p' <<<"$out" | head -1)
		if [ "$status" = NOERROR ] && grep -Eq '[[:space:]]TXT[[:space:]]' <<<"$out"; then
			line ok "$r" "a test query came back through it"
		elif [ "$status" = NXDOMAIN ]; then
			line warn "$r" "nxdomain: check the NS record for $domain"
			bad=1
		elif [ -n "$status" ]; then
			line warn "$r" "${status,,}"
			bad=1
		else
			line warn "$r" "no answer"
			bad=1
		fi
	done
	return "$bad"
}

cmd_status() {
	need_root
	load_state
	printf 'dns-tunnel %s: %s, %s users\n' "$domain" "$(systemctl is-active dns-tunnel || true)" "$(cmd_users | grep -c . || true)"
}

cmd_uninstall() {
	need_root
	local u
	systemctl disable --now dns-tunnel >/dev/null 2>&1 || true
	nft delete table inet dns_tunnel 2>/dev/null || true
	for u in $(cmd_users); do
		pkill -u "$u" 2>/dev/null || true
		userdel "$u" 2>/dev/null || true
	done
	groupdel "$GROUP" 2>/dev/null || true
	userdel "$SVC_USER" 2>/dev/null || true
	rm -f "$UNIT" "$BIN" "$SSHD_DROPIN"
	rm -rf "$ETC"
	systemctl daemon-reload
	systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
	have ufw && ufw delete allow "$port/udp" >/dev/null 2>&1 || true
	echo "removed dns-tunnel, its keys, its users and its firewall rules"
}

# --- main ----------------------------------------------------------------------

cmd=install
case ${1:-} in
install | add | del | passwd | users | show | check | status | uninstall) cmd=$1; shift ;;
help) usage; exit 0 ;;
esac
args=()
while [ $# -gt 0 ]; do
	case $1 in
	--domain) domain=${2:?--domain needs a name}; shift ;;
	--port) port=${2:?}; shift ;;
	--mtu) mtu=${2:?}; shift ;;
	--bin) bin=${2:?--bin needs a file}; shift ;;
	--resolver) resolvers+=" ${2:?--resolver needs an address}"; shift ;;
	-h | --help) usage; exit 0 ;;
	--version) echo "$VERSION"; exit 0 ;;
	-*) die "unknown option: $1 (see --help)" ;;
	*) args+=("$1") ;;
	esac
	shift
done
domain=${domain,,}
[[ $port =~ ^[0-9]+$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ] || die "--port must be 1024-65535"
[[ $mtu =~ ^[0-9]+$ ]] && [ "$mtu" -ge 512 ] && [ "$mtu" -le 1452 ] || die "--mtu must be 512-1452"

case $cmd in
install) [ ${#args[@]} -eq 0 ] || die "unknown command: ${args[0]} (see --help)"; cmd_install ;;
add) cmd_add "${args[0]:-}" ;;
del) cmd_del "${args[0]:-}" ;;
passwd) cmd_passwd "${args[0]:-}" ;;
users) cmd_users ;;
show) cmd_show ;;
check) cmd_check ;;
status) cmd_status ;;
uninstall) cmd_uninstall ;;
esac
