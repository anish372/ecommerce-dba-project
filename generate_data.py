"""
generate_data.py
-----------------
Populates the e-commerce schema with realistic, skewed data so that
your query-optimization case study (step 4 of the project) actually
has something to optimize.

Why "skewed" matters: a uniform random dataset is unrealistically easy
for the query planner. Real e-commerce data has power-law behavior —
a small number of customers place a large share of orders, a small
number of products account for most order volume, etc. This script
mimics that on purpose.

Usage:
    pip install faker psycopg2-binary numpy
    python generate_data.py --customers 50000 --products 2000 --orders 600000

Adjust the counts down if you're running this on a laptop with limited
RAM/disk — 50k customers / 600k orders is already enough to make
unindexed queries visibly slow (multi-second) on a typical machine.
"""

import argparse
import random
from datetime import datetime, timedelta

import numpy as np
import psycopg2
from psycopg2.extras import execute_values
from faker import Faker

fake = Faker("en_IN")
Faker.seed(42)
random.seed(42)
np.random.seed(42)

INDIAN_STATES_CITIES = [
    ("Bengaluru", "Karnataka"), ("Chennai", "Tamil Nadu"), ("Hyderabad", "Telangana"),
    ("Coimbatore", "Tamil Nadu"), ("Kochi", "Kerala"), ("Mumbai", "Maharashtra"),
    ("Pune", "Maharashtra"), ("Delhi", "Delhi"), ("Kolkata", "West Bengal"),
    ("Ahmedabad", "Gujarat"),
]

CATEGORIES = [
    "Electronics", "Mobiles & Accessories", "Fashion - Men", "Fashion - Women",
    "Home & Kitchen", "Books", "Beauty & Personal Care", "Sports & Fitness",
    "Grocery", "Toys & Baby",
]

PAYMENT_METHODS = ["CARD", "UPI", "NETBANKING", "COD", "WALLET"]
ORDER_STATUSES_FLOW = ["PLACED", "CONFIRMED", "SHIPPED", "DELIVERED"]


def get_conn(dsn: str):
    return psycopg2.connect(dsn)


def insert_categories(cur):
    rows = [(name,) for name in CATEGORIES]
    execute_values(cur, "INSERT INTO categories (category_name) VALUES %s", rows)
    cur.execute("SELECT category_id FROM categories")
    return [r[0] for r in cur.fetchall()]


def insert_warehouses(cur):
    rows = [(f"{city} Fulfillment Center", city, state) for city, state in INDIAN_STATES_CITIES[:6]]
    execute_values(
        cur,
        "INSERT INTO warehouses (warehouse_name, city, state) VALUES %s",
        rows,
    )
    cur.execute("SELECT warehouse_id FROM warehouses")
    return [r[0] for r in cur.fetchall()]


def insert_customers(cur, n):
    print(f"Generating {n} customers...")
    batch = []
    for _ in range(n):
        city, state = random.choice(INDIAN_STATES_CITIES)
        signup = fake.date_between(start_date="-3y", end_date="today")
        batch.append((
            fake.first_name(), fake.last_name(), fake.unique.email(),
            fake.numerify("9#########"), signup, city, state, random.random() > 0.05
        ))
        if len(batch) >= 5000:
            _flush_customers(cur, batch); batch = []
    if batch:
        _flush_customers(cur, batch)
    cur.execute("SELECT customer_id FROM customers")
    return [r[0] for r in cur.fetchall()]


def _flush_customers(cur, batch):
    execute_values(
        cur,
        """INSERT INTO customers
           (first_name, last_name, email, phone, signup_date, city, state, is_active)
           VALUES %s""",
        batch,
    )


def insert_products(cur, n, category_ids):
    print(f"Generating {n} products...")
    batch = []
    for i in range(n):
        price = round(random.lognormvariate(mu=6.5, sigma=1.0), 2)  # skewed price distribution
        price = min(max(price, 49), 150000)
        batch.append((
            f"SKU-{100000+i}", fake.catch_phrase()[:100], random.choice(category_ids),
            price, random.random() > 0.03
        ))
    execute_values(
        cur,
        """INSERT INTO products (sku, product_name, category_id, unit_price, is_active)
           VALUES %s""",
        batch,
    )
    cur.execute("SELECT product_id, unit_price FROM products")
    return cur.fetchall()  # list of (product_id, unit_price)


def insert_inventory(cur, products, warehouse_ids):
    print("Generating inventory...")
    batch = []
    for product_id, _ in products:
        for wh_id in warehouse_ids:
            qty = int(np.random.exponential(scale=40))  # most SKUs low stock, a few deep stock
            batch.append((product_id, wh_id, qty, 20))
    execute_values(
        cur,
        """INSERT INTO inventory (product_id, warehouse_id, quantity, reorder_level)
           VALUES %s""",
        batch,
    )


