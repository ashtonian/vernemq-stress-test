terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

# ---------------------------------------------------------------------------
# IAM User — scoped operator for vernemq-bench infrastructure
# ---------------------------------------------------------------------------

resource "aws_iam_user" "operator" {
  name = var.iam_user_name
  path = "/"

  tags = {
    Project   = var.project_name
    ManagedBy = "terraform"
  }
}

# ---------------------------------------------------------------------------
# IAM Policy — EC2/VPC/ELB permissions for all three modules
# Uses managed policy (10KB limit) instead of inline (2KB limit)
# ---------------------------------------------------------------------------

resource "aws_iam_policy" "operator" {
  name        = "${var.project_name}-operator-policy"
  description = "EC2, VPC, and ELB permissions for vernemq-bench infrastructure"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EC2VPC"
        Effect   = "Allow"
        Action   = ["ec2:*"]
        Resource = "*"
      },
      {
        Sid      = "ELB"
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:*"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_user_policy_attachment" "operator" {
  user       = aws_iam_user.operator.name
  policy_arn = aws_iam_policy.operator.arn
}

# ---------------------------------------------------------------------------
# Access Key — programmatic credentials
# ---------------------------------------------------------------------------

resource "aws_iam_access_key" "operator" {
  user = aws_iam_user.operator.name
}
