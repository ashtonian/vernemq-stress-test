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
# VPC
# ---------------------------------------------------------------------------

resource "aws_vpc" "bench" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name    = "${var.project_name}-vpc"
    Project = var.project_name
  }
}

# ---------------------------------------------------------------------------
# Subnets
# ---------------------------------------------------------------------------

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.bench.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name    = "${var.project_name}-public"
    Project = var.project_name
  }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.bench.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name    = "${var.project_name}-private"
    Project = var.project_name
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

# ---------------------------------------------------------------------------
# Internet Gateway
# ---------------------------------------------------------------------------

resource "aws_internet_gateway" "bench" {
  vpc_id = aws_vpc.bench.id

  tags = {
    Name    = "${var.project_name}-igw"
    Project = var.project_name
  }
}

# ---------------------------------------------------------------------------
# NAT Gateway (for private subnet outbound access)
# ---------------------------------------------------------------------------

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name    = "${var.project_name}-nat-eip"
    Project = var.project_name
  }
}

resource "aws_nat_gateway" "bench" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  tags = {
    Name    = "${var.project_name}-nat"
    Project = var.project_name
  }

  depends_on = [aws_internet_gateway.bench]
}

# ---------------------------------------------------------------------------
# Route Tables
# ---------------------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.bench.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.bench.id
  }

  tags = {
    Name    = "${var.project_name}-public-rt"
    Project = var.project_name
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.bench.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.bench.id
  }

  tags = {
    Name    = "${var.project_name}-private-rt"
    Project = var.project_name
  }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# ---------------------------------------------------------------------------
# Security Groups
# ---------------------------------------------------------------------------

resource "aws_security_group" "vmq_cluster" {
  name        = "${var.project_name}-vmq-cluster"
  description = "VerneMQ cluster nodes"
  vpc_id      = aws_vpc.bench.id

  # SSH from monitor bastion
  ingress {
    description     = "SSH from monitor"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.vmq_monitor.id]
  }

  # MQTT default listener
  ingress {
    description = "MQTT"
    from_port   = 1883
    to_port     = 1883
    protocol    = "tcp"
    self        = true
  }

  # VerneMQ HTTP API
  ingress {
    description = "VerneMQ HTTP API"
    from_port   = 8888
    to_port     = 8888
    protocol    = "tcp"
    self        = true
  }

  # VerneMQ clustering
  ingress {
    description = "VerneMQ clustering"
    from_port   = 44053
    to_port     = 44053
    protocol    = "tcp"
    self        = true
  }

  # Node exporter
  ingress {
    description = "Node exporter"
    from_port   = 9100
    to_port     = 9100
    protocol    = "tcp"
    self        = true
  }

  # Erlang EPMD
  ingress {
    description = "EPMD"
    from_port   = 4369
    to_port     = 4369
    protocol    = "tcp"
    self        = true
  }

  # Erlang distribution ports
  ingress {
    description = "Erlang distribution"
    from_port   = 9090
    to_port     = 9099
    protocol    = "tcp"
    self        = true
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
    security_groups = [aws_security_group.vmq_monitor.id]
  }

  ingress {
    description     = "Node exporter from monitor"
    from_port       = 9100
    to_port         = 9100
    protocol        = "tcp"
    security_groups = [aws_security_group.vmq_monitor.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-vmq-cluster"
    Project = var.project_name
  }
}

resource "aws_security_group" "vmq_bench" {
  name        = "${var.project_name}-vmq-bench"
  description = "Benchmark client nodes"
  vpc_id      = aws_vpc.bench.id

  ingress {
    description     = "SSH from monitor"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.vmq_monitor.id]
  }

  # Allow node exporter scraping from monitor
  ingress {
    description     = "Node exporter from monitor"
    from_port       = 9100
    to_port         = 9100
    protocol        = "tcp"
    security_groups = [aws_security_group.vmq_monitor.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-vmq-bench"
    Project = var.project_name
  }
}

resource "aws_security_group" "vmq_monitor" {
  name        = "${var.project_name}-vmq-monitor"
  description = "Monitoring node (Prometheus + Grafana)"
  vpc_id      = aws_vpc.bench.id

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
    Name    = "${var.project_name}-vmq-monitor"
    Project = var.project_name
  }
}

# ---------------------------------------------------------------------------
# Placement Group (cluster strategy for low-latency VerneMQ communication)
# ---------------------------------------------------------------------------

resource "aws_placement_group" "vmq_cluster" {
  name     = "${var.project_name}-vmq-cluster${terraform.workspace == "default" ? "" : "-${terraform.workspace}"}"
  strategy = "cluster"

  tags = {
    Project = var.project_name
  }
}
