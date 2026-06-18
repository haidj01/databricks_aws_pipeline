terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.50"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# Databricks 계정 레벨 (워크스페이스 생성용)
provider "databricks" {
  alias         = "mws"
  host          = "https://accounts.cloud.databricks.com"
  account_id    = var.databricks_account_id
  client_id     = var.databricks_client_id
  client_secret = var.databricks_client_secret
}

# Databricks 워크스페이스 레벨 (클러스터/노트북 생성용)
provider "databricks" {
  host          = databricks_mws_workspaces.this.workspace_url
  client_id     = var.databricks_client_id
  client_secret = var.databricks_client_secret
}

resource "random_id" "suffix" {
  byte_length = 4
}

# ─── S3 Buckets ───────────────────────────────────────────────

# Databricks 워크스페이스 루트 스토리지
resource "aws_s3_bucket" "workspace_root" {
  bucket        = "${var.name}-databricks-root-${random_id.suffix.hex}"
  force_destroy = true

  tags = { Name = "${var.name}-databricks-root" }
}

resource "aws_s3_bucket_public_access_block" "workspace_root" {
  bucket                  = aws_s3_bucket.workspace_root.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "databricks_aws_bucket_policy" "workspace_root" {
  provider = databricks.mws
  bucket   = aws_s3_bucket.workspace_root.bucket
}

resource "aws_s3_bucket_policy" "workspace_root" {
  bucket     = aws_s3_bucket.workspace_root.id
  policy     = data.databricks_aws_bucket_policy.workspace_root.json
  depends_on = [aws_s3_bucket_public_access_block.workspace_root]
}

# Bronze Layer (Delta Lake 저장소)
resource "aws_s3_bucket" "bronze" {
  bucket        = "${var.name}-bronze-layer-${random_id.suffix.hex}"
  force_destroy = true

  tags = { Name = "${var.name}-bronze-layer" }
}

resource "aws_s3_bucket_public_access_block" "bronze" {
  bucket                  = aws_s3_bucket.bronze.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ─── IAM: Databricks Cross-account Role ───────────────────────

data "databricks_aws_assume_role_policy" "this" {
  provider    = databricks.mws
  external_id = var.databricks_account_id
}

data "databricks_aws_crossaccount_policy" "this" {
  provider = databricks.mws
}

resource "aws_iam_role" "crossaccount" {
  name               = "${var.name}-databricks-crossaccount"
  assume_role_policy = data.databricks_aws_assume_role_policy.this.json
}

resource "aws_iam_role_policy" "crossaccount" {
  name   = "crossaccount"
  role   = aws_iam_role.crossaccount.id
  policy = data.databricks_aws_crossaccount_policy.this.json
}

resource "aws_iam_role_policy" "crossaccount_s3" {
  name = "workspace-root-s3"
  role = aws_iam_role.crossaccount.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ]
      Resource = [
        aws_s3_bucket.workspace_root.arn,
        "${aws_s3_bucket.workspace_root.arn}/*"
      ]
    }]
  })
}

# ─── IAM: Cluster Instance Profile (S3 Bronze 접근) ──────────

resource "aws_iam_role" "cluster" {
  name = "${var.name}-databricks-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "cluster_s3" {
  name = "bronze-s3-access"
  role = aws_iam_role.cluster.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ]
      Resource = [
        aws_s3_bucket.bronze.arn,
        "${aws_s3_bucket.bronze.arn}/*"
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "cluster" {
  name = "${var.name}-databricks-cluster-profile"
  role = aws_iam_role.cluster.name
}

# ─── Security Group ───────────────────────────────────────────

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# NAT Gateway용 Elastic IP
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.name}-nat-eip" }
}

# NAT Gateway (첫 번째 public 서브넷에 생성)
resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = data.aws_subnets.default.ids[0]
  tags          = { Name = "${var.name}-nat-gw" }
}

# Private 서브넷 (Databricks 클러스터 노드 전용)
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = data.aws_vpc.default.id
  cidr_block        = "172.31.${192 + count.index * 16}.0/20"
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags              = { Name = "${var.name}-private-${count.index}" }
}

data "aws_availability_zones" "available" {
  state = "available"
}

# Private 서브넷 라우팅 테이블 (NAT Gateway를 통해 인터넷 접근)
resource "aws_route_table" "private" {
  vpc_id = data.aws_vpc.default.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = { Name = "${var.name}-private-rt" }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "databricks" {
  name        = "${var.name}-databricks-sg"
  description = "Databricks cluster nodes"
  vpc_id      = data.aws_vpc.default.id

  # 클러스터 노드 간 통신
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }

  # Databricks Control Plane (us-east-2) inbound
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name}-databricks-sg" }
}

