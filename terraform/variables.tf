variable "folder_id" {
  description = "Yandex Cloud folder ID"
  type        = string
}

variable "cloud_id" {
  description = "Yandex Cloud cloud ID"
  type        = string
}

variable "zone" {
  description = "Availability zone"
  type        = string
  default     = "ru-central1-a"
}

variable "kafka_version" {
  description = "Kafka server version"
  type        = string
  default     = "3.5"
}

variable "kafka_user" {
  description = "Kafka service account username (basic-auth principal)"
  type        = string
  default     = "schema-service"
}

variable "kafka_password" {
  description = "Kafka service account password (SASL + schema-registry basic auth)"
  type        = string
  sensitive   = true
}

variable "topic" {
  description = "Topic name the producer publishes to"
  type        = string
  default     = "checkout.order.created.v2"
}

variable "k8s_version" {
  description = "Managed Kubernetes version"
  type        = string
  default     = "1.30"
}

variable "k8s_node_count" {
  description = "Number of nodes in the single node group"
  type        = number
  default     = 1
}

variable "k8s_sa_id" {
  description = "Service account ID used by the Kubernetes node group (roles: container-registry, k8s.clusters.agent)"
  type        = string
}
