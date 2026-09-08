#!/usr/bin/env bash
# ============================================================
# NOKVMVECTAR VPS MANAGER 13.1.2
# Ubuntu 24.04 host + LXD 5.21.x
# Designed for AWS / Oracle Cloud / Azure style VPS hosts.
#
# Key fixes:
# - Valid LXD bridge IPv4 addresses (gateway uses .1/24, never .0/24)
# - No invalid lvm.vg.force option
# - LXD-managed bounded loop-backed LVM pool
# - Real per-container root disk size
# - Safe, idempotent NIC/profile handling (no "device already exists")
# - Managed DHCP + NAT + DNS
# - Host UFW forwarding rules without disabling UFW
# - Guest DNS repair and APT retry/IPv4 fallback
# - Automatic network repair
# - Deletes an automatically-created bridge when no containers use it
# - Diagnostics
# ============================================================

set -u
export DEBIAN_FRONTEND=noninteractive

VERSION="13.1.2"
APP="nokvmvectar"
LOG="/var/log/${APP}.log"
PORT_DB="/var/lib/${APP}/port-forwards"
POOL="nokvmvectar"
PROFILE="default"
BR_PREFIX="nkvbr"
SUBNET_PREFIX="10.77"
BRIDGE_NAME=""
UPLINK=""

mkdir -p "$(dirname "$LOG")"
touch "$LOG"
chmod 600 "$LOG"
mkdir -p "$(dirname "$PORT_DB")"
touch "$PORT_DB"
chmod 600 "$PORT_DB"

exec 3>&1 4>&2
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG" >&3; }
info(){ log "[INFO] $*"; }
ok(){ log "[ OK ] $*"; }
warn(){ log "[WARN] $*"; }
err(){ log "[ERROR] $*"; }

die(){ err "$*"; exit 1; }

need_root(){
  [ "$(id -u)" -eq 0 ] || die "Run as root."
}

run(){
  "$@" >>"$LOG" 2>&1
}

retry(){
  local tries="$1"; shift
  local n=1
  while [ "$n" -le "$tries" ]; do
    if "$@" >>"$LOG" 2>&1; then return 0; fi
    sleep "$((n<5?n:5))"
    n=$((n+1))
  done
  return 1
}

valid_name(){
  [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]]
}

