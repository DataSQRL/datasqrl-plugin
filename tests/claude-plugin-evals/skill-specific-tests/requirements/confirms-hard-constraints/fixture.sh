#!/bin/bash
# Writes notes.md into a new git repository. The notes name Postgres only in passing, and they give
# a GraphQL query that existing clients already call.
set -euo pipefail

cat > notes.md <<'EOF'
# Order totals

We have order events on the Kafka topic `orders`. A record looks like this:

    {"order_id": "o-1001", "customer_id": "c-17", "amount": 42.50, "created_at": "2026-03-01T10:15:00Z"}

We want the daily order total for each customer. We could keep the totals in Postgres, I guess.

Our app already calls this query, so keep it exactly as it is:

    type Query {
      customerDailyTotals(customerId: String!, day: String!): DailyTotal
    }

    type DailyTotal {
      customerId: String!
      day: String!
      total: Float!
    }
EOF

git init -q
git add notes.md
git -c user.name=eval -c user.email=eval@example.com commit -q -m "notes"
