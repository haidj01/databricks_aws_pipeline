# Kafka → Databricks 실시간 스트리밍 파이프라인

Apache Kafka(KRaft 모드)를 AWS EC2에 배포하고, Databricks Structured Streaming으로 데이터를 수집해 Delta Lake에 Bronze/Silver 레이어로 적재하는 end-to-end 스트리밍 파이프라인입니다.

---

## 아키텍처

```
┌─────────────────────────────────────────────────────────────────┐
│ Local                                                           │
│  generator.py ──► producer.py ──► Kafka EC2 (port 9094)        │
└───────────────────────────────────┬─────────────────────────────┘
                                    │ :9092 (VPC 내부)
┌───────────────────────────────────▼─────────────────────────────┐
│ AWS                                                             │
│  EC2 (Kafka 3.7.0 KRaft)                                        │
│       ↓  topic: raw-events                                      │
│  Databricks Cluster (Structured Streaming)                      │
│       ↓                          ↓                              │
│  bronze_streaming.py        ETL_pipeline.py (DLT)              │
│       ↓                          ↓           ↓                  │
│  S3 Bronze (Delta)        sales_bronze   sales_silver           │
└─────────────────────────────────────────────────────────────────┘
```

### 데이터 흐름

| 단계 | 설명 |
|------|------|
| **Producer** | 가상 이커머스 이벤트(page_view / add_to_cart / order / payment)를 CSV로 생성 후 Kafka로 발행 |
| **Kafka EC2** | KRaft 모드 단일 브로커. VPC 내부 `:9092`, 외부(로컬 프로듀서) `:9094` |
| **Bronze** | Kafka 메시지를 원본 그대로 Delta Lake에 적재 (파티션: `event_date`) |
| **Silver** | JSON 파싱 + 타입 캐스팅 + 빈 문자열 NULL 처리 후 정제된 Delta 테이블로 저장 |

---

## 디렉토리 구조

```
databricks_aws_pipeline/
├── kafka_producer/                  # 이벤트 생성 & Kafka 발행 (로컬)
│   ├── generator.py                 # 가상 이커머스 이벤트 CSV 생성
│   ├── producer.py                  # CSV → Kafka 토픽 발행
│   ├── config.py                    # Kafka 연결 설정
│   └── requirements.txt
│
├── kafka_databricks_terraform/      # Terraform: 인프라 프로비저닝
│   ├── main.tf                      # Kafka EC2 + 보안 그룹
│   ├── variables.tf
│   ├── outputs.tf
│   ├── terraform.tfvars.example
│   ├── scripts/
│   │   └── user_data.sh             # EC2 부팅 시 Kafka 자동 설치
│   └── databricks/
│       ├── main.tf                  # Databricks MWS 워크스페이스 + Unity Catalog
│       ├── variables.tf
│       ├── outputs.tf
│       └── terraform.tfvars.example
│
└── databricks_aws/                  # Databricks 노트북 & DLT 파이프라인 코드
    ├── bronze_streaming.py          # Structured Streaming: Kafka → S3 Delta Bronze
    └── ETL_pipeline.py              # DLT 파이프라인: sales_bronze + sales_silver
```

---

## 기술 스택

| 구분 | 기술 |
|------|------|
| 메시지 브로커 | Apache Kafka 3.7.0 (KRaft, ZooKeeper 없음) |
| 인프라 | AWS EC2 (t3.medium), Amazon Linux 2023 |
| 스토리지 | AWS S3 + Delta Lake |
| 스트리밍 엔진 | Databricks Structured Streaming / DLT |
| 데이터 거버넌스 | Databricks Unity Catalog |
| IaC | Terraform >= 1.0 (AWS ~5.0, Databricks ~1.50) |
| 프로듀서 | Python 3, confluent-kafka 2.3.0, Faker 24.0.0 |

---

## 사전 요구사항

