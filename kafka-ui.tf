locals {
  # Values-файл kafbat-ui. Рендерится на диск, ставится вручную через helm CLI:
  # helm upgrade --install kafbat-ui kafbat-ui/kafka-ui -n kafka-ui \
  #   --create-namespace -f kafka-ui-values.yaml
  # Пароль пользователя Kafka не попадает в git (файл kafka-ui-values.yaml в .gitignore).
  kafka_ui_values = templatefile("${path.module}/kafka-ui-values.yaml.tftpl", {
    kafka_ui_bootstrap = local.kafka_ui_bootstrap
    kafka_ui_fqdn      = local.kafka_ui_fqdn
    kafka_ui_user      = var.kafka_ui_user
    kafka_ui_password  = var.kafka_ui_password
  })
}

resource "local_file" "write_kafka_ui_values" {
  content         = local.kafka_ui_values
  filename        = "${path.module}/kafka-ui-values.yaml"
  file_permission = "0600"
}