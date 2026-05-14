/*
 * kafka-node — NexusPlatform Kafka ecosystem node template (Phase 0.H.1)
 *
 * Fifteen instances of this template clone into the 03-kafka tier per
 * nexus-platform-plan/docs/infra/vms.yaml lines 84-112:
 *
 *   - kafka-east-1/2/3   — KRaft broker+controller (primary cluster)
 *   - kafka-west-1/2/3   — KRaft broker+controller (DR cluster)
 *   - schema-registry-1/2 — Confluent Schema Registry primary/replica
 *   - kafka-connect-1/2   — Kafka Connect distributed + Debezium
 *   - ksqldb-1/2          — ksqlDB primary/replica
 *   - mm2-1/2             — MirrorMaker 2 (east->west / west->east)
 *   - kafka-rest-1        — Confluent REST Proxy
 *
 *   - OS: Debian 13 (same ISO + preseed pattern as deb13 + vault + swarm-node)
 *   - Brokers: 4 vCPU / 8 GB / 200 GB; ecosystem nodes 2 vCPU / 2-8 GB /
 *     30-60 GB (vmrun-resized at clone time by terraform/envs/kafka/).
 *   - Dual-NIC at clone time: ethernet0 = VMnet11 (service); ethernet1 =
 *     VMnet10 (cluster backplane — KRaft controller quorum + inter-broker
 *     replication + MM2 cross-cluster traffic).
 *
 * Build-time vs clone-time vs first-boot:
 *   - Build-time (this template): single NAT NIC for apt + tarball fetch,
 *     then `vmx_remove_ethernet_interfaces = true` strips it. Temurin JDK
 *     21 + Apache Kafka 3.8.1 (brokers + connect-mirror-maker) + Confluent
 *     Community 7.7.1 (Schema Registry / Connect / ksqlDB / REST Proxy)
 *     downloaded + verified + installed. All role systemd units delivered
 *     DISABLED — first-boot does NIC/identity only; the Terraform role-
 *     overlays render config + enable exactly one role's service.
 *   - Clone-time (terraform/modules/vm): scripts/configure-vm-nic.ps1
 *     writes ethernet0 (VMnet11) + ethernet1 (VMnet10) post-clone.
 *   - First-boot (kafka-node-firstboot.service ExecStart): MAC-OUI-byte-5
 *     NIC discovery (same pattern as swarm-node-firstboot.sh); maps the
 *     VMnet11 IP to canonical hostname + VMnet10 backplane IP + role +
 *     cluster (east/west for brokers); writes /etc/hosts; configures the
 *     VMnet10 static IP; writes /etc/nexus-kafka/node-identity.env for the
 *     Terraform overlays to source. It does NOT touch any Kafka service —
 *     KRaft formatting needs a per-cluster UUID generated at Terraform time.
 *   - Cluster bring-up (terraform/envs/kafka/role-overlay-*.tf): kraft-
 *     format generates one cluster UUID per cluster + formats each node's
 *     log dir; broker-config renders server.properties + starts kafka.service.
 *
 * Build:   cd packer/kafka-node; packer init .; packer build .
 * See:     docs/handbook.md
 */

