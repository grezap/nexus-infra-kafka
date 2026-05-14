/*
 * envs/kafka -- variables
 *
 * Selective ops (memory/feedback_selective_provisioning.md):
 *   - var.enable_kafka_cluster        -- master gate for the whole env
 *   - var.enable_kafka_east / _west   -- per-cluster gates (bring up one
 *                                        KRaft cluster at a time during dev)
 *   - var.enable_kafka_<vm>           -- per-VM toggles for iteration
 *   - var.enable_nftables_backplane / _kraft_format / _broker_config
 *                                     -- per-overlay toggles
 *
 * MAC convention (distinct range from foundation + swarm tiers, which use
 * 00:50:56:3F:00:1X and :00:5X respectively):
 *   00:50:56:3F:00:60-6E  -> kafka primaries   (VMnet11 / service)
 *   00:50:56:3F:01:60-6E  -> kafka secondaries (VMnet10 / backplane)
 * 0.H.1 uses :60-:65 (6 brokers); :66-:6E reserved for the 9 ecosystem
 * VMs added in 0.H.3-0.H.5.
 *
 * Pre-flight dependency: nexus-gateway dnsmasq must have dhcp-host
 * reservations mapping these MACs to the canonical VMnet11 IPs
 * (192.168.70.21-26 for brokers). Owned by nexus-infra-vmware's foundation
 * env (role-overlay-gateway-kafka-reservations.tf). firstboot maps the
 * DHCP-assigned VMnet11 IP -> hostname/role/cluster, so the reservation
 * must be live before this env applies.
 */

variable "template_vmx_path" {
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/kafka-node/kafka-node.vmx"
  description = "Absolute path to the kafka-node Packer template .vmx."
}

variable "vmrun_path" {
  type        = string
  default     = "C:/Program Files (x86)/VMware/VMware Workstation/vmrun.exe"
  description = "Absolute path to vmrun.exe."
}

variable "vm_output_dir_root" {
  type        = string
  default     = "H:/VMS/NexusPlatform/03-kafka"
  description = "Tier directory root. Per-VM subdirs per memory/feedback_vmware_per_vm_folders.md."
}

variable "vnet_primary" {
  type        = string
  default     = "VMnet11"
  description = "Service network (mgmt + app). DHCP via nexus-gateway dnsmasq."
}

variable "vnet_secondary" {
  type        = string
  default     = "VMnet10"
  description = "Cluster backplane -- KRaft controller quorum + inter-broker replication + MM2 cross-cluster traffic. Static IP per hostname in kafka-node-firstboot.sh."
}

# ─── Master + per-cluster + per-VM gates ──────────────────────────────────
variable "enable_kafka_cluster" {
  type        = bool
  default     = true
  description = "Master gate for the entire kafka env."
}

variable "enable_kafka_east" {
  type        = bool
  default     = true
  description = "Gate for the kafka-east KRaft cluster (kafka-east-1/2/3)."
}

variable "enable_kafka_west" {
  type        = bool
  default     = true
  description = "Gate for the kafka-west KRaft cluster (kafka-west-1/2/3)."
}

variable "enable_kafka_east_1" {
  type    = bool
  default = true
}
variable "enable_kafka_east_2" {
  type    = bool
  default = true
}
variable "enable_kafka_east_3" {
  type    = bool
  default = true
}
variable "enable_kafka_west_1" {
  type    = bool
  default = true
}
variable "enable_kafka_west_2" {
  type    = bool
  default = true
}
variable "enable_kafka_west_3" {
  type    = bool
  default = true
}

# ─── Overlay gates ────────────────────────────────────────────────────────
variable "enable_nftables_backplane" {
  type        = bool
  default     = true
  description = "role-overlay-nftables-backplane.tf -- VMnet10 accept rules for the Kafka ports (9092 client, 9093 controller)."
}

variable "enable_kraft_format" {
  type        = bool
  default     = true
  description = "role-overlay-kraft-format.tf -- per-cluster cluster-UUID generation + kafka-storage format on each broker's log dir."
}

variable "enable_broker_config" {
  type        = bool
  default     = true
  description = "role-overlay-broker-config.tf -- render server.properties, enable + start kafka.service, verify controller quorum."
}