def zipf_customer_ids(customer_ids, n_orders):
    """Pareto-style skew: a minority of customers place most orders."""
    n_cust = len(customer_ids)
    # Zipf exponent >1 gives a strong head/long-tail split
    ranks = np.random.zipf(a=1.5, size=n_orders)
    ranks = np.clip(ranks, 1, n_cust)
    idx = ranks - 1
    return [customer_ids[i] for i in idx]


def insert_orders_and_items(cur, conn, customer_ids, products, n_orders, batch_size=10000):
    print(f"Generating {n_orders} orders with line items...")
    product_ids_weights = np.array([p[1] for p in products], dtype=float)
    # Cheaper/popular items should sell more often -> inverse weight by price rank
    popularity = 1.0 / (np.argsort(np.argsort(product_ids_weights)) + 1)
    popularity = popularity / popularity.sum()

    order_customers = zipf_customer_ids(customer_ids, n_orders)
    start_date = datetime.now() - timedelta(days=365)

    order_batch = []
    for i in range(n_orders):
        order_date = start_date + timedelta(
            seconds=random.randint(0, 365 * 24 * 3600)
        )
        status = random.choices(
            ORDER_STATUSES_FLOW + ["CANCELLED", "RETURNED"],
            weights=[5, 5, 10, 65, 10, 5],
        )[0]
        city, state = random.choice(INDIAN_STATES_CITIES)
        order_batch.append((order_customers[i], order_date, status, 0, city, state))

        if len(order_batch) >= batch_size:
            _flush_orders_and_items(cur, conn, order_batch, products, popularity)
            order_batch = []
            print(f"  ...{i+1}/{n_orders} orders committed")
    if order_batch:
        _flush_orders_and_items(cur, conn, order_batch, products, popularity)


def _flush_orders_and_items(cur, conn, order_batch, products, popularity):
    returned = execute_values(
        cur,
        """INSERT INTO orders (customer_id, order_date, status, total_amount, shipping_city, shipping_state)
           VALUES %s RETURNING order_id""",
        order_batch,
        fetch=True,
    )
    order_ids = [r[0] for r in returned]

    item_rows = []
    status_rows = []
    payment_rows = []
    product_ids = [p[0] for p in products]
    product_price = {p[0]: p[1] for p in products}

    for order_id, (cust_id, order_date, status, _, _, _) in zip(order_ids, order_batch):
        n_items = np.random.choice([1, 2, 3, 4, 5], p=[0.45, 0.25, 0.15, 0.1, 0.05])
        chosen = np.random.choice(product_ids, size=n_items, replace=False, p=popularity)
        order_total = 0
        for pid in chosen:
            qty = random.randint(1, 3)
            price = float(product_price[pid])
            item_rows.append((order_id, int(pid), qty, price))
            order_total += qty * price

        status_rows.append((order_id, "PLACED", order_date))
        if status != "PLACED":
            status_rows.append((order_id, status, order_date + timedelta(hours=random.randint(1, 72))))

        payment_rows.append((
            order_id, round(order_total, 2), random.choice(PAYMENT_METHODS),
            "SUCCESS" if status != "CANCELLED" else "FAILED",
            order_date,
        ))

    execute_values(
        cur,
        "INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES %s",
        item_rows,
    )
    execute_values(
        cur,
        "INSERT INTO order_status_history (order_id, status, changed_at) VALUES %s",
        status_rows,
    )
    execute_values(
        cur,
        "INSERT INTO payments (order_id, amount, payment_method, payment_status, paid_at) VALUES %s",
        payment_rows,
    )

    # backfill order totals in this batch
    cur.execute("""
        UPDATE orders o
        SET total_amount = sub.total
        FROM (
            SELECT order_id, SUM(quantity * unit_price) AS total
            FROM order_items
            WHERE order_id = ANY(%s)
            GROUP BY order_id
        ) sub
        WHERE o.order_id = sub.order_id
    """, (order_ids,))

    conn.commit()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dsn", default="dbname=ecommerce_dba user=postgres password=postgres host=localhost port=5432")
    parser.add_argument("--customers", type=int, default=50000)
    parser.add_argument("--products", type=int, default=2000)
    parser.add_argument("--orders", type=int, default=600000)
    args = parser.parse_args()

    conn = get_conn(args.dsn)
    conn.autocommit = False
    cur = conn.cursor()

    category_ids = insert_categories(cur)
    warehouse_ids = insert_warehouses(cur)
    conn.commit()

    customer_ids = insert_customers(cur, args.customers)
    conn.commit()

    products = insert_products(cur, args.products, category_ids)
    conn.commit()

    insert_inventory(cur, products, warehouse_ids)
    conn.commit()

    insert_orders_and_items(cur, conn, customer_ids, products, args.orders)

    cur.close()
    conn.close()
    print("Done. Database populated.")


if __name__ == "__main__":
    main()
