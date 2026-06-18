output "workspace_url" {
  description = "Databricks workspace URL"
  value       = databricks_mws_workspaces.this.workspace_url
}

output "bronze_s3_bucket" {
  description = "Bronze layer S3 bucket name"
  value       = aws_s3_bucket.bronze.bucket
}

output "bronze_s3_path" {
  description = "Bronze layer S3 path"
  value       = "s3://${aws_s3_bucket.bronze.bucket}/bronze"
}

output "catalog_bucket" {
  description = "Unity Catalog S3 bucket"
  value       = aws_s3_bucket.catalog.bucket
}

output "catalog_name" {
  description = "Unity Catalog name"
  value       = databricks_catalog.this.name
}

output "catalog_schemas" {
  description = "Unity Catalog schema paths (catalog.schema)"
  value = {
    bronze = "${databricks_catalog.this.name}.${databricks_schema.bronze.name}"
    silver = "${databricks_catalog.this.name}.${databricks_schema.silver.name}"
    gold   = "${databricks_catalog.this.name}.${databricks_schema.gold.name}"
  }
}

