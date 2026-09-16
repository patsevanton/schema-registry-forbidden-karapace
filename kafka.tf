# --- Managed Kafka (MDB) -----------------------------------------------------

resource "yandex_mdb_kafka_cluster" "this" {
  name                = "schema-registry-forbidden"
  environment         = "PRODUCTION"
  network_id          = yandex_vpc_network.this.id
  subnet_ids          = [for s in yandex_vpc_subnet.this : s.id]
  deletion_protection = false

  config {
    version       = var.kafka_version
    brokers_count = 1
    zones         = var.zones

    # Управляемый Schema Registry (Karapace). Это REST-эндпоинт, к которому
    # продюсер обращается для регистрации схем.
    schema_registry = true

    kafka {
      resources {
        resource_preset_id = "s2.micro"
        disk_type_id       = "network-ssd"
        disk_size          = 32
      }
      kafka_config {
        # Настоящий баг ACL: продюсер (и его генератор) ожидает, что сможет
        # прочитать per-subject /config до создания субъекта. Разрешено это
        # или нет — зависит от ролей, выданных ниже.
        sasl_enabled_mechanisms    = ["SASL_MECHANISM_SCRAM_SHA_512"]
        num_partitions             = 1
        default_replication_factor = "1"
        auto_create_topics_enable  = true
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

# Топик, в который публикует продюсер (рекомендуется управлять отдельным
# ресурсом).
resource "yandex_mdb_kafka_topic" "events" {
  cluster_id         = yandex_mdb_kafka_cluster.this.id
  name               = var.topic
  partitions         = 1
  replication_factor = 1
}

# Сервисный пользователь с правами producer на топик. Согласно документации
# Yandex, одной роли ACCESS_ROLE_PRODUCER на топик достаточно для субъекта
# {topic}-value, но Karapace REST всё равно отвечает 403 на /subjects и /config,
# пока роли SCHEMA_* не выданы и на топик, и на субъект.
resource "yandex_mdb_kafka_user" "producer" {
  cluster_id = yandex_mdb_kafka_cluster.this.id
  name       = var.kafka_schema_service_user
  password   = var.kafka_schema_service_password

  permission {
    topic_name = var.topic
    role       = "ACCESS_ROLE_PRODUCER"
  }

  # Воспроизведение 403 (см. README, «Как сломать ACL»): SCHEMA_* permissions
  # намеренно убраны. Karapace REST отвечает Forbidden на /config и /subjects,
  # пока роли ACCESS_ROLE_SCHEMA_READER/WRITER не выданы и на топик, и на
  # субъект {topic}-value.
}

# Пользователь для kafbat-ui: полный доступ ко всем топикам и схемам.
# Отдельный от продюсера, чтобы UI не зависел от урезанных прав schema-service.
resource "yandex_mdb_kafka_user" "kafka_ui" {
  cluster_id = yandex_mdb_kafka_cluster.this.id
  name       = var.kafbat_ui_admin_user
  password   = var.kafbat_ui_admin_password

  permission {
    topic_name = "*"
    role       = "ACCESS_ROLE_ADMIN"
  }
}
