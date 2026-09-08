-- =========================================================
-- Query Optimization Case Study — runnable SQL
-- Run schema.sql + generate_data.py first.
-- See case_study.md for the full before/after write-up and numbers.
-- =========================================================

-- Always start with fresh stats before measuring.
VACUUM ANALYZE;

-- -------------------------------------------------------
-- Query 1: Top 10 customers by lifetime order value
-- -------------------------------------------------------
EXPLAIN ANALYZE
SELECT c.customer_id, c.first_name, c.last_name, SUM(o.total_amount) AS lifetime_value
FROM customers c
JOIN orders o ON o.customer_id = c.customer_id
WHERE o.status <> 'CANCELLED'
GROUP BY c.customer_id, c.first_name, c.last_name
ORDER BY lifetime_value DESC
LIMIT 10;

-- Index (aggregation touches most of the table, so expect a small gain)
CREATE INDEX IF NOT EXISTS idx_orders_customer_active_total
  ON orders(customer_id, total_amount) WHERE status <> 'CANCELLED';

-- -------------------------------------------------------
-- Query 2: Low-stock products across warehouses
-- -------------------------------------------------------
EXPLAIN ANALYZE
SELECT p.product_id, p.product_name, w.warehouse_name, i.quantity, i.reorder_level
FROM inventory i
JOIN products p ON p.product_id = i.product_id
JOIN warehouses w ON w.warehouse_id = i.warehouse_id
WHERE i.quantity < i.reorder_level
ORDER BY i.quantity ASC;

-- Index (useful mainly at larger inventory scale — see case_study.md)
CREATE INDEX IF NOT EXISTS idx_inventory_low_stock
  ON inventory(warehouse_id, quantity) WHERE quantity < reorder_level;

-- -------------------------------------------------------
-- Query 3: Monthly revenue by category
-- -------------------------------------------------------
EXPLAIN ANALYZE
SELECT date_trunc('month', o.order_date) AS month, c.category_name, SUM(oi.line_total) AS revenue
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
JOIN products p ON p.product_id = oi.product_id
JOIN categories c ON c.category_id = p.category_id
WHERE o.status NOT IN ('CANCELLED')
GROUP BY 1, 2
ORDER BY 1, revenue DESC;

-- Indexes
CREATE INDEX IF NOT EXISTS idx_orders_month ON orders (date_trunc('month', order_date));
CREATE INDEX IF NOT EXISTS idx_order_items_order_covering
  ON order_items(order_id) INCLUDE (product_id, line_total);

-- -------------------------------------------------------
-- Query 4: Orders stuck in a status too long (>3 days)
-- -------------------------------------------------------
EXPLAIN ANALYZE
SELECT o.order_id, o.status, o.order_date,
       (SELECT MAX(h.changed_at) FROM order_status_history h WHERE h.order_id = o.order_id) AS last_status_change
FROM orders o
WHERE o.status IN ('PLACED','CONFIRMED')
  AND o.order_date < NOW() - INTERVAL '3 days';

-- Index
CREATE INDEX IF NOT EXISTS idx_orders_status_date ON orders(status, order_date);

-- -------------------------------------------------------
-- Re-run all four EXPLAIN ANALYZE statements above after the
-- VACUUM ANALYZE below to capture your own "after" numbers.
-- -------------------------------------------------------
VACUUM ANALYZE;