# ─── Databricks MWS: 워크스페이스 생성 ───────────────────────

resource "time_sleep" "wait_for_iam" {
  depends_on      = [aws_iam_role_policy.crossaccount, aws_iam_role_policy.crossaccount_s3]
  create_duration = "15s"
}

resource "databricks_mws_credentials" "this" {
  provider         = databricks.mws
  credentials_name = "${var.name}-credentials"
  role_arn         = aws_iam_role.crossaccount.arn
  depends_on       = [time_sleep.wait_for_iam]
}

resource "databricks_mws_storage_configurations" "this" {
  provider                   = databricks.mws
  account_id                 = var.databricks_account_id
  storage_configuration_name = "${var.name}-storage"
  bucket_name                = aws_s3_bucket.workspace_root.bucket
}

resource "databricks_mws_networks" "this" {
  provider           = databricks.mws
  account_id         = var.databricks_account_id
  network_name       = "${var.name}-network-private"
  vpc_id             = data.aws_vpc.default.id
  subnet_ids         = aws_subnet.private[*].id
  security_group_ids = [aws_security_group.databricks.id]

  lifecycle {
    create_before_destroy = true
  }
}

resource "databricks_mws_workspaces" "this" {
  provider                = databricks.mws
  account_id              = var.databricks_account_id
  workspace_name          = "${var.name}-workspace"
  aws_region              = var.region
  is_no_public_ip_enabled = true

  credentials_id           = databricks_mws_credentials.this.credentials_id
  storage_configuration_id = databricks_mws_storage_configurations.this.storage_configuration_id
  network_id               = databricks_mws_networks.this.network_id

  depends_on = [aws_s3_bucket_policy.workspace_root]
}

# ─── Unity Catalog ────────────────────────────────────────────────

data "aws_caller_identity" "current" {}

# Catalog 전용 S3 버킷 (Bronze/Silver/Gold 스키마 + Metastore 루트)
resource "aws_s3_bucket" "catalog" {
  bucket        = "${var.name}-catalog-${random_id.suffix.hex}"
  force_destroy = true

  tags = { Name = "${var.name}-catalog" }
}

resource "aws_s3_bucket_public_access_block" "catalog" {
  bucket                  = aws_s3_bucket.catalog.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Unity Catalog용 IAM role (catalog 버킷 + 기존 bronze 버킷 접근)
resource "aws_iam_role" "unity_catalog" {
  name = "${var.name}-unity-catalog"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::414351767826:role/unity-catalog-prod-UCMasterRole-14S5ZJVKOTYTL" }
        Action    = "sts:AssumeRole"
        Condition = {
          StringEquals = { "sts:ExternalId" = var.databricks_account_id }
        }
      }
    ]
  })

  # storage credential 생성 후 null_resource가 trust policy를 실제 external_id로 업데이트함
  lifecycle {
    ignore_changes = [assume_role_policy]
  }
}

# storage credential 발급 후 trust policy 갱신:
# - unity_catalog_iam_arn + external_id (Databricks UC 인증)
# - self-assume (external location 검증 시 Databricks 필수 요건)
resource "null_resource" "update_iam_trust" {
  triggers = {
    external_id = databricks_storage_credential.this.aws_iam_role[0].external_id
    uc_iam_arn  = databricks_storage_credential.this.aws_iam_role[0].unity_catalog_iam_arn
    role_arn    = aws_iam_role.unity_catalog.arn
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-BASH
      set -euo pipefail
      UC_IAM_ARN="${databricks_storage_credential.this.aws_iam_role[0].unity_catalog_iam_arn}"
      EXTERNAL_ID="${databricks_storage_credential.this.aws_iam_role[0].external_id}"
      ROLE_ARN="${aws_iam_role.unity_catalog.arn}"
      ROLE_NAME="${aws_iam_role.unity_catalog.name}"
      echo "Updating IAM trust: role=$ROLE_NAME uc_iam_arn=$UC_IAM_ARN external_id=$EXTERNAL_ID"
      aws iam update-assume-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"$UC_IAM_ARN\"},\"Action\":\"sts:AssumeRole\",\"Condition\":{\"StringEquals\":{\"sts:ExternalId\":\"$EXTERNAL_ID\"}}},{\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"$ROLE_ARN\"},\"Action\":\"sts:AssumeRole\"}]}"
      echo "Trust policy updated successfully"
    BASH
  }
}