- Terraform >= 1.0
- AWS CLI (`aws configure` 완료)
- AWS EC2 Key Pair (콘솔에서 사전 생성)
- Databricks 계정 ([accounts.cloud.databricks.com](https://accounts.cloud.databricks.com)) + Service Principal
- Python 3.9+

---

## Step 1. Kafka EC2 배포

```bash
cd kafka_databricks_terraform/
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars` 편집:

```hcl
region        = "us-east-1"
name          = "test"
instance_type = "t3.medium"
key_name      = "your-key-pair-name"
volume_size   = 30
allowed_cidr  = "x.x.x.x/32"   # 본인 IP로 제한 권장
```

```bash
terraform init
terraform plan
terraform apply
```

배포 후 출력 확인:

```bash
terraform output
# kafka_bootstrap_server = "3.x.x.x:9092"
# ssh_command = "ssh -i your-key.pem ec2-user@3.x.x.x"
```

Kafka 서비스 확인:

```bash
ssh -i your-key.pem ec2-user@<PUBLIC_IP>
sudo systemctl status kafka

# 토픽 생성
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
| 내부 포트 | 9092 (VPC → Databricks) |
| 외부 포트 | 9094 (로컬 프로듀서) |
| 데이터 경로 | `/var/kafka/data` |
| 파티션 기본값 | 3 |
| 로그 보존 기간 | 168시간 (7일) |

---

## Step 2. Databricks 워크스페이스 배포

Databricks Service Principal을 먼저 생성해야 합니다. ([Service Principal 생성 가이드](https://docs.databricks.com/administration-guide/users-groups/service-principals.html))

```bash
cd kafka_databricks_terraform/databricks/
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars` 편집:

```hcl
region = "us-east-1"
name   = "test"

databricks_account_id    = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
databricks_client_id     = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
databricks_client_secret = "your-client-secret"

# Step 1 output 값 사용
kafka_bootstrap_servers = "3.x.x.x:9092"
kafka_topic             = "raw-events"
```

```bash
terraform init
terraform plan
terraform apply   # 약 10~15분 소요
```

### 생성되는 리소스

| 리소스 | 설명 |
|--------|------|
| S3 버킷 (workspace-root) | Databricks 워크스페이스 루트 스토리지 |
| S3 버킷 (bronze-layer) | Delta Lake Bronze 데이터 저장소 |
| S3 버킷 (catalog) | Unity Catalog Managed 테이블 저장소 |
| IAM Role (crossaccount) | Databricks ↔ AWS 교차 계정 접근 |
| IAM Role (cluster) | 클러스터 노드 S3 접근 권한 |
| IAM Role (unity-catalog) | Unity Catalog S3 접근 권한 |
| NAT Gateway | Private 서브넷 → 인터넷 (Databricks 필수) |
| Databricks Workspace | MWS 방식 프라이빗 워크스페이스 |
| Unity Catalog | Bronze / Silver / Gold 스키마 |

---

## Step 3. 이벤트 생성 & Kafka 발행 (로컬)

```bash
cd kafka_producer/
pip install -r requirements.txt
```

`config.py`에서 Kafka 주소 확인 후 수정:

```python
KAFKA_BOOTSTRAP_SERVERS = "<EC2_PUBLIC_IP>:9094"   # 외부 포트
KAFKA_TOPIC = "raw-events"
DEFAULT_DELAY = 0.1  # 메시지 간격 (초)
```

이벤트 생성:

```bash
python generator.py --rows 5000 --output data/events.csv
```

Kafka로 발행:

```bash
python producer.py --file data/events.csv --topic raw-events --delay 0.05
```

### 이벤트 스키마

| 필드 | 타입 | 설명 |
|------|------|------|
| event_id | UUID | 고유 이벤트 ID |
| event_type | string | page_view / add_to_cart / order / payment |
| user_id | string | user-001 ~ user-200 |
| session_id | string | 세션 식별자 |
| product_id | string | prod-001 ~ prod-500 |
| product_name | string | 상품명 (Faker 생성) |
| category | string | Electronics / Clothing / Sports 등 6종 |
| quantity | int | 수량 (add_to_cart, order만) |
| price | double | 5.0 ~ 500.0 |
| order_id | string | 주문 ID (order, payment만) |
| payment_method | string | credit_card / kakao_pay 등 5종 |
| timestamp | ISO 8601 | 이벤트 발생 시각 |

이벤트 비율: page_view 50% / add_to_cart 25% / order 15% / payment 10%

---

## Step 4. 스트리밍 파이프라인 실행

### 방법 A: Structured Streaming 노트북 (`bronze_streaming.py`)

Databricks 워크스페이스에서 `bronze_streaming.py`를 노트북으로 임포트합니다.

위젯 파라미터:

| 파라미터 | 예시 |
|----------|------|
| kafka_bootstrap_servers | `3.x.x.x:9092` |
| kafka_topic | `raw-events` |
| bronze_s3_path | `s3://test-bronze-layer-xxxx/bronze` |

실행하면 10초마다 Kafka에서 배치를 읽어 Delta Lake에 적재합니다.

### 방법 B: DLT 파이프라인 (`ETL_pipeline.py`)

Databricks에서 **Delta Live Tables** 파이프라인으로 등록합니다.

- `sales_bronze` — Kafka 원본 메시지 (event_key, event_value, 메타데이터)
- `sales_silver` — JSON 파싱 + 타입 변환 + NULL 정제

### Bronze 테이블 스키마 (`bronze_streaming.py`)

| 컬럼 | 타입 | 설명 |
|------|------|------|
| topic | string | Kafka 토픽명 |
| partition | int | Kafka 파티션 번호 |
| offset | long | 메시지 오프셋 |
| kafka_timestamp | timestamp | Kafka 메시지 타임스탬프 |
| message_key | string | 메시지 키 (user_id) |
| raw_value | string | 메시지 원본 JSON |
| ingested_at | timestamp | 수집 시각 |
| event_date | date | 파티션 키 |

---

## 리소스 삭제

```bash
# 1. Databricks 리소스 삭제
cd kafka_databricks_terraform/databricks/
terraform destroy

# 2. Kafka EC2 삭제
cd ../
terraform destroy
```

> S3 버킷은 `force_destroy = true`로 설정되어 있어 데이터가 있어도 삭제됩니다.

---

## 트러블슈팅

**Kafka 서비스가 시작되지 않을 때**

```bash
sudo journalctl -u kafka -n 100
sudo systemctl restart kafka
```

**Databricks에서 Kafka 연결 오류**

- EC2 Security Group 포트 `9092`가 VPC CIDR(`172.31.0.0/16`)에 열려 있는지 확인
- Databricks 클러스터가 Private 서브넷에 있으므로 Kafka EC2와 동일 VPC여야 함

**Databricks 워크스페이스 생성 타임아웃**

- `terraform apply`를 재실행하면 대부분 해결됨
- AWS 계정의 VPC/NAT Gateway 서비스 한도 확인

**Unity Catalog IAM trust 업데이트 실패**

- `null_resource.update_iam_trust`는 AWS CLI를 로컬에서 실행하므로 `aws configure` 인증 확인
- IAM 변경 전파(15~20초) 대기 후 재실행
