# Changelog

All notable changes to `nexus-infra-kafka` are documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the repo adheres to [Semantic Versioning](https://semver.org/).

This repo implements **Phase 0.H** (Kafka ecosystem) of the NexusPlatform
blueprint — `nexus-platform-plan/MASTER-PLAN.md` line 160.

## [Unreleased]

## 0.H.1 — Repo scaffold + kafka-node template + KRaft bring-up — 2026-05-14

Two 3-node KRaft clusters (`kafka-east` primary + `kafka-west` DR) are
live on PLAINTEXT VMnet10 backplanes, each with an elected controller
quorum and a verified RF=3 produce/consume round-trip. Smoke gate
`scripts/smoke-0.H.1.ps1` is ALL GREEN (38 `[OK]` / 0 `[FAIL]`).
Verification: `docs/verification/0.H.1-kraft-bringup.md`.

### Added

- **New repo** `grezap/nexus-infra-kafka`, structurally mirroring
  `nexus-infra-swarm-nomad` (per master plan §7.1 — one `nexus-infra-*`
  repo per lab tier).
- **`kafka-node` Packer template** — one parameterised Debian 13 template
  for all 15 VMs of the `03-kafka` tier. Bakes Temurin JDK 21, Apache
  Kafka 3.8.1 (brokers + `connect-mirror-maker`), and Confluent Community
  7.7.1 (Schema Registry / Connect / ksqlDB / REST Proxy). All six role
  systemd units delivered **disabled** — the Terraform role-overlays
  enable exactly one per node.
- **`kafka_node` Ansible role** — JDK via the Adoptium apt repo; Kafka +
  Confluent via verified tarball downloads; `kafka` system account;
  `/etc/nexus-kafka/` config dir (root:kafka 0750); `kafka-node-firstboot.sh`.
- **`kafka-node-firstboot.sh`** — MAC-OUI NIC discovery, hostname +
  `/etc/hosts`, VMnet10 backplane `.link` MAC-match + static `.network`,
  and `/etc/nexus-kafka/node-identity.env` (role / cluster / KRaft node.id
  / IPs) for the Terraform role-overlays to source. Adapts the
  `swarm-node-firstboot.sh` pattern; unlike swarm-node it enables **no**
  role service (KRaft formatting needs a Terraform-time cluster UUID).
- **`terraform/envs/kafka/`** — 6 broker `module.vm` blocks (kafka-east-1/2/3,
  kafka-west-1/2/3) gated by `enable_kafka_cluster` / `enable_kafka_east` /
  `enable_kafka_west` / per-VM toggles; 12 broker MAC vars; outputs +
  operator `next_step` crib.
- **`role-overlay-nftables-backplane.tf`** — pushes the kafka-correct
  `nftables.conf` (whole-segment VMnet10 trust + operator ports
  9092/8081/8082/8083/8088) to all brokers via SSH stdin + `nft -f`;
  `filesha256` trigger.
- **`role-overlay-broker-config.tf`** — renders `/etc/nexus-kafka/server.properties`
  per broker (`process.roles=broker,controller`, `controller.quorum.voters`,
  PLAINTEXT + CONTROLLER listeners, RF=3 defaults); enabled-broker set
  passed into PowerShell via `jsonencode` + `ConvertFrom-Json`.
- **`role-overlay-kraft-format.tf`** — `kafka_kraft_format` (per-cluster
  cluster-UUID recover-or-mint + `kafka-storage format --ignore-formatted`)
  and `kafka_broker_start_verify` (big-bang `kafka.service` enable+start,
  wait for quorum, RF=3 round-trip).
- **`scripts/kafka.ps1`** — pwsh operator wrapper (apply / destroy / smoke /
  cycle / plan / validate), mirrors `swarm.ps1`.
- **`scripts/smoke-0.H.1.ps1`** — chained 5-section verification gate.
- **`nexus-infra-vmware`** foundation env gains
  `role-overlay-gateway-kafka-reservations.tf` — 15 dnsmasq `dhcp-host`
  reservations pinning the kafka-tier MACs to canonical VMnet11 IPs +
  the `enable_kafka_dhcp_reservations` toggle + 15 `mac_kafka_*` vars.
- Reused verbatim from `nexus-infra-swarm-nomad`: the four `nexus_*`
  shared Ansible roles, `terraform/modules/vm`, `scripts/configure-vm-nic.ps1`,
  `ansible.cfg`, the Debian 13 preseed + `chrony.conf` + `nftables.conf`.

### Fixed

- **Apache Kafka sha512 verification** — the `.tgz.sha512` sidecar wraps
  the hash across indented multi-line continuation lines, breaking the
  single-line `awk` parse (`no properly formatted checksum lines found`).
  Pinned the literal hash in `kafka_node_kafka_sha512` and verify via
  `echo "<hash>  <file>" | sha512sum -c -`. ([`3a59928`])

[`3a59928`]: https://github.com/grezap/nexus-infra-kafka/commit/3a59928
