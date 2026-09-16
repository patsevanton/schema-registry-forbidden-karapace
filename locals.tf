locals {
  network_id = yandex_vpc_network.this.id

  subnet_id   = yandex_vpc_subnet.this.id
  subnet_zone = yandex_vpc_subnet.this.zone

  # Kafka bootstrap host and Karapace REST endpoint (managed schema registry)
  # are exposed on the same broker host.
  kafka_host          = one(yandex_mdb_kafka_cluster.this.host).name
  schema_registry_url = "https://${local.kafka_host}:443"
}
