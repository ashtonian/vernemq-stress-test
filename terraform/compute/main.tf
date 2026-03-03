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
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

# ---------------------------------------------------------------------------
# Remote State
# ---------------------------------------------------------------------------

data "terraform_remote_state" "network" {
  backend = "local"
  config = {
    path = "../state/network.tfstate"
  }
}

data "terraform_remote_state" "monitoring" {
  backend = "local"
  config = {
    path = "../state/monitoring.tfstate"
  }
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
# User data: sysctl tuning for high-connection MQTT workloads
# ---------------------------------------------------------------------------

locals {
  sysctl_user_data = <<-EOF
#!/bin/bash
cat >> /etc/sysctl.d/99-vernemq-bench.conf <<'SYSCTL'
# File descriptor limits
fs.file-max = 2097152
fs.nr_open = 2097152

# TCP connection backlog
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 16384

# TCP buffer auto-tuning (small defaults for many-connection MQTT workloads)
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.optmem_max = 16777216
net.ipv4.tcp_rmem = 4096 16384 16777216
net.ipv4.tcp_wmem = 4096 16384 16777216

# Ephemeral ports and TIME_WAIT recycling
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 1048576
SYSCTL
sysctl --system

# Raise conntrack limit (AWS EC2 loads nf_conntrack by default)
if modinfo nf_conntrack &>/dev/null; then
    echo 'net.nf_conntrack_max = 1048576' >> /etc/sysctl.d/99-vernemq-bench.conf
    sysctl -w net.nf_conntrack_max=1048576 2>/dev/null || true
fi

# Raise file descriptor limits for all users
cat >> /etc/security/limits.d/99-vernemq.conf <<'LIMITS'
*  soft  nofile  1048576
*  hard  nofile  1048576
LIMITS
EOF

  ws_suffix          = terraform.workspace == "default" ? "" : "-${terraform.workspace}"
  inventory_filename = terraform.workspace == "default" ? "hosts" : "hosts-${terraform.workspace}"
}

# ---------------------------------------------------------------------------
# Security Groups
# ---------------------------------------------------------------------------

resource "aws_security_group" "vmq_cluster" {
  name        = "${var.project_name}-vmq-cluster${local.ws_suffix}"
  description = "VerneMQ cluster nodes"
  vpc_id      = data.terraform_remote_state.network.outputs.vpc_id

  # SSH from monitor bastion
  ingress {
    description     = "SSH from monitor"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [data.terraform_remote_state.monitoring.outputs.monitor_security_group_id]
  }

  # Allow all traffic within the security group
  ingress {
    description = "All intra-cluster"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  # Allow MQTT from bench nodes
  ingress {
    description     = "MQTT from bench"
    from_port       = 1883
    to_port         = 1883
    protocol        = "tcp"
    security_groups = [aws_security_group.vmq_bench.id]
  }

  # Allow metrics scraping from monitor
  ingress {
    description     = "Metrics from monitor"
    from_port       = 8888
    to_port         = 8888
    protocol        = "tcp"
    security_groups = [data.terraform_remote_state.monitoring.outputs.monitor_security_group_id]
  }

  ingress {
    description     = "Node exporter from monitor"
    from_port       = 9100
    to_port         = 9100
    protocol        = "tcp"
    security_groups = [data.terraform_remote_state.monitoring.outputs.monitor_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-vmq-cluster${local.ws_suffix}"
    Project = var.project_name
  }
}

resource "aws_security_group" "vmq_bench" {
  name        = "${var.project_name}-vmq-bench${local.ws_suffix}"
  description = "Benchmark client nodes"
  vpc_id      = data.terraform_remote_state.network.outputs.vpc_id

  ingress {
    description     = "SSH from monitor"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [data.terraform_remote_state.monitoring.outputs.monitor_security_group_id]
  }

  # Allow node exporter scraping from monitor
  ingress {
    description     = "Node exporter from monitor"
    from_port       = 9100
    to_port         = 9100
    protocol        = "tcp"
    security_groups = [data.terraform_remote_state.monitoring.outputs.monitor_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-vmq-bench${local.ws_suffix}"
    Project = var.project_name
  }
}

# ---------------------------------------------------------------------------
# VerneMQ Cluster Nodes
# ---------------------------------------------------------------------------

resource "aws_instance" "vmq" {
  count = var.vmq_node_count

  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type_vmq
  key_name               = var.key_pair_name
  subnet_id              = data.terraform_remote_state.network.outputs.private_subnet_id
  vpc_security_group_ids = [aws_security_group.vmq_cluster.id]
  placement_group        = data.terraform_remote_state.network.outputs.placement_group_name
  user_data              = local.sysctl_user_data
  ebs_optimized          = true

  root_block_device {
    volume_size           = 50
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  tags = {
    Name    = "${var.project_name}-vmq${local.ws_suffix}-${count.index + 1}"
    Role    = "vernemq"
    Index   = count.index + 1
    Cluster = terraform.workspace
    Project = var.project_name
  }
}

# ---------------------------------------------------------------------------
# Benchmark Client Nodes
# ---------------------------------------------------------------------------

resource "aws_instance" "bench" {
  count = var.bench_node_count

  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type_bench
  key_name               = var.key_pair_name
  subnet_id              = data.terraform_remote_state.network.outputs.private_subnet_id
  vpc_security_group_ids = [aws_security_group.vmq_bench.id]
  user_data              = local.sysctl_user_data
  ebs_optimized          = true

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  tags = {
    Name    = "${var.project_name}-bench${local.ws_suffix}-${count.index + 1}"
    Role    = "bench"
    Index   = count.index + 1
    Cluster = terraform.workspace
    Project = var.project_name
  }
}

# ---------------------------------------------------------------------------
# MQTT Authentication Credentials
# ---------------------------------------------------------------------------

resource "random_password" "bench_mqtt_password" {
  count   = var.enable_auth ? 1 : 0
  length  = 24
  special = false
}

# ---------------------------------------------------------------------------
# Network Load Balancer (optional)
# ---------------------------------------------------------------------------

resource "aws_lb" "vmq" {
  count              = var.enable_lb ? 1 : 0
  name               = substr("${var.project_name}-vmq-nlb${local.ws_suffix}", 0, 32)
  internal           = true
  load_balancer_type = "network"
  subnets            = [data.terraform_remote_state.network.outputs.private_subnet_id]

  tags = {
    Name    = "${var.project_name}-vmq-nlb${local.ws_suffix}"
    Project = var.project_name
  }
}

resource "aws_lb_target_group" "vmq_mqtt" {
  count    = var.enable_lb ? 1 : 0
  name     = substr("${var.project_name}-mqtt${local.ws_suffix}", 0, 32)
  port     = 1883
  protocol = "TCP"
  vpc_id   = data.terraform_remote_state.network.outputs.vpc_id

  health_check {
    protocol = "TCP"
    port     = 1883
  }

  tags = {
    Project = var.project_name
  }
}

resource "aws_lb_target_group_attachment" "vmq" {
  count            = var.enable_lb ? var.vmq_node_count : 0
  target_group_arn = aws_lb_target_group.vmq_mqtt[0].arn
  target_id        = aws_instance.vmq[count.index].id
  port             = 1883
}

resource "aws_lb_listener" "vmq_mqtt" {
  count             = var.enable_lb ? 1 : 0
  load_balancer_arn = aws_lb.vmq[0].arn
  port              = 1883
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.vmq_mqtt[0].arn
  }
}

# ---------------------------------------------------------------------------
# Generate Ansible inventory from template
# ---------------------------------------------------------------------------

resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/templates/inventory.tpl", {
    vmq_nodes          = aws_instance.vmq
    bench_nodes        = aws_instance.bench
    monitor_ip         = data.terraform_remote_state.monitoring.outputs.monitor_public_ip
    lb_enabled         = var.enable_lb
    lb_dns_name        = var.enable_lb ? aws_lb.vmq[0].dns_name : ""
    auth_enabled       = var.enable_auth
    bench_mqtt_username = var.enable_auth ? var.bench_username : ""
    bench_mqtt_password = var.enable_auth ? random_password.bench_mqtt_password[0].result : ""
  })
  filename = "${path.module}/../../ansible/inventory/${local.inventory_filename}"
}
