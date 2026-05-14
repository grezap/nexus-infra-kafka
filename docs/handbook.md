# nexus-infra-kafka — Operator Handbook

Operator runbook for **Phase 0.H** (Tier-3 data backbone — the Kafka ecosystem).
Mirrors the structure of [`nexus-infra-swarm-nomad/docs/handbook.md`](https://github.com/grezap/nexus-infra-swarm-nomad/blob/main/docs/handbook.md).

The `03-kafka` tier is **15 VMs**: two 3-node KRaft clusters (`kafka-east`
primary + `kafka-west` DR) + 9 ecosystem nodes (Schema Registry ×2, REST
Proxy, Kafka Connect ×2, ksqlDB ×2, MirrorMaker 2 ×2). One parameterised
`kafka-node` Packer template clones to all 15.

## §0 Prerequisites

- **Build host:** Windows 11 Pro at `10.0.70.101` with VMware Workstation Pro,
  Packer 1.11+, Terraform 1.9+, OpenSSH client, ssh-agent loaded with the lab
  key (zero passphrase).
- **Foundation tier healthy:** `nexus-infra-vmware` Phase 0.D fully closed.
  `nexus-gateway`, `dc-nexus`, `vault-1/2/3`, `vault-transit` running; the
  3-node Vault HA cluster initialised + unsealed.
- **Security env state for the Kafka tier:** the `nexus-infra-vmware`
  `security` env must have run its Kafka overlays — `role-overlay-vault-pki-kafka.tf`
  (the `kafka-broker` PKI role, server+client EKU, 90-day TTL, all 15 tier
  hostnames in `allowed_domains`) + `role-overlay-vault-agent-kafka-{policies,approles}.tf`
  (15 narrow policies + 15 AppRoles + per-host JSON sidecars). This is the
  **cross-env coupling**: see §1.2.
- **dnsmasq dhcp-host reservations active for the kafka tier:** managed by
  `nexus-infra-vmware/terraform/envs/foundation/role-overlay-gateway-kafka-reservations.tf`
  (default `enable_kafka_dhcp_reservations = true`). Verify on the gateway:

  ```pwsh
  ssh nexusadmin@192.168.70.1 'cat /etc/dnsmasq.d/foundation-kafka-reservations.conf'
  # Expect 15 dhcp-host lines pinning the kafka MACs (00:50:56:3F:00:60-6E)
  # to the canonical VMnet11 IPs.
  ```

  If absent, run `pwsh -File ../nexus-infra-vmware/scripts/foundation.ps1 apply`
  from the parent repo first.

## §1 Phase walkthrough

### 1.1 Build the `kafka-node` Packer template

One template, fifteen clones reuse it. ~30-45 min on the build host (JDK +
Kafka + Confluent tarball downloads dominate).

```pwsh
cd packer/kafka-node
packer init .
packer build .
# Output: H:\VMS\NexusPlatform\_templates\kafka-node\kafka-node.vmx
```

The template bakes Debian 13 + Temurin JDK 21 + Apache Kafka 3.8.1 (brokers +
`connect-mirror-maker`) + Confluent Community 7.7.1 (Schema Registry / Connect
/ ksqlDB / REST Proxy). **All six role systemd units are delivered disabled** —
the Terraform role-overlays enable exactly one per node. The build's post-install
provisioner runs sanity checks (`kafka-topics.sh --version`, `systemctl
is-enabled` on each unit); cluster behaviour is exercised at apply-time + by the
smoke gates.

> The Packer build memory (`var.memory_mb`) is the broker spec (8 GB). `modules/vm`
> does not yet resize on clone (`memory_mb` is reserved-not-applied), so **all 15
> clones run at 8 GB** — see `vms.yaml`'s RAM-ratification note. The lighter
> per-role sizing is a tracked future enhancement.

### 1.2 Operator order — security env FIRST, then kafka env

This is a **hard ordering**, not a preference:

```pwsh
# 1. nexus-infra-vmware: provision the Kafka tier's Vault-side state.
#    Writes the kafka-broker PKI role + 15 AppRole policies + 15 AppRoles +
#    15 per-host JSON sidecars to $HOME/.nexus/vault-agent-<host>.json.
pwsh -File ..\nexus-infra-vmware\scripts\security.ps1 apply

# 2. nexus-infra-kafka: bring up the tier.
pwsh -File scripts\kafka.ps1 apply
```

The kafka env's `role-overlay-kafka-vault-agents.tf` reads each sidecar via
`filesha256()` **at plan time** — the kafka env cannot even `terraform plan`
until the security env has written the sidecars. Re-running `security.ps1 apply`
is safe and idempotent: AppRole writes are upserts; the role-id is stable; the
secret-id is regenerated each apply and the kafka-side overlay always reads the
freshest sidecar.

### 1.3 Apply the env

```pwsh
pwsh -File scripts\kafka.ps1 apply
```

Apply flow (the overlays run in `depends_on` order — never id-trigger
cascades, per ADR-0022):

1. **15 `module.vm` clones** — `vmrun clone` + `configure-vm-nic.ps1` writes the
   dual-NIC config (VMnet11 service + VMnet10 backplane) + `vmrun start nogui`.
2. **`kafka-node-firstboot.service`** runs once per clone — MAC-OUI NIC
   discovery, hostname + `/etc/hosts`, VMnet10 backplane IP, and
   `/etc/nexus-kafka/node-identity.env` (role / cluster / KRaft node.id / IPs)
   for the role-overlays to source. It enables **no** role service.
3. **0.H.1 — KRaft bring-up:** `role-overlay-nftables-backplane.tf` (whole-segment
   VMnet10 trust) → `role-overlay-broker-config.tf` (renders PLAINTEXT
   `server.properties`) → `role-overlay-kraft-format.tf` (per-cluster cluster-UUID
   recover-or-mint + `kafka-storage format` + big-bang `kafka.service` start +
   RF=3 round-trip verify).
4. **0.H.2 — broker mTLS:** `role-overlay-kafka-vault-agents.tf` (per-node
   `nexus-vault-agent.service`) → `role-overlay-kafka-tls.tf` (per-node cert
   render + `server.properties` → SSL + per-cluster **parallel** big-bang
   restart — a TLS wire-format flip can't be a sequential rolling restart).
5. **0.H.3-0.H.5 — ecosystem:** `role-overlay-ecosystem-tls.tf` (per-node PEM +
   PKCS#12 keystores) → the per-service overlays: `schema-registry`, `rest`,
   `connect`, `ksqldb`, `mm2`. Each renders config, enables its one role
   service, and verifies.

Total wall-clock for a fresh apply (post-Packer-build): ~30-40 min.

### 1.4 Verify

```pwsh
pwsh -File scripts\kafka.ps1 smoke               # defaults to -Phase 0.H.5
pwsh -File scripts\kafka.ps1 smoke -Phase 0.H.1  # any sub-phase gate
```

Each `smoke-0.H.<N>.ps1` is **scoped to that sub-phase's nodes** (they do not
chain — 0.H.4 covers the Connect/ksqlDB nodes, the brokers are covered by
0.H.1/0.H.2, etc.). A full-tier verification runs all five — see §3.2.

Quick manual spot-checks:

```pwsh
# KRaft quorum on each cluster (run FROM a broker -- sudo, mTLS):
ssh nexusadmin@192.168.70.21 'sudo /opt/kafka/bin/kafka-metadata-quorum.sh --bootstrap-server SSL://192.168.10.21:9092 --command-config /etc/nexus-kafka/client-ssl.properties describe --status'

# Phase 0.H exit gate -- the MM2 round-trip is asserted by smoke-0.H.5.ps1.
```

### 1.5 Iterating

Selective ops (`feedback_selective_provisioning.md`) — every VM, every overlay
is toggleable:

```pwsh
# Bring up only the east KRaft cluster (skip west + all ecosystem)
pwsh -File scripts\kafka.ps1 apply -Vars `
    enable_kafka_west=false, enable_schema_registry=false, `
    enable_kafka_rest=false, enable_kafka_connect=false, `
    enable_ksqldb=false, enable_mm2=false

# Iterate on just the MM2 overlay (assumes the rest of the tier is up)
pwsh -File scripts\kafka.ps1 apply -Vars enable_mm2_config=true
```

> **Watch out:** per `feedback_terraform_partial_apply_destroys_resources.md`,
> every `-Vars` invocation is the FULL override set for that apply — vars not
> passed default back, and `count = var.X ? 1 : 0` resources get destroyed. The
> defaults reflect the steady state (everything enabled), so omitting `-Vars` is
> the safe operator path.

### 1.6 Tear down

```pwsh
pwsh -File scripts\kafka.ps1 destroy
```

Each overlay's destroy provisioner stops + disables its role service and removes
the rendered config (surgically — e.g. the Vault Agent destroy keeps the TLS
template the TLS overlays own). Each `module.vm`'s destroy provisioner runs
`vmrun stop` + `vmrun deleteVM` + removes the per-VM directory.

Gateway dhcp-host reservations stay live (they belong to foundation env). The
Vault-side state (PKI role, AppRoles, sidecars) stays — it is owned by the
`nexus-infra-vmware` security env.

## §2 Phase status

| Sub-phase | Scope | Status |
|---|---|---|
| 0.H.1 | Repo scaffold + `kafka-node` Packer template + both 3-node KRaft clusters (PLAINTEXT bring-up) | ✅ closed (2026-05-14) — `smoke-0.H.1.ps1` 38/38 |
| 0.H.2 | Broker mutual TLS — Vault PKI per-node leaf certs, `ssl.client.auth=required` | ✅ closed (2026-05-14) — `smoke-0.H.2.ps1` 92/92 |
| 0.H.3 | Schema Registry HA pair + Confluent REST Proxy | ✅ closed (2026-05-14) — `smoke-0.H.3.ps1` 37/37 |
| 0.H.4 | Kafka Connect distributed cluster + Debezium + ksqlDB cluster | ✅ closed (2026-05-14) — `smoke-0.H.4.ps1` 48/48 |
| 0.H.5 | MirrorMaker 2 cross-cluster DR pair + the Phase 0.H exit gate | ✅ closed (2026-05-14) — `smoke-0.H.5.ps1` 38/38 |
| 0.H.6 | Close-out canon batch (MASTER-PLAN sub-phase rows + ADRs 0020-0023 + `vms.yaml` + `glossary.md` + this handbook) + cold-rebuild proof | ✅ closed (`v0.1.0`, 2026-05-15) — **Phase 0.H complete** |

**Phase 0.H exit gate:** produce a record to `kafka-east` → it appears on the
mirrored `east.*` topic on `kafka-west` via MirrorMaker 2 (and the `west.*`
reverse). Asserted by `smoke-0.H.5.ps1`.

KRaft cluster UUIDs (stable across the 0.H.2 mTLS flip): `kafka-east`
`ZD-HhB5fQfioHydHQWiHkw`, `kafka-west` `FezdEIKlRCWP6nCSrHNJww`.

## §3 Operator runbooks

### 3.1 Cold rebuild — destroy → apply → smoke (canon)

The Kafka tier is engineered to be re-deployable from cold with **no operator
hot-state** between destroy and smoke. Unlike the swarm tier, there is **no
stale-Vault-KV prerequisite** — the Kafka tier's Vault-side state is per-host
AppRoles (re-`apply` regenerates the secret-ids; role-ids are stable) and the
`kafka-broker` PKI role (an upsert). The per-cluster KRaft cluster-UUIDs are
minted fresh by `role-overlay-kraft-format.tf` on a cold apply (the old VMs —
and their `meta.properties` — are gone).

```pwsh
# 1. Tear down the tier (~8-10 min). nexus-gateway + the Vault cluster are
#    foundation/security env -- NOT torn down here.
pwsh -File scripts\kafka.ps1 destroy

# 2. Re-provision the Vault-side state (regenerates the 15 AppRole sidecars).
pwsh -File ..\nexus-infra-vmware\scripts\security.ps1 apply

# 3. Re-apply from cold (~30-40 min: 15 clones + firstboot + per-overlay
#    bring-up, including the 0.H.5 exit-gate round-trip).
pwsh -File scripts\kafka.ps1 apply

# 4. Full-tier smoke gate (~5 min). 0.H.2 is the broker gate for a BUILT
#    tier -- 0.H.1 is the PLAINTEXT-era bring-up gate and its plaintext
#    probes correctly FAIL once 0.H.2 has flipped the brokers to mTLS, so
#    it is NOT run here. 0.H.2 re-asserts quorum + RF=3 round-trip over mTLS.
foreach ($p in '0.H.2','0.H.3','0.H.4','0.H.5') {
  pwsh -File scripts\kafka.ps1 smoke -Phase $p
}
# Expect: ALL <p> SMOKE CHECKS PASSED for each.
```

There must be **zero manual steps** between (3) and (4) — no cert shuffling, no
`--insecure`, no KV surgery. If any are needed, that is a regression in the
tier build, not an operator workaround.

> **Cold-rebuild proven 2026-05-15.** `destroy` → `security apply` → `apply`
> → `0.H.2`-`0.H.5` smoke gates ALL GREEN (92 / 37 / 48 / 38). The rebuild
> surfaced four VMware-under-load transients — all VM-layer, none a config
> bug, each recovered without touching an overlay's logic except one
> verification-robustness fix (the MM2 journal-window, see the CHANGELOG).
> See **§3.7** for the apply-time VM-layer recovery playbook; the 15×8 GB
> fleet stresses the build host, which is the standing argument for the
> `modules/vm` resize-on-clone enhancement (`vms.yaml` RAM-ratification note).

> A from-absolute-zero rebuild also re-runs §1.1 (`packer build`). The proof run
> reuses the current template — the template is immutable build output and is
> not part of the per-apply churn.

### 3.2 Smoke gate cheat sheet

```pwsh
pwsh -File scripts\kafka.ps1 smoke                # -Phase 0.H.5 (default)
pwsh -File scripts\kafka.ps1 smoke -Phase 0.H.1   # brokers, PLAINTEXT-era checks
pwsh -File scripts\kafka.ps1 smoke -Phase 0.H.2   # brokers, mTLS
pwsh -File scripts\kafka.ps1 smoke -Phase 0.H.3   # schema-registry-1/2 + kafka-rest-1
pwsh -File scripts\kafka.ps1 smoke -Phase 0.H.4   # kafka-connect-1/2 + ksqldb-1/2
pwsh -File scripts\kafka.ps1 smoke -Phase 0.H.5   # mm2-1/2 + the exit gate
```

Each gate is **scoped to its sub-phase's nodes** — they do not chain. `0.H.1`
checks the PLAINTEXT-era broker behaviour and is only meaningful before the
0.H.2 mTLS flip — on a fully-built tier its plaintext probes **correctly
fail**, because the brokers no longer speak PLAINTEXT; `0.H.2` is the broker
gate for a built tier (it re-asserts quorum + RF=3 round-trip over mTLS). A
full-tier sweep on a built tier runs the four post-bring-up gates
`0.H.2`-`0.H.5` (see §3.1 step 4).

### 3.3 Operator credential reference

| Asset | Location | Field | Used by |
|---|---|---|---|
| Kafka-tier PKI role | Vault `pki_int/roles/kafka-broker` | — | Each node's Vault Agent (`pki_int/issue/kafka-broker`) |
| Per-host AppRole sidecar (×15) | `$HOME\.nexus\vault-agent-<host>.json` | `role_id` + `secret_id` | `role-overlay-kafka-vault-agents.tf` (read via `filesha256()`) |
| CA bundle | `$HOME\.nexus\vault-ca-bundle.crt` | — | Vault Agent on each node verifies the Vault server cert |
| Build host root token | `$HOME\.nexus\vault-init.json` | `root_token` | The `security.ps1 apply` overlays |
| PKCS#12 keystore password | `var.kafka_keystore_password` (Terraform default `NexusKafkaP12!1`) | — | Connect + ksqlDB REST listeners' `.p12` files (lab convenience; production → Vault KV) |
| KRaft cluster UUIDs | `kafka-east` `ZD-HhB5fQfioHydHQWiHkw` / `kafka-west` `FezdEIKlRCWP6nCSrHNJww` | — | `role-overlay-kraft-format.tf` `kafka-storage format` |
| Per-node client TLS config | on each node: `/etc/nexus-kafka/client-ssl.properties` (+ `tls/{keystore,truststore}.{pem,p12}`) | — | The Kafka CLI tools — **see §3.4** |

### 3.4 The Kafka CLI `sudo` rule + common failure modes

**The Kafka CLI tools MUST run under `sudo`.** `/etc/nexus-kafka/` is
`0750 root:kafka` and `nexusadmin` is not in the `kafka` group, so a non-sudo
`kafka-topics.sh --command-config /etc/nexus-kafka/client-ssl.properties ...`
throws `java.nio.file.AccessDeniedException` — it cannot even traverse the
directory to read the config or the keystore it points at. This is the
`feedback_sudo_required_for_consul_etc_traverse.md` lesson (the Consul
`/etc/consul.d/` 0750 case), Kafka edition.

| Symptom | Diagnosis | Fix |
|---|---|---|
| `java.nio.file.AccessDeniedException: /etc/nexus-kafka/client-ssl.properties` | Kafka CLI run without `sudo` — can't traverse `0750 root:kafka` | Prefix the CLI invocation with `sudo` |
| Broker crash-loop, `InvalidKeyException: algid parse error, not a sequence` | Vault PKI issued a PKCS#1 key; Kafka's PEM parser needs PKCS#8 | `kafka-tls-split.sh` converts via `openssl pkcs8 -topk8` — verify the split script ran (`ls -l /etc/nexus-kafka/tls/keystore.pem`) |
| Connect/ksqlDB REST listener won't start, `PEM KeyStore not available` / `Invalid value PEM` | Their REST servers reject `ssl.keystore.type=PEM` | They must use the `.p12` files — verify `role-overlay-ecosystem-tls.tf` emitted `keystore.p12` + `truststore.p12` |
| `trustAnchors parameter must be non-empty` (Connect/ksqlDB) | `truststore.p12` built with `openssl pkcs12 -export -nokeys` (empty cert bag) | Must be built with `keytool -importcert` — `ecosystem_tls_v` ≥ 3 |
| ksqlDB won't start, `UnsupportedOperationException: The Security Manager is deprecated` | Java 21 removed `System.setSecurityManager()` | `ksql.udf.enable.security.manager=false` in `ksqldb-server.properties` |
| MM2 healthy in the journal but a probe says "heartbeats topic never appeared" | The probe ran the Kafka CLI without `sudo` (see row 1) — MM2 itself is fine | `sudo` the probe; confirm with `sudo /opt/kafka/bin/kafka-topics.sh ... --list` |
| Re-apply churns the brokers (re-renders `server.properties`, restarts `kafka.service`) | An overlay keyed a `triggers` entry on an upstream resource's `.id` | The id-trigger cascade anti-pattern — see ADR-0022; `triggers` must key only on the overlay's own inputs |
| `terraform plan` errors before any apply: sidecar file not found | `security.ps1 apply` hasn't run, or ran without the kafka overlays enabled | Run `..\nexus-infra-vmware\scripts\security.ps1 apply` first (§1.2) |

### 3.5 Vault HA reboot recovery

The Kafka tier's per-node Vault Agents depend on the 3-node Vault HA cluster
being unsealed. On a build-host reboot, `vault-transit` comes up sealed and the
HA cluster crash-loops. Recovery is **identical to the swarm tier's** — see
[`nexus-infra-swarm-nomad/docs/handbook.md` §3.2](https://github.com/grezap/nexus-infra-swarm-nomad/blob/main/docs/handbook.md),
or run `nexus-infra-vmware/scripts/recover-vault-ha.ps1`. After Vault HA
recovers, the kafka-node Vault Agents self-heal (their systemd unit ships
`RuntimeDirectory=nexus-vault-agent`, so the `/var/run` token sink is recreated
on every start — the `feedback_systemd_runtime_directory_tmpfs.md` fix).

### 3.6 MirrorMaker 2 / cross-cluster troubleshooting

| Symptom | Diagnosis | Fix |
|---|---|---|
| `mm2.service` active but no `east.*` topics on `kafka-west` | MM2 discovers topics on a refresh interval | `refresh.topics.interval.seconds` is 10s (lab-snappy); wait ~15-20s. Check `sudo journalctl -u mm2.service` for the connectors |
| Journal shows `SSLHandshakeException` / `Failed authentication` | The node's keystore isn't a valid client cert for one of the clusters | Verify `role-overlay-ecosystem-tls.tf` rendered the node's `keystore.pem`; check the leaf CN |
| `mm2.service` ExecStart has no `--clusters` flag | The systemd drop-in didn't render | `sudo cat /etc/systemd/system/mm2.service.d/10-clusters.conf` should show `--clusters west` (mm2-1) / `east` (mm2-2); re-run `kafka.ps1 apply -Vars enable_mm2_config=true` |
| Mirrored topic name is wrong (`orders` not `east.orders`) | `replication.policy.class` isn't `DefaultReplicationPolicy` | The source-alias prefix is mandatory for the loop-safe bidirectional pair — never `IdentityReplicationPolicy` (ADR-0023) |
| Both flows running on one node | `mm2.properties` enabled both directions | Each node enables exactly one `<src>-><dst>.enabled = true`; the reverse must be `false` |

To inspect cross-cluster state by hand (from an MM2 node — note the `sudo`):

```pwsh
# Topics on the WEST cluster, listed from mm2-1:
ssh nexusadmin@192.168.70.85 'sudo /opt/kafka/bin/kafka-topics.sh --bootstrap-server 192.168.10.24:9092,192.168.10.25:9092,192.168.10.26:9092 --command-config /etc/nexus-kafka/client-ssl.properties --list'
# Expect: heartbeats, mm2-*.east.internal, east.checkpoints.internal, and the
#         mirrored east.* data topics.
```

### 3.7 Apply-time VM-layer recovery (the cold-rebuild transients)

The 0.H.6 cold-rebuild surfaced four VMware-Workstation-under-load transients.
None was a config or overlay-logic bug — bringing up 15 × 8 GB clones at once
stresses the build host, and VMware's clone / power-on / vNIC-attach paths get
flaky. Each is recoverable without editing an overlay; the recovery actions
below are the canon. (The standing fix is the `modules/vm` resize-on-clone
enhancement — see the `vms.yaml` RAM-ratification note — so the light
ecosystem nodes stop running at the broker's 8 GB.)

| Symptom | Diagnosis | Recovery |
|---|---|---|
| `vmrun start ... Error: Unknown error` on a handful of VMs during `apply` | Terraform fires ~10 `vmrun start` calls in parallel; VMware Workstation chokes under the concurrent load. Transient — the VMs are cloned, just not powered on. | **Re-run `kafka.ps1 apply`.** The failed `power_on` resources are tainted; terraform retries just those (the other VMs are settled by then) and continues the graph. |
| A clone boots but is unreachable — no SSH, no ping; `vmrun getGuestIPAddress` returns "Unable to get the IP address" though tools state is `running` | A botched clone — the guest came up with unrecoverable network state. A guest reset does **not** fix it. | **Re-clone just that VM:** `terraform -chdir=terraform/envs/kafka apply -replace='module.<vm>[0].null_resource.clone_vm' -replace='module.<vm>[0].null_resource.configure_nic' -replace='module.<vm>[0].null_resource.power_on'`. The `clone_vm` destroy provisioner removes the bad VM + dir, then re-clones; the graph continues. |
| A clone is reachable on VMnet11 but its VMnet10 NIC is dead — `nic1 DOWN`, `networkctl status nic1` shows `no-carrier (configuring)`, can't reach the brokers on `192.168.10.x` (config files + `.vmx` `ethernet1` are correct) | The `ethernet1` vNIC powered on **disconnected from the VMnet10 virtual switch** despite `ethernet1.startConnected = "TRUE"`. A guest reset does not re-init the vNIC↔switch binding. | **`vmrun connectNamedDevice "<...>.vmx" ethernet1`** — reconnects the vNIC at the VMware layer; `nic1` comes up `routable` within seconds. Then re-run `kafka.ps1 apply` so the tainted role overlay re-runs. |
| A role overlay fails its journal-sanity check though the service is healthy | A busy connector floods `journalctl`; a one-shot startup line falls out of the `-n` tail window. | A verification-robustness bug, not a service fault — fixed in 0.H.6 for the MM2 overlay (`role-overlay-mm2.tf` + `smoke-0.H.5.ps1` now require **any** MM2 connector class in the journal tail, since the topic-existence check already proves the heartbeat connector ran). Same shape elsewhere → relax the journal grep, don't widen the window. |

After any of the above, the **tainted** resources are what re-run on the next
`apply` — `terraform plan` names them. The cold-rebuild proof is met when
`0.H.2`-`0.H.5` are ALL GREEN with no manual step between `apply` and smoke
(VM-layer recovery actions during `apply` are part of `apply`, not "manual
hot-state" — they leave no operator-managed state behind).
