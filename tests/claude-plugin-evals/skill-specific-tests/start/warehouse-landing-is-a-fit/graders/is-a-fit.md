---
type: llm
---

The user asks if DataSQRL fits this task. The source is change data capture (CDC) from a Postgres database. The pipeline enriches the changes with customer data and lands the result in Iceberg. Analysts query the result from Snowflake.

PASS if the reply does both of these:
- It says that DataSQRL is a good fit.
- It says that DataSQRL lands the data in Iceberg and makes it available to Snowflake, for example through generated views.

The reply can also say that the analysts' own queries run in Snowflake and not in DataSQRL, and that models inside the warehouse stay in dbt. That is correct.

FAIL if the reply says that DataSQRL is not a good fit.
FAIL if the reply sends the user to dbt or SQLMesh for the whole task.
