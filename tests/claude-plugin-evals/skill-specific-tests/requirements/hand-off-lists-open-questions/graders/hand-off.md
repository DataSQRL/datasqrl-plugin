---
type: llm
---

The reply is the hand-off that follows the requirements file.

PASS if the reply does all of these:
- It gives the path of the file, `adr/requirements_<timestamp>.md`.
- It lists the open questions, one line each.
- It puts the driver questions. The driver questions are about workload, budget, reliability, API latency and authorization. 
- It tells the user that they can answer in the file or in the chat.
- It asks the user to answer the questions or to plan with the defaults.

FAIL if one of these is missing.
FAIL if the reply says that planning started.