# IAM 변경 전파 대기 (eventually consistent)
resource "time_sleep" "wait_for_trust_propagation" {
  depends_on      = [null_resource.update_iam_trust]
  create_duration = "20s"
}

resource "aws_iam_role_policy" "unity_catalog_s3" {
  name = "catalog-s3-access"
  role = aws_iam_role.unity_catalog.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.catalog.arn,
          "${aws_s3_bucket.catalog.arn}/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["sts:AssumeRole"]
        Resource = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.name}-unity-catalog"]
      }
    ]
  })
}

# 기존 Metastore 참조 (리전당 1개 제한으로 신규 생성 불가)
data "databricks_metastore" "this" {
  provider = databricks.mws
  name     = "metastore_aws_us_east_2"
}

# test-workspace에 Metastore 연결
resource "databricks_metastore_assignment" "this" {
  provider             = databricks.mws
  workspace_id         = databricks_mws_workspaces.this.workspace_id
  metastore_id         = data.databricks_metastore.this.metastore_id
  default_catalog_name = "hive_metastore"
}

# Storage credential: UC IAM role로 S3 인증
resource "databricks_storage_credential" "this" {
  name = "${var.name}-uc-credential"
  aws_iam_role {
    role_arn = aws_iam_role.unity_catalog.arn
  }
  depends_on = [databricks_metastore_assignment.this]
}

# External location: catalog 전용 버킷 (managed 테이블 저장소)
resource "databricks_external_location" "catalog" {
  name            = "${var.name}-catalog-location"
  url             = "s3://${aws_s3_bucket.catalog.bucket}"
  credential_name = databricks_storage_credential.this.id
  depends_on      = [databricks_metastore_assignment.this, time_sleep.wait_for_trust_propagation]
}

# Unity Catalog
resource "databricks_catalog" "this" {
  name         = "${var.name}_catalog"
  storage_root = "s3://${aws_s3_bucket.catalog.bucket}"
  comment      = "Unity Catalog backed by s3://${aws_s3_bucket.catalog.bucket}"
  depends_on   = [databricks_external_location.catalog]
}

# Bronze schema: raw ingestion layer
resource "databricks_schema" "bronze" {
  catalog_name = databricks_catalog.this.name
  name         = "bronze"
  storage_root = "s3://${aws_s3_bucket.catalog.bucket}/bronze"
  comment      = "Raw ingestion layer"
}

# Silver schema: cleaned and enriched data
resource "databricks_schema" "silver" {
  catalog_name = databricks_catalog.this.name
  name         = "silver"
  storage_root = "s3://${aws_s3_bucket.catalog.bucket}/silver"
  comment      = "Cleaned and enriched data"
}

# Gold schema: aggregated and business-ready data
resource "databricks_schema" "gold" {
  catalog_name = databricks_catalog.this.name
  name         = "gold"
  storage_root = "s3://${aws_s3_bucket.catalog.bucket}/gold"
  comment      = "Aggregated and business-ready data"
}

# Workspace isolation이 켜진 metastore에서 catalog 명시적 바인딩
resource "databricks_workspace_binding" "catalog" {
  securable_name = databricks_catalog.this.name
  securable_type = "catalog"
  workspace_id   = databricks_mws_workspaces.this.workspace_id
  binding_type   = "BINDING_TYPE_READ_WRITE"
}

# account users에게 catalog/schema 접근 권한 부여
resource "databricks_grants" "catalog" {
  catalog = databricks_catalog.this.name
  grant {
    principal  = "account users"
    privileges = ["USE CATALOG", "CREATE SCHEMA"]
  }
  depends_on = [databricks_workspace_binding.catalog]
}

resource "databricks_grants" "bronze" {
  schema = "${databricks_catalog.this.name}.${databricks_schema.bronze.name}"
  grant {
    principal  = "account users"
    privileges = ["USE SCHEMA", "CREATE TABLE", "SELECT"]
  }
}

resource "databricks_grants" "silver" {
  schema = "${databricks_catalog.this.name}.${databricks_schema.silver.name}"
  grant {
    principal  = "account users"
    privileges = ["USE SCHEMA", "CREATE TABLE", "SELECT"]
  }
}

resource "databricks_grants" "gold" {
  schema = "${databricks_catalog.this.name}.${databricks_schema.gold.name}"
  grant {
    principal  = "account users"
    privileges = ["USE SCHEMA", "CREATE TABLE", "SELECT"]
  }
}

