-- =========================================================
-- E-Commerce Order Management Database
-- DBA Portfolio Project — Schema (PostgreSQL)
-- =========================================================
-- Design notes:
--  - Normalized to 3NF.
--  - order_status_history exists separately from orders.status
--    so we can show state-transition queries and audit trails
--    (a common real-world DBA/reporting requirement).
--  - inventory is per (product, warehouse) to model multi-warehouse
--    stock, which is what makes "low stock" queries non-trivial.
--  - Indexes are added deliberately AFTER you've run the "before"
--    EXPLAIN ANALYZE in step 4 of the project — don't create them
--    all up front, or you lose your before/after story.
-- =========================================================

DROP TABLE IF EXISTS returns CASCADE;
DROP TABLE IF EXISTS payments CASCADE;
DROP TABLE IF EXISTS order_status_history CASCADE;
DROP TABLE IF EXISTS order_items CASCADE;
DROP TABLE IF EXISTS orders CASCADE;
DROP TABLE IF EXISTS inventory CASCADE;
DROP TABLE IF EXISTS products CASCADE;
DROP TABLE IF EXISTS categories CASCADE;
DROP TABLE IF EXISTS warehouses CASCADE;
DROP TABLE IF EXISTS customers CASCADE;

-- =========================================================
-- Reference / dimension tables
-- =========================================================

CREATE TABLE customers (
    customer_id     BIGSERIAL PRIMARY KEY,
    first_name      VARCHAR(50)  NOT NULL,
    last_name       VARCHAR(50)  NOT NULL,
    email           VARCHAR(150) NOT NULL UNIQUE,
    phone           VARCHAR(20),
    signup_date     DATE NOT NULL DEFAULT CURRENT_DATE,
    city            VARCHAR(80),
    state           VARCHAR(80),
    is_active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE categories (
    category_id     SERIAL PRIMARY KEY,
    category_name   VARCHAR(100) NOT NULL UNIQUE,
    parent_category_id INTEGER REFERENCES categories(category_id)
);

CREATE TABLE products (
    product_id      BIGSERIAL PRIMARY KEY,
    sku             VARCHAR(30) NOT NULL UNIQUE,
    product_name    VARCHAR(200) NOT NULL,
    category_id     INTEGER NOT NULL REFERENCES categories(category_id),
    unit_price      NUMERIC(10,2) NOT NULL CHECK (unit_price >= 0),
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE warehouses (
    warehouse_id    SERIAL PRIMARY KEY,
    warehouse_name  VARCHAR(100) NOT NULL,
    city            VARCHAR(80) NOT NULL,
    state           VARCHAR(80) NOT NULL
);

-- =========================================================
-- Inventory (per product, per warehouse)
-- =========================================================

CREATE TABLE inventory (
    inventory_id    BIGSERIAL PRIMARY KEY,
    product_id      BIGINT NOT NULL REFERENCES products(product_id),
    warehouse_id    INTEGER NOT NULL REFERENCES warehouses(warehouse_id),
    quantity        INTEGER NOT NULL CHECK (quantity >= 0),
    reorder_level   INTEGER NOT NULL DEFAULT 20,
    updated_at      TIMESTAMP NOT NULL DEFAULT NOW(),
    UNIQUE (product_id, warehouse_id)
);

-- =========================================================
-- Orders and line items
-- =========================================================

CREATE TABLE orders (
    order_id        BIGSERIAL PRIMARY KEY,
    customer_id     BIGINT NOT NULL REFERENCES customers(customer_id),
    order_date      TIMESTAMP NOT NULL DEFAULT NOW(),
    status          VARCHAR(20) NOT NULL DEFAULT 'PLACED'
                        CHECK (status IN ('PLACED','CONFIRMED','SHIPPED','DELIVERED','CANCELLED','RETURNED')),
    total_amount    NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (total_amount >= 0),
    shipping_city   VARCHAR(80),
    shipping_state  VARCHAR(80)
);

CREATE TABLE order_items (
    order_item_id   BIGSERIAL PRIMARY KEY,
    order_id        BIGINT NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    product_id      BIGINT NOT NULL REFERENCES products(product_id),
    quantity        INTEGER NOT NULL CHECK (quantity > 0),
    unit_price      NUMERIC(10,2) NOT NULL CHECK (unit_price >= 0),
    line_total      NUMERIC(12,2) GENERATED ALWAYS AS (quantity * unit_price) STORED
);

CREATE TABLE order_status_history (
    history_id      BIGSERIAL PRIMARY KEY,
    order_id        BIGINT NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    status          VARCHAR(20) NOT NULL,
    changed_at      TIMESTAMP NOT NULL DEFAULT NOW()
);

-- =========================================================
-- Payments and returns
-- =========================================================

CREATE TABLE payments (
    payment_id      BIGSERIAL PRIMARY KEY,
    order_id        BIGINT NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    amount          NUMERIC(12,2) NOT NULL CHECK (amount >= 0),
    payment_method  VARCHAR(20) NOT NULL CHECK (payment_method IN ('CARD','UPI','NETBANKING','COD','WALLET')),
    payment_status  VARCHAR(20) NOT NULL DEFAULT 'SUCCESS'
                        CHECK (payment_status IN ('SUCCESS','FAILED','REFUNDED','PENDING')),
    paid_at         TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE returns (
    return_id       BIGSERIAL PRIMARY KEY,
    order_item_id   BIGINT NOT NULL REFERENCES order_items(order_item_id),
    reason          VARCHAR(200),
    return_date     TIMESTAMP NOT NULL DEFAULT NOW(),
    refund_amount   NUMERIC(10,2) NOT NULL CHECK (refund_amount >= 0)
);

-- =========================================================
-- Baseline indexes (foreign keys only — deliberately minimal)
-- Add tuning indexes later, after you've captured the "before"
-- EXPLAIN ANALYZE output for your case-study queries.
-- =========================================================

CREATE INDEX idx_products_category ON products(category_id);
CREATE INDEX idx_inventory_product ON inventory(product_id);
CREATE INDEX idx_inventory_warehouse ON inventory(warehouse_id);
CREATE INDEX idx_orders_customer ON orders(customer_id);
CREATE INDEX idx_order_items_order ON order_items(order_id);
CREATE INDEX idx_order_items_product ON order_items(product_id);
CREATE INDEX idx_payments_order ON payments(order_id);
CREATE INDEX idx_status_history_order ON order_status_history(order_id);
