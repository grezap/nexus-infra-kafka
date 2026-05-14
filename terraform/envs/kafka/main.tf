/*
 * envs/kafka -- Phase 0.H: the Kafka ecosystem (03-kafka tier).
 *
 * Per nexus-platform-plan/docs/infra/vms.yaml lines 84-112 + MASTER-PLAN.md
 * Phase 0.H goal (line 160):
 *
 *   0.H.1 (this file's broker blocks): two 3-node KRaft clusters --
 *     kafka-east-1/2/3 (primary) + kafka-west-1/2/3 (DR). Combined
 *     broker+controller mode, replication factor 3.
 *   0.H.3-0.H.5 (added later): schema-registry-1/2, kafka-connect-1/2,
 *     ksqldb-1/2, mm2-1/2, kafka-rest-1.
 *
 *   - OS: Debian 13 via the kafka-node Packer template
 *   - Tier directory: H:/VMS/NexusPlatform/03-kafka/<vm>/
 *   - Per-VM subdirs (memory/feedback_vmware_per_vm_folders.md)
 *   - Dual-NIC: VMnet11 service (DHCP via dnsmasq dhcp-host reservation
 *     -> .21-.26) + VMnet10 cluster backplane (static per-hostname IP set
 *     by kafka-node-firstboot.sh)
 *   - Brokers: 4 vCPU, 8 GB RAM, 200 GB disk (vms.yaml lines 88-90; RAM
 *     down-sizing validated empirically in 0.H.1, deviation logged + vms.yaml
 *     updated at 0.H.6 close-out per memory/feedback_prefer_less_memory.md)
 *
 * Selective ops (memory/feedback_selective_provisioning.md):
 *   - var.enable_kafka_cluster gates the whole env
 *   - var.enable_kafka_east / _west gate each KRaft cluster
 *   - var.enable_kafka_<vm> per-VM toggles
 *   - role-overlay-*.tf each independently `-target`-able
 *
 * Pre-flight dependency: nexus-gateway dnsmasq dhcp-host reservations for
 * the kafka VMnet11 IPs. Owned by nexus-infra-vmware foundation env
 * (role-overlay-gateway-kafka-reservations.tf). Operator order:
 *   1. nexus-infra-vmware foundation env applied (gateway reservations live)
 *   2. kafka-node Packer template built (packer build packer/kafka-node)
 *   3. THIS env: pwsh -File scripts/kafka.ps1 apply
 */

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
  }
}

# ─── kafka-east KRaft cluster (3) ─────────────────────────────────────────
module "kafka_east_1" {
  source = "../../modules/vm"
  count  = var.enable_kafka_cluster && var.enable_kafka_east && var.enable_kafka_east_1 ? 1 : 0

  vm_name           = "kafka-east-1"
  template_vmx_path = var.template_vmx_path
  vm_output_dir     = "${var.vm_output_dir_root}/kafka-east-1"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_kafka_east_1_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_kafka_east_1_secondary
}

module "kafka_east_2" {
  source = "../../modules/vm"
  count  = var.enable_kafka_cluster && var.enable_kafka_east && var.enable_kafka_east_2 ? 1 : 0

  vm_name           = "kafka-east-2"
  template_vmx_path = var.template_vmx_path
  vm_output_dir     = "${var.vm_output_dir_root}/kafka-east-2"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_kafka_east_2_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_kafka_east_2_secondary
}

module "kafka_east_3" {
  source = "../../modules/vm"
  count  = var.enable_kafka_cluster && var.enable_kafka_east && var.enable_kafka_east_3 ? 1 : 0

  vm_name           = "kafka-east-3"
  template_vmx_path = var.template_vmx_path
  vm_output_dir     = "${var.vm_output_dir_root}/kafka-east-3"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_kafka_east_3_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_kafka_east_3_secondary
}

# ─── kafka-west KRaft cluster (3, DR) ─────────────────────────────────────
module "kafka_west_1" {
  source = "../../modules/vm"
  count  = var.enable_kafka_cluster && var.enable_kafka_west && var.enable_kafka_west_1 ? 1 : 0

  vm_name           = "kafka-west-1"
  template_vmx_path = var.template_vmx_path
  vm_output_dir     = "${var.vm_output_dir_root}/kafka-west-1"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_kafka_west_1_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_kafka_west_1_secondary
}

module "kafka_west_2" {
  source = "../../modules/vm"
  count  = var.enable_kafka_cluster && var.enable_kafka_west && var.enable_kafka_west_2 ? 1 : 0

  vm_name           = "kafka-west-2"
  template_vmx_path = var.template_vmx_path
  vm_output_dir     = "${var.vm_output_dir_root}/kafka-west-2"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_kafka_west_2_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_kafka_west_2_secondary
}

module "kafka_west_3" {
  source = "../../modules/vm"
  count  = var.enable_kafka_cluster && var.enable_kafka_west && var.enable_kafka_west_3 ? 1 : 0

