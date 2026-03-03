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

variable "instance_type_monitor" {
  description = "EC2 instance type for monitoring node"
  type        = string
  default     = "c6i.xlarge"
}

variable "key_pair_name" {
  description = "AWS key pair name for SSH access"
  type        = string

  validation {
    condition     = length(var.key_pair_name) > 0
    error_message = "key_pair_name is required. Set it in shared.tfvars."
  }
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed for SSH access"
  type        = string
  default     = "0.0.0.0/0"

  validation {
    condition     = var.allowed_ssh_cidr != "0.0.0.0/0"
    error_message = "allowed_ssh_cidr must not be 0.0.0.0/0. Set it to your IP CIDR (e.g., 203.0.113.5/32)."
  }
}
