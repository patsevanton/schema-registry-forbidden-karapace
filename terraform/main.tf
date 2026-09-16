# VPC network and subnets shared by both the managed Kafka cluster and the
# managed Kubernetes cluster.
resource "yandex_vpc_network" "this" {
  name = "schema-registry-forbidden"
}

resource "yandex_vpc_subnet" "this" {
  name           = "schema-registry-forbidden-${var.zone}"
  zone           = var.zone
  network_id     = yandex_vpc_network.this.id
  v4_cidr_blocks = ["10.10.0.0/24"]
}

# --- Security groups ---------------------------------------------------------

# Kafka cluster: brokers + schema registry (Karapace REST).
# The Karapace REST endpoint is exposed on the same broker hosts over 9091
# (managed schema registry). We open it only from inside the VPC so the
# producer in k8s can reach it.
resource "yandex_vpc_security_group" "kafka" {
  name       = "kafka-sg"
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
  name       = "k8s-sg"
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

# --- Managed Kafka (MDB) -----------------------------------------------------

resource "yandex_mdb_kafka_cluster" "this" {
  name               = "schema-registry-forbidden"
  environment        = "PRODUCTION"
  network_id         = yandex_vpc_network.this.id
  subnet_ids         = [yandex_vpc_subnet.this.id]
  security_group_ids = [yandex_vpc_security_group.kafka.id]
  deletion_protection = false

  config {
    version       = var.kafka_version
    brokers_count = 1
    zones         = [var.zone]

    # Managed Schema Registry (Karapace). This is the REST endpoint the
    # producer talks to for schema registration.
    schema_registry = true

    kafka {
      resources {
        resource_preset_id = "s2.micro"
        disk_type_id       = "network-ssd"
        disk_size          = 32
      }
      kafka_config {
        # The real ACL bug: the producer (and its generator) expects to be able
        # to read per-subject /config before create. Whether it may or may not
        # depends on the roles granted below.
        sasl_enabled_mechanisms = ["SASL_MECHANISM_SCRAM_SHA_512"]
        num_partitions         = 1
        default_replication_factor = "1"
        auto_create_topics_enable = true
      }
    }

    zookeeper {
      resources {
        resource_preset_id = "s2.micro"
        disk_type_id       = "network-ssd"
        disk_size          = 10
      }
    }
  }
}

# Topic the producer publishes to (managed via dedicated resource, recommended).
resource "yandex_mdb_kafka_topic" "events" {
  cluster_id         = yandex_mdb_kafka_cluster.this.id
  name               = var.topic
  partitions         = 1
  replication_factor = 1
}

# Service user with a producer grant on the topic. Per Yandex docs a single
# ACCESS_ROLE_PRODUCER on the topic is enough for the {topic}-value subject,
# but Karapace REST still answers 403 on /subjects and /config unless the
# SCHEMA_* roles are granted on the subject.
resource "yandex_mdb_kafka_user" "producer" {
  cluster_id = yandex_mdb_kafka_cluster.this.id
  name       = var.kafka_user
  password   = var.kafka_password

  permission {
    topic_name = var.topic
    role       = "ACCESS_ROLE_PRODUCER"
  }

  # Subject-level schema permissions. `topic_name` holds the Schema Registry
  # subject, NOT the Kafka topic. For a value subject the name is
  # "{topic}-value".
  permission {
    topic_name = "${var.topic}-value"
    role       = "ACCESS_ROLE_SCHEMA_READER"
  }

  permission {
    topic_name = "${var.topic}-value"
    role       = "ACCESS_ROLE_SCHEMA_WRITER"
  }
}

# --- Managed Kubernetes ------------------------------------------------------

resource "yandex_kubernetes_cluster" "this" {
  name        = "schema-registry-forbidden"
  network_id  = yandex_vpc_network.this.id
  folder_id   = var.folder_id

  master {
    version   = var.k8s_version
    public_ip = true

    regional {
      region = "ru-central1"
      location {
        zone      = var.zone
        subnet_id = yandex_vpc_subnet.this.id
      }
    }

    security_group_ids = [yandex_vpc_security_group.k8s.id]
  }

  service_account_id      = var.k8s_sa_id
  node_service_account_id = var.k8s_sa_id
  release_channel         = "STABLE"
}

resource "yandex_kubernetes_node_group" "this" {
  cluster_id  = yandex_kubernetes_cluster.this.id
  name        = "default"

  instance_template {
    platform_id = "standard-v3"

    resources {
      cores  = 2
      memory = 4
    }

    boot_disk {
      size = 64
      type = "network-ssd"
    }

    network_interface {
      nat                = true
      subnet_ids         = [yandex_vpc_subnet.this.id]
      security_group_ids = [yandex_vpc_security_group.k8s.id, yandex_vpc_security_group.kafka.id]
    }

    metadata = {
      ssh-keys = ""
    }
  }

  scale_policy {
    fixed_scale {
      size = var.k8s_node_count
    }
  }
}

# --- Outputs -----------------------------------------------------------------

output "kafka_bootstrap" {
  description = "Bootstrap host for Kafka clients"
  value       = [for h in yandex_mdb_kafka_cluster.this.host : h.name]
}

output "schema_registry_url" {
  description = "Managed Schema Registry (Karapace) REST endpoint"
  value       = "https://${one(yandex_mdb_kafka_cluster.this.host).name}:443"
}

output "kafka_user" {
  value = var.kafka_user
}

output "k8s_cluster_id" {
  value = yandex_kubernetes_cluster.this.id
}
