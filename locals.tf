locals {
  network_id = yandex_vpc_network.this.id

  subnet_id   = yandex_vpc_subnet.this[var.zone].id
  subnet_zone = yandex_vpc_subnet.this[var.zone].zone

  # Bootstrap-хост Kafka и REST-эндпоинт Karapace (managed schema registry)
  # доступны на одном и том же broker-хосте. В кластере есть хосты ZooKeeper,
  # которые не слушают 9091/443, поэтому выбираем именно брокер (role=KAFKA).
  kafka_host = sort([
    for h in yandex_mdb_kafka_cluster.this.host : h.name
    if h.role == "KAFKA"
  ])[0]
  schema_registry_url = "https://${local.kafka_host}:443"

  # Список брокеров (только role=KAFKA) для kafbat-ui. UI ходит по
  # SASL_PLAINTEXT на порт 9092, как в соседнем проекте sentry-v29-yc-k8s-elastic.
  kafka_ui_bootstrap = join(",", [
    for h in yandex_mdb_kafka_cluster.this.host : "${h.name}:9092"
    if h.role == "KAFKA"
  ])

  # Публичный IP балансировщика Traefik и FQDN kafbat-ui через sslip.io.
  ingress_public_ip = yandex_vpc_address.ingress.external_ipv4_address[0].address
  kafka_ui_fqdn     = "kafka-ui.${local.ingress_public_ip}.sslip.io"
}
