#!/bin/bash
# Writes a small DataSQRL project at the root of a new git repository. The project computes the
# daily order total of each customer in the column `total`.
set -euo pipefail

cat > orders.sqrl <<'EOF'
IMPORT orders-source.Orders;

DailyTotals := SELECT customer_id, CAST(created_at AS DATE) AS day, SUM(amount) AS total
               FROM Orders GROUP BY customer_id, CAST(created_at AS DATE);
EOF

cat > package.json <<'EOF'
{ "version": "1", "script": { "main": "orders.sqrl" } }
EOF

git init -q
git add -A
git -c user.name=eval -c user.email=eval@example.com commit -q -m "orders project"
