#!/bin/bash
# kafka-node-firstboot.sh — runs once at first boot per kafka-node clone.
#
# Mirrors swarm-node-firstboot.sh (nexus-infra-swarm-nomad), adapted for the
# 15-VM 03-kafka tier. Same NIC discrimination by MAC OUI byte 5 (0x00
# primary VMnet11, 0x01 secondary VMnet10), same /etc/hosts pattern, same
# hostname renaming, same VMnet10 backplane .link MAC-match.
#
# KEY DIFFERENCE from swarm-node-firstboot.sh: this script does NOT render
# any Kafka service config and does NOT enable any role service. KRaft
# storage formatting needs a per-cluster cluster-UUID that is generated at
# Terraform time (role-overlay-kraft-format.tf). firstboot's job is purely
# identity: NIC + hostname + /etc/hosts + VMnet10 backplane + writing
# /etc/nexus-kafka/node-identity.env for the Terraform role-overlays to source.
#
# Idempotent: marker file at /var/lib/kafka-node-firstboot-done short-circuits
# re-runs. Removing the marker forces re-run on next boot.

set -euo pipefail

MARKER=/var/lib/kafka-node-firstboot-done
IDENTITY_DIR=/etc/nexus-kafka
IDENTITY_FILE="$IDENTITY_DIR/node-identity.env"
LOG_PREFIX="[kafka-node-firstboot]"

if [ -f "$MARKER" ]; then
  echo "$LOG_PREFIX already done, skipping (remove $MARKER to force re-run)"
  exit 0
fi

