#!/bin/bash
set -e

# Java 17 설치
dnf install -y java-17-amazon-corretto-headless

# kafka 전용 유저 생성
useradd -r -s /bin/false kafka

# Kafka 다운로드
KAFKA_VERSION="3.7.0"
SCALA_VERSION="2.13"
KAFKA_DIR="/opt/kafka"

curl -fsSL "https://archive.apache.org/dist/kafka/${KAFKA_VERSION}/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz" \
  -o /tmp/kafka.tgz
mkdir -p ${KAFKA_DIR}
tar -xzf /tmp/kafka.tgz -C ${KAFKA_DIR} --strip-components=1
rm /tmp/kafka.tgz

# 데이터 디렉토리 생성
mkdir -p /var/kafka/data
chown -R kafka:kafka ${KAFKA_DIR} /var/kafka

# EC2 IP 조회
PRIVATE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)

# KRaft 설정
cat > ${KAFKA_DIR}/config/kraft/server.properties << EOF
process.roles=broker,controller
node.id=1
controller.quorum.voters=1@localhost:9093

listeners=PLAINTEXT://:9092,EXTERNAL://:9094,CONTROLLER://:9093
advertised.listeners=PLAINTEXT://${PRIVATE_IP}:9092,EXTERNAL://${PUBLIC_IP}:9094
inter.broker.listener.name=PLAINTEXT
controller.listener.names=CONTROLLER
listener.security.protocol.map=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT,EXTERNAL:PLAINTEXT

log.dirs=/var/kafka/data
num.partitions=3
default.replication.factor=1
offsets.topic.replication.factor=1
transaction.state.log.replication.factor=1
transaction.state.log.min.isr=1

log.retention.hours=168
log.segment.bytes=1073741824
log.retention.check.interval.ms=300000

num.network.threads=3
num.io.threads=8
socket.send.buffer.bytes=102400
socket.receive.buffer.bytes=102400
socket.request.max.bytes=104857600
EOF

# 스토리지 포맷 (KRaft 초기화)
CLUSTER_UUID=$(${KAFKA_DIR}/bin/kafka-storage.sh random-uuid)
sudo -u kafka ${KAFKA_DIR}/bin/kafka-storage.sh format \
  -t ${CLUSTER_UUID} \
  -c ${KAFKA_DIR}/config/kraft/server.properties

chown -R kafka:kafka /var/kafka

# systemd 서비스 등록
cat > /etc/systemd/system/kafka.service << EOF
[Unit]
Description=Apache Kafka (KRaft)
After=network.target

[Service]
Type=simple
User=kafka
ExecStart=${KAFKA_DIR}/bin/kafka-server-start.sh ${KAFKA_DIR}/config/kraft/server.properties
ExecStop=${KAFKA_DIR}/bin/kafka-server-stop.sh
Restart=on-abnormal
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable kafka
systemctl start kafka
