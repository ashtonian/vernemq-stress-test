variable "aws_region" {
  description = "AWS region for benchmark infrastructure"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use"
  type        = string
  default     = "home-ops-bench"
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

variable "instance_type_monitor" {
  description = "EC2 instance type for monitoring node"
  type        = string
  default     = "c6i.xlarge"
}

variable "key_pair_name" {
  description = "AWS key pair name for SSH access"
  type        = string
}

variable "vmq_node_count" {
  description = "Number of VerneMQ cluster nodes"
  type        = number
  default     = 10
}

variable "bench_node_count" {
  description = "Number of benchmark client nodes"
  type        = number
  default     = 3
}

variable "project_name" {
  description = "Project name used for resource tagging"
  type        = string
  default     = "vernemq-bench"
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed for SSH access"
  type        = string
  default     = "0.0.0.0/0"
}
