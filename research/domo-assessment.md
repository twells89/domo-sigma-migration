# Domo assessment — skill design notes

Design sketch for a `domo-assessment` skill, parallel to `tableau-assessment` and
`powerbi-assessment`. Inventories a Domo instance and produces a migration-readiness
readout + value/cost-ranked shortlist that hands off to `domo-to-sigma`.

> Status: research / design only. No validated code. Blocked on a live Domo
> instance. Last touched 2026-06-02. Companion to `domo-to-sigma.md`.

---

## The lucky break: DomoStats / Governance datasets = Domo's "Admin Insights"

Domo ships two admin connectors — **DomoStats** and **Domo Governance Datasets**
— that materialize a few dozen **system datasets** describing the instance:
`Cards`, `Pages`, `Users`, `Groups`, `DataFlows`, `DataSets`, `PDP Policies`,
`Activity Log`, and more. They are **ordinary DataSets**, so they're queryable via
the documented public `POST /v1/datasets/query/execute/{id}` (MySQL SQL) — exactly
like Tableau Admin Insights' published datasources.

**Consequence:** the *inventory* half of the assessment runs entirely on the
**public, documented API** — no private-API scraping needed. The private API is
only needed for the *deep per-card complexity* signals (Beast Mode text, card viz
config), and even those have a public-proxy fallback. This makes the assessment
**lower-risk than the converter** and runnable on day one of any engagement,
gated only on the customer having the Governance/DomoStats datasets installed
(admin one-click) and granting `data` + `audit` scopes.

