variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-2"
}

variable "name" {
  description = "Resource name prefix"
  type        = string
  default     = "test"
}

# ─── Databricks 계정 정보 ─────────────────────────────────────
variable "databricks_account_id" {
  description = "Databricks Account ID (accounts.cloud.databricks.com > Account ID)"
  type        = string
}

variable "databricks_client_id" {
  description = "Databricks Service Principal Client ID"
  type        = string
}

variable "databricks_client_secret" {
  description = "Databricks Service Principal Client Secret"
  type        = string
  sensitive   = true
}

# ─── Kafka 연결 정보 ──────────────────────────────────────────
variable "kafka_bootstrap_servers" {
  description = "Kafka bootstrap servers (EC2 public IP:9092)"
  type        = string
}

variable "kafka_topic" {
  description = "Kafka topic to consume"
  type        = string
  default     = "raw-events"
}
