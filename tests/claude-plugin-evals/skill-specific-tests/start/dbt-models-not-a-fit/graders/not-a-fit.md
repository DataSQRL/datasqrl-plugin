---
type: llm
---

The user asks if DataSQRL can build SQL models that run every night inside Snowflake, for the tables behind their finance dashboards. All their data is already in Snowflake.

PASS if the reply does both of these:
- It says that DataSQRL is not the right tool for scheduled models inside a warehouse.
- It points to dbt or SQLMesh for that work.

The reply can also say that DataSQRL builds the operational pipelines that land data in the warehouse, and that a team can use both tools. That is correct.

FAIL if the reply says that DataSQRL is a good fit for these scheduled models.
FAIL if the reply names neither dbt nor SQLMesh.
