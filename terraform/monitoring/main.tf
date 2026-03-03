terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

# ---------------------------------------------------------------------------
# Remote State: Network
# ---------------------------------------------------------------------------

data "terraform_remote_state" "network" {
  backend = "local"
  config = {
    path = "../state/network.tfstate"
  }
}

# ---------------------------------------------------------------------------
# Grafana Admin Password
# ---------------------------------------------------------------------------

resource "random_password" "grafana_admin" {
  length           = 24
  special          = true
  override_special = "!@#$%"
}

# ---------------------------------------------------------------------------
# Amazon Linux 2023 AMI
# ---------------------------------------------------------------------------

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ---------------------------------------------------------------------------
# Security Group
# ---------------------------------------------------------------------------

resource "aws_security_group" "vmq_monitor" {
  name        = "${data.terraform_remote_state.network.outputs.project_name}-vmq-monitor"
  description = "Monitoring node (Prometheus + Grafana)"
  vpc_id      = data.terraform_remote_state.network.outputs.vpc_id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  ingress {
    description = "Prometheus"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  ingress {
    description = "Grafana"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${data.terraform_remote_state.network.outputs.project_name}-vmq-monitor"
    Project = data.terraform_remote_state.network.outputs.project_name
  }
}

# ---------------------------------------------------------------------------
# Monitoring EC2 Instance
# ---------------------------------------------------------------------------

locals {
  sysctl_user_data = <<-EOF
#!/bin/bash
cat >> /etc/sysctl.d/99-vernemq-bench.conf <<'SYSCTL'
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
fs.file-max = 2097152
fs.nr_open = 2097152
SYSCTL
sysctl --system

# Raise file descriptor limits for all users
cat >> /etc/security/limits.d/99-vernemq.conf <<'LIMITS'
*  soft  nofile  1048576
*  hard  nofile  1048576
LIMITS
EOF
}

resource "aws_instance" "monitor" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type_monitor
  key_name               = var.key_pair_name
  subnet_id              = data.terraform_remote_state.network.outputs.public_subnet_id
  vpc_security_group_ids = [aws_security_group.vmq_monitor.id]
  user_data              = local.sysctl_user_data
  ebs_optimized          = true

  root_block_device {
    volume_size           = 100
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  tags = {
    Name    = "${data.terraform_remote_state.network.outputs.project_name}-monitor"
    Role    = "monitor"
    Project = data.terraform_remote_state.network.outputs.project_name
  }
}