# ─── 1. Discover both NICs by MAC OUI pattern ──────────────────────────────
PRIMARY_IF=""
PRIMARY_MAC=""
SECONDARY_IF=""
SECONDARY_MAC=""
for ifdir in /sys/class/net/*; do
  ifname=$(basename "$ifdir")
  [ "$ifname" = "lo" ] && continue
  [ -e "$ifdir/device" ] || continue
  ifmac=$(cat "$ifdir/address" 2>/dev/null || true)
  case "$ifmac" in
    00:50:56:*:00:*) PRIMARY_IF=$ifname; PRIMARY_MAC=$ifmac ;;
    00:50:56:*:01:*) SECONDARY_IF=$ifname; SECONDARY_MAC=$ifmac ;;
  esac
done

if [ -z "$PRIMARY_IF" ]; then
  echo "$LOG_PREFIX ERROR: no primary NIC (MAC pattern 00:50:56:*:00:*) found" >&2
  ip -br link >&2
  exit 1
fi
echo "$LOG_PREFIX detected primary NIC: $PRIMARY_IF (MAC $PRIMARY_MAC)"
if [ -n "$SECONDARY_IF" ]; then
  echo "$LOG_PREFIX detected secondary NIC: $SECONDARY_IF (MAC $SECONDARY_MAC)"
else
  echo "$LOG_PREFIX ERROR: no secondary NIC (MAC pattern 00:50:56:*:01:*) found -- kafka requires the VMnet10 backplane" >&2
  ip -br link >&2
  exit 1
fi

# ─── 2. Ensure nic0 == primary, nic1 == secondary ──────────────────────────
NEED_NETWORKD_RESTART=0

if [ "$PRIMARY_IF" != "nic0" ]; then
  echo "$LOG_PREFIX nic0 swap needed: $PRIMARY_IF should be nic0"
  if [ -e /sys/class/net/nic0 ]; then
    CURRENT_NIC0_MAC=$(cat /sys/class/net/nic0/address 2>/dev/null || true)
    echo "$LOG_PREFIX moving current nic0 (MAC $CURRENT_NIC0_MAC) aside as nic-old"
    ip link set nic0 down 2>/dev/null || true
    ip link set nic0 name nic-old
    if [ "$CURRENT_NIC0_MAC" = "$SECONDARY_MAC" ]; then
      SECONDARY_IF="nic-old"
    fi
  fi
  ip link set "$PRIMARY_IF" down 2>/dev/null || true
  ip link set "$PRIMARY_IF" name nic0
  ip link set nic0 up
  PRIMARY_IF="nic0"
  NEED_NETWORKD_RESTART=1
  echo "$LOG_PREFIX nic0 now has primary MAC $PRIMARY_MAC"
fi

if [ "$SECONDARY_IF" != "nic1" ]; then
  echo "$LOG_PREFIX renaming secondary $SECONDARY_IF -> nic1"
  ip link set "$SECONDARY_IF" down 2>/dev/null || true
  ip link set "$SECONDARY_IF" name nic1
  SECONDARY_IF="nic1"
  NEED_NETWORKD_RESTART=1
fi

if [ "$NEED_NETWORKD_RESTART" = "1" ]; then
  echo "$LOG_PREFIX restarting systemd-networkd after NIC rename(s)"
  systemctl restart systemd-networkd
  sleep 3
fi

# ─── 3. Wait for nic0 DHCP ─────────────────────────────────────────────────
VMNET11_IP=""
for i in 1 2 3 4 5 6 7 8 9 10; do
  VMNET11_IP=$(ip -4 -o addr show nic0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
  [ -n "$VMNET11_IP" ] && break
  echo "$LOG_PREFIX waiting for nic0 IPv4 (attempt $i/10)..."
  sleep 5
done

if [ -z "$VMNET11_IP" ]; then
  echo "$LOG_PREFIX ERROR: nic0 has no IPv4 address after 50s -- DHCP failed?" >&2
  ip -br addr show nic0 >&2 || true
  systemctl status systemd-networkd --no-pager >&2 || true
  exit 1
fi
echo "$LOG_PREFIX nic0 (VMnet11) IP: $VMNET11_IP"

# ─── 4. Map IP -> hostname + VMnet10 IP + role + cluster + KRaft node.id ────
# Canon: nexus-platform-plan/docs/infra/vms.yaml lines 84-112.
# NOTE: ksqldb-2's vmnet11 is .98 here -- vms.yaml line 109 has a typo (.99);
# fixed in vms.yaml as part of the 0.H.6 close-out canon batch.
HOSTNAME=""; VMNET10_IP=""; ROLE=""; CLUSTER=""; NODE_ID=""
case "$VMNET11_IP" in
  192.168.70.21) HOSTNAME=kafka-east-1;      VMNET10_IP=192.168.10.21; ROLE=broker;          CLUSTER=east; NODE_ID=1 ;;
  192.168.70.22) HOSTNAME=kafka-east-2;      VMNET10_IP=192.168.10.22; ROLE=broker;          CLUSTER=east; NODE_ID=2 ;;
  192.168.70.23) HOSTNAME=kafka-east-3;      VMNET10_IP=192.168.10.23; ROLE=broker;          CLUSTER=east; NODE_ID=3 ;;
  192.168.70.24) HOSTNAME=kafka-west-1;      VMNET10_IP=192.168.10.24; ROLE=broker;          CLUSTER=west; NODE_ID=1 ;;
  192.168.70.25) HOSTNAME=kafka-west-2;      VMNET10_IP=192.168.10.25; ROLE=broker;          CLUSTER=west; NODE_ID=2 ;;
  192.168.70.26) HOSTNAME=kafka-west-3;      VMNET10_IP=192.168.10.26; ROLE=broker;          CLUSTER=west; NODE_ID=3 ;;
  192.168.70.91) HOSTNAME=schema-registry-1; VMNET10_IP=192.168.10.91; ROLE=schema-registry; CLUSTER=east; NODE_ID= ;;
  192.168.70.92) HOSTNAME=schema-registry-2; VMNET10_IP=192.168.10.92; ROLE=schema-registry; CLUSTER=east; NODE_ID= ;;
  192.168.70.95) HOSTNAME=kafka-connect-1;   VMNET10_IP=192.168.10.95; ROLE=connect;         CLUSTER=east; NODE_ID= ;;
  192.168.70.96) HOSTNAME=kafka-connect-2;   VMNET10_IP=192.168.10.96; ROLE=connect;         CLUSTER=east; NODE_ID= ;;
  192.168.70.97) HOSTNAME=ksqldb-1;          VMNET10_IP=192.168.10.97; ROLE=ksqldb;          CLUSTER=east; NODE_ID= ;;
  192.168.70.98) HOSTNAME=ksqldb-2;          VMNET10_IP=192.168.10.98; ROLE=ksqldb;          CLUSTER=east; NODE_ID= ;;
  192.168.70.85) HOSTNAME=mm2-1;             VMNET10_IP=192.168.10.85; ROLE=mm2;             CLUSTER=;     NODE_ID= ;;
  192.168.70.86) HOSTNAME=mm2-2;             VMNET10_IP=192.168.10.86; ROLE=mm2;             CLUSTER=;     NODE_ID= ;;
  192.168.70.88) HOSTNAME=kafka-rest-1;      VMNET10_IP=192.168.10.88; ROLE=rest;            CLUSTER=east; NODE_ID= ;;
  *)
    echo "$LOG_PREFIX ERROR: unknown VMnet11 IP '$VMNET11_IP' (expected a 03-kafka tier IP)" >&2
    exit 1
    ;;
esac
echo "$LOG_PREFIX mapped: hostname=$HOSTNAME role=$ROLE cluster=${CLUSTER:-n/a} node_id=${NODE_ID:-n/a} VMnet10=$VMNET10_IP/24"

# ─── 5. Hostname + /etc/hosts ──────────────────────────────────────────────
CURRENT_HOSTNAME=$(cat /etc/hostname 2>/dev/null || echo '')
if [ "$CURRENT_HOSTNAME" != "$HOSTNAME" ]; then
  echo "$LOG_PREFIX renaming hostname: '$CURRENT_HOSTNAME' -> '$HOSTNAME'"
  hostnamectl set-hostname "$HOSTNAME"
fi

# Per memory/feedback_smoke_gate_probe_robustness.md: every Linux first-boot
# must write /etc/hosts entry for the new hostname or sudo emits "unable to
# resolve host" stderr noise on every invocation.
HOSTS_LINE="127.0.1.1 $HOSTNAME.nexus.lab $HOSTNAME"
sed -i '/^127\.0\.1\.1\s/d' /etc/hosts
echo "$HOSTS_LINE" >> /etc/hosts
echo "$LOG_PREFIX wrote /etc/hosts entry: $HOSTS_LINE"

# ─── 6. VMnet10 backplane config (.link MAC-match + .network static) ───────
echo "$LOG_PREFIX configuring nic1 (VMnet10 backplane)"
cat > /etc/systemd/network/20-nic1.link <<EOF
[Match]
MACAddress=$SECONDARY_MAC

[Link]
Name=nic1
EOF
cat > /etc/systemd/network/20-nic1.network <<EOF
[Match]
Name=nic1

[Network]
Address=$VMNET10_IP/24
LinkLocalAddressing=no
DHCP=no
IPv6AcceptRA=no
EOF

# Per memory/feedback_systemd_link_precedence_multi_nic.md -- rewrite the
# baseline 10-nic0.link to MAC-match the primary NIC instead of the greedy
# OriginalName=en* match. Without this, on every reboot AFTER firstboot the
# udev lex-order match leaves nic1 on its kernel-default name, the static
# .network never applies, the backplane has no IP, and KRaft controller
# quorum + inter-broker replication go unreachable on any restart.
if [ -f /etc/systemd/network/10-nic0.link ] && ! grep -q "^MACAddress=$PRIMARY_MAC" /etc/systemd/network/10-nic0.link; then
  echo "$LOG_PREFIX rewriting 10-nic0.link to MAC-match primary"
  cat > /etc/systemd/network/10-nic0.link <<EOF
[Match]
MACAddress=$PRIMARY_MAC

[Link]
Name=nic0
EOF
  udevadm control --reload 2>/dev/null || true
fi

ip link set nic1 up 2>/dev/null || true
if ! ip -4 -o addr show nic1 2>/dev/null | grep -q "$VMNET10_IP"; then
  ip addr add "$VMNET10_IP/24" dev nic1 || true
fi
systemctl restart systemd-networkd
sleep 3

# ─── 7. Write the node-identity env file for the Terraform role-overlays ───
# The overlays (kraft-format, broker-config, schema-registry, connect,
# ksqldb, mm2, rest) source this to learn what this VM is without re-deriving
# it. config-dir is root:kafka 0750; the env file is 0640 so kafka-group
# services can read it.
mkdir -p "$IDENTITY_DIR"
cat > "$IDENTITY_FILE" <<EOF
# Generated by kafka-node-firstboot.sh -- do not edit by hand.
NEXUS_HOSTNAME=$HOSTNAME
NEXUS_ROLE=$ROLE
NEXUS_CLUSTER=$CLUSTER
NEXUS_NODE_ID=$NODE_ID
NEXUS_VMNET11_IP=$VMNET11_IP
NEXUS_VMNET10_IP=$VMNET10_IP
EOF
chown root:kafka "$IDENTITY_FILE"
chmod 640 "$IDENTITY_FILE"
echo "$LOG_PREFIX wrote $IDENTITY_FILE"

# ─── 8. Mark complete ──────────────────────────────────────────────────────
# No Kafka service is enabled here -- the Terraform role-overlays render
# config (which needs a Terraform-time cluster UUID) then enable exactly
# one role service per node.
touch "$MARKER"
echo "$LOG_PREFIX done -- $HOSTNAME ready ($ROLE role on VMnet11 $VMNET11_IP / VMnet10 $VMNET10_IP)"
