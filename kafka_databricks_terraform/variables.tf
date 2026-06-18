variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Resource name prefix"
  type        = string
  default     = "test"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.medium"
}

variable "key_name" {
  description = "EC2 Key Pair name (must exist in AWS)"
  type        = string
}

variable "volume_size" {
  description = "Root EBS volume size (GB)"
  type        = number
  default     = 30
}

variable "allowed_cidr" {
  description = "CIDR allowed for SSH and Kafka access"
  type        = string
  default     = "0.0.0.0/0"
}
