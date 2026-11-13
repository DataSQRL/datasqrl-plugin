---
description: A question about a per-customer GraphQL API over Kafka. The start skill answers from its "Using DataSQRL" section that DataSQRL fits.
tags: [start]
max_turns: 10
allowed_tools: [Read, Glob, Grep, Skill]
---

We get order events on a Kafka topic. We want a GraphQL API where each customer sees only their own orders, based on the customer id in their JWT. Is DataSQRL a good fit for this? Do not build anything yet.
