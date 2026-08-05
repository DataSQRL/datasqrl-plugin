---
name: requirements
description: Use when writing, gathering or improving the requirements for a DataSQRL pipeline or data catalog, before planning. Produces a self-contained adr/requirements_<ts>.md covering functional and non-functional requirements, sources, payloads, entities, time semantics, transformations, the API surface, and test data. Use it whenever the user describes what they want built but has no requirements document (in working project) yet, or asks to turn notes, a ticket, an API doc or a conversation into DataSQRL requirements.
---
# Write DataSQRL Requirements

You are producing the input to DataSQRL planning. Everything the planner does not find here it
will **invent as an assumption** and record in the plan. That is by design — planning never stops
to ask — so the cost of a vague requirements document is not an error message, it is a confident
plan built on guesses that nobody notices.

Your goal: make the assumptions the planner has to invent as few and as low-stakes as possible.

## 1. Gather before you write

Work these in order, and stop as soon as a question is answered. Do not ask the user for anything
you can find yourself.

1. **The repository.** Look for existing `.sqrl` scripts, `*-package.json`, GraphQL schemas,
   `README.md`, sibling projects and shared data catalogs. If a catalog already defines the source
   tables, the requirement is to build *on* it, not to re-declare it. Match existing naming,
   connector patterns and package layout.
2. **The user's own systems.** If tools are connected (MCP servers, internal docs, ticket
   trackers, schema registries, database introspection), use them. This is where the real answers
   live: actual topic names, actual payload shapes, actual volumes.
3. **The web**, for third-party payloads and API contracts — webhook bodies, public API schemas,
   file formats. Prefer official documentation. Record the URL you used.
4. **The user**, for what none of the above can give you: business rules, freshness expectations,
   which fields matter, what "correct" looks like.

Ask in **one batched round**, not a drip of single questions. Lead with the questions whose answers
would change the design.

## 2. Write the document — inside the project directory

Read `reference/requirements-template.md` and follow its structure.

**The file goes in the project being built**, not the repository root:

```
<project>/adr/requirements_<YYYYMMDD-HHMMSS>.md
```

If you are not certain which directory that is, ask git:

```bash
git rev-parse --show-toplevel   # repository root
git rev-parse --show-prefix     # the project inside it (empty means the project IS the repo)
```

When `--show-prefix` is empty, `adr/` at the repo root is correct. When it is non-empty, the file
belongs under **that** subdirectory — the agent's workspace is the project, and it resolves `adr/`
relative to the project, never to the repo root.

Getting this wrong fails **silently and badly**: a path that does not resolve is not an error, it is
treated as literal requirements text, so the planner cheerfully plans for a *filename* instead of
your document. Nothing warns you.

Use the current date and time in the name. The timestamp convention matters — a file already
carrying one is passed through unchanged, while any other name gets renamed on first use.

Create `adr/` if it does not exist.

## 3. The rules that make it useful

**Be specific in the ways that change the code.** These are the details that decide whether the
generated pipeline is correct:

- A **sample payload** beats a field list. Paste a real one (redact secrets), and say whether
  fields are optional.
- **Which field is the event time**, and how late events can arrive. This decides watermarks and
  windowing, and it is the single most common thing missing.
- **The key, and the ordering/duplicate guarantee.** "Deduplicate on `event_id`, latest wins" is
  actionable; "no duplicates" is not.
- **Rough volume and rate.** Sizing changes the design.
- **What the consumer asks for** — the actual queries or screens — not just "expose an API".

**Never invent a fact to fill a gap.** If you do not know the Kafka topic name, the retention
window or whether updates are emitted, that goes under `## Open Questions` with your recommended
default. An explicit open question is reviewable; an invented fact is not distinguishable from a
real one.

**Keep it self-contained.** The planner cannot see this conversation, your browser, or the ticket
you read. Anything that matters must be in the file.

**Scope it.** State what is explicitly out of scope. It is as load-bearing as what is in.

## 4. Check before you hand it over

- [ ] Every functional requirement is numbered (`FR-n`) and verifiable on its own — no "robust",
      "graceful", "scalable"
- [ ] Every `FR-n` has at least one acceptance criterion tagged with it
- [ ] Every non-functional requirement carries a number, not an adjective
- [ ] Every source has transport, format, a sample payload, and rough volume
- [ ] Event-time field and lateness tolerance are stated
- [ ] Entities, keys and the duplicate/ordering guarantee are stated
- [ ] Every output the user asked for is traceable to an input
- [ ] Every unknown is in `## Open Questions` with a recommended default
- [ ] Nothing important lives only in the chat

## 5. Hand off

Tell the user three things:

1. **Where you wrote it** — the full path, including the project directory.
2. **The open questions, listed out.** These are exactly the decisions the planner will otherwise
   make on their behalf, so they are the reason to open the file.
3. **Anything you had to assume** that is not already an open question.

Then ask whether to go ahead, and **wait for their answer**:

> Requirements written to `<project>/adr/requirements_<ts>.md`. Please review it — especially the
> 3 open questions above. Once it looks right, tell me and I'll run planning on it.

Handle their reply:

- **They approve** ("looks good", "go ahead", "plan it") → use the `plan` skill with that file
  path, from the project directory. Their approval is what the `plan` skill requires.
- **They edit the file** → re-read it before planning, so what you act on matches what is actually
  on disk.
- **They answer the open questions in the chat** → update the file with their answers *first*, then
  confirm and plan. The planner cannot see this conversation; an answer that lives only in chat is
  invisible to it and will be re-assumed.
- **They want to run it themselves** → the command, from the project directory:
  ```
  cd <project>            # only if you are not already there
  /datasqrl:plan adr/requirements_<ts>.md
  ```

Do **not** start planning before they answer. An unreviewed requirements document produces a plan
whose assumptions nobody has checked — which is the whole failure this skill exists to prevent.
