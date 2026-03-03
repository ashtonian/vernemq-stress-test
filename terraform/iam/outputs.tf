output "user_name" {
  description = "IAM user name"
  value       = aws_iam_user.operator.name
}

output "user_arn" {
  description = "IAM user ARN"
  value       = aws_iam_user.operator.arn
}

output "access_key_id" {
  description = "Access key ID for the operator user"
  value       = aws_iam_access_key.operator.id
}

output "secret_access_key" {
  description = "Secret access key for the operator user"
  value       = aws_iam_access_key.operator.secret
  sensitive   = true
}

output "aws_profile_name" {
  description = "Suggested AWS CLI profile name for the operator user"
  value       = "vernemq-bench"
}
