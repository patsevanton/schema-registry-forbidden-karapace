variable "folder_id" {
  description = "ID каталога Yandex Cloud"
  type        = string
}

variable "zone" {
  description = "Зона доступности (NAT public IP, k8s master/node group)"
  type        = string
  default     = "ru-central1-a"
}

variable "zones" {
  description = "Availability zones for the multi-host Kafka cluster (ZooKeeper subcluster)"
  type        = list(string)
  default     = ["ru-central1-a", "ru-central1-b", "ru-central1-d"]
}

variable "kafka_version" {
  description = "Версия сервера Kafka"
  type        = string
  default     = "3.9"
}

variable "kafka_schema_service_user" {
  description = "Имя пользователя сервисного аккаунта Kafka (принципал basic-auth)"
  type        = string
  default     = "schema-service"
}

variable "kafka_schema_service_password" {
  description = "Пароль сервисного аккаунта Kafka (SASL + basic auth в schema registry)"
  type        = string
  sensitive   = true
}

variable "kafbat_ui_admin_user" {
  description = "Имя админ-пользователя Kafka для kafbat-ui (доступ ACCESS_ROLE_ADMIN)"
  type        = string
  default     = "kafka-ui"
}

variable "kafbat_ui_admin_password" {
  description = "Пароль админ-пользователя Kafka для kafbat-ui"
  type        = string
  sensitive   = true
}

variable "topic" {
  description = "Имя топика, в который публикует продюсер"
  type        = string
  default     = "checkout.order.created.v2"
}

variable "k8s_version" {
  description = "Версия Managed Kubernetes"
  type        = string
  default     = "1.33"
}

variable "k8s_node_count" {
  description = "Количество узлов в единственной группе узлов"
  type        = number
  default     = 1
}
