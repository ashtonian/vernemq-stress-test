output "monitor_public_ip" {
  description = "Public IP address of the monitoring node"
  value       = aws_instance.monitor.public_ip
}

output "monitor_private_ip" {
  description = "Private IP address of the monitoring node"
  value       = aws_instance.monitor.private_ip
}

output "monitor_security_group_id" {
  description = "Security group ID of the monitoring node"
  value       = aws_security_group.vmq_monitor.id
}

output "grafana_admin_password" {
  description = "Grafana admin password (auto-generated)"
  value       = random_password.grafana_admin.result
  sensitive   = true
}

output "grafana_url" {
  # NOTE: Ansible configures HTTPS (TLS) later; Terraform only provisions HTTP.
  description = "Grafana dashboard URL"
  value       = "http://${aws_instance.monitor.public_ip}:3000"
}
