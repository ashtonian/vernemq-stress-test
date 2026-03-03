variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile with IAM admin permissions (used only during bootstrap)"
  type        = string
  default     = "default"
}

variable "project_name" {
  description = "Project name used for resource tagging"
  type        = string
  default     = "vernemq-bench"
}

variable "iam_user_name" {
  description = "Name for the IAM operator user"
  type        = string
  default     = "vernemq-bench-operator"
}
