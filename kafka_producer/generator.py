import csv
import os
import uuid
import random
import argparse
from datetime import datetime, timedelta
from faker import Faker

fake = Faker()

CATEGORIES = ["Electronics", "Clothing", "Sports", "Books", "Home", "Beauty"]
PAYMENT_METHODS = ["credit_card", "debit_card", "kakao_pay", "naver_pay", "paypal"]

EVENT_TYPES = ["page_view", "add_to_cart", "order", "payment"]
EVENT_WEIGHTS = [0.50, 0.25, 0.15, 0.10]

FIELDNAMES = [
    "event_id", "event_type", "user_id", "session_id",
    "product_id", "product_name", "category",
    "quantity", "price", "order_id", "payment_method", "timestamp",
]


def _make_event(base_time: datetime) -> dict:
    event_type = random.choices(EVENT_TYPES, weights=EVENT_WEIGHTS)[0]
    category = random.choice(CATEGORIES)

    is_cart_or_order = event_type in ("add_to_cart", "order")
    is_transactional = event_type in ("order", "payment")

    return {
        "event_id": str(uuid.uuid4()),
        "event_type": event_type,
        "user_id": f"user-{random.randint(1, 200):03d}",
        "session_id": f"sess-{uuid.uuid4().hex[:8]}",
        "product_id": f"prod-{random.randint(1, 500):03d}",
        "product_name": fake.catch_phrase(),
        "category": category,
        "quantity": random.randint(1, 5) if is_cart_or_order else "",
        "price": round(random.uniform(5.0, 500.0), 2),
        "order_id": f"ord-{uuid.uuid4().hex[:8]}" if is_transactional else "",
        "payment_method": random.choice(PAYMENT_METHODS) if event_type == "payment" else "",
        "timestamp": (base_time + timedelta(seconds=random.randint(0, 86400))).isoformat(),
    }


def generate(rows: int, output: str) -> None:
    out_dir = os.path.dirname(output)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    base_time = datetime.now()
    with open(output, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDNAMES)
        writer.writeheader()
        for _ in range(rows):
            writer.writerow(_make_event(base_time))

    print(f"Generated {rows} rows → {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Generate fake e-commerce event CSV")
    parser.add_argument("--rows", type=int, default=1000, help="Number of rows to generate")
    parser.add_argument(
        "--output",
        default=f"data/events_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv",
        help="Output CSV file path",
    )
    args = parser.parse_args()
    generate(args.rows, args.output)
