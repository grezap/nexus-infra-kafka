# nexus-infra-kafka

Tier-3 of the **NexusPlatform 66-VM lab** — the Kafka ecosystem. Two
KRaft clusters (East primary + West DR), Schema Registry, Kafka Connect +
Debezium, ksqlDB, MirrorMaker 2, and a REST Proxy, all on Debian 13 VMs
under VMware Workstation Pro.

> **Canon:** This repo implements [Phase 0.H](https://github.com/grezap/nexus-platform-plan/blob/main/MASTER-PLAN.md) (line 160) of the NexusPlatform blueprint. VM inventory is `nexus-platform-plan/docs/infra/vms.yaml` lines 84-112. Read [`nexus-platform-plan`](https://github.com/grezap/nexus-platform-plan) for the architectural source of truth.
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

**0.H.3 closed** (2026-05-14) — the first three ecosystem nodes are live:
the **Schema Registry HA pair** (`schema-registry-1/2`) and the
**Confluent REST Proxy** (`kafka-rest-1`). Each holds a per-node Vault-PKI
keystore, connects to the `kafka-east` brokers over mutual TLS, and serves
its own HTTPS listener. Verified: an HA schema register→fetch round-trip
across the pair + a REST produce/consume round-trip. Smoke gate
`scripts/smoke-0.H.3.ps1` is ALL GREEN (37 checks). Proof:
[`docs/verification/0.H.3-schema-registry-rest.md`](./docs/verification/0.H.3-schema-registry-rest.md).
Next: **0.H.4** — Kafka Connect ×2 + Debezium + ksqlDB ×2.

Earlier:
- **0.H.2 closed** (2026-05-14) — both KRaft clusters flipped to **mutual
  TLS** (per-node Vault PKI leaf certs, `ssl.client.auth=required`);
  [`docs/verification/0.H.2-broker-mtls.md`](./docs/verification/0.H.2-broker-mtls.md).
- **0.H.1 closed** (2026-05-14) — both 3-node KRaft clusters brought up on
  the PLAINTEXT VMnet10 backplane;
  [`docs/verification/0.H.1-kraft-bringup.md`](./docs/verification/0.H.1-kraft-bringup.md).

## License

[MIT](./LICENSE).
