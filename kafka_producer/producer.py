import csv
import json
import time
import argparse
from confluent_kafka import Producer

from config import KAFKA_BOOTSTRAP_SERVERS, KAFKA_TOPIC, DEFAULT_DELAY


def _delivery_report(err, msg):
    if err:
        print(f"[ERROR] Delivery failed for key={msg.key()}: {err}")


def publish(file: str, topic: str, delay: float) -> None:
    producer = Producer({"bootstrap.servers": KAFKA_BOOTSTRAP_SERVERS})

    with open(file, newline="") as f:
        reader = csv.DictReader(f)
        count = 0
        for row in reader:
            producer.produce(
                topic=topic,
                key=row["user_id"],
                value=json.dumps(row),
                callback=_delivery_report,
            )
            producer.poll(0)
            count += 1

            if count % 100 == 0:
                print(f"Sent {count} messages...")

            if delay > 0:
                time.sleep(delay)

    producer.flush()
    print(f"Done. {count} messages sent to topic '{topic}'.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Publish CSV rows to Kafka")
    parser.add_argument("--file", required=True, help="CSV file path to read")
    parser.add_argument("--topic", default=KAFKA_TOPIC, help="Kafka topic name")
    parser.add_argument("--delay", type=float, default=DEFAULT_DELAY, help="Delay between messages (seconds)")
    args = parser.parse_args()
    publish(args.file, args.topic, args.delay)
