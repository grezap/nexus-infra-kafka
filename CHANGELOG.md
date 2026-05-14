# Changelog

All notable changes to `nexus-infra-kafka` are documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the repo adheres to [Semantic Versioning](https://semver.org/).

This repo implements **Phase 0.H** (Kafka ecosystem) of the NexusPlatform
blueprint — `nexus-platform-plan/MASTER-PLAN.md` line 160.

## [Unreleased]

### 0.H.1 — Repo scaffold + kafka-node Packer template (in progress)

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
- Reused verbatim from `nexus-infra-swarm-nomad`: the four `nexus_*`
  shared Ansible roles, `terraform/modules/vm`, `scripts/configure-vm-nic.ps1`,
  `ansible.cfg`, the Debian 13 preseed + `chrony.conf` + `nftables.conf`.

#### Still to land in 0.H.1

- `terraform/envs/kafka/` — 6 broker `module.vm` blocks + per-cluster
  toggles.
- `role-overlay-nftables-backplane.tf` — VMnet10 accept rules for the
  Kafka ports.
- `role-overlay-kraft-format.tf` — per-cluster cluster-UUID generation +
  `kafka-storage format`.
- `role-overlay-broker-config.tf` — render `server.properties`, start
  `kafka.service`.
- `scripts/kafka.ps1` + `scripts/smoke-0.H.1.ps1`.
- `kafka-node` Packer build + `kafka-east` / `kafka-west` Terraform apply.
