# --- Traefik (ingress-контроллер) --------------------------------------------
#
# Ставится через Terraform, как в соседних проектах (coroot, buildkit, vlogs).
# Балансировщик получает зарезервированный публичный IP, из которого через
# sslip.io формируется FQDN kafbat-ui (см. locals.tf).

# Публичный IP для LoadBalancer Traefik.
resource "yandex_vpc_address" "ingress" {
  name = "schema-registry-forbidden-ingress-pip"

  external_ipv4_address {
    zone_id = var.zone
  }
}

# Пауза перед удалением публичного IP при terraform destroy:
# LoadBalancer, создаваемый cloud-controller-manager через Service Traefik,
# освобождает адрес не мгновенно после удаления кластера/helm-релиза.
resource "time_sleep" "wait_lb_release" {
  destroy_duration = "60s"

  depends_on = [
    yandex_vpc_address.ingress,
  ]
}

resource "helm_release" "traefik" {
  name             = "traefik"
  chart            = "traefik"
  repository       = "https://traefik.github.io/charts"
  version          = "41.5.0"
  namespace        = "traefik"
  create_namespace = true

  depends_on = [
    yandex_kubernetes_cluster.this,
    yandex_kubernetes_node_group.this,
    time_sleep.wait_lb_release,
  ]

  values = [
    yamlencode({
      image = {
        registry   = "ghcr.io"
        repository = "traefik/traefik"
      }
      service = {
        spec = {
          type           = "LoadBalancer"
          loadBalancerIP = local.ingress_public_ip
        }
      }
    })
  ]
}

output "ingress_public_ip" {
  description = "External Traefik IP"
  value       = local.ingress_public_ip
}

output "kafka_ui_fqdn" {
  description = "FQDN kafbat-ui (сформирован через sslip.io из публичного IP Traefik)"
  value       = local.kafka_ui_fqdn
}

output "kafka_ui_url" {
  description = "URL kafbat-ui за Traefik (http, TLS не настроен)"
  value       = "http://${local.kafka_ui_fqdn}"
}