# ─── MACs: 6 brokers x 2 NICs ─────────────────────────────────────────────
variable "mac_kafka_east_1_primary" {
  type    = string
  default = "00:50:56:3F:00:60"
}
variable "mac_kafka_east_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:60"
}
variable "mac_kafka_east_2_primary" {
  type    = string
  default = "00:50:56:3F:00:61"
}
variable "mac_kafka_east_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:61"
}
variable "mac_kafka_east_3_primary" {
  type    = string
  default = "00:50:56:3F:00:62"
}
variable "mac_kafka_east_3_secondary" {
  type    = string
  default = "00:50:56:3F:01:62"
}
variable "mac_kafka_west_1_primary" {
  type    = string
  default = "00:50:56:3F:00:63"
}
variable "mac_kafka_west_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:63"
}
variable "mac_kafka_west_2_primary" {
  type    = string
  default = "00:50:56:3F:00:64"
}
variable "mac_kafka_west_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:64"
}
variable "mac_kafka_west_3_primary" {
  type    = string
  default = "00:50:56:3F:00:65"
}
variable "mac_kafka_west_3_secondary" {
  type    = string
  default = "00:50:56:3F:01:65"
}

# ─── Operator + timing ────────────────────────────────────────────────────
variable "kafka_node_user" {
  type        = string
  default     = "nexusadmin"
  description = "SSH username on every kafka-node clone."
}

variable "kafka_cluster_timeout_minutes" {
  type        = number
  default     = 20
  description = "Per-node readiness timeout (SSH echo + firstboot marker) in the bring-up overlays."
}

# ─── Phase 0.H.2 — broker mTLS (Vault Agents + TLS overlay) ───────────────
#
# Cross-env coupling: the Vault-side state (pki_int/roles/kafka-broker + 6
# per-broker AppRoles + JSON sidecars) is owned by nexus-infra-vmware's
# security env (role-overlay-vault-pki-kafka.tf + role-overlay-vault-agent-
# kafka-{policies,approles}.tf). Operator order:
#   1. nexus-infra-vmware: pwsh -File scripts/security.ps1 apply
#   2. nexus-infra-kafka:  pwsh -File scripts/kafka.ps1 apply
#
# role-overlay-kafka-vault-agents.tf installs nexus-vault-agent.service on
# each broker; role-overlay-kafka-tls.tf issues per-node PKI leaf certs and
# flips both KRaft clusters from PLAINTEXT to mutual TLS.

variable "enable_kafka_vault_agents" {
  type        = bool
  default     = true
  description = "Master gate for role-overlay-kafka-vault-agents.tf -- install nexus-vault-agent.service on all 6 brokers. Reads the AppRole sidecars written by the security env. Default true (steady state per memory/feedback_terraform_partial_apply_destroys_resources.md)."
}

variable "enable_kafka_east_1_vault_agent" {
  type    = bool
  default = true
}
variable "enable_kafka_east_2_vault_agent" {
  type    = bool
  default = true
}
variable "enable_kafka_east_3_vault_agent" {
  type    = bool
  default = true
}
variable "enable_kafka_west_1_vault_agent" {
  type    = bool
  default = true
}
variable "enable_kafka_west_2_vault_agent" {
  type    = bool
  default = true
}
variable "enable_kafka_west_3_vault_agent" {
  type    = bool
  default = true
}

variable "enable_kafka_tls" {
  type        = bool
  default     = true
  description = "role-overlay-kafka-tls.tf -- flip both KRaft clusters from PLAINTEXT (0.H.1) to mutual TLS (per-node Vault PKI leaf certs, ssl.client.auth=required, per-cluster parallel big-bang restart). Default true. Set false to keep the clusters on PLAINTEXT/9092 (0.H.1 steady state)."
}

variable "vault_agent_version" {
  type        = string
  default     = "1.18.4"
  description = "Vault binary version to install on each broker as nexus-vault-agent.service. Matches nexus-infra-vmware/packer/vault/variables.pkr.hcl + nexus-infra-swarm-nomad's vault_agent_version."
}

variable "vault_agent_kafka_creds_dir" {
  type        = string
  default     = "$HOME/.nexus"
  description = "Directory on the build host holding the 6 vault-agent-kafka-<host>.json AppRole sidecars (written by nexus-infra-vmware security env). Each carries role_id + secret_id + CA path + vault address."
}

variable "vault_pki_ca_bundle_path" {
  type        = string
  default     = "$HOME/.nexus/vault-ca-bundle.crt"
  description = "Path on the build host to the Vault PKI root+intermediate CA bundle (written by nexus-infra-vmware security env at 0.D.2). Each broker's Vault Agent uses it to verify the vault server cert."
}

variable "vault_pki_kafka_role_name" {
  type        = string
  default     = "kafka-broker"
  description = "Name of the Vault PKI role under pki_int/ that issues broker leaf certs. Must match var.vault_pki_kafka_role_name in nexus-infra-vmware's security env."
}
