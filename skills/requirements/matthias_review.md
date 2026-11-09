It is important that the requirements capture:

- what are the sources of data and what - if anything - needs to be captured
- what the result is (data lake/product, API, stream)
- how quickly new data from a source needs to be reflected in the results. What staleness is acceptable? Does it really need to be realtime (push back since it is more expensive)? This is critical to understand since it drives architecture.
- what is the workload (how much data, how many events, etc) and what are the budget constraints and reliability expectations for this workload.
- what are the SLA/latency requirements for the API (if the result is served via API)


have `plan` review requirements for these criteria and point out gaps to user.