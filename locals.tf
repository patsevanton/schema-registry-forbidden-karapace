locals {
  network_id = yandex_vpc_network.this.id

  subnet_id   = yandex_vpc_subnet.this[var.zone].id
  subnet_zone = yandex_vpc_subnet.this[var.zone].zone

  # Bootstrap-хост Kafka и REST-эндпоинт Karapace (managed schema registry)
  # доступны на одном и том же broker-хосте.
  kafka_host          = one(yandex_mdb_kafka_cluster.this.host).name
  schema_registry_url = "https://${local.kafka_host}:443"
}
