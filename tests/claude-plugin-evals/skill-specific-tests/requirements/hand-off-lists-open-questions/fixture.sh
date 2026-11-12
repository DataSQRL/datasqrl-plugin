#!/bin/bash
# Writes notes.md into a new git repository. The notes state the source, the result and the
# freshness. They leave out the workload, the budget, the reliability, the API latency and who may
# read the results.
set -euo pipefail

cat > notes.md <<'EOF'
# Order totals

We have order events on the Kafka topic `orders`. A record looks like this:

    {"order_id": "o-1001", "customer_id": "c-17", "amount": 42.50, "created_at": "2026-03-01T10:15:00Z"}

We want a GraphQL API that returns the daily order total for each customer.
The totals can be up to 5 minutes old.
EOF

git init -q
git add notes.md
git -c user.name=eval -c user.email=eval@example.com commit -q -m "notes"
