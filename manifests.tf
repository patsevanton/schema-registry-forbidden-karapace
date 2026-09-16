locals {
  # Secret с кредами Kafka/Schema Registry. Рендерится на диск, применяется
  # вручную: kubectl apply -f manifests/kafka-credentials-secret.yaml.
  # Пароль не попадает в git (terraform.tfvars в .gitignore) и в Helm values.
  kafka_secret = templatefile("${path.module}/manifests/kafka-credentials-secret.yaml.tftpl", {
    kafka_bootstrap     = local.kafka_host
    schema_registry_url = local.schema_registry_url
    kafka_user          = var.kafka_user
    kafka_password      = var.kafka_password
  })
}

resource "local_file" "write_kafka_secret" {
  content         = local.kafka_secret
  filename        = "${path.module}/manifests/kafka-credentials-secret.yaml"
  file_permission = "0600"
}
