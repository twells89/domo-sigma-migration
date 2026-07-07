---
name: domo-to-sigma
description: >-
  Convert a Domo dashboard (pages + cards + DataSets + Beast Modes) into a Sigma
  data model and matching workbook. Use when the user has a Domo instance and
  wants to recreate dashboards in Sigma. Discovery via Domo APIs, Beast Mode →
  Sigma formula translation, data model + workbook creation via REST API, layout
  generation, and parity verification — driven by `scripts/*.rb`.
user-invocable: true
---

# Domo → Sigma Conversion

> **STATUS: DRAFT / BLOCKED ON API ACCESS.** This skill is scaffolded from
> research but not yet validated against a live Domo instance. The auth path and
> the *public* API endpoints are documented and ready; the **private/internal
> API** endpoints (card definitions, Beast Mode text, page layout) are
> best-effort and must be confirmed on first contact with a real instance.
> Design rationale + open questions live in `../research/domo-to-sigma.md`.
> Before running for a customer, resolve the **Open questions** at the bottom.

**Read ALL of the following before replying or taking any action:**
- `../research/domo-to-sigma.md` — object model, API surface, scope, open questions
- `refs/connection.md` — Domo auth (OAuth public API + developer access token for private API)
- `refs/beast-mode-to-sigma.md` — Beast Mode (MySQL SQL) → Sigma formula mapping
- `refs/card-to-element.md` — **Domo card → Sigma element map. Read before Phase 5.** Rule 0 (Summary Number → KPI, never a table) is the #1 fidelity fix; also covers filtering + no-liberties discipline.
- The `tableau-to-sigma` skill's `refs/workbook-layout.md` and `refs/data-model-spec.md` — reused wholesale

---

## The one big idea

**Beast Mode is MySQL-dialect SQL.** Domo's calc-field language routes straight
through the existing `mcp__sigma-data-model__convert_sql_to_sigma_formula` tool —
no bespoke parser like Power BI's DAX. The formula layer is nearly free. The work
that remains is *extraction* (getting card defs + Beast Mode text + layout out of
Domo) and *layout/binding* (cards → Sigma elements on a 24-col grid).

---

## Scripts

| Script | Phase | Purpose |
|---|---|---|
| `scripts/get-token.sh` | prereq | OAuth2 client-credentials → public-API bearer token |
| `scripts/lib/domo_rest.rb` | prereq | Domo REST wrapper (public + private), auto token refresh |
| `scripts/domo-discover.rb` | 1 | Enumerate DataSets, pages, cards; pull schemas + (private) card defs + Beast Modes |
| `scripts/domo-capture-visuals.rb` | 1b | Render per-card PNG + full-page PDF, normalize card geometry → layout JSON (design-fidelity reference) |
| `scripts/convert-beast-modes.rb` | 2 | Beast Mode SQL → Sigma formula via `convert_sql_to_sigma_formula` |
| `scripts/build-dm.rb` | 3 | DataSet schema + calc columns → Sigma DM spec |
| `post-and-readback.rb` *(reuse from tableau-to-sigma)* | 4 | POST DM/WB + capture server element IDs |
| `scripts/build-workbook.rb` | 5 | Card defs → Sigma chart/table/KPI elements |
| `build-dashboard-layout.rb` *(reuse)* | 5d | Card geometry → 24-col grid XML |
| `put-layout.rb` *(reuse)* | 5d | PUT layout to workbook |
| `verify-parity.rb` *(reuse)* | 6 | Compare Domo `query/execute` aggregations vs Sigma `query` |
| `assert-phase6-ran.rb` *(reuse)* | 6 | Hard gate before declaring GREEN |

> Scripts marked *(reuse)* are symlinked/vendored from `tableau-to-sigma/scripts/`.
> Scripts NOT marked reuse are Domo-specific and currently **stubs** — they
> document the endpoint + expected shape with `TODO` markers to wire on access.

---

## Prerequisites

### Sigma credentials
```bash
ruby ../tableau-to-sigma/scripts/setup.rb   # one-time
eval "$(../tableau-to-sigma/scripts/get-token.sh)"
```

### Domo access — see `refs/connection.md`
Two surfaces, both usually needed:
1. **Public API** (`api.domo.com`) — OAuth2 client (`DOMO_CLIENT_ID` / `DOMO_CLIENT_SECRET`). Gives DataSet schemas, CSV export, SQL execute, page/card IDs, users/groups.
2. **Private API** (`{instance}.domo.com/api/...`) — a **developer access token** (Admin → Security → Access Tokens). Gives card definitions, Beast Mode text, page layout. **Undocumented — confirm shapes on first contact.**

```bash
export DOMO_CLIENT_ID=...  DOMO_CLIENT_SECRET=...
export DOMO_INSTANCE=acme           # for {instance}.domo.com
export DOMO_DEV_TOKEN=...           # private-API access token (optional but needed for full fidelity)
eval "$(scripts/get-token.sh)"      # sets DOMO_ACCESS_TOKEN (public)
```

---

## Phase 0 — Confirm access fidelity

Before scoping, determine which extraction tier is available:
- **Tier A (full):** developer token reaches `/api/content/v1/cards` → auto-extract card defs + Beast Modes. Aim for this.
- **Tier B (degraded):** public API only → DataSet schemas + CSV + card IDs, but **no** card defs/Beast Modes/layout. Fall back to **PNG-read** of each card (see `feedback_phase1d_dashboard_png`) + manual chart-kind tagging.

Run `ruby scripts/domo-discover.rb --probe` to detect the tier.

---

## Phase 1 — Discover

