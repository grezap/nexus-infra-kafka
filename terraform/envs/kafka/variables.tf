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
