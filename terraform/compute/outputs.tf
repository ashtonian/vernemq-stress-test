output "vmq_node_private_ips" {
  description = "Private IP addresses of VerneMQ cluster nodes"
  value       = aws_instance.vmq[*].private_ip
}

output "bench_node_private_ips" {
  description = "Private IP addresses of benchmark client nodes"
  value       = aws_instance.bench[*].private_ip
}

output "ssh_vmq" {
  description = "SSH command for VerneMQ nodes (via monitor bastion)"
  value       = "ssh -J ec2-user@${data.terraform_remote_state.monitoring.outputs.monitor_public_ip} ec2-user@<vmq-private-ip>"
}

output "ssh_bench" {
  description = "SSH command for bench nodes (via monitor bastion)"
  value       = "ssh -J ec2-user@${data.terraform_remote_state.monitoring.outputs.monitor_public_ip} ec2-user@<bench-private-ip>"
}

output "ansible_inventory_path" {
  description = "Path to generated Ansible inventory file"
  value       = local_file.ansible_inventory.filename
}

output "lb_dns_name" {
  description = "DNS name of the NLB (empty if LB disabled)"
  value       = var.enable_lb ? aws_lb.vmq[0].dns_name : ""
}

output "lb_enabled" {
  description = "Whether the NLB is enabled"
  value       = var.enable_lb
}

output "bench_mqtt_username" {
  description = "MQTT username for benchmark clients"
  value       = var.enable_auth ? var.bench_username : ""
}

output "bench_mqtt_password" {
  description = "MQTT password for benchmark clients"
  value       = var.enable_auth ? random_password.bench_mqtt_password[0].result : ""
  sensitive   = true
}