packer {
  required_version = ">= 1.11.0"
  required_plugins {
    vmware = {
      version = ">= 1.0.11"
      source  = "github.com/hashicorp/vmware"
    }
    ansible = {
      version = ">= 1.1.1"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

# ─── Source: Debian 13 netinst, VMware Workstation builder ────────────────
source "vmware-iso" "kafka-node" {
  vm_name          = var.vm_name
  output_directory = var.output_directory

  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  guest_os_type = "debian12-64" # Workstation catalog lags; compatible with Debian 13
  cpus          = var.cpus
  memory        = var.memory_mb
  disk_size     = var.disk_gb * 1024
  disk_type_id  = 0 # growable single-file VMDK

  # Single NAT NIC at build time -- Terraform's modules/vm attaches the real
  # dual-NIC config (VMnet11 + VMnet10) at clone time.
  network_adapter_type = "vmxnet3"
  network              = "nat"

  version = "20" # WS 17+ hw version

  http_directory = "http"
  boot_wait      = var.boot_wait
  boot_command = [
    "<esc><wait>",
    "auto ",
    "url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg ",
    "language=en country=US locale=en_US.UTF-8 keymap=us ",
    "hostname=${var.vm_name} domain=nexus.local ",
    "priority=critical ",
    "interface=auto ",
    "<enter>"
  ]

  communicator           = "ssh"
  ssh_username           = var.ssh_username
  ssh_password           = var.ssh_password
  ssh_timeout            = var.ssh_timeout
  ssh_handshake_attempts = 200

  shutdown_command = "echo '${var.ssh_password}' | sudo -S -E shutdown -P now"
  shutdown_timeout = "5m"

  headless        = true
  skip_compaction = false

  # Strip all ethernet*.* lines so Terraform's modules/vm can write the
  # dual-NIC config cleanly post-clone.
  vmx_remove_ethernet_interfaces = true

  vmx_data = {
    "annotation"           = "kafka-node template (Phase 0.H.1) -- built by Packer; Temurin JDK ${var.jdk_major}, Apache Kafka ${var.kafka_version}, Confluent Community ${var.confluent_version}"
    "tools.upgrade.policy" = "useGlobal"
  }
}

# ─── Build: install OS + JDK + Kafka + Confluent + apply shared roles ─────
build {
  name    = "kafka-node"
  sources = ["source.vmware-iso.kafka-node"]

  # Stage static config files the shared roles + kafka_node role expect
  provisioner "file" {
    source      = "files/nftables.conf"
    destination = "/tmp/nftables.conf"
  }
  provisioner "file" {
    source      = "files/chrony.conf"
    destination = "/tmp/chrony.conf"
  }

  provisioner "shell" {
    inline = [
      "echo 'Waiting for systemd to settle...'",
      "sudo systemctl is-system-running --wait || true",
      "echo 'Installing Ansible + prerequisites...'",
      "sudo apt-get update -qq",
      "sudo apt-get install -y -qq python3 python3-apt sudo ansible curl ca-certificates gnupg openssl jq unzip"
    ]
  }

  # Apply the shared nexus_* roles + the kafka_node tail.
  # extra_arguments per-pair to avoid the shell-tokenization issue
  # documented in nexus-infra-swarm-nomad/packer/swarm-node/swarm-node.pkr.hcl.
  provisioner "ansible-local" {
    playbook_file = "ansible/playbook.yml"
    role_paths = [
      "../_shared/ansible/roles/nexus_identity",
      "../_shared/ansible/roles/nexus_network",
      "../_shared/ansible/roles/nexus_firewall",
      "../_shared/ansible/roles/nexus_observability",
      "ansible/roles/kafka_node",
    ]
    extra_arguments = [
      "--extra-vars", "target_user=${var.ssh_username}",
      "--extra-vars", "jdk_apt_channel=${var.jdk_apt_channel}",
      "--extra-vars", "jdk_major=${var.jdk_major}",
      "--extra-vars", "kafka_version=${var.kafka_version}",
      "--extra-vars", "kafka_scala_version=${var.kafka_scala_version}",
      "--extra-vars", "confluent_version=${var.confluent_version}",
    ]
  }

  # Final sanity + cleanup.
  # Service-state checks only -- no FS-permission-sensitive probes (Kafka
  # data dirs are 0700 owned by the kafka user; nexusadmin can't traverse).
  provisioner "shell" {
    inline = [
      "echo '--- kafka-node post-install checks ---'",
      "test -x /opt/kafka/bin/kafka-server-start.sh",
      "test -x /opt/kafka/bin/kafka-storage.sh",
      "test -x /opt/kafka/bin/connect-mirror-maker.sh",
      "test -d /opt/confluent/bin",
      "java -version",
      "/opt/kafka/bin/kafka-topics.sh --version",
      # All role units are INTENTIONALLY DISABLED at template time -- the
      # template has no IP/role/cluster-UUID yet. firstboot writes the
      # identity env file; Terraform role-overlays render config + enable
      # exactly one. `systemctl cat` exits 0 if the unit file exists in any
      # lookup path regardless of enable-state.
      "systemctl cat kafka.service > /dev/null",
      "systemctl cat schema-registry.service > /dev/null",
      "systemctl cat connect-distributed.service > /dev/null",
      "systemctl cat ksqldb-server.service > /dev/null",
      "systemctl cat kafka-rest.service > /dev/null",
      "systemctl cat mm2.service > /dev/null",
      "systemctl is-enabled kafka-node-firstboot",
      "systemctl is-enabled ssh",
      "systemctl is-enabled nftables",
      "systemctl is-enabled chrony",
      "systemctl is-enabled prometheus-node-exporter",
      "id kafka",
      "echo '--- cleanup ---'",
      "sudo apt-get clean",
      "sudo rm -rf /var/lib/apt/lists/*",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /var/lib/dbus/machine-id && sudo ln -s /etc/machine-id /var/lib/dbus/machine-id",
      "sudo rm -f /var/lib/systemd/random-seed",
      "sudo rm -f /etc/ssh/ssh_host_*", # regenerated on first boot
      "history -c || true",
      "sudo rm -f /home/${var.ssh_username}/.bash_history || true"
    ]
  }

  post-processor "manifest" {
    output     = "${var.output_directory}/packer-manifest.json"
    strip_path = true
  }
}
