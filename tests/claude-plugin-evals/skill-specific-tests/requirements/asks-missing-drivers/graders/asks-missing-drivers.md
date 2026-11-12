---
type: llm
---

The user's notes give these facts: the Kafka topic `orders`, a sample record, the result, and the freshness. The result is a GraphQL API with the daily order total for each customer. The freshness is 5 minutes.

PASS if the reply asks the user about all three of these:
- the workload: the data volume or the event rate
- the budget for running the pipeline
- who may access the results, or whether access needs authorization

FAIL if the reply misses one of those three.
FAIL if the reply asks for the name of the Kafka topic, or asks how old the results can be. The notes give both.

These are new questions, not repeated ones, so they do not make the reply fail:
- who runs the topic, its format, or if it can be replayed
- how late an event can arrive and still count
