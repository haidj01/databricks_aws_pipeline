# Kafka on EC2 + Databricks on AWS — Terraform 배포 가이드

Kafka(KRaft 모드)를 AWS EC2에 배포하고, Databricks 워크스페이스를 생성하여 Kafka → Delta Lake Bronze Layer 스트리밍 파이프라인을 구성하는 Terraform 프로젝트입니다.

## 아키텍처 개요

```
[Producer] → Kafka EC2 (KRaft) :9092
                      ↓
           Databricks Structured Streaming
                      ↓
           S3 Bronze Layer (Delta Lake)
```

## 디렉토리 구조

```
kafka_databricks_aws/
├── main.tf                          # Kafka EC2 인프라
├── variables.tf
├── outputs.tf
├── terraform.tfvars.example
├── scripts/
│   └── user_data.sh                 # EC2 부팅 시 Kafka 자동 설치 스크립트
└── databricks/
    ├── main.tf                      # Databricks 워크스페이스 + 클러스터 + Job
    ├── variables.tf
    ├── outputs.tf
    ├── terraform.tfvars.example
    └── notebooks/
        └── bronze_streaming.py      # Kafka → Delta Lake 스트리밍 노트북
```

---

## 사전 요구사항

| 도구 | 버전 |
|------|------|
| Terraform | >= 1.0 |
| AWS CLI | 설정 완료 (`aws configure`) |
| AWS EC2 Key Pair | 콘솔에서 미리 생성 |
| Databricks 계정 | [accounts.cloud.databricks.com](https://accounts.cloud.databricks.com) 가입 완료 |

---

## Step 1. Kafka EC2 배포

### 1-1. 변수 파일 작성

```bash
cd kafka_databricks_aws/
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars` 편집:

```hcl
region        = "ap-northeast-2"
name          = "test"
instance_type = "t3.medium"
key_name      = "your-key-pair-name"   # AWS에 등록된 Key Pair 이름
volume_size   = 20
allowed_cidr  = "0.0.0.0/0"           # 보안 강화 시 본인 IP로 변경: "x.x.x.x/32"
```

### 1-2. Terraform 실행

```bash
terraform init
terraform plan
terraform apply
```

### 1-3. 배포 결과 확인

```bash
terraform output
```

예시 출력:

```
instance_id            = "i-0abc1234567890"
public_ip              = "3.34.xxx.xxx"
kafka_bootstrap_server = "3.34.xxx.xxx:9092"
ssh_command            = "ssh -i your-key-pair-name.pem ec2-user@3.34.xxx.xxx"
```

### 1-4. Kafka 서비스 상태 확인

```bash
# EC2 접속
ssh -i your-key-pair-name.pem ec2-user@<PUBLIC_IP>

# Kafka 서비스 상태
sudo systemctl status kafka

# 토픽 생성 (선택)
/opt/kafka/bin/kafka-topics.sh \
  --create \
  --topic raw-events \
  --bootstrap-server localhost:9092 \
  --partitions 3 \
  --replication-factor 1
```

### Kafka 설정 요약

| 항목 | 값 |
|------|----|
| 버전 | 3.7.0 (Scala 2.13) |
| 모드 | KRaft (ZooKeeper 없음) |
| 포트 | 9092 (PLAINTEXT) |
| 데이터 경로 | `/var/kafka/data` |
| 파티션 기본값 | 3 |
| 로그 보존 기간 | 168시간 (7일) |

---

## Step 2. Databricks 워크스페이스 배포

### 2-1. Databricks Account ID 확인

[accounts.cloud.databricks.com](https://accounts.cloud.databricks.com) → 우측 상단 계정 메뉴 → **Account ID** 복사

### 2-2. 변수 파일 작성

```bash
cd databricks/
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars` 편집:

```hcl
region = "ap-northeast-2"
name   = "test"

# Databricks 계정 정보
databricks_account_id       = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
databricks_account_email    = "your@email.com"
databricks_account_password = "your-password"

# 클러스터 노드 타입 (테스트용 최소 사양)
cluster_node_type = "m5d.large"

# Step 1에서 얻은 Kafka bootstrap server
kafka_bootstrap_servers = "3.34.xxx.xxx:9092"
kafka_topic             = "raw-events"
```

> **주의:** `terraform.tfvars`는 절대 git에 커밋하지 마세요. `.gitignore`에 추가 권장.

### 2-3. Terraform 실행

```bash
terraform init
terraform plan
terraform apply
```

워크스페이스 생성에 약 **5~10분** 소요됩니다.

### 2-4. 배포 결과 확인

```bash
terraform output
```

예시 출력:

```
workspace_url      = "https://dbc-xxxxxxxx-xxxx.cloud.databricks.com"
bronze_s3_bucket   = "test-bronze-layer-ab12cd34"
bronze_s3_path     = "s3://test-bronze-layer-ab12cd34/bronze"
streaming_job_id   = "12345"
cluster_id         = "0101-xxxxxx-xxxxxxxx"
```

### 2-5. 생성되는 AWS/Databricks 리소스

| 리소스 | 설명 |
|--------|------|
| S3 버킷 (workspace root) | Databricks 워크스페이스 루트 스토리지 |
| S3 버킷 (bronze layer) | Delta Lake Bronze 데이터 저장소 |
| IAM Role (crossaccount) | Databricks ↔ AWS 교차 계정 접근 |
| IAM Role (cluster) | 클러스터 노드의 S3 접근 권한 |
| Security Group | 클러스터 노드 간 통신 허용 |
| Databricks Workspace | MWS 방식으로 생성된 워크스페이스 |
| Databricks Cluster | Kafka 스트리밍 전용 오토스케일 클러스터 (1~2 workers) |
| Databricks Notebook | `/Shared/bronze_streaming` |
| Databricks Job | Bronze Streaming Job |

---

## Step 3. Streaming Job 실행

### 워크스페이스에서 수동 실행

1. `terraform output workspace_url` 에서 얻은 URL로 접속
2. 좌측 메뉴 **Workflows** → `test-bronze-streaming-job` 선택
3. **Run now** 클릭

### CLI로 실행

```bash
databricks jobs run-now --job-id <streaming_job_id>
```

### 데이터 확인

```python
# Databricks 노트북에서 실행
df = spark.read.format("delta").load("s3://test-bronze-layer-ab12cd34/bronze/raw-events")
df.show(10)
```

### Bronze 테이블 스키마

| 컬럼 | 타입 | 설명 |
|------|------|------|
| topic | string | Kafka 토픽명 |
| partition | int | Kafka 파티션 번호 |
| offset | long | 메시지 오프셋 |
| kafka_timestamp | timestamp | Kafka 메시지 타임스탬프 |
| message_key | string | 메시지 키 |
| raw_value | string | 메시지 원본 값 (JSON 등) |
| ingested_at | timestamp | 수집 시각 |
| event_date | date | 파티션 키 (날짜별 분리) |

---

## 리소스 삭제

```bash
# Databricks 리소스 먼저 삭제
cd databricks/
terraform destroy

# Kafka EC2 삭제
cd ../
terraform destroy
```

> S3 버킷은 `force_destroy = true`로 설정되어 데이터가 있어도 삭제됩니다.

---

## 트러블슈팅

### Kafka가 시작되지 않을 때

```bash
# 로그 확인
sudo journalctl -u kafka -n 50

# 수동 재시작
sudo systemctl restart kafka
```

### Databricks 워크스페이스 생성 타임아웃

- `terraform apply` 재실행으로 대부분 해결됩니다.
- AWS 계정의 EC2/VPC 서비스 한도를 확인하세요.

### Kafka 연결 오류 (Databricks → EC2)

- EC2 Security Group에서 포트 `9092`가 Databricks 클러스터 IP 대역에 열려 있는지 확인하세요.
- `allowed_cidr`을 `"0.0.0.0/0"` 으로 설정하면 외부에서 접근 가능합니다 (테스트 환경에서만 사용).