- Activity Log = near-real-time, rolling 1-year window → the **usage/value signal**.
- Governance datasets connector: [doc](https://domo-support.domo.com/s/article/360056318074),
  DomoStats: [doc](https://domohelp.domo.com/hc/en-us/articles/360043433813),
  Activity Log: [doc](https://www.domo.com/docs/s/article/360042934574).

---

## Inventory dimensions (readout sections)

Mirrors the 12-section tableau/powerbi readout shape:

| # | Section | Source |
|---|---|---|
| 1 | Environment overview — DataSets, DataFlows, Pages, Cards, Apps, users, groups | Governance `DataSets`/`Pages`/`Cards`/`Users` datasets |
| 2 | Licenses / roles — Admin, Privileged, Participant, Social; days since login | `Users` dataset + `/v1/users` |
| 3 | DataSet patterns — by connector type, row counts, last-updated, schedule | `DataSets` dataset + `/v1/datasets/{id}` |
| 4 | DataFlow inventory — Magic ETL vs SQL DataFlow vs Adrenaline; input→output lineage | `DataFlows` dataset |
| 5 | Refresh insights — DataSet update cadence + last run status | `DataSets` dataset |
| 6 | Card/page priority — usage-ranked (views, distinct viewers) | `Activity Log` dataset |
| 7 | Migration shortlist — value/cost score, tags | computed |
| 8 | Per-card/page complexity — Beast Mode buckets, card-type histogram, PDP, DDX | private API (Tier A) or proxy (Tier B) |
| 9 | Found vs not found (caveats) | — |
| 10 | Privacy disclosure | PRIVACY.md |
| 11 | Hand-off package contents | — |
| 12 | Next steps → `domo-to-sigma` | — |

---

## Complexity scoring — Domo-specific

Same framework as the other assessments (features classed
**auto / hint / manual / unhandled**; `cost = 10·unhandled + 3·manual + 1·hint`;
`score = value / (1 + cost)`; tags retire / needs-gap-scout / migrate-first /
easy-win / moderate). What differs is the **signals**, because Domo's complexity
drivers are Beast Modes + card types + PDP, not `.twb` features or DAX.

### Beast Mode buckets (the Domo analog of DAX a/b/c)
Because Beast Mode is MySQL SQL routed through `convert_sql_to_sigma_formula`,
**most Beast Modes are bucket-a (auto)** — the convertibility curve is much flatter
than Power BI's DAX.

- **a — auto** (expected majority): standard SQL — `SUM/AVG/COUNT/CASE/IFNULL/COALESCE/CONCAT/SUBSTRING/LEFT/RIGHT/UPPER/LOWER/TRIM/REPLACE`, most date funcs.
- **b — manual / restructure**: aggregate `CEILING`/`FLOOR` traps; `IN(...)` (→ `or` chains); period-over-period (`PERIOD_ADD`/`PERIOD_DIFF` on `YYYYMM`); `WEEK`/`YEARWEEK` modes; "fixed"/partition Beast Modes → `*Over` window functions (mind `feedback_sigma_window_functions`); HLL sketch funcs → collapse to `CountDistinct`.
- **c — unhandled**: legacy unsupported funcs if present (`SQRT`, `CONVERT_TZ`, `MICROSECOND`); anything genuinely without a Sigma analog.

Mapping to tiers: `a→auto`, `b→manual`, `c→unhandled` (no "hint" tier, like Power BI).

### Card-type histogram → element coverage
- **auto**: table, bar, line, pie/donut, stacked/grouped bar, area, single-value/KPI, combo.
- **manual**: pivot table (needs `rowsBy`+`columnsBy`, see `feedback_sigma_pivot_rowsby_columnsby`), gauge, funnel, map/geo, sankey, period-over-period card, waterfall.
- **unhandled**: DDX brick / custom app, Domo-proprietary viz with no Sigma analog.

### Other cost signals folded in
- PDP policy on a card's DataSet → +manual (row-level security to recreate).
- Card sits on a heavily-transformed DataFlow output AND customer wants the pipeline migrated → +manual/unhandled (DataFlow is v1-out-of-scope).
- Card filters / drill paths / card-to-card links → +manual.

### Tier degradation (critical, Domo-specific)
- **Tier A** (dev token reaches `/api/content/v1/cards`): full per-card complexity.
- **Tier B** (public only): can't read Beast Modes or card config → **everything
  defaults to `manual`**, and complexity collapses to a proxy:
  `cost_proxy = 3 × (cards_on_page) + 1 × (beast_mode_count_if_known)`.
  Flag the readout as "complexity-only proxy — Tier B".

### Value signal
- **Audit mode** (`Activity Log` available): `value = views × √(distinct_viewers)` per card/page.
- **Fallback** (no audit): `value = 10 × (cards + beast_modes/4)` complexity-only proxy.

---

## Phases (mirror tableau/powerbi)

0. **Probe access** — public token OK? Governance/DomoStats datasets installed? dev token (Tier A/B)? audit scope?
1–3. **Inventory** — query Governance datasets for DataSets/DataFlows/Pages/Cards/Users/PDP (always runs, public API).
2. **Usage** — Activity Log → per-card/page views + distinct viewers (needs audit scope).
4. **Complexity** — Tier A: pull card defs + Beast Modes (private API), bucket them; Tier B: proxy.
5. **Shortlist** — value × complexity → `score = value/(1+cost)`, tag.
6. **Render readout** — 12-section markdown.
7. **Migration plan** — per-page `recommended_path` + DataSet/DM reuse clusters (pages sharing a DataSet cluster together).
8. **Hand off** — to `domo-to-sigma` (ask the user).

---

## Output contract (same shape as tableau/powerbi)

`/tmp/domo-assessment-<instance>/`:
- `readout.md` — 12-section customer-facing report
- `inventory.json` — environment + datasets + dataflows + pages + cards + users
- `complexity.json` — per-card/page `n_auto/n_hint/n_manual/n_unhandled` + feature lists + Beast Mode buckets + tier flag
- `usage.json` — per-card/page views + distinct viewers (audit mode)
- `shortlist.json` — ranked, with `value_basis` (activity-log | complexity-proxy)
- `migration-plan.json` — per-page `recommended_path` + DM-reuse clusters (keyed on shared DataSet)

---

## What's reusable

- `render-readout.rb` renderer + `refs/readout-template.md` + `refs/output-shapes.md` shapes (tableau/powerbi) — same 12-section structure, swap field names.
- `build-shortlist.rb` ranking engine + tag vocabulary — identical math.
- `migration-plan.rb` clustering — cluster pages by shared DataSet (Domo analog of shared semantic model / datasource).
- `lib/domo_rest.rb` from `domo-to-sigma` — same auth wrapper.
- `PRIVACY.md` discipline — read-only inventory; never writes back; user controls sharing.

Not reusable: the source-specific inventory queries (Governance-dataset SQL) and
the Beast Mode bucketer (shared with the converter's `refs/beast-mode-to-sigma.md`).

---

## Effort + open questions

**Smaller than `powerbi-assessment`** — inventory is clean public-API SQL against
Governance datasets, and Beast Mode convertibility is mostly bucket-a so the
complexity classifier is simpler than DAX bucketing. ~1.5–2 weeks once access is
confirmed.

Open questions (resolve on first access):
1. Exact schema (column names) of the Governance `Cards` / `Pages` / `Activity Log` / `DataFlows` datasets — these drive every inventory query.
2. Does Activity Log expose per-**card** views, or only per-page? (Determines value granularity.)
3. Can we read Beast Mode text from a Governance dataset (some instances surface a `Beast Modes` dataset), avoiding the private API for complexity? If yes, Tier A is reachable on the **public** API.
4. PDP policy representation in the Governance `PDP` dataset → mapping to Sigma row-level security.
