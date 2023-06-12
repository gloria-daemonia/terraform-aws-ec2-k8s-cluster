output "kubeconfig_local_path" {
  description = "Local path to the cluster kubeconfig."
  value       = local_sensitive_file.cluster_config.filename
}

output "kubeconfig_secret_name" {
  description = "The secret name with the cluster kubeconifg"
  value       = aws_secretsmanager_secret.cluster_config.name
}


output "join_cluster_secret_name" {
  description = "The secret name with the join command to the cluster (both master and slave)"
  value       = aws_secretsmanager_secret.join_cluster.name
}