`ruby scripts/domo-discover.rb --pages <id,...>` →
- DataSets used by the target pages (schema: column names + types)
- Card list per page + per-card definition (Tier A) or PNG (Tier B)
- Beast Mode formulas (Tier A)
- Page layout (collections + card geometry)

Outputs `discovery/datasets.json`, `discovery/cards.json`, `discovery/pages.json`,
`discovery/beast-modes.json`.

---

## Phase 1b — Capture visuals + layout (design fidelity)

**This is the step that prevents generically-templated output.** Rebuilding from
DataSets + chart-type strings alone is why early Domo migrations "didn't look
good." Capture a true visual + real geometry so the build has something to match:

`ruby scripts/domo-capture-visuals.rb --pages <id,...>` →
- `discovery/layout/<pageId>.json` — card positions/sizes on Domo's grid (so the
  hero viz keeps its weight instead of collapsing to an equal-weight grid)
- `discovery/png/cards/<cardId>.png` — per-card visual reference
- `discovery/png/pages/<pageId>.pdf` — full-page source image for the QA gate

Tier A (dev token) does this automatically via the card render endpoint. **Tier B:
export the same PNGs/PDF from the Domo UI into those same paths** — the build and
QA steps consume them identically (see `refs/connection.md` "Visual + layout
capture"). Either way, **READ these images** before and during Phase 5.

---

## Phase 2 — Translate Beast Modes

`ruby scripts/convert-beast-modes.rb` → feeds each Beast Mode SQL string through
`convert_sql_to_sigma_formula`. Apply the normalizations in
`refs/beast-mode-to-sigma.md` FIRST (strip backticks, `WEEKDAY`→`DAYOFWEEK`,
flag aggregate `CEILING`/`FLOOR`, reject unsupported `SQRT`/`CONVERT_TZ`).
Outputs `discovery/formulas.json` (Beast Mode id → Sigma formula).

---

## Phase 3 — Data model

`ruby scripts/build-dm.rb` → one DM element per DataSet (flat table) + calc
columns from translated Beast Modes. No star schema unless a DataFlow join is in
scope (out of scope for v1 — DataSets are treated as opaque source tables).

---

## Phase 4 — Post DM

Reuse `post-and-readback.rb`: POST to `/v2/dataModels/spec`, GET back, capture
server element IDs, verify zero error columns.

---

## Phase 5 — Workbook

`ruby scripts/build-workbook.rb` → map each card to a Sigma element, following
**`refs/card-to-element.md`** (the chart map). **Read the per-card PNG from
`discovery/png/cards/` while mapping** — the image disambiguates chart kind and
formatting that the chartType string alone misses.

**For EVERY card, decide the element kind FIRST (Rule 0 in the ref):**
> Does the Domo tile show a single big **Summary Number**? → emit a `kpi-chart`,
> **never a table.** This is the failure mode that shipped: Domo lets any card
> (including a table) display as a summary number, and porting it as a Sigma
> table produces an ugly grid where a big number was expected. When torn between
> KPI and a 1-row table, choose KPI. Missing sparkline support is NOT a reason to
> fall back to a table — emit the KPI and warn that the trend must be bound in
> the UI (`sigma-kpi-trend-comparison-ui-only`).

Then translate the rest per the ref:
- Domo chart type → Sigma chart kind (full table in `refs/card-to-element.md`)
- axis / series / sort / Top-N binding
- pivot cards → `rowsBy` + `columnsBy` arrays (see `feedback_sigma_pivot_rowsby_columnsby`)
- page filters → workbook controls; card-level filter clauses → element filters
  (port **both** levels — see the ref's Filtering fidelity section)
- **No liberties:** one card → one element; reproduce labels/formats/layout; every
  unsupported/dropped item → a Phase-5e warning, never a silent substitution

### Phase 5d — Layout
Reuse `build-dashboard-layout.rb` + `put-layout.rb`: feed `discovery/layout/<pageId>.json`
(card geometry from Phase 1b) → 24-col grid, preserving relative position and the
hero viz's weight.

### Phase 5e — Layout visual QA (MANDATORY gate)
Run the shared **layout-visual-qa** loop (`shared/refs/layout-visual-qa.md`):
render the full Sigma page to PNG and compare it **side-by-side against the Domo
full-page PDF** (`discovery/png/pages/<pageId>.pdf`) plus the per-card PNGs. Check
the source-fidelity → structural → design-quality rubrics, fix the spec, re-render,
and loop until the render passes. Declare done on a *clean render*, never on HTTP 200.

Plus the Domo-specific gate from `refs/card-to-element.md`:
- **Every Domo summary-number tile → a Sigma `kpi-chart`.** Count summary tiles
  in the source PDF vs `kpi-chart` elements in the spec — they must match. Zero
  KPIs when the source has summary tiles is an automatic **fail**.
- No Sigma table stands where the Domo tile showed a single number.
- Filter-inventory diff is clean (every page filter → control, every card filter
  → element filter).

---

## Phase 6 — Parity (hard-gated)

Pull ground-truth aggregations from Domo's **public** `POST /v1/datasets/query/execute/{id}`
(stable) and compare to Sigma `query`. Run `assert-phase6-ran.rb` before declaring
GREEN. Do NOT rely on the private API for parity data.

---

## Phase 7 — Cleanup

Delete orphan test workbooks (`/v2/files/<id>`, see `feedback_sigma_workbook_delete_endpoint`).

---

## Open questions — resolve on first instance access

See `../research/domo-to-sigma.md` "Open questions". The blockers that most change
the skill: (1) does the dev token reach `/api/content/v1/cards`? (2) exact card-def
JSON shape; (3) page-layout geometry units. Until confirmed, treat Phases 1/2/5 as
unvalidated.
