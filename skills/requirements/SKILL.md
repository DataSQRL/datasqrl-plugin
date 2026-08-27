---
name: requirements
description: Use when writing, gathering or improving the requirements for a DataSQRL pipeline or data catalog, before planning. Use whenever the user describes what they want built but has no requirements document (in working project) yet, or asks to turn notes, a ticket, an API doc or a conversation into DataSQRL requirements. Produces a self-contained adr/requirements_<ts>.md covering functional and non-functional requirements, sources, payloads, entities, time semantics, transformations, the API surface, and test data.
---
# Write DataSQRL Requirements

The requirements file is the source document for downstream stages: planning turns it into `adr/plan_<ts>.md`, and implementation builds from that plan. What this file specifies is what gets built. What it leaves open becomes a recorded assumption in the plan, so ask the user whatever is needed to close a gap, and record what stays open under `## Open Questions`.

Steps to follow:

1. [Information gathering](#1-gather-before-you-write)
2. [Writing the requirements file](#2-write-the-document-inside-the-project-directory)
3. [Detailing the requirements](#3-the-details-that-decide-the-pipeline)
4. [Reviewing the requirements](#4-check-before-you-hand-it-over)
5. [Delivering](#5-hand-off)

## 1. Gather before you write

Information gathering requires the following steps to be done in order.

1. **The repository.** Look for existing `.sqrl` scripts, `*-package.json`, GraphQL schemas, `README.md` in the current project, sibling projects and shared data catalogs. If a catalog already defines the source tables, the requirement is to build *on* it rather than re-declare it. Match existing naming, connector patterns and package layout.
2. **The user's own systems.** If tools are connected (MCP servers, internal docs, ticket trackers, schema registries, database introspection), use them. This is where the real answers live: actual topic names, actual payload shapes, actual volumes.
3. **The web**, for third-party payloads and API contracts: webhook bodies, public API schemas, file formats. Prefer official documentation. Record the URL you used.
4. **The user**, for what none of the above can give you: business rules, freshness expectations, which fields matter, what "correct" looks like.

The user konws the system and imagines the system that is going to be built, so it is a source to determine detailes:

* Derive what must be specified from [section 3](#3-the-details-that-decide-the-pipeline) and the
  [section 4](#4-check-before-you-hand-it-over) checklist, then ask the user for whatever sources
  1 to 3 left open.
* Ask in one batched round, leading with the questions whose answers would change the design.

## 2. Write the document, inside the project directory

Read `reference/requirements-template.md` and follow its structure.

The file path is:

```
<project>/adr/requirements_<YYYYMMDD-HHMMSS>.md
```

If you are not certain which directory that is, ask git:

```bash
git rev-parse --show-toplevel   # repository root
git rev-parse --show-prefix     # the project inside it (empty means the project IS the repo)
```

An empty `--show-prefix` means `adr/` at the repo root is correct. A non-empty one means the file belongs under that subdirectory: the agent's workspace is the project, and it resolves `adr/` relative to the project.

Use the current date and time in the name. Create `adr/` when it is absent.

Confirm the written path resolves before handing off.

## 3. The details that decide the pipeline

Specify each of these from what section 1 gathered. The template's Sources and Time semantics sections give the full field list.

- **Sample payload**: a real record, redacted, with optional and nullable fields marked.
- **Event-time field**: which field carries it, and how late an event can arrive and still count.
- **Key and duplicate rule**: what identifies a duplicate and which copy wins, for example "deduplicate on `event_id`, latest wins".
- **Volume and rate**: records/sec or /day, average and peak.
- **Consumer queries**: the actual questions asked, with their parameters and expected shape.

Record every unknown under `## Open Questions` with a recommended default and an impact rating.

Keep the requirements file self-contained. Everything that matters lives in the requirements file.

State what is out of scope alongside what is in.

## 4. Check before you hand it over

Every item below is answered one of three ways: a stated value, an entry in `## Open Questions` with a recommended default, or an explicit note that it does not apply to this pipeline.

- [ ] Every functional requirement is numbered (`FR-n`) and verifiable on its own, with no "robust",
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

1. **Where you wrote it**: the full path, including the project directory.
2. **The open questions, listed out.** These are the decisions the planner will otherwise make on their behalf, so they are the reason to open the file.
3. **Anything you had to assume** that is not already an open question.

Then ask whether to go ahead, and **wait for their answer**:

> Requirements written to `<project>/adr/requirements_<ts>.md`. Please review it, especially the
> 3 open questions above. Once it looks right, tell me and I'll run planning on it.

Handle their reply:

- **They approve** ("looks good", "go ahead", "plan it"): use the [`plan` skill](../plan/SKILL.md) with that file path, from the project directory. Their approval is what the `plan` skill requires.
- **They edit the file**: re-read it before planning, so what you act on matches what is on disk.
- **They answer the open questions in the chat**: update the file with their answers first, then confirm and plan. The file is the planner's only input, so an answer that lives only in the chat is re-assumed.
- **They want to run it themselves**: the command, from the project directory:
  ```
  cd <project>            # only if you are not already there
  /datasqrl:plan adr/requirements_<ts>.md
  ```
