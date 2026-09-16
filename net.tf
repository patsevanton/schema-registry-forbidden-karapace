# VPC-сеть и подсеть, общие для managed Kafka-кластера и managed Kubernetes-кластера.
resource "yandex_vpc_network" "this" {
  name = "schema-registry-forbidden"
}

resource "yandex_vpc_subnet" "this" {
  for_each = toset(var.zones)

  name           = "schema-registry-forbidden-${each.key}"
  zone           = each.key
  network_id     = yandex_vpc_network.this.id
  v4_cidr_blocks = [cidrsubnet("10.10.0.0/16", 8, index(var.zones, each.key))]
  route_table_id = yandex_vpc_route_table.rt.id # Исходящий трафик через NAT-шлюз
}

# Публичный IP-адрес для NAT-шлюза
resource "yandex_vpc_address" "nat" {
  name = "schema-registry-forbidden-nat-pip"
  external_ipv4_address {
    zone_id = var.zone
  }
}

# NAT-шлюз для исходящего трафика из приватной подсети
resource "yandex_vpc_gateway" "nat" {
  name = "schema-registry-forbidden-nat-gw"
  shared_egress_gateway {}
}

# Таблица маршрутизации: весь исходящий трафик (0.0.0.0/0) направляем через NAT-шлюз
resource "yandex_vpc_route_table" "rt" {
  name       = "schema-registry-forbidden-rt-nat"
  network_id = yandex_vpc_network.this.id
  static_route {
    destination_prefix = "0.0.0.0/0"
    gateway_id         = yandex_vpc_gateway.nat.id
  }
}

# Кастомные группы безопасности не создаются: объектам явно не назначена
# ни одна SG, поэтому действует группа безопасности по умолчанию (DSG),
# автоматически создаваемая вместе с сетью и разрешающая весь входящий и
# исходящий трафик.
