# Создание сервисного аккаунта для управления Kubernetes
resource "yandex_iam_service_account" "sa_k8s_editor" {
  folder_id = var.folder_id
  name      = "schema-registry-forbidden-sa-k8s-editor"
}

# Назначение роли "editor" сервисному аккаунту на уровне папки
resource "yandex_resourcemanager_folder_iam_member" "sa_k8s_editor_permissions" {
  folder_id = var.folder_id
  role      = "editor"
  member    = "serviceAccount:${yandex_iam_service_account.sa_k8s_editor.id}"
}

# Пауза, чтобы изменения IAM успели примениться до создания кластера
resource "time_sleep" "wait_sa" {
  create_duration = "20s"
  depends_on = [
    yandex_iam_service_account.sa_k8s_editor,
    yandex_resourcemanager_folder_iam_member.sa_k8s_editor_permissions,
  ]
}

# Создание Kubernetes-кластера в Yandex Cloud
resource "yandex_kubernetes_cluster" "this" {
  name       = "schema-registry-forbidden"
  folder_id  = var.folder_id
  network_id = local.network_id

  master {
    version   = var.k8s_version
    public_ip = true

    regional {
      region = "ru-central1"
      location {
        zone      = local.subnet_zone
        subnet_id = local.subnet_id
      }
    }

    security_group_ids = [yandex_vpc_security_group.k8s.id]
  }

  service_account_id      = yandex_iam_service_account.sa_k8s_editor.id
  node_service_account_id = yandex_iam_service_account.sa_k8s_editor.id
  release_channel         = "STABLE"

  depends_on = [
    time_sleep.wait_sa,
  ]
}

# Группа узлов кластера
resource "yandex_kubernetes_node_group" "this" {
  description = "Node group for the Managed Service for Kubernetes cluster"
  name        = "schema-registry-forbidden-node-group"
  cluster_id  = yandex_kubernetes_cluster.this.id
  version     = var.k8s_version

  scale_policy {
    fixed_scale {
      size = var.k8s_node_count
    }
  }

  allocation_policy {
    location { zone = local.subnet_zone }
  }

  instance_template {
    platform_id = "standard-v3"

    # Прерываемые ноды для снижения стоимости стенда
    scheduling_policy {
      preemptible = true
    }

    network_interface {
      nat                = false # Публичные IP на нодах выключены; исходящий трафик через NAT-шлюз (см. net.tf)
      subnet_ids         = [local.subnet_id]
      security_group_ids = [yandex_vpc_security_group.k8s.id, yandex_vpc_security_group.kafka.id]
    }

    resources {
      cores  = 2
      memory = 4
    }

    boot_disk {
      type = "network-hdd"
      size = 33
    }
  }
}

# --- Outputs -----------------------------------------------------------------

output "k8s_cluster_credentials_command" {
  value = "yc managed-kubernetes cluster get-credentials --id ${yandex_kubernetes_cluster.this.id} --external --force"
}

output "kafka_bootstrap" {
  description = "Bootstrap host for Kafka clients"
  value       = local.kafka_host
}

output "schema_registry_url" {
  description = "Managed Schema Registry (Karapace) REST endpoint"
  value       = local.schema_registry_url
}

output "kafka_user" {
  value = var.kafka_user
}

output "k8s_cluster_id" {
  value = yandex_kubernetes_cluster.this.id
}
