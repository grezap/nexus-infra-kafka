# envs/kafka -- outputs + operator next-step crib.

output "kafka_east_ips" {
  description = "Canonical VMnet11 / VMnet10 IPs for the kafka-east KRaft cluster."
  value = {
    kafka_east_1 = { vmnet11 = "192.168.70.21", vmnet10 = "192.168.10.21" }
    kafka_east_2 = { vmnet11 = "192.168.70.22", vmnet10 = "192.168.10.22" }
    kafka_east_3 = { vmnet11 = "192.168.70.23", vmnet10 = "192.168.10.23" }
  }
}

output "kafka_west_ips" {
  description = "Canonical VMnet11 / VMnet10 IPs for the kafka-west KRaft cluster (DR)."
  value = {
    kafka_west_1 = { vmnet11 = "192.168.70.24", vmnet10 = "192.168.10.24" }
    kafka_west_2 = { vmnet11 = "192.168.70.25", vmnet10 = "192.168.10.25" }
    kafka_west_3 = { vmnet11 = "192.168.70.26", vmnet10 = "192.168.10.26" }
  }
}

output "kafka_broker_vm_paths" {
  description = "Filesystem paths of every running kafka broker clone's .vmx (the ones enabled this apply)."
  value = merge(
    length(module.kafka_east_1) > 0 ? { kafka_east_1 = module.kafka_east_1[0].vm_path } : {},
    length(module.kafka_east_2) > 0 ? { kafka_east_2 = module.kafka_east_2[0].vm_path } : {},
    length(module.kafka_east_3) > 0 ? { kafka_east_3 = module.kafka_east_3[0].vm_path } : {},
    length(module.kafka_west_1) > 0 ? { kafka_west_1 = module.kafka_west_1[0].vm_path } : {},
    length(module.kafka_west_2) > 0 ? { kafka_west_2 = module.kafka_west_2[0].vm_path } : {},
    length(module.kafka_west_3) > 0 ? { kafka_west_3 = module.kafka_west_3[0].vm_path } : {},
  )
}

output "next_step" {
  description = "Operator crib -- what to do once apply is green."
  value       = <<-EOT
    Phase 0.H.1 (if smoke-0.H.1.ps1 is green): two 3-node KRaft clusters
    live -- kafka-east + kafka-west. Combined broker+controller mode,
    PLAINTEXT listeners on the VMnet10 backplane, replication factor 3.

    Verify each cluster has an elected controller quorum + RF=3 round-trip
    (from any broker -- env vars in /etc/profile.d, or use the full path):

      ssh nexusadmin@192.168.70.21
      /opt/kafka/bin/kafka-metadata-quorum.sh \
        --bootstrap-server localhost:9092 describe --status
      # ^ LeaderId set, 3 CurrentVoters, 0 CurrentObservers

      /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
        --create --topic smoke --partitions 3 --replication-factor 3
      echo "hello-east" | /opt/kafka/bin/kafka-console-producer.sh \
        --bootstrap-server localhost:9092 --topic smoke
      /opt/kafka/bin/kafka-console-consumer.sh \
        --bootstrap-server localhost:9092 --topic smoke \
        --from-beginning --timeout-ms 10000

    Run the chained smoke gate:

      pwsh -File scripts/kafka.ps1 smoke

    Iterating?
      pwsh -File scripts/kafka.ps1 cycle                                   # destroy + apply + smoke
      pwsh -File scripts/kafka.ps1 apply -Vars enable_kafka_west=false      # bring up only the east cluster
      pwsh -File scripts/kafka.ps1 apply -Vars enable_broker_config=false   # clones + KRaft format only, no broker start

    Forward direction (subsequent sub-phases):
      0.H.2 = Vault PKI kafka-broker role + per-node Vault Agents + broker
              mTLS (inter-broker + controller-quorum + client SSL listener)
      0.H.3 = Schema Registry x2 + REST Proxy
      0.H.4 = Kafka Connect x2 + Debezium + ksqlDB x2
      0.H.5 = MirrorMaker 2 x2 + the phase exit gate
              (produce east -> appears west)
      0.H.6 = close-out canon batch + cold-rebuild proof; tag v0.1.0
  EOT
}
