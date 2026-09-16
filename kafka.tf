# --- Managed Kafka (MDB) -----------------------------------------------------

resource "yandex_mdb_kafka_cluster" "this" {
  name                = "schema-registry-forbidden"
  environment         = "PRODUCTION"
  network_id          = yandex_vpc_network.this.id
  subnet_ids          = [yandex_vpc_subnet.this.id]
  security_group_ids  = [yandex_vpc_security_group.kafka.id]
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
        disk_type_id       = "network-hdd"
        disk_size          = 32
      }
      kafka_config {
        # The real ACL bug: the producer (and its generator) expects to be able
        # to read per-subject /config before create. Whether it may or may not
        # depends on the roles granted below.
        sasl_enabled_mechanisms    = ["SASL_MECHANISM_SCRAM_SHA_512"]
        num_partitions             = 1
        default_replication_factor = "1"
        auto_create_topics_enable  = true
      }
    }

    zookeeper {
      resources {
        resource_preset_id = "s2.micro"
        disk_type_id       = "network-hdd"
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
