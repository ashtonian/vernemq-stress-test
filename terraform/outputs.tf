output "vmq_node_private_ips" {
  description = "Private IP addresses of VerneMQ cluster nodes"
  value       = aws_instance.vmq[*].private_ip
}

output "bench_node_private_ips" {
  description = "Private IP addresses of benchmark client nodes"
  value       = aws_instance.bench[*].private_ip
}

output "monitor_public_ip" {
  description = "Public IP address of the monitoring node"
  value       = aws_instance.monitor.public_ip
}

output "ssh_vmq" {
  description = "SSH command for VerneMQ nodes (via monitor bastion)"
  value       = "ssh -J ec2-user@${aws_instance.monitor.public_ip} ec2-user@<vmq-private-ip>"
}

output "ssh_bench" {
  description = "SSH command for bench nodes (via monitor bastion)"
  value       = "ssh -J ec2-user@${aws_instance.monitor.public_ip} ec2-user@<bench-private-ip>"
}

output "ssh_monitor" {
  description = "SSH command for monitoring node"
  value       = "ssh ec2-user@${aws_instance.monitor.public_ip}"
}

output "grafana_url" {
  description = "Grafana dashboard URL"
  value       = "http://${aws_instance.monitor.public_ip}:3000"
}

output "ansible_inventory_path" {
  description = "Path to generated Ansible inventory file"
  value       = local_file.ansible_inventory.filename
}
