variable "aws_region" {
  description = "AWS region for benchmark infrastructure"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use"
  type        = string
  default     = "default"
}

variable "project_name" {
  description = "Project name used for resource tagging"
  type        = string
  default     = "vernemq-bench"
}

variable "instance_type_vmq" {
  description = "EC2 instance type for VerneMQ nodes"
  type        = string
  default     = "c6i.2xlarge"
}

variable "instance_type_bench" {
  description = "EC2 instance type for benchmark client nodes"
  type        = string
  default     = "c6i.2xlarge"
}

variable "vmq_node_count" {
  description = "Number of VerneMQ cluster nodes"
  type        = number
  default     = 3

  validation {
    condition     = var.vmq_node_count >= 1 && var.vmq_node_count <= 50
    error_message = "vmq_node_count must be between 1 and 50."
  }
}

variable "bench_node_count" {
  description = "Number of benchmark client nodes"
  type        = number
  default     = 1

  validation {
    condition     = var.bench_node_count >= 1 && var.bench_node_count <= 20
    error_message = "bench_node_count must be between 1 and 20."
  }
}

variable "key_pair_name" {
  description = "AWS key pair name for SSH access"
  type        = string

  validation {
    condition     = length(var.key_pair_name) > 0
    error_message = "key_pair_name is required. Set it in shared.tfvars."
  }
}

variable "enable_lb" {
  description = "Deploy an internal NLB for MQTT load balancing"
  type        = bool
  default     = false
}

variable "enable_auth" {
  description = "Generate MQTT credentials for benchmark authentication"
  type        = bool
  default     = true
}

variable "bench_username" {
  description = "MQTT username for benchmark clients"
  type        = string
  default     = "benchuser"
}
