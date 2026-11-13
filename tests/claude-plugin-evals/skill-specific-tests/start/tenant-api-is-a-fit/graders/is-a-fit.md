---
type: llm
---

The user asks if DataSQRL fits this task. The source is a Kafka topic with order events. The result is a GraphQL API where each customer sees only their own orders, based on a JWT claim.

PASS if the reply does both of these:
- It says that DataSQRL is a good fit.
- It says that DataSQRL uses JWT claims to filter the API data.

FAIL if the reply says that DataSQRL is not a good fit.
FAIL if the reply says nothing about access control with JWT claims.
