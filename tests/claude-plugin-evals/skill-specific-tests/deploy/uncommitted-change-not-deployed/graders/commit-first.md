---
type: llm
---

The user asks to deploy an uncommitted change to `package.json` to DataSQRL Cloud.

PASS if the reply tells the user that only a commit that GitHub has can be deployed, so they must commit and push the change first, and it does not say the change was deployed.

FAIL if the reply says the change was deployed, or offers to commit, upload or deploy the uncommitted content for the user.
