# Requirements template

Copy this structure into `adr/requirements_<YYYYMMDD-HHMMSS>.md`. Every section is answered one of three ways: a stated value, an entry in `## Open Questions` with a recommended default, or an explicit note that it does not apply to this pipeline.

**Vague and specific request examples:**

> vague: *ingest transcription events and aggregate them*
>
> specific: *POST `/webhooks/transcription`, JSON body, ~50/min peak, at-least-once delivery, deduplicate on `meeting_id`, event time is `completed_at` (RFC3339, UTC), up to 2 min late*

---

## Goal

One or two sentences: what this pipeline is for, and who consumes it. State the business outcome.

## Scope

**In scope:** what this work delivers.

**Out of scope:** what this work deliberately excludes. Name the tempting adjacent things.

## Functional requirements

What the system must **do**, as numbered statements: one behavior each, each verifiable on its own.

This is the spine of the document. The sections below (Sources, Transformations, API surface) are the detail that implements these; the plan's checklist and the acceptance criteria both map back here. Give each an id so they can be referenced.

Write each one so that a test can pass or fail it:

- **FR-1**: Ingest `<source>` continuously; each record is queryable within `<n>` seconds of arrival.
- **FR-2**: Deduplicate `<entity>` on `<key>`, keeping the latest by `<event-time field>`.
- **FR-3**: Expose `<query>` returning `<shape>`, filtered by `<parameter>`, for `<consumer>`.
- **FR-4**: Recompute `<aggregate>` when a late event lands inside the `<n>`-minute window.
- **FR-5**: Reject `<invalid input>` with `<behavior>` rather than dropping it silently.

A statement that no test can fail belongs in Non-functional requirements with a number attached.

## Sources

One subsection per source.

### `<source name>`

- **Transport**: Kafka topic (name it), webhook/REST endpoint (give the path and method), database table, file drop, object store path.
- **Format**: JSON / Avro / Parquet / CSV. Schema registry, if any.
- **Sample payload**: a real record, redacted. Mark optional and nullable fields.
- **Volume and rate**: records/sec or /day, average and peak. Expected growth.
- **Delivery guarantee**: at-least-once / exactly-once / unknown. Can records be replayed?
- **Duplicates and ordering**: what identifies a duplicate, which copy wins, is per-key order guaranteed?
- **Updates**: are records immutable events, or updates to prior state (CDC, upserts)?

## Time semantics

These decide watermarks and windowing.

- **Event-time field**: name, type, timezone, format.
- **Lateness**: how late an event can arrive and still count.
- **Processing time acceptable?**: say so explicitly when event time is unavailable.

## Entities and keys

The nouns of the domain, their primary keys, and how they relate. If a source table already exists in a shared data catalog, reference it rather than redefining it.

## Transformations and aggregations

What must be computed. For each: the input, the grouping, the window (tumbling/sliding/session + size, or unbounded), and the aggregation. State how late-arriving data should affect a result that was already emitted.

## API surface

What consumers need, concretely.

- **Queries**: the actual questions asked, with their parameters and expected shape.
- **Mutations**: write endpoints, and what they accept.
- **Subscriptions**: what should push, and on what trigger.
- **Access**: public, authenticated, per-tenant? Which field carries the tenant.

## Test data and acceptance criteria

- **Test data**: what representative records look like, and which edge cases must be present (late arrival, duplicate, null field, out-of-order, empty group).
- **Acceptance criteria**: concrete enough to write an assertion against, and **tagged with the requirement each one proves**. "*(FR-2)* Given these 5 input records, two of them duplicates on `order_id`, `daily_totals` returns exactly these 2 rows."

If possible every FR need at least one criterion.

## Non-functional requirements

How well it must do it, with numbers rather than adjectives. List what constrains the design.

- **Freshness / latency**: end-to-end target, and measured from what to what.
- **Throughput**: sustained and peak, and what happens above peak.
- **Retention**: how long data is kept, and what happens at the boundary.
- **PII and sensitive fields**: which fields, and what is required of them (masking, exclusion from the API, restricted access).
- **Compliance**: regimes that constrain storage, residency or deletion.
- **Availability**: expectations during deploys and failures.

## Open Questions

Everything left open, each with a **recommended default** and an impact rating.

- **<question>**. Recommended default: *<what to assume if unanswered>*. Impact if wrong: high / medium / low.
