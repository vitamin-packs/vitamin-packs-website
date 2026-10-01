output "state_bucket_name" {
  description = "Name of the S3 bucket holding Terraform remote state for the bootstrap, dev, and prod roots."
  value       = aws_s3_bucket.state.id
}

output "state_bucket_arn" {
  description = "ARN of the Terraform remote state bucket, for scoping deployer permission sets."
  value       = aws_s3_bucket.state.arn
}