  vm_name           = "kafka-west-3"
  template_vmx_path = var.template_vmx_path
  vm_output_dir     = "${var.vm_output_dir_root}/kafka-west-3"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_kafka_west_3_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_kafka_west_3_secondary
}

# ─── Ecosystem VMs (schema-registry / connect / ksqldb / mm2 / rest) ──────
# MAC range 00:50:56:3F:00:66-6E (primaries) / :01:66-6E (secondaries).
# 0.H.3 brings up the schema-registry pair + the REST proxy; 0.H.4 adds
# kafka-connect + ksqldb, 0.H.5 adds mm2.

# ─── Schema Registry HA pair (2) -- 0.H.3 ─────────────────────────────────
module "schema_registry_1" {
  source = "../../modules/vm"
  count  = var.enable_kafka_cluster && var.enable_schema_registry && var.enable_schema_registry_1 ? 1 : 0

  vm_name           = "schema-registry-1"
  template_vmx_path = var.template_vmx_path
  vm_output_dir     = "${var.vm_output_dir_root}/schema-registry-1"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_schema_registry_1_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_schema_registry_1_secondary
}

module "schema_registry_2" {
  source = "../../modules/vm"
  count  = var.enable_kafka_cluster && var.enable_schema_registry && var.enable_schema_registry_2 ? 1 : 0

  vm_name           = "schema-registry-2"
  template_vmx_path = var.template_vmx_path
  vm_output_dir     = "${var.vm_output_dir_root}/schema-registry-2"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_schema_registry_2_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_schema_registry_2_secondary
}

# ─── Confluent REST Proxy (1) -- 0.H.3 ────────────────────────────────────
module "kafka_rest_1" {
  source = "../../modules/vm"
  count  = var.enable_kafka_cluster && var.enable_kafka_rest && var.enable_kafka_rest_1 ? 1 : 0

  vm_name           = "kafka-rest-1"
  template_vmx_path = var.template_vmx_path
  vm_output_dir     = "${var.vm_output_dir_root}/kafka-rest-1"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_kafka_rest_1_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_kafka_rest_1_secondary
}

# ─── Kafka Connect distributed cluster (2) -- 0.H.4 ───────────────────────
module "kafka_connect_1" {
  source = "../../modules/vm"
  count  = var.enable_kafka_cluster && var.enable_kafka_connect && var.enable_kafka_connect_1 ? 1 : 0

  vm_name           = "kafka-connect-1"
  template_vmx_path = var.template_vmx_path
  vm_output_dir     = "${var.vm_output_dir_root}/kafka-connect-1"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_kafka_connect_1_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_kafka_connect_1_secondary
}

module "kafka_connect_2" {
  source = "../../modules/vm"
  count  = var.enable_kafka_cluster && var.enable_kafka_connect && var.enable_kafka_connect_2 ? 1 : 0

  vm_name           = "kafka-connect-2"
  template_vmx_path = var.template_vmx_path
  vm_output_dir     = "${var.vm_output_dir_root}/kafka-connect-2"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_kafka_connect_2_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_kafka_connect_2_secondary
}

# ─── ksqlDB cluster (2) -- 0.H.4 ──────────────────────────────────────────
module "ksqldb_1" {
  source = "../../modules/vm"
  count  = var.enable_kafka_cluster && var.enable_ksqldb && var.enable_ksqldb_1 ? 1 : 0

  vm_name           = "ksqldb-1"
  template_vmx_path = var.template_vmx_path
  vm_output_dir     = "${var.vm_output_dir_root}/ksqldb-1"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_ksqldb_1_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_ksqldb_1_secondary
}

module "ksqldb_2" {
  source = "../../modules/vm"
  count  = var.enable_kafka_cluster && var.enable_ksqldb && var.enable_ksqldb_2 ? 1 : 0

  vm_name           = "ksqldb-2"
  template_vmx_path = var.template_vmx_path
  vm_output_dir     = "${var.vm_output_dir_root}/ksqldb-2"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_ksqldb_2_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_ksqldb_2_secondary
}

# ─── MirrorMaker 2 (2, bidirectional DR) -- 0.H.5 ─────────────────────────
module "mm2_1" {
  source = "../../modules/vm"
  count  = var.enable_kafka_cluster && var.enable_mm2 && var.enable_mm2_1 ? 1 : 0

  vm_name           = "mm2-1"
  template_vmx_path = var.template_vmx_path
  vm_output_dir     = "${var.vm_output_dir_root}/mm2-1"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_mm2_1_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_mm2_1_secondary
}

module "mm2_2" {
  source = "../../modules/vm"
  count  = var.enable_kafka_cluster && var.enable_mm2 && var.enable_mm2_2 ? 1 : 0

  vm_name           = "mm2-2"
  template_vmx_path = var.template_vmx_path
  vm_output_dir     = "${var.vm_output_dir_root}/mm2-2"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_mm2_2_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_mm2_2_secondary
}
