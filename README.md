# Domo → Sigma migration skills

Two [Claude Code](https://claude.com/claude-code) skills for migrating
[Domo](https://www.domo.com/) dashboards to [Sigma](https://www.sigmacomputing.com/),
modeled on the existing `tableau-to-sigma` / `powerbi-to-sigma` converter and
assessment skills.

> **Status: research + scaffold. Not yet validated against a live Domo instance.**
> The authentication path and the *documented public-API* parts are ready to wire;
> the *private-API* parts (card definitions, Beast Mode text, page layout) are
> reconstructed from public sources and marked with `TODO(on-access)` to confirm
> on first contact with a real instance. Everything here is designed so that once
> a Domo API client + instance are available, the scripts plug straight in.

---

## What's in here

| Path | What it is |
|---|---|
| [`domo-to-sigma/`](domo-to-sigma/) | **Converter skill** — turns a Domo dashboard (pages + cards + DataSets + Beast Modes) into a Sigma data model + workbook |
| [`domo-assessment/`](domo-assessment/) | **Assessment skill** — inventories a Domo instance and produces a migration-readiness readout + value/cost-ranked shortlist |
| [`research/domo-to-sigma.md`](research/domo-to-sigma.md) | Design notes for the converter: object model, API surface, translation table, effort estimate, open questions |
| [`research/domo-assessment.md`](research/domo-assessment.md) | Design notes for the assessment: inventory dimensions, scoring rubric, open questions |

Each skill has a `SKILL.md` (the entry point Claude reads) and a `refs/` folder of
reference docs. Start with the two `research/*.md` files for the "why," then the
`SKILL.md` files for the "how."

---

## The three findings that shape the design

1. **Beast Mode is MySQL-dialect SQL.** Domo's calculated-field language is plain
   SQL, so it routes straight through the existing `convert_sql_to_sigma_formula`
   converter — no bespoke parser like Power BI's DAX. The formula layer is the
   *easiest* of any BI source. The full function-by-function mapping lives in
   [`domo-to-sigma/refs/beast-mode-to-sigma.md`](domo-to-sigma/refs/beast-mode-to-sigma.md).

2. **The real risk is extraction, not translation.** Domo's *public* OAuth API
   exposes DataSet schemas, CSV export, SQL execute, and page/card *IDs* — but not
   card visualization definitions, Beast Mode text, or layout geometry. Those live
   behind the undocumented *private* UI API (`{instance}.domo.com/api/content/v1/...`),
   reachable with a developer access token. The skills detect this up front and
   degrade gracefully (**Tier A** = full fidelity, **Tier B** = public-only + PNG
   fallback).

3. **DomoStats / Governance datasets are Domo's "Admin Insights."** The system
   datasets (`Cards`, `Pages`, `Users`, `DataFlows`, `PDP`, `Activity Log`) are
   ordinary DataSets, queryable with public SQL. So the *assessment inventory* runs
   entirely on the documented public API — no scraping. See
   [`domo-assessment/refs/governance-datasets.md`](domo-assessment/refs/governance-datasets.md).

---

## `domo-to-sigma` — the converter

Recreates a Domo dashboard in Sigma end-to-end:

```
Phase 0  Confirm access fidelity (Tier A vs B)
Phase 1  Discover  — DataSets, pages, cards, Beast Modes
Phase 2  Translate — Beast Mode SQL → Sigma formulas (convert_sql_to_sigma_formula)
Phase 3  Data model — one DM element per DataSet + calc columns
Phase 4  Post DM    — POST /v2/dataModels/spec, capture element IDs
Phase 5  Workbook   — cards → Sigma chart/table/KPI elements (+ 24-col layout)
Phase 6  Parity     — Domo query/execute vs Sigma query (hard-gated)
Phase 7  Cleanup
```

**Key files**
- [`SKILL.md`](domo-to-sigma/SKILL.md) — phased workflow + script table
- [`refs/connection.md`](domo-to-sigma/refs/connection.md) — auth for both API surfaces
- [`refs/beast-mode-to-sigma.md`](domo-to-sigma/refs/beast-mode-to-sigma.md) — complete Beast Mode → Sigma formula map
- [`scripts/get-token.sh`](domo-to-sigma/scripts/get-token.sh) — OAuth2 client-credentials → bearer token
- [`scripts/lib/domo_rest.rb`](domo-to-sigma/scripts/lib/domo_rest.rb) — REST wrapper (public + private), auto token refresh
- [`scripts/domo-discover.rb`](domo-to-sigma/scripts/domo-discover.rb) — Phase 1 discovery (public paths runnable; private paths stubbed)

---

## `domo-assessment` — scope before you convert

Inventories an instance and ranks what to migrate first, reusing the same
`value / (1 + cost)` scoring and `migrate-first / easy-win / moderate /
needs-gap-scout / retire` tags as the Tableau/Power BI assessments.

```
Phase 0    Probe access (public OK? Governance datasets? audit scope? Tier A/B)
Phase 1-3  Inventory  — DataSets, DataFlows, Pages, Cards, Users, PDP (public API)
Phase 2    Usage      — Activity Log → views + distinct viewers
Phase 4    Complexity — Beast Mode buckets + card-type coverage + PDP/DDX flags
Phase 5    Shortlist  — value/cost ranking + tags
Phase 6    Readout    — 12-section markdown report
Phase 7    Migration plan → hand off to domo-to-sigma
```

**Key files**
- [`SKILL.md`](domo-assessment/SKILL.md) — phased workflow
- [`refs/governance-datasets.md`](domo-assessment/refs/governance-datasets.md) — the DomoStats/Governance system datasets (inventory source)
- [`refs/complexity-scoring.md`](domo-assessment/refs/complexity-scoring.md) — the Domo complexity rubric
- [`refs/output-shapes.md`](domo-assessment/refs/output-shapes.md) — JSON output contract
- [`PRIVACY.md`](domo-assessment/PRIVACY.md) — read-only posture + sensitive-field callouts
- [`scripts/probe-governance.rb`](domo-assessment/scripts/probe-governance.rb) — runnable access/tier probe

---

## Prerequisites (once you have access)

```bash
# Public API — create a client at https://developer.domo.com/manage-clients
export DOMO_CLIENT_ID=...
export DOMO_CLIENT_SECRET=...
export DOMO_INSTANCE=acme            # -> acme.domo.com

# Private API (Tier A) — developer access token from Admin > Security
export DOMO_DEV_TOKEN=...            # omit for Tier B (public only)

eval "$(domo-to-sigma/scripts/get-token.sh)"   # sets DOMO_ACCESS_TOKEN
ruby domo-assessment/scripts/probe-governance.rb
```

Scripts are Ruby (stdlib only — `net/http`, `json`) + a Bash token helper. The
two skills share `domo_rest.rb` and `get-token.sh` via relative symlinks, so keep
the `domo-to-sigma/` and `domo-assessment/` folders side by side.

---

## Open questions to resolve on first instance access

Both `research/*.md` files end with an **Open questions** list. The blockers that
most change the implementation:

1. Does a developer token reach `/api/content/v1/cards`? (Tier A vs B.)
   *Partially answered (June 2026):* A customer engagement confirmed the endpoint is
   real and reachable with a dev token. The `parts=metadata,properties,datasources`
   form returns the full card definition. Exact field paths for sort/filter/series
   still need confirming on a live instance (`TODO(on-access)` in discovery scripts).
   Also confirmed: Beast Mode formula SQL is available via the public API on the
   DataSet object (`properties.formulas.formulas`) — private token not required for
   formula extraction, only for per-card column/filter/sort config.
   Reference implementation: [`domolibrary`](https://github.com/jaewilson07/domo_library)
   (Jae Wilson / DataCrew) independently confirms these endpoints are in active use.

2. Exact card-definition JSON shape — where chart type, axes, series, sort, and
   Beast Mode SQL actually live. **Still open** — endpoint confirmed, field paths not.

3. Page-layout geometry units, for mapping to Sigma's 24-column grid.

4. Exact column schemas of the Governance `Cards` / `Pages` / `Activity Log`
   datasets — and whether a `Beast Modes` Governance dataset exists (if so, Tier A
   becomes reachable on the *public* API and the private dependency drops out).

**Compliance note (June 2026):** The private card API (`/api/content/v1/...`) is
undocumented. Before a production migration run, confirm with the customer's Domo
account team that programmatic extraction is acceptable. Same caution as the
ThoughtSpot private API situation. See `refs/connection.md` for the rate-limit and
token-refresh guidance.

---

## Relationship to the other migration skills

These mirror the conventions of `tableau-to-sigma` / `tableau-assessment` and
`powerbi-to-sigma` / `powerbi-assessment`: same phased structure, same
`value/(1+cost)` shortlist math, same output contract, and reuse of the shared
layout/parity helpers. Effort estimate: converter ~3–4 weeks MVP, assessment
~1.5–2 weeks — both *smaller* than the Power BI equivalents because Beast Mode's
SQL nature removes the hardest part (formula translation).
