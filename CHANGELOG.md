# Changelog

All notable changes to `nexus-infra-kafka` are documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the repo adheres to [Semantic Versioning](https://semver.org/).

This repo implements **Phase 0.H** (Kafka ecosystem) of the NexusPlatform
blueprint — `nexus-platform-plan/MASTER-PLAN.md` line 160.

## [Unreleased]

## 0.H.5 — MirrorMaker 2 + the Phase 0.H exit gate — 2026-05-14

The last two ecosystem nodes are live: a **MirrorMaker 2 cross-cluster DR
pair** (`mm2-1` east→west, `mm2-2` west→east). **All 15 `03-kafka` tier
VMs are now up.** This sub-phase also clears the **Phase 0.H exit gate** —
a fresh record produced to `kafka-east` appears on the mirrored topic on
`kafka-west`, and the reverse. Smoke gate `scripts/smoke-0.H.5.ps1` is
ALL GREEN (38 `[OK]` / 0 `[FAIL]`). Verification:
`docs/verification/0.H.5-mirrormaker2.md`.

### Added

- **2 ecosystem `module.vm` blocks** — `mm2-1/mm2-2` (.85/.86), with
  enable toggles + MACs matched to the foundation env's dnsmasq
  reservations.
- **`role-overlay-mm2.tf`** *(new)* — renders `mm2.properties` per node
  (MM2 dedicated mode: both clusters registered, per-cluster `<alias>.ssl.*`
  PEM mTLS, only that node's one `<src>→<dst>.enabled = true` flow) + a
  systemd drop-in appending `--clusters <target>` to the baked
  `mm2.service` `ExecStart`; sequential start; per-node verify (journal
  sanity → `heartbeats` topic on the target → the exit-gate
  produce→mirror→consume round-trip).
- **`role-overlay-ecosystem-tls.tf` / `role-overlay-kafka-vault-agents.tf`
  / `role-overlay-nftables-backplane.tf`** extended to the 2 MM2 nodes
  (`overlay_v` v4); the security env's policies + AppRoles extended to
  **15 kafka-node Vault Agents — the whole tier** (`kafka_policies_overlay_v`
  / `kafka_approles_v` v4; the MM2 policy `cluster = "both"`).
- **`scripts/smoke-0.H.5.ps1`** *(new)* — 9-section, 38-check MM2 gate
  including the bidirectional Phase 0.H exit gate; `scripts/kafka.ps1`
  default phase → `0.H.5`.

### Design

- **MM2 dedicated mode auto-cascades cluster-level TLS.** Unlike
  standalone Connect (0.H.4's pain), `<alias>.ssl.*` / `<alias>.security.protocol`
  `putIfAbsent`-cascade to the producer/consumer/admin clients — the SSL
  block is written **once per alias**. All MM2 clients are Kafka clients,
  so `ssl.keystore.type=PEM` works throughout.
- **The embedded Connect REST server is left off** (`dedicated.mode.enable.internal.rest`
  defaults to `false`) — it is only needed for multi-node MM2
  coordination, and this topology runs one node per flow. So the
  Apache-Kafka-`RestServer`-rejects-PEM problem never arises; the `.p12`
  files on the MM2 nodes are unused.
- `DefaultReplicationPolicy` — `T` on `east` mirrors to `west` as
  `east.T`; the source-alias prefix keeps the bidirectional pair
  loop-safe.

### Fixed

- **Kafka CLI probes need `sudo`** — the `kafka_mm2` overlay's first
  apply attempt failed with `java.nio.file.AccessDeniedException:
  /etc/nexus-kafka/client-ssl.properties`: that dir is `0750 root:kafka`
  and `nexusadmin` cannot traverse it to read the client config / the
  keystore. MM2 itself was healthy (the journal showed all three
  connectors committing offsets) — only the probe was blind. Every Kafka
  CLI call in `role-overlay-mm2.tf` + `smoke-0.H.5.ps1` now runs under
  `sudo` (the `/etc/consul.d/` 0750-traverse lesson, Kafka edition). Also
  hardened the topic-list match for `Out-String`'s `\r\n`
  (`(?m)^heartbeats\r?$`).

## 0.H.4 — Kafka Connect + Debezium + ksqlDB — 2026-05-14

The next four ecosystem nodes are live: a Kafka Connect distributed
cluster (`kafka-connect-1/2`, with the Debezium Postgres + SQL Server
connector plugins loaded) and a ksqlDB cluster (`ksqldb-1/2`). 13 of the
15 `03-kafka` tier VMs are now up. Smoke gate `scripts/smoke-0.H.4.ps1`
is ALL GREEN (48 `[OK]` / 0 `[FAIL]`). Verification:
`docs/verification/0.H.4-connect-ksqldb.md`.

### Added

- **4 ecosystem `module.vm` blocks** — `kafka-connect-1/2` (.95/.96) +
  `ksqldb-1/2` (.97/.98), with enable toggles + MACs matched to the
  foundation env's dnsmasq reservations.
- **`role-overlay-connect.tf`** *(new)* — installs the Debezium Postgres +
  SQL Server connector plugins (`2.7.3.Final`) under `/opt/connect-plugins`,
  renders `connect-distributed.properties` (mTLS Kafka client repeated
  under `producer.`/`consumer.`/`admin.` prefixes; KIP-208
  `listeners.https.ssl.*` PKCS#12 REST listener), sequential 2-worker
  start, verifies the Debezium classes in `/connector-plugins`.
- **`role-overlay-ksqldb.tf`** *(new)* — renders `ksqldb-server.properties`
  (all-PKCS#12 SSL, `ksql.service.id`-based clustering, SR HA pair wired,
  `ksql.heartbeat.enable=true`, `ksql.udf.enable.security.manager=false`
  for Java 21), sequential 2-node start, verifies the `/info` cluster
  agreement + a `SHOW TOPICS;` round-trip.
- **`role-overlay-ecosystem-tls.tf`** — now also emits a `keytool`-built
  PKCS#12 `keystore.p12` + `truststore.p12` beside the PEM pair
  (`ecosystem_tls_v` v3). New var `kafka_keystore_password`.
- **`nftables-backplane` / `kafka-vault-agents`** extended to the 4 nodes;
  the security env's policies + AppRoles extended to 13 kafka-node Vault
  Agents.
- **`scripts/smoke-0.H.4.ps1`** *(new)* — 8-section, 48-check ecosystem
  gate; `scripts/kafka.ps1` default phase → `0.H.4`.

### Design

- Connect's REST listener uses PKCS#12 (Apache Kafka's `RestServer`
  rejects `ssl.keystore.type=PEM`); ksqlDB uses **PKCS#12 everywhere**
  (its `KsqlRestConfig` rejects PEM, and its bare `ssl.*` is inherited by
  the embedded Kafka clients). Schema Registry / REST Proxy keep PEM
  (Confluent `rest-utils` has a PEM helper). The Kafka client connections
  are mTLS throughout.
- Connect + ksqlDB self-create their internal/command topics via
  AdminClient (works with the brokers' `auto.create.topics.enable=false`);
  the pairs start sequentially to avoid the 2-node create race.

### Fixed

- **id-trigger cascade in the 0.H.1 broker overlays** — `broker_config` /
  `kraft_format` / `broker_start_verify` chained on each other's resource
  ids, so bumping the nftables overlay re-ran the whole chain;
  `broker_config` re-rendered PLAINTEXT `server.properties` over the
  0.H.2 SSL config and `broker_start_verify`'s PLAINTEXT probe OOM'd
  against the mTLS brokers. Dropped the id-triggers; `broker_config` now
  skips any TLS-flipped broker; `broker_start_verify` is wire-mode-aware
  (`broker_config` v2, `kraft_format` v2, `kafka_tls_v` v4).
- **Connect/ksqlDB REST listeners + ksqlDB Kafka client need PKCS#12** —
  see Design. Plus: ksqlDB's UDF SecurityManager disabled for Java 21;
  `truststore.p12` built with `keytool` (the `openssl -nokeys` form
  produced an empty trust store); bare `security.protocol=SSL` for
  ksqlDB's startup AdminClient; ksqlDB cluster verified via the `/info`
  agreement (not the heartbeat-driven `/clusterStatus`, which only lists
  peers once a persistent query exists).

## 0.H.3 — Schema Registry HA pair + REST Proxy — 2026-05-14

The first three ecosystem nodes are live: the Schema Registry HA pair
(`schema-registry-1/2`) and the Confluent REST Proxy (`kafka-rest-1`).
Each holds a per-node Vault-PKI keystore, connects to the `kafka-east`
brokers over mutual TLS, and serves its own HTTPS listener. Smoke gate
`scripts/smoke-0.H.3.ps1` is ALL GREEN (37 `[OK]` / 0 `[FAIL]`).
Verification: `docs/verification/0.H.3-schema-registry-rest.md`.

### Added

- **3 ecosystem `module.vm` blocks** — `schema-registry-1/2` (.91/.92) +
  `kafka-rest-1` (.88), with enable toggles + MACs matched to the
  foundation env's dnsmasq reservations.
- **`role-overlay-ecosystem-tls.tf`** — renders the Vault-PKI PEM
  keystore/truststore + `client-ssl.properties` on every enabled
  ecosystem node (the ecosystem-node analogue of
  `role-overlay-kafka-tls.tf`'s Phase 1). Reused + extended by 0.H.4/0.H.5.
- **`role-overlay-schema-registry.tf`** — pre-creates the `_schemas`
  topic (1 partition / RF 3 / `cleanup.policy=compact` /
  `min.insync.replicas=2`), renders `schema-registry.properties` per node
  (`host.name` = VMnet10 IP), starts the Kafka-group-elected HA pair, and
  HA-verifies (register on SR-1, fetch from SR-2). mTLS to the brokers;
  HTTPS REST listener; `inter.instance.protocol=https`.
- **`role-overlay-rest.tf`** — renders `kafka-rest.properties` (mTLS to
  the brokers, HTTPS listener, `schema.registry.url` → the SR HA pair),
  starts the REST Proxy, and `/topics`-verifies.
- **`role-overlay-nftables-backplane.tf`** + **`role-overlay-kafka-vault-agents.tf`**
  extended to the 3 ecosystem nodes; the Vault Agent overlay gained an
  SSH + firstboot wait so it works on freshly-cloned nodes.
- **`scripts/smoke-0.H.3.ps1`** — 10-section, 37-check ecosystem gate;
  `scripts/kafka.ps1` default phase → `0.H.3`.
- **`nexus-infra-vmware`** security env: the `kafka-broker` PKI role's
  `allowed_domains` extended from the 6 brokers to all 15 kafka-tier
  hostnames; +3 ecosystem policies + AppRoles + sidecars (9 kafka-node
  Vault Agents total).

### Design

- Confluent 7.7.1's Jetty REST listeners accept `ssl.keystore.type=PEM`
  (verified in the `rest-utils` source), so Schema Registry + REST Proxy
  use the **same password-less PEM keystore** as the brokers — no JKS, no
  `keytool`, no keystore password.
- The SR/REST own HTTPS listeners are server-side TLS only
  (`ssl.client.authentication=NONE`) — the consul-tls operator-API
  precedent (`https.verify_incoming=false`). mTLS is mandatory only on the
  data plane (the connection to the brokers).

### Fixed

- **0.H.2 re-apply churn** — `kafka_vault_agent`'s destroy did
  `rm -rf /etc/vault-agent/` (wiping the TLS template the TLS overlays
  own), and `kafka_tls`'s `va_ids` trigger re-ran the broker mTLS flip
  whenever any Vault Agent id changed (every security-env apply rotates
  secret-ids). Left unfixed, every 0.H.x apply cycle would needlessly
  restart both broker clusters. Now: `kafka_vault_agent` destroy is
  surgical (keeps the TLS template); `kafka_tls` + `kafka_ecosystem_tls`
  dropped the `va_ids` trigger (re-run only on broker/node-set change).
  (`kafka_tls_v` v3.)
- **JSON-payload over-escaping** — the SR schema-register payload and two
  REST Proxy payloads had `\"`-escaped *outer* quotes; corrected to plain
  quotes (only the inner schema string is `\"`-escaped). Also: the
  smoke gate's `_schemas` probe targeted `localhost:9092` from an SR node
  (no broker there) and the REST round-trip produced to a non-existent
  topic (brokers run `auto.create.topics.enable=false`) — both fixed.

## 0.H.2 — Broker mutual TLS — 2026-05-14

Both KRaft clusters flipped from the 0.H.1 PLAINTEXT backplane to mutual
TLS — per-node Vault PKI leaf certs, SSL on the client *and* controller
listeners, `ssl.client.auth=required` everywhere. Smoke gate
`scripts/smoke-0.H.2.ps1` is ALL GREEN (92 `[OK]` / 0 `[FAIL]`).
Verification: `docs/verification/0.H.2-broker-mtls.md`.

### Added

- **`role-overlay-kafka-vault-agents.tf`** — installs `nexus-vault-agent.service`
  on each broker (`for_each`, independently `-target`-able). Each agent
  authenticates to `vault-1` via a narrow per-host AppRole and renders
  certs from Vault PKI. Systemd unit ships with `RuntimeDirectory=` for
  reboot-survival of the `/var/run` token sink.
- **`role-overlay-kafka-tls.tf`** — the PLAINTEXT→mTLS flip. Phase 1:
  per-node sequential cert render (Vault Agent `pkiCert` →
  `kafka-tls-split.sh` → PEM keystore/truststore) + mTLS `server.properties`
  drop. Phase 2: per-cluster **parallel-within-cluster big-bang restart**
  of `kafka.service` (a TLS wire-format flip can't be a sequential rolling
  restart — the consul-tls / nomad-tls lesson). Phase 3: KRaft quorum +
  RF=3 round-trip verified over mTLS. Destroy provisioner restores a
  working PLAINTEXT state.
- **`scripts/smoke-0.H.2.ps1`** — 9-section, 92-check mTLS gate;
  `scripts/kafka.ps1` default phase → `0.H.2`.
- **`nexus-infra-vmware`** security env gains the Vault-side state:
  `role-overlay-vault-pki-kafka.tf` (the `kafka-broker` PKI role,
  server+client EKU, 90-day TTL) + `role-overlay-vault-agent-kafka-policies.tf`
  + `role-overlay-vault-agent-kafka-approles.tf` (6 narrow policies + 6
  AppRoles + per-host JSON credential sidecars).

### Design

- mTLS on the existing 0.H.1 ports (`9092` client + inter-broker, `9093`
  controller) — only the wire protocol flips, so the nftables overlay
  needs no change. `ssl.client.auth=required` everywhere → every Kafka
  client runs *from* a broker and uses that broker's own keystore as its
  client identity.
- Kafka 3.8 native PEM keystore (`ssl.keystore.type=PEM`) — no JKS, no
  `keytool`, no keystore password.

### Fixed

- **PKCS#1 → PKCS#8 key conversion** — Vault PKI issues RSA keys in
  PKCS#1 (`-----BEGIN RSA PRIVATE KEY-----`); Kafka's Java PEM keystore
  parser only accepts PKCS#8, failing broker startup with
  `java.security.InvalidKeyException: algid parse error`. `kafka-tls-split.sh`
  now converts via `openssl pkcs8 -topk8 -nocrypt`. Also added
  `systemctl reset-failed` before the Phase 2 restart so a re-run isn't
  blocked by a start-limited prior attempt. (`kafka_tls_v` v2)

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
