output "vpc_id" {
  description = "ID of the benchmark VPC"
  value       = aws_vpc.bench.id
}

output "public_subnet_id" {
  description = "ID of the public subnet"
  value       = aws_subnet.public.id
}

output "private_subnet_id" {
  description = "ID of the private subnet"
  value       = aws_subnet.private.id
}

output "placement_group_name" {
  description = "Name of the VerneMQ cluster placement group"
  value       = aws_placement_group.vmq_cluster.name
}

output "project_name" {
  description = "Project name for use by other modules"
  value       = var.project_name
}
