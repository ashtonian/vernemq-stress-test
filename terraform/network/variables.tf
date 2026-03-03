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

