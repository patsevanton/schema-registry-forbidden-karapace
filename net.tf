# VPC network and subnet shared by both the managed Kafka cluster and the
# managed Kubernetes cluster.
resource "yandex_vpc_network" "this" {
  name = "schema-registry-forbidden"
}

resource "yandex_vpc_subnet" "this" {
  name           = "schema-registry-forbidden-${var.zone}"
  zone           = var.zone
  network_id     = yandex_vpc_network.this.id
  v4_cidr_blocks = ["10.10.0.0/24"]
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

# Kafka cluster: brokers + schema registry (Karapace REST).
# The Karapace REST endpoint is exposed on the same broker hosts over 9091
# (managed schema registry). We open it only from inside the VPC so the
# producer in k8s can reach it.
resource "yandex_vpc_security_group" "kafka" {
  name       = "schema-registry-forbidden-kafka-sg"
  network_id = yandex_vpc_network.this.id

  ingress {
    description    = "Kafka brokers (SASL/TLS)"
    protocol       = "TCP"
    port           = 9091
    v4_cidr_blocks = ["10.10.0.0/24"]
  }

  ingress {
    description    = "Kafka plaintext bootstrap"
    protocol       = "TCP"
    port           = 9092
    v4_cidr_blocks = ["10.10.0.0/24"]
  }

  egress {
    description    = "allow all outbound"
    protocol       = "ANY"
    from_port      = 0
    to_port        = 65535
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

# Kubernetes node group + master egress.
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
    v4_cidr_blocks = ["10.10.0.0/24"]
  }

  ingress {
    description    = "node-to-node"
    protocol       = "ANY"
    from_port      = 0
    to_port        = 65535
    v4_cidr_blocks = ["10.10.0.0/24"]
  }

  egress {
    description    = "allow all outbound"
    protocol       = "ANY"
    from_port      = 0
    to_port        = 65535
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}
