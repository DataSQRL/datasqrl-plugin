---
type: llm
---

The user asks if DataSQRL can run ad hoc SQL queries that their analysts write.

PASS if the reply does both of these:
- It says that DataSQRL does not execute custom or ad hoc queries.
- It points to a data warehouse or a query engine for those queries.

The reply can also say that DataSQRL builds the tables that those queries read. That is correct.

FAIL if the reply says that DataSQRL runs the analysts' ad hoc queries.
