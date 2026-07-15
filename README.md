# Domo → Sigma migration skills

Two [Claude Code](https://claude.com/claude-code) skills for migrating
[Domo](https://www.domo.com/) dashboards to [Sigma](https://www.sigmacomputing.com/),
modeled on the existing `tableau-to-sigma` / `powerbi-to-sigma` converter and
assessment skills.

> **Status: deterministic build pipeline built + tested offline; final live
> field-path check pending.** The converter now has runnable Phase 1–5 build
> scripts (discovery, Beast Mode translation, data-model + workbook builders, a
> Phase-5e QA gate) with unit + end-to-end tests (`bash domo-to-sigma/test/run-all.sh`).
> The private-API card-definition shapes are confirmed against Domo's OpenAPI +
> three production reference implementations; a final field-path check on first
> contact with a live instance is still recommended (a few paths carry a
> `TODO(on-access)` note). The Sigma-side reuse scripts are vendored in, so the
> repo is self-contained.

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
Phase 0   Confirm access fidelity (Tier A vs B)
Phase 1   Discover  — DataSets, pages, cards, Beast Modes (two card-def shapes auto-detected)
Phase 1b  Capture   — per-card PNG + page PDF + card geometry (design fidelity)
Phase 2   Translate — Beast Mode SQL → Sigma formulas (normalize + classify + lint around convert_sql_to_sigma_formula)
Phase 3   Data model — one DM element per DataSet + projection calc columns (clean display names)
Phase 4   Post DM    — POST /v2/dataModels/spec, capture element IDs / column labels
Phase 5   Workbook   — cards → Sigma chart/table/KPI elements + controls; assemble master + pages
Phase 5d  Layout     — Domo card geometry → 24-col grid
Phase 5e  QA gate    — Domo-specific spec checks (KPI-not-count-of-id, filter fan-out, no bar-as-table, wrap, gridlines-off)
Phase 6   Parity     — Domo query/execute vs Sigma query (hard-gated)
Phase 7   Cleanup
```

**Key files**
- [`SKILL.md`](domo-to-sigma/SKILL.md) — phased workflow + script table
- [`refs/connection.md`](domo-to-sigma/refs/connection.md) — auth + the two card-definition shapes
- [`refs/card-to-element.md`](domo-to-sigma/refs/card-to-element.md) — Domo card → Sigma element map (KPI/filter/bar/wrap/axis rules)
- [`refs/beast-mode-to-sigma.md`](domo-to-sigma/refs/beast-mode-to-sigma.md) — complete Beast Mode → Sigma formula map
- [`scripts/lib/domo_rest.rb`](domo-to-sigma/scripts/lib/domo_rest.rb) — REST wrapper (public + private), auto token refresh
- [`scripts/domo-discover.rb`](domo-to-sigma/scripts/domo-discover.rb) — Phase 1 discovery (two-shape card-def parser + Beast Mode extraction/classification)
- `scripts/convert-beast-modes.rb` · `build-dm.rb` · `build-workbook.rb` · `qa-check.rb` · `build-domo-layout.rb` — the Phase 2–5e build pipeline
- Vendored from `tableau-to-sigma` (clone-safe, provenance-headed): `post-and-readback.rb`, `build-workbook-spec.rb`, `build-dashboard-layout.rb`, `put-layout.rb`, `verify-parity.rb`, `assert-phase6-ran.rb` + lib closure
- [`test/`](domo-to-sigma/test/) — offline unit + end-to-end suites (`bash domo-to-sigma/test/run-all.sh`)

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
   *Confirmed:* a customer engagement reached the endpoint with a dev token. Beast
   Mode formula SQL is also available on the public-API DataSet object
   (`properties.formulas.formulas`, a map keyed by id) — a private token is needed
   only for per-card column/filter/sort config. Live reference implementations:
   [`jsade/domo-query-cli`](https://github.com/jsade/domo-query-cli) (TS, generated
   from Domo's OpenAPI), [`brycewc/domo-toolkit`](https://github.com/brycewc/domo-toolkit)
   (JS), [`newli5737/domo-chousa`](https://github.com/newli5737/domo-chousa) (Python).

2. Exact card-definition JSON shape. *Largely answered:* Domo returns **two** shapes
   and `domo-discover.rb` auto-detects/normalizes both — Shape A (official
   `CardDefinition`: `chartBody`/`summaryNumber` Components, `chartType`,
   `calculatedFields`, `conditionalFormats`) and Shape B (internal analyzer def,
   `PUT /api/content/v3/cards/kpi/definition` → `definition.subscriptions.main.*`).
   A final field-path check on a live instance is still recommended.

3. Page-layout geometry units, for mapping to Sigma's 24-column grid. *Mitigated:*
   `build-domo-layout.rb` normalizes geometry **relative** to each page's max extent,
   so it works whether Domo reports cells or pixels.

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
layout/parity helpers (vendored in). The converter build pipeline is now
implemented and tested offline; the assessment skill remains a scaffold
(~1.5–2 weeks). Both are *smaller* than the Power BI equivalents because Beast
Mode's SQL nature removes the hardest part (formula translation).