detect_uplink(){
  UPLINK="$(ip -4 route show default 2>/dev/null | awk 'NR==1 {print $5}')"
  [ -n "$UPLINK" ] || {
    UPLINK="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  }
  [ -n "$UPLINK" ] || die "Could not detect host IPv4 uplink interface."
}

host_apt(){
  info "Refreshing host APT metadata..."
  if retry 4 apt-get update \
      -o Acquire::ForceIPv4=true \
      -o Acquire::Retries=3 \
      -o Acquire::http::Timeout=20 \
      -o Acquire::https::Timeout=20; then
    ok "Host APT update succeeded."
  else
    warn "Host APT update failed after retries. Continuing only if required packages are already available."
  fi

  info "Installing required packages..."
  retry 4 apt-get install -y \
    ca-certificates curl dnsutils iproute2 iputils-ping \
    lvm2 thin-provisioning-tools util-linux jq nftables iptables \
    e2fsprogs snapd || die "Required host packages could not be installed."
  ok "Host prerequisites ready."
}

install_lxd(){
  if ! command -v lxc >/dev/null 2>&1; then
    info "Installing LXD snap..."
    systemctl enable --now snapd.socket >/dev/null 2>&1 || true
    sleep 2
    retry 4 snap install lxd || die "Could not install LXD."
  fi

  snap start lxd >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    if lxc info >/dev/null 2>&1; then
      ok "LXD ready: $(lxc version 2>/dev/null | head -1)"
      return
    fi
    sleep 1
  done
  die "LXD daemon did not become ready."
}

ensure_lxd_init(){
  if ! lxc storage list >/dev/null 2>&1; then
    info "Initializing LXD..."
    printf '\n' | lxd init --minimal >>"$LOG" 2>&1 || true
  fi

  # If the default profile has no root device, attach the first usable pool.
  local pool
  pool="$(lxc storage list --format csv 2>/dev/null | awk -F, '$2=="dir" || $2=="lvm" || $2=="zfs" {print $1; exit}')"
  if [ -n "$pool" ]; then
    if ! lxc profile device show "$PROFILE" root >/dev/null 2>&1; then
      lxc profile device add "$PROFILE" root disk path=/ pool="$pool" >>"$LOG" 2>&1 || true
    fi
  fi
}

pool_exists(){ lxc storage show "$POOL" >/dev/null 2>&1; }

pool_size_gib(){
  df -Pk /var/snap/lxd/common/lxd/storage-pools/default 2>/dev/null | awk 'NR==2{print int($4/1024/1024)}'
}

ensure_storage(){
  if pool_exists; then
    ok "Storage pool $POOL already exists."
    return
  fi

  local free_gib size_gib
  free_gib="$(df -Pk /var/snap/lxd/common/lxd 2>/dev/null | awk 'NR==2{print int($4/1024/1024)}')"
  [ -n "$free_gib" ] || free_gib="$(df -Pk / | awk 'NR==2{print int($4/1024/1024)}')"

  # Keep substantial headroom for the cloud host and existing applications.
  # Do not request a pool larger than 80% of currently free space.
  size_gib=$((free_gib * 80 / 100))
  [ "$size_gib" -gt 64 ] && size_gib=64
  [ "$size_gib" -ge 8 ] || die "Not enough free host disk for a bounded LXD storage pool (need at least ~10GiB free)."

  info "Creating bounded ${size_gib}GiB LXD-managed loop-backed LVM pool..."
  # Do NOT pass the invalid lvm.vg.force option.
  if lxc storage create "$POOL" lvm size="${size_gib}GiB"  >>"$LOG" 2>&1; then
    ok "Created bounded LVM storage pool: $POOL (${size_gib}GiB maximum)."
  else
    err "Could not create LVM storage pool."
    return 1
  fi
}

network_exists(){ lxc network show "$1" >/dev/null 2>&1; }

network_in_use(){
  local net="$1"
  lxc network show "$net" 2>/dev/null | grep -q 'used_by:'
}

choose_network(){
  local i name gw cidr
  for i in $(seq 10 250); do
    name="${BR_PREFIX}${i}"
    gw="${SUBNET_PREFIX}.${i}.1"
    cidr="${SUBNET_PREFIX}.${i}.0/24"

    # Linux interface names are limited to 15 characters.
    [ "${#name}" -le 15 ] || continue

    # Never reuse an existing LXD network name.
    network_exists "$name" && continue

    # Never select a subnet already present on the host.
    ip -4 addr show 2>/dev/null | grep -qF "${gw}/24" && continue
    ip -4 route show 2>/dev/null | grep -qF "${cidr}" && continue

    BRIDGE_NAME="$name"
    return
  done
  die "No free managed LXD bridge name/subnet found."
}

ensure_network(){
  detect_uplink

  # Reuse an existing manager-created network and re-assert all settings.
  # This is important for older installations whose bridge exists but whose
  # NAT/firewall settings were changed or lost after a reboot.
  local existing
  existing="$(current_network 2>/dev/null || true)"
  if [ -n "$existing" ]; then
    BRIDGE_NAME="$existing"
    info "Repairing managed LXD network: $BRIDGE_NAME"
    lxc network set "$BRIDGE_NAME" ipv4.nat true >>"$LOG" 2>&1 || true
    lxc network set "$BRIDGE_NAME" ipv4.routing true >>"$LOG" 2>&1 || true
    lxc network set "$BRIDGE_NAME" ipv4.firewall true >>"$LOG" 2>&1 || true
    lxc network set "$BRIDGE_NAME" ipv6.address none >>"$LOG" 2>&1 || true
    lxc network set "$BRIDGE_NAME" ipv6.nat false >>"$LOG" 2>&1 || true
    lxc network set "$BRIDGE_NAME" dns.mode managed >>"$LOG" 2>&1 || true

    local existing_gw
    existing_gw="$(lxc network get "$BRIDGE_NAME" ipv4.address 2>/dev/null || true)"
    if [ -n "$existing_gw" ]; then
      ok "Using managed LXD network: ${BRIDGE_NAME} (${existing_gw})."
      return 0
    fi
  fi

  choose_network

  local i="${BRIDGE_NAME#${BR_PREFIX}}"
  local gw="${SUBNET_PREFIX}.${i}.1/24"

  info "Creating managed LXD network ${BRIDGE_NAME} (${gw}, uplink ${UPLINK})..."

  if ! lxc network create "$BRIDGE_NAME" \
      ipv4.address="$gw" \
      ipv4.dhcp=true \
      ipv4.nat=true \
      ipv4.routing=true \
      ipv6.address=none \
      ipv6.nat=false \
      dns.mode=managed \
      dns.domain=nokvmvectar \
      ipv4.firewall=true >>"$LOG" 2>&1; then
    err "Network creation failed for ${BRIDGE_NAME} (${gw})."
    return 1
  fi

  ok "Network ready: ${BRIDGE_NAME} / ${gw} / DHCP + NAT + firewall + managed DNS."
  return 0
}

current_network(){
  lxc network list --format csv 2>/dev/null |
    awk -F, '$2=="bridge" && $1 ~ /^nkvbr[0-9]+$/ {print $1; exit}'
}

ensure_ufw_forwarding(){
  if ! command -v ufw >/dev/null 2>&1; then
    return 0
  fi
  if ! ufw status 2>/dev/null | grep -qi active; then
    return 0
  fi

  info "UFW active: applying forwarding allowances for LXD."
  ufw route allow in on "$BRIDGE_NAME" out on "$UPLINK" >/dev/null 2>&1 || true
  ufw route allow in on "$UPLINK" out on "$BRIDGE_NAME" >/dev/null 2>&1 || true
  ok "UFW forwarding allowances applied."
}

ensure_forwarding(){
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  cat >/etc/sysctl.d/99-nokvmvectar-lxd.conf <<EOF
net.ipv4.ip_forward=1
EOF
  sysctl --system >/dev/null 2>&1 || true
}

ensure_filter_forwarding(){
  local i subnet bridge="$BRIDGE_NAME"
  i="${BRIDGE_NAME#${BR_PREFIX}}"
  subnet="${SUBNET_PREFIX}.${i}.0/24"

  # Explicit forwarding rules make guest internet work even when the host
  # firewall defaults to DROP. Rules are narrow and idempotent.
  iptables -C FORWARD -i "$bridge" -o "$UPLINK" -s "$subnet" -j ACCEPT >/dev/null 2>&1 || \
    iptables -I FORWARD 1 -i "$bridge" -o "$UPLINK" -s "$subnet" -j ACCEPT >/dev/null 2>&1 || true

  iptables -C FORWARD -i "$UPLINK" -o "$bridge" -d "$subnet" \
    -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1 || \
    iptables -I FORWARD 1 -i "$UPLINK" -o "$bridge" -d "$subnet" \
    -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1 || true
}

ensure_nat_fallback(){
  local i subnet
  i="${BRIDGE_NAME#${BR_PREFIX}}"
  subnet="${SUBNET_PREFIX}.${i}.0/24"

  # LXD normally owns this MASQUERADE rule. Keep an idempotent fallback for
  # hosts where LXD's firewall backend is incomplete after a reboot.
  iptables -t nat -C POSTROUTING -s "$subnet" ! -d "$subnet" -o "$UPLINK" -j MASQUERADE \
    >/dev/null 2>&1 || \
  iptables -t nat -A POSTROUTING -s "$subnet" ! -d "$subnet" -o "$UPLINK" -j MASQUERADE \
    >/dev/null 2>&1 || true
}

ensure_network_stack(){
  ensure_forwarding
  ensure_ufw_forwarding
  ensure_filter_forwarding
  ensure_nat_fallback
}

ensure_image(){
  local image="$1"
  info "Checking LXD image: $image"
  lxc image info "$image" >/dev/null 2>&1 && return 0
  retry 4 lxc image list "$image" >/dev/null 2>&1 || true
  lxc image info "$image" >/dev/null 2>&1 || die "Could not access LXD image $image. Check host Internet/DNS."
}

guest_dns_repair(){
  local n="$1"
  # Set DNS at the guest level without replacing systemd-resolved permanently.
  # Network DNS is supplied by LXD; fallback nameservers help when managed DNS
  # is temporarily unavailable.
  lxc exec "$n" -- bash -lc '
    set -u
    mkdir -p /etc/systemd/resolved.conf.d
    cat >/etc/systemd/resolved.conf.d/90-nokvmvectar.conf <<EOF
[Resolve]
DNS=1.1.1.1 8.8.8.8
FallbackDNS=9.9.9.9 1.0.0.1
DNSStubListener=yes
EOF
    systemctl restart systemd-resolved 2>/dev/null || true
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true
    if command -v dhclient >/dev/null 2>&1; then
      dhclient -r eth0 2>/dev/null || true
      dhclient eth0 2>/dev/null || true
    fi
    ip link set eth0 up 2>/dev/null || true
  ' >>"$LOG" 2>&1 || true
}

guest_apt_repair(){
  local n="$1"
  lxc exec "$n" -- bash -lc '
    set -u
    export DEBIAN_FRONTEND=noninteractive

    # FIX for VPS guests that hang at:
    #   Connecting to archive.ubuntu.com (IPv6)
    # Some cloud networks advertise IPv6 but do not provide working IPv6
    # internet. Make IPv4-only APT behavior persistent.
    mkdir -p /etc/apt/apt.conf.d
    cat >/etc/apt/apt.conf.d/80-nokvmvectar-network <<EOF
Acquire::ForceIPv4 "true";
Acquire::Retries "5";
Acquire::http::Timeout "20";
Acquire::https::Timeout "20";
Acquire::http::Pipeline-Depth "0";
EOF

    # Prefer HTTPS for the standard Ubuntu archive hosts.
    if [ -f /etc/os-release ]; then . /etc/os-release; fi
    if [ "${ID:-}" = ubuntu ]; then
      sed -i -E "s#http://(archive|security)\.ubuntu\.com#https://\1.ubuntu.com#g" /etc/apt/sources.list 2>/dev/null || true
      find /etc/apt/sources.list.d -type f \( -name "*.sources" -o -name "*.list" \) 2>/dev/null |
      while read -r f; do
        sed -i -E "s#http://(archive|security)\.ubuntu\.com#https://\1.ubuntu.com#g" "$f" 2>/dev/null || true
      done
    fi

    # Repair systemd-resolved without permanently replacing LXD networking.
    mkdir -p /etc/systemd/resolved.conf.d
    cat >/etc/systemd/resolved.conf.d/90-nokvmvectar.conf <<EOF
[Resolve]
DNS=1.1.1.1 8.8.8.8
FallbackDNS=9.9.9.9 1.0.0.1
DNSStubListener=yes
EOF
    systemctl restart systemd-resolved 2>/dev/null || true
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true

    ip link set eth0 up 2>/dev/null || true
    if command -v dhclient >/dev/null 2>&1; then
      dhclient -r eth0 2>/dev/null || true
      dhclient eth0 2>/dev/null || true
    fi

    # Retry APT with an explicit IPv4 override as well.
    for i in 1 2 3 4 5; do
      if apt-get -o Acquire::ForceIPv4=true update; then exit 0; fi
      sleep "$i"
    done

    systemctl restart systemd-resolved 2>/dev/null || true
    sleep 2
    for i in 1 2 3; do
      apt-get -o Acquire::ForceIPv4=true update && exit 0
      sleep "$i"
    done
    exit 1
  ' >>"$LOG" 2>&1
}

configure_nic(){
  local n="$1"
  local dev

  # Idempotent: if eth0 already exists, modify it rather than adding another.
  if lxc config device show "$n" 2>/dev/null | grep -q '^eth0:'; then
    lxc config device set "$n" eth0 network "$BRIDGE_NAME" >>"$LOG" 2>&1 || true
  else
    lxc network attach "$BRIDGE_NAME" "$n" eth0 eth0 >>"$LOG" 2>&1 || {
      # Race-safe fallback: inspect again before declaring failure.
      if ! lxc config device show "$n" 2>/dev/null | grep -q '^eth0:'; then
        err "Could not attach eth0 to $n."
        return 1
      fi
    }
  fi

  # Ensure boot autostart and wait for interface to appear.
  lxc config set "$n" boot.autostart true >>"$LOG" 2>&1 || true
  lxc config device set "$n" eth0 boot.priority 10 >>"$LOG" 2>&1 || true

  dev="$(lxc config device get "$n" eth0 network 2>/dev/null || true)"
  [ "$dev" = "$BRIDGE_NAME" ] || {
    err "$n NIC is not attached to $BRIDGE_NAME."
    return 1
  }
  ok "$n NIC verified: eth0 -> $BRIDGE_NAME"
}

guest_has_network(){
  local n="$1"
  local addr route dns
  addr="$(lxc exec "$n" -- ip -4 -o addr show dev eth0 2>/dev/null || true)"
  route="$(lxc exec "$n" -- ip -4 route show default 2>/dev/null || true)"
  dns="$(lxc exec "$n" -- getent hosts archive.ubuntu.com 2>/dev/null || true)"
  [[ "$addr" == *"inet "* ]] && [ -n "$route" ] && [ -n "$dns" ] &&
    lxc exec "$n" -- ping -4 -c 1 -W 2 1.1.1.1 >/dev/null 2>&1
}

repair_network(){
  local n="$1"
  info "Repairing network for $n..."
  ensure_network_stack
  configure_nic "$n" || true
  lxc restart "$n" >>"$LOG" 2>&1 || true
  sleep 3
  guest_dns_repair "$n"

  local attempt
  for attempt in $(seq 1 30); do
    if guest_has_network "$n"; then
      ok "$n network verified."
      return 0
    fi
    if (( attempt % 5 == 0 )); then
      info "$n network recovery attempt $attempt/30"
      # Re-assert NIC without adding a duplicate device.
      configure_nic "$n" || true
      guest_dns_repair "$n"
      lxc restart "$n" >>"$LOG" 2>&1 || true
    fi
    sleep 2
  done

  warn "$n network could not be verified automatically."
  return 1
}

validate_port(){
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

host_ipv4(){
  ip -4 addr show dev "$UPLINK" 2>/dev/null |
    awk '/inet / {print $2}' | cut -d/ -f1 | head -1
}

ensure_port_forward(){
  local n="$1" host_port="$2" guest_ip guest_port="22" host_ip
  guest_ip="$(lxc exec "$n" -- ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
  [ -n "$guest_ip" ] || guest_ip="$(lxc list "$n" -c 4 --format csv 2>/dev/null | head -1)"
  [ -n "$guest_ip" ] || { warn "Could not determine IPv4 for $n; port forwarding was not added."; return 1; }

  host_ip="$(host_ipv4)"

  # Prevent accidentally assigning one public TCP port to multiple VPSes.
  if awk -v p="$host_port" -v n="$n" '$1 == p && $2 != n {found=1} END {exit !found}' "$PORT_DB"; then
    err "Host port $host_port is already assigned to another VPS."
    return 1
  fi

  # Remove exact old rules first so re-running Repair is idempotent.
  while iptables -t nat -C PREROUTING -i "$UPLINK" -p tcp --dport "$host_port" -j DNAT --to-destination "${guest_ip}:${guest_port}" >/dev/null 2>&1; do
    iptables -t nat -D PREROUTING -i "$UPLINK" -p tcp --dport "$host_port" -j DNAT --to-destination "${guest_ip}:${guest_port}" >/dev/null 2>&1 || break
  done
  iptables -t nat -A PREROUTING -i "$UPLINK" -p tcp --dport "$host_port" -j DNAT --to-destination "${guest_ip}:${guest_port}" || return 1

  # Permit the forwarded SSH packet through the host firewall.
  iptables -C FORWARD -i "$UPLINK" -o "$BRIDGE_NAME" -p tcp -d "$guest_ip" --dport "$guest_port" -j ACCEPT >/dev/null 2>&1 || \
    iptables -I FORWARD 1 -i "$UPLINK" -o "$BRIDGE_NAME" -p tcp -d "$guest_ip" --dport "$guest_port" -j ACCEPT || return 1

  # Allow return traffic explicitly.
  iptables -C FORWARD -i "$BRIDGE_NAME" -o "$UPLINK" -p tcp -s "$guest_ip" --sport "$guest_port" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1 || \
    iptables -I FORWARD 1 -i "$BRIDGE_NAME" -o "$UPLINK" -p tcp -s "$guest_ip" --sport "$guest_port" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || true

  # UFW must allow the public host port, even when it is not currently active.
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "$host_port/tcp" >/dev/null 2>&1 || true
  fi

  # Support connections originating on the host itself (host IP -> forwarded VPS).
  if [ -n "$host_ip" ]; then
    iptables -t nat -C OUTPUT -d "$host_ip" -p tcp --dport "$host_port" -j DNAT --to-destination "${guest_ip}:${guest_port}" >/dev/null 2>&1 || \
      iptables -t nat -A OUTPUT -d "$host_ip" -p tcp --dport "$host_port" -j DNAT --to-destination "${guest_ip}:${guest_port}" || true
  fi

  grep -v -E "^[[:space:]]*${host_port}[[:space:]]+${n}([[:space:]]|$)" "$PORT_DB" > "${PORT_DB}.tmp" 2>/dev/null || true
  printf "%s %s %s %s\n" "$host_port" "$n" "$guest_ip" "$guest_port" >> "${PORT_DB}.tmp"
  mv "${PORT_DB}.tmp" "$PORT_DB"

  ok "Port forwarding ready: ${host_ip:-HOST_IP}:${host_port} -> ${n}:${guest_ip}:${guest_port}/tcp"
  ok "UFW allowed: ${host_port}/tcp"
}

remove_port_forwards(){
  local n="$1"
  local guest_ip
  guest_ip="$(lxc exec "$n" -- ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
  [ -n "$guest_ip" ] || return 0
  # Host-port rules are intentionally not guessed here; they are recorded below.
  return 0
}


ensure_guest_ssh(){
  local n="$1"
  info "Ensuring SSH server is available inside $n..."
  lxc exec "$n" -- bash -lc '
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y openssh-server >/dev/null 2>&1 || exit 1
    systemctl enable ssh >/dev/null 2>&1 || true
    systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || true
    mkdir -p /run/sshd
  ' >>"$LOG" 2>&1 || {
    warn "$n SSH server could not be installed automatically. Port forwarding may work, but SSH must listen on guest port 22."
    return 1
  }
  ok "$n SSH server is listening on guest port 22."
}

create_vps(){
  local n="$1" image="$2" ram="$3" cpu="$4" disk="$5" host_port="$6"

  valid_name "$n" || { err "Invalid VPS name: $n"; return 1; }
  validate_port "$host_port" || { err "Invalid host port: $host_port (use 1-65535)."; return 1; }
  lxc info "$n" >/dev/null 2>&1 && { warn "$n already exists."; return 1; }

  ensure_image "$image"

  info "Creating $n: $ram RAM / $cpu CPU / $disk root disk"
  if ! lxc init "$image" "$n" --storage "$POOL" >>"$LOG" 2>&1; then
    err "Could not create $n."
    return 1
  fi

  # Configure actual resource limits before start.
  lxc config set "$n" limits.memory "$ram" >>"$LOG" 2>&1 || true
  lxc config set "$n" limits.cpu "$cpu" >>"$LOG" 2>&1 || true

  # Real bounded root volume, not host filesystem presentation.
  if ! lxc config device set "$n" root size "$disk" >>"$LOG" 2>&1; then
    # If the root device is not attached, add it safely.
    if ! lxc config device show "$n" 2>/dev/null | grep -q '^root:'; then
      lxc config device add "$n" root disk path=/ pool="$POOL" size="$disk" >>"$LOG" 2>&1 || {
        err "Could not configure $disk root disk for $n."
        lxc delete "$n" --force >>"$LOG" 2>&1 || true
        return 1
      }
    else
      err "Could not set root disk size for $n."
      lxc delete "$n" --force >>"$LOG" 2>&1 || true
      return 1
    fi
  fi

  configure_nic "$n" || {
    lxc delete "$n" --force >>"$LOG" 2>&1 || true
    return 1
  }

  lxc start "$n" >>"$LOG" 2>&1 || {
    err "Could not start $n."
    lxc delete "$n" --force >>"$LOG" 2>&1 || true
    return 1
  }

  repair_network "$n" || true
  guest_apt_repair "$n" || warn "$n APT initial repair did not complete; run Repair from the menu."
  ensure_guest_ssh "$n" || true
  ensure_port_forward "$n" "$host_port" || warn "Port forwarding setup failed for $n."

  ok "VPS $n created. Connect to HOST_IP:${host_port} (TCP/SSH)."
}

delete_vps(){
  local n="$1"
  [ -n "$n" ] || return
  lxc info "$n" >/dev/null 2>&1 || { warn "$n does not exist."; return; }

  local net=""
  net="$(lxc config device get "$n" eth0 network 2>/dev/null || true)"

  info "Deleting VPS $n..."
  lxc delete "$n" --force >>"$LOG" 2>&1 || {
    err "Could not delete $n."
    return 1
  }
  ok "VPS $n deleted."

  # Only delete bridges managed by this script and only when unused.
  if [[ "$net" =~ ^${BR_PREFIX}[0-9]+$ ]] && network_exists "$net"; then
    if ! lxc network show "$net" 2>/dev/null | grep -q 'used_by:.*\S'; then
      lxc network delete "$net" >>"$LOG" 2>&1 || true
      ok "Unused managed network $net deleted."
    fi
  fi
}

repair_existing_vps(){
  local n state net
  while read -r n; do
    [ -n "$n" ] || continue
    state="$(lxc list "$n" -c s --format csv 2>/dev/null || true)"
    [ "$state" = "RUNNING" ] || continue
    net="$(lxc config device get "$n" eth0 network 2>/dev/null || true)"
    if [[ "$net" =~ ^${BR_PREFIX}[0-9]+$ ]] || [ -z "$net" ]; then
      info "Checking existing VPS network: $n"
      repair_network "$n" || warn "$n network still needs manual repair."
    fi
  done < <(lxc list -c n --format csv 2>/dev/null)
}

repair_vps(){
  local n="$1"
  lxc info "$n" >/dev/null 2>&1 || { err "$n does not exist."; return 1; }

  # Recover the network currently configured on this VPS; if absent, use the
  # current manager network or create a new one.
  local net
  net="$(lxc config device get "$n" eth0 network 2>/dev/null || true)"
  if [ -n "$net" ] && network_exists "$net"; then
    BRIDGE_NAME="$net"
    detect_uplink
  else
    ensure_network || return 1
  fi

  ensure_network_stack
  configure_nic "$n" || true
  lxc start "$n" >>"$LOG" 2>&1 || true
  guest_dns_repair "$n"
  repair_network "$n" || true
  local saved_port=""
  saved_port="$(awk -v n="$n" '$2 == n {print $1; exit}' "$PORT_DB" 2>/dev/null || true)"
  if [ -z "$saved_port" ]; then
    read -r -p "Host port for SSH [2201]: " saved_port
    saved_port="${saved_port:-2201}"
  fi
  if validate_port "$saved_port"; then
    ensure_guest_ssh "$n" || true
    ensure_port_forward "$n" "$saved_port" || warn "Port forwarding repair failed for $n."
  else
    warn "Invalid host port: $saved_port; skipping port-forward repair."
  fi
  if guest_apt_repair "$n"; then
    ok "$n APT update repair succeeded."
  else
    warn "$n APT still cannot update; diagnostics will show the cause."
  fi
}

diagnostics(){
  detect_uplink || true
  echo
  echo "============================================================"
  echo " NOKVMVECTAR DIAGNOSTICS $VERSION"
  echo "============================================================"
  echo "Host uplink : ${UPLINK:-unknown}"
  echo "Storage pool:"
  lxc storage list || true
  echo
  echo "Networks:"
  lxc network list || true
  echo
  echo "Instances:"
  lxc list || true
  echo
  echo "Default profile:"
  lxc profile show default || true
  echo
  echo "IPv4 forwarding:"
  sysctl net.ipv4.ip_forward 2>/dev/null || true
  echo
  echo "Host APT policy:"
  echo "This manager uses Acquire::ForceIPv4=true for host APT."
  echo
  echo "Default route:"
  ip -4 route show default || true
  echo
  echo "NAT rules:"
  iptables -t nat -S POSTROUTING 2>/dev/null | grep -E '10\.77\.' || true
  echo
  echo "Port forwards:"
  cat "$PORT_DB" 2>/dev/null || true
  echo
  echo "Recent manager log:"
  tail -60 "$LOG" || true
  echo
}

status(){
  echo
  echo "============================================================"
  echo " NOKVMVECTAR VPS MANAGER $VERSION"
  echo "============================================================"
  lxc list || true
  echo
  printf '%-18s %-10s %-16s %-10s %-6s %-10s\n' NAME STATE IPV4 RAM CPU DISK
  printf '%-18s %-10s %-16s %-10s %-6s %-10s\n' "------------------" "----------" "----------------" "----------" "------" "----------"
  while read -r n; do
    [ -n "$n" ] || continue
    local state ip ram cpu disk
    state="$(lxc list "$n" -c s --format csv 2>/dev/null || echo unknown)"
    ip="$(lxc list "$n" -c 4 --format csv 2>/dev/null | head -1)"
    if [ -z "$ip" ]; then
      ip="$(lxc exec "$n" -- ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
    fi
    ram="$(lxc config get "$n" limits.memory 2>/dev/null || true)"
    cpu="$(lxc config get "$n" limits.cpu 2>/dev/null || true)"
    disk="$(lxc config device get "$n" root size 2>/dev/null || true)"
    printf '%-18s %-10s %-16s %-10s %-6s %-10s\n' "$n" "$state" "${ip:-pending}" "${ram:--}" "${cpu:--}" "${disk:--}"
  done < <(lxc list -c n --format csv 2>/dev/null)
}

menu(){
  while true; do
    status
    echo
    echo "  1) Create VPS"
    echo "  2) Delete VPS"
    echo "  3) Repair VPS"
    echo "  4) VPS shell"
    echo "  5) Show diagnostics"
    echo "  6) Exit"
    read -r -p "Select [6]: " choice
    case "${choice:-6}" in
      1)
        read -r -p "Name [vps1]: " n; n="${n:-vps1}"
        read -r -p "Image [ubuntu:24.04]: " image; image="${image:-ubuntu:24.04}"
        read -r -p "RAM [2GiB]: " ram; ram="${ram:-2GiB}"
        read -r -p "CPU [1]: " cpu; cpu="${cpu:-1}"
        read -r -p "Disk [5GiB]: " disk; disk="${disk:-5GiB}"
        read -r -p "Host port for SSH [2201]: " host_port; host_port="${host_port:-2201}"
        create_vps "$n" "$image" "$ram" "$cpu" "$disk" "$host_port"
        read -r -p "Press Enter to continue..." _
        ;;
      2)
        read -r -p "VPS name: " n
        delete_vps "$n"
        read -r -p "Press Enter to continue..." _
        ;;
      3)
        read -r -p "VPS name: " n
        repair_vps "$n"
        read -r -p "Press Enter to continue..." _
        ;;
      4)
        read -r -p "VPS name: " n
        if lxc info "$n" >/dev/null 2>&1; then
          lxc start "$n" >/dev/null 2>&1 || true
          lxc exec "$n" -- bash
        else
          err "VPS not found: $n"
        fi
        ;;
      5)
        diagnostics
        read -r -p "Press Enter to continue..." _
        ;;
      6) exit 0 ;;
      *) warn "Invalid choice." ;;
    esac
  done
}

main(){
  need_root
  clear 2>/dev/null || true
  echo "============================================================"
  echo "        NOKVMVECTAR VPS MANAGER ${VERSION}"
  echo "============================================================"

  host_apt
  install_lxd
  ensure_lxd_init
  ensure_storage || die "Storage initialization failed."
  ensure_network || die "Network initialization failed."
  ensure_network_stack
  repair_existing_vps

  menu
}

main "$@"
