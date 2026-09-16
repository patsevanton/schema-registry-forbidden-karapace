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

# --- Security groups ---------------------------------------------------------

# Kafka-кластер: брокеры + schema registry (Karapace REST).
# REST-эндпоинт Karapace (Managed Schema Registry) доступен на тех же
# broker-хостах по HTTPS на порту 443. Открываем его из группы безопасности
# k8s, чтобы продюсер в кластере мог достучаться до реестра.
resource "yandex_vpc_security_group" "kafka" {
  name       = "schema-registry-forbidden-kafka-sg"
  network_id = yandex_vpc_network.this.id

  ingress {
    description       = "Karapace REST API (Managed Schema Registry)"
    protocol          = "TCP"
    port              = 443
    security_group_id = yandex_vpc_security_group.k8s.id
  }

  ingress {
    description    = "Kafka брокеры (SASL/TLS)"
    protocol       = "TCP"
    port           = 9091
    v4_cidr_blocks = ["10.10.0.0/16"]
  }

  ingress {
    description    = "Kafka plaintext bootstrap"
    protocol       = "TCP"
    port           = 9092
    v4_cidr_blocks = ["10.10.0.0/16"]
  }

  egress {
    description    = "разрешить весь исходящий трафик"
    protocol       = "ANY"
    from_port      = 0
    to_port        = 65535
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

# Группа узлов Kubernetes + egress мастер-ноды.
resource "yandex_vpc_security_group" "k8s" {
  name       = "schema-registry-forbidden-k8s-sg"
  network_id = yandex_vpc_network.this.id

  ingress {
    description    = "K8s API"
    protocol       = "TCP"
    port           = 443
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description    = "K8s API master"
    protocol       = "TCP"
    port           = 6443
    v4_cidr_blocks = ["10.10.0.0/16"]
  }

  ingress {
    description    = "node-to-node"
    protocol       = "ANY"
    from_port      = 0
    to_port        = 65535
    v4_cidr_blocks = ["10.10.0.0/16"]
  }

  # LoadBalancer Traefik принимает трафик и проксирует его на NodePort сервисов
  # (диапазон 30000-32767). Health-check балансировщика приходит из подсетей
  # 198.18.235.0/24 и 198.18.248.0/24, поэтому без этого правила LB остаётся
  # без healthy-таргетов.
  ingress {
    description    = "LoadBalancer health check (NodePort)"
    protocol       = "TCP"
    from_port      = 30000
    to_port        = 32767
    v4_cidr_blocks = ["198.18.235.0/24", "198.18.248.0/24"]
  }

  egress {
    description    = "разрешить весь исходящий трафик"
    protocol       = "ANY"
    from_port      = 0
    to_port        = 65535
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}
