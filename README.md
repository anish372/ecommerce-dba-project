# E-Commerce Order Management Database

I built this to have something real to point to when applying for DBA
and data analyst roles — most of the "portfolio projects" I saw online
were just a schema and maybe a couple of SELECT statements, so I wanted
to actually go through the things a DBA gets asked about: indexing
decisions backed by real numbers, a backup that's actually been
restored from, and a replica that's actually been tested, not just
configured.

Everything below is stuff I ran myself against a real 600K-order
Postgres database, not estimated or made up.

## What's here

- **schema.sql** — 10-table normalized schema (customers, orders,
  order_items, inventory across multiple warehouses, payments, returns,
  order status history, etc.)
- **docker-compose.yml** — spins up Postgres in one command
- **generate_data.py** — fills the schema with realistic, skewed data
  (Faker + numpy) — customer order counts follow a Zipf distribution
  because real customers don't order uniformly, and neither should test
  data
- **optimization_queries.sql** / **case_study.md** — four queries I
  optimized, with real EXPLAIN ANALYZE output before and after indexing
- **recovery_plan.md** — a backup/restore cycle including a simulated
  DROP TABLE incident
- **REPLICATION.md** — a working streaming replica, set up and verified

## Getting it running

```bash
docker compose up -d
pip install faker psycopg2-binary numpy
python generate_data.py --dsn "dbname=ecommerce_dba user=postgres password=postgres host=localhost port=5432" \
  --customers 50000 --products 2000 --orders 600000
```

Takes 15-30 minutes to generate depending on your machine. Grab a
coffee.

## The query optimization part

This is the part I'd actually walk an interviewer through. I picked
four queries that felt like real business questions — top customers by
lifetime value, low-stock products across warehouses, monthly revenue
by category, orders stuck in a status too long — and measured them
before and after adding indexes.

Two of the results were the boring "added an index, got faster" story:
the monthly revenue query went from 2.2 seconds down to about 875ms
once I stopped a sort from spilling 13-14MB to disk per worker. That
one's satisfying because you can see the exact moment `external merge
Disk` turns into `quicksort Memory` in the plan.

The other two were more interesting, honestly. The top-customers query
barely moved (270ms → 265ms) because it's aggregating over roughly 90%
of the orders table — no index fixes that, you'd need a materialized
rollup instead. And the "stuck orders" query actually looked like it
got *worse* after indexing on my first measurement (643ms → 1055ms).
Turned out that was cold-cache noise right after creating the index —
I re-ran it three more times and it settled at a consistent ~554ms,
about 14% faster. I almost didn't catch that and would've written up a
wrong conclusion. Full breakdown with the actual EXPLAIN ANALYZE output
is in case_study.md.

## Backup and recovery

Took a `pg_dump` backup (41MB, custom format), then actually dropped a
table on purpose — `DROP TABLE order_items CASCADE` — to see what
breaks and whether the backup holds up. It did: restored all 1,230,169
rows with zero loss in about 50 seconds. Details and the exact commands
are in recovery_plan.md, including what this setup *doesn't* cover
(point-in-time recovery, off-host storage) if I were doing this for
real.

## Replication

Set up a streaming read replica — `pg_basebackup` clone, standby mode,
live WAL streaming. Confirmed it actually works by inserting a row on
the primary and watching it show up on the replica within a couple
seconds, and confirmed the replica genuinely rejects writes rather than
just being a stale copy.

Hit a real permissions bug doing this: the base backup ran as root
inside the container, so when Postgres tried to start as the `postgres`
user it couldn't read its own config file. Fixed it by chowning the
data directory before starting the server. Left the details in
REPLICATION.md because "here's a bug I hit and how I fixed it" is more
useful than pretending everything worked first try.

## Still to do

Security and access control — role-based users (read-only analyst vs.
app read/write vs. admin), row-level security, basic audit logging.
Haven't gotten to this part yet.
