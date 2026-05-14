variable "vm_name" {
  type        = string
  default     = "kafka-node"
  description = "VM display name and output .vmx basename. Default `kafka-node` -- the template; per-clone names (kafka-east-1/2/3, kafka-west-1/2/3, schema-registry-1/2, kafka-connect-1/2, ksqldb-1/2, mm2-1/2, kafka-rest-1) are set by terraform/envs/kafka/."
}

variable "output_directory" {
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/kafka-node"
  description = "Absolute directory for the built template (.vmx + disks)."
}

variable "iso_url" {
  type        = string
  default     = "https://cdimage.debian.org/debian-cd/13.4.0/amd64/iso-cd/debian-13.4.0-amd64-netinst.iso"
  description = "Debian 13 netinst ISO URL. Same pin as nexus-infra-vmware/packer/{deb13,vault} + nexus-infra-swarm-nomad/packer/swarm-node."
}

variable "iso_checksum" {
  type        = string
  default     = "sha256:0b813535dd76f2ea96eff908c65e8521512c92a0631fd41c95756ffd7d4896dc"
  description = "ISO checksum (literal sha256). Same hash as deb13/vault/swarm-node -- all pin Debian 13.4.0 netinst."
}

variable "jdk_apt_channel" {
  type        = string
  default     = "main"
  description = "Adoptium (Temurin) apt repo component. `main` is the only published component."
}

variable "jdk_major" {
  type        = number
  default     = 21
  description = "Temurin JDK major version. 21 is the current LTS; Apache Kafka 3.8 + Confluent 7.7 both support JDK 21."
}

variable "kafka_version" {
  type        = string
  default     = "3.8.1"
  description = "Apache Kafka version to bake. Matches the local-data-stack reference (apache/kafka:3.8.1). KRaft brokers + connect-mirror-maker (MM2) come from this distribution."
}

variable "kafka_scala_version" {
  type        = string
  default     = "2.13"
  description = "Scala build suffix for the Apache Kafka tarball (kafka_<scala>-<kafka>.tgz). 2.13 is the recommended build."
}

variable "confluent_version" {
  type        = string
  default     = "7.7.1"
  description = "Confluent Community Edition version. 7.7.x is based on Apache Kafka 3.8. Provides Schema Registry, Kafka Connect, ksqlDB, REST Proxy (used from 0.H.3 onwards; baked now so the template is cold-rebuild-complete)."
}

variable "cpus" {
  type        = number
  default     = 4
  description = "Build-time vCPU. Brokers are 4 vCPU (vms.yaml lines 88-90); ecosystem nodes are 2 vCPU (vmrun-resize at clone time via terraform/envs/kafka/)."
}

variable "memory_mb" {
  type        = number
  default     = 8192
  description = "Build-time RAM (MB). Set to broker spec (8 GB, vms.yaml lines 88-90). Ecosystem nodes get vmrun-resized at clone time (SR/MM2 4 GB, REST 2 GB, Connect/ksqlDB 8 GB). RAM down-sizing validated empirically in 0.H.1 -- deviations logged + vms.yaml updated at 0.H.6 close-out per memory/feedback_prefer_less_memory.md."
}

variable "disk_gb" {
  type        = number
  default     = 200
  description = "Disk size in GB. Set to broker spec (200 GB, vms.yaml lines 88-90) -- the largest kafka VM. Ecosystem nodes use less (30-60 GB) but a growable single-file VMDK only consumes what it writes."
}

variable "ssh_username" {
  type    = string
  default = "nexusadmin"
}

variable "ssh_password" {
  type      = string
  default   = "nexus-packer-build-only"
  sensitive = true
  # Build-time only. 0.H.2 rotates to Vault Agent + key-only via PKI cert.
}

variable "boot_wait" {
  type    = string
  default = "15s"
}

variable "ssh_timeout" {
  type    = string
  default = "30m"
}
