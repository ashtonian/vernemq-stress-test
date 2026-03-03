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

# ---------------------------------------------------------------------------
# VerneMQ Cluster Nodes
# ---------------------------------------------------------------------------

resource "aws_instance" "vmq" {
  count = var.vmq_node_count

  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type_vmq
  key_name               = var.key_pair_name
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.vmq_cluster.id]
  placement_group        = aws_placement_group.vmq_cluster.id
  user_data              = local.sysctl_user_data

  root_block_device {
    volume_size = 50
    volume_type = "gp3"
  }

  tags = {
    Name    = "${var.project_name}-vmq-${count.index + 1}"
    Role    = "vernemq"
    Index   = count.index + 1
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
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.vmq_bench.id]
  user_data              = local.sysctl_user_data

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  tags = {
    Name    = "${var.project_name}-bench-${count.index + 1}"
    Role    = "bench"
    Index   = count.index + 1
    Project = var.project_name
  }
}

# ---------------------------------------------------------------------------
# Monitoring Node
# ---------------------------------------------------------------------------

resource "aws_instance" "monitor" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type_monitor
  key_name               = var.key_pair_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.vmq_monitor.id]
  user_data              = local.sysctl_user_data

  root_block_device {
    volume_size = 100
    volume_type = "gp3"
  }

  tags = {
    Name    = "${var.project_name}-monitor"
    Role    = "monitor"
    Project = var.project_name
  }
}

# ---------------------------------------------------------------------------
# Generate Ansible inventory from template
# ---------------------------------------------------------------------------

resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/templates/inventory.tpl", {
    vmq_nodes   = aws_instance.vmq
    bench_nodes = aws_instance.bench
    monitor     = aws_instance.monitor
  })
  filename = "${path.module}/../ansible/inventory/hosts"
}
