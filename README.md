# nexus-infra-kafka

Tier-3 of the **NexusPlatform 66-VM lab** — the Kafka ecosystem. Two
KRaft clusters (East primary + West DR), Schema Registry, Kafka Connect +
Debezium, ksqlDB, MirrorMaker 2, and a REST Proxy, all on Debian 13 VMs
under VMware Workstation Pro.

> **Canon:** This repo implements [Phase 0.H](https://github.com/grezap/nexus-platform-plan/blob/main/MASTER-PLAN.md) (line 160) of the NexusPlatform blueprint. VM inventory is `nexus-platform-plan/docs/infra/vms.yaml` lines 84-112. Read [`nexus-platform-plan`](https://github.com/grezap/nexus-platform-plan) for the architectural source of truth.
>
> **➜ Want to rebuild the Kafka tier from zero?** [`docs/handbook.md`](./docs/handbook.md) is the operator canon — §0 prerequisites (foundation + security tiers alive, gateway dnsmasq has the 15 Kafka MAC reservations, security env has written the 15 AppRole sidecars), §1.1 Packer build, §1.2 cross-env operator order (security FIRST, then kafka — hard ordering), §1.3 apply with numbered apply-flow breakdown, §1.4 verify, §1.5 selective-ops `-Vars` examples, §1.6 destroy, §3.1 cold-rebuild canon (proven 2026-05-15), §3.7 apply-time VM-layer recovery. Cross-tier index: [`nexus-platform-plan/docs/setup-guides.md`](https://github.com/grezap/nexus-platform-plan/blob/main/docs/setup-guides.md).
>
> **Phase exit gate:** produce a record to a topic on `kafka-east` → it appears on the mirrored topic on `kafka-west` via MirrorMaker 2.

## The 15 VMs (`03-kafka` tier)

| Cluster | VMs | Role |
|---|---|---|
| `kafka-east` | kafka-east-1/2/3 | KRaft broker + controller (primary) |
| `kafka-west` | kafka-west-1/2/3 | KRaft broker + controller (DR) |
| `kafka-ecosystem` | schema-registry-1/2 | Confluent Schema Registry primary/replica |
| `kafka-ecosystem` | kafka-connect-1/2 | Kafka Connect distributed + Debezium |
| `kafka-ecosystem` | ksqldb-1/2 | ksqlDB primary/replica |
| `kafka-ecosystem` | mm2-1/2 | MirrorMaker 2 (east→west / west→east) |
| `kafka-ecosystem` | kafka-rest-1 | Confluent REST Proxy |

Dual-NIC: VMnet11 (`192.168.70.0/24`) = mgmt + app; VMnet10
(`192.168.10.0/24`) = cluster backplane (KRaft controller quorum,
inter-broker replication, MM2 cross-cluster traffic).

## Software stack

- **Brokers:** Apache Kafka 3.8.1 (KRaft, combined broker+controller),
  matching the `local-data-stack` reference (`apache/kafka:3.8.1`).
- **Ecosystem:** Confluent Community 7.7.1 (Schema Registry, Connect,
  ksqlDB, REST Proxy).
- **MirrorMaker 2:** `connect-mirror-maker` — ships inside Apache Kafka.
- **Runtime:** Temurin JDK 21 (LTS) on Debian 13.

## Layout

```
packer/
  _shared/ansible/roles/       # nexus_{identity,network,firewall,observability}
  kafka-node/
    kafka-node.pkr.hcl         # one parameterised template -> all 15 VMs
    variables.pkr.hcl
    ansible/roles/kafka_node/  # JDK + Kafka + Confluent + firstboot + units
terraform/
  modules/vm/                  # generic dual-NIC VMware clone module
  envs/kafka/                  # 15 module.vm blocks + role-overlay-*.tf
scripts/
  kafka.ps1                    # pwsh operator wrapper (apply/destroy/smoke/cycle)
  smoke-0.H.*.ps1              # chained verification gates
docs/
  handbook.md                  # walkthrough + cold-rebuild canon + runbooks
  verification/                # per-sub-phase verification records
```

## Build-time vs clone-time vs first-boot

- **Build-time** (`packer build`): single NAT NIC for fetch; JDK + Kafka +
  Confluent downloaded + verified + installed; all role systemd units
  delivered **disabled**.
- **Clone-time** (`terraform apply`): `modules/vm` writes the dual-NIC
  config (VMnet11 + VMnet10) onto each clone.
- **First-boot** (`kafka-node-firstboot.service`): MAC-OUI NIC discovery,
  hostname + `/etc/hosts`, VMnet10 backplane IP, and
  `/etc/nexus-kafka/node-identity.env` for the Terraform role-overlays.
  It does **not** touch any Kafka service — KRaft formatting needs a
  per-cluster UUID generated at Terraform time.
- **Bring-up** (`role-overlay-*.tf`): KRaft format, broker config, TLS,
  and the ecosystem services.

## Sub-phases

| Sub-phase | Scope |
|---|---|
| 0.H.1 | Repo scaffold + `kafka-node` Packer template + both KRaft clusters bring-up (PLAINTEXT on VMnet10) |
| 0.H.2 | Vault PKI `kafka-broker` role + per-node Vault Agents + broker mTLS |
| 0.H.3 | Schema Registry ×2 + REST Proxy |
| 0.H.4 | Kafka Connect ×2 + Debezium + ksqlDB ×2 |
| 0.H.5 | MirrorMaker 2 ×2 + the phase exit-gate test |
| 0.H.6 | Close-out canon batch + cold-rebuild proof; tag `v0.1.0` |

## Status

**Phase 0.H complete** — `v0.1.0` tagged 2026-05-15. All 6 sub-phases
closed; all 15 `03-kafka` tier VMs up; all five sub-phase smoke gates ALL
GREEN; the tier is proven cold-rebuildable (`destroy` → `security apply` →
`apply` → smoke, no operator hot-state). Operator handbook:
[`docs/handbook.md`](./docs/handbook.md).

- **0.H.6 closed** (2026-05-15) — close-out canon batch (MASTER-PLAN
  sub-phase rows + `vms.yaml` ratification + `glossary.md` + ADRs
  0020-0023 + this repo's `docs/handbook.md`) + cold-rebuild proof; tagged
  `v0.1.0`.
- **0.H.5 closed** (2026-05-14) — the **MirrorMaker 2 cross-cluster DR
  pair** (`mm2-1` east→west, `mm2-2` west→east), each running Apache
  Kafka's `connect-mirror-maker` in dedicated mode, talking to **both**
  KRaft clusters over mutual TLS. This sub-phase clears the **Phase 0.H
  exit gate** — a fresh record produced to `kafka-east` appears on the
  mirrored topic on `kafka-west`, and the reverse. `smoke-0.H.5.ps1` ALL
  GREEN (38 checks).
  [`docs/verification/0.H.5-mirrormaker2.md`](./docs/verification/0.H.5-mirrormaker2.md).
- **0.H.4 closed** (2026-05-14) — the Kafka Connect distributed cluster
  (+ Debezium plugins) + the ksqlDB cluster;
  [`docs/verification/0.H.4-connect-ksqldb.md`](./docs/verification/0.H.4-connect-ksqldb.md).
- **0.H.3 closed** (2026-05-14) — the Schema Registry HA pair + Confluent
  REST Proxy;
  [`docs/verification/0.H.3-schema-registry-rest.md`](./docs/verification/0.H.3-schema-registry-rest.md).
- **0.H.2 closed** (2026-05-14) — both KRaft clusters flipped to **mutual
  TLS**;
  [`docs/verification/0.H.2-broker-mtls.md`](./docs/verification/0.H.2-broker-mtls.md).
- **0.H.1 closed** (2026-05-14) — both 3-node KRaft clusters brought up on
  the VMnet10 backplane;
  [`docs/verification/0.H.1-kraft-bringup.md`](./docs/verification/0.H.1-kraft-bringup.md).

## License

[MIT](./LICENSE).
