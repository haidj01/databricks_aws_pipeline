# Databricks notebook source
# Bronze Layer: Kafka → Delta Lake (Structured Streaming)

# COMMAND ----------

dbutils.widgets.text("kafka_bootstrap_servers", "", "Kafka Bootstrap Servers")
dbutils.widgets.text("kafka_topic", "raw-events", "Kafka Topic")
dbutils.widgets.text("bronze_s3_path", "", "Bronze S3 Path")

kafka_bootstrap_servers = dbutils.widgets.get("kafka_bootstrap_servers")
kafka_topic             = dbutils.widgets.get("kafka_topic")
bronze_s3_path          = dbutils.widgets.get("bronze_s3_path")

bronze_table_path  = f"{bronze_s3_path}/{kafka_topic}"
checkpoint_path    = f"{bronze_s3_path}/_checkpoints/{kafka_topic}"

print(f"Kafka:     {kafka_bootstrap_servers}")
print(f"Topic:     {kafka_topic}")
print(f"Bronze:    {bronze_table_path}")

# COMMAND ----------

from pyspark.sql import functions as F

# Kafka에서 읽기 (Structured Streaming)
kafka_df = (
    spark.readStream
    .format("kafka")
    .option("kafka.bootstrap.servers", kafka_bootstrap_servers)
    .option("subscribe", kafka_topic)
    .option("startingOffsets", "latest")
    .option("failOnDataLoss", "false")
    .load()
)

# COMMAND ----------

# Bronze Layer: 원본 데이터 + 메타데이터 그대로 저장
bronze_df = kafka_df.select(
    F.col("topic"),
    F.col("partition"),
    F.col("offset"),
    F.col("timestamp").alias("kafka_timestamp"),
    F.col("key").cast("string").alias("message_key"),
    F.col("value").cast("string").alias("raw_value"),
    F.current_timestamp().alias("ingested_at"),
    F.to_date(F.col("timestamp")).alias("event_date"),   # 파티션 키
)

# COMMAND ----------

# Delta Lake에 쓰기 (append, 파티션: event_date)
query = (
    bronze_df.writeStream
    .format("delta")
    .outputMode("append")
    .option("checkpointLocation", checkpoint_path)
    .option("mergeSchema", "true")
    .partitionBy("event_date")
    .trigger(processingTime="10 seconds")
    .start(bronze_table_path)
)

print(f"Streaming started. Query ID: {query.id}")
query.awaitTermination()
