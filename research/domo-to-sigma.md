# Domo → Sigma — converter design notes

Design sketch for a future `domo-to-sigma` skill, parallel to the existing
`tableau-to-sigma` / `powerbi-to-sigma` converters. Not yet built — **blocked on
a Domo instance + API client.** Captures the object model, API surface,
translation surface, hard problems, MVP scope, and what's reusable.

> Status: research / design only. No code yet. Last touched 2026-06-02.

---

## TL;DR for whoever picks this up

- **Beast Mode (Domo's calc-field language) is MySQL-dialect SQL.** This is the
  single biggest finding: it routes straight through the existing
  `convert_sql_to_sigma_formula` MCP tool. No DAX-style bespoke parser needed.
  This makes Domo's *formula* surface the **easiest** of any BI source we've done.
- **The hard part is the opposite end: getting the definitions out.** The public
  OAuth API exposes DataSets, Streams, Users, Groups, and a thin Page API — but
  it does **not** expose card visualization definitions or Beast Mode formulas.
  Those live behind the private/internal UI API (`/api/content/v1`,
  `/api/query/v1`, `/api/data/v3`). Extraction strategy is the whole risk.
- **DataSets are flat, already-materialized tables**, not a relational semantic
  layer. The "data model" is thin; the modeling logic hides in DataFlows
  (Magic ETL / SQL DataFlows) and in Beast Modes on the card.

---

## Object model

Domo's hierarchy, top to bottom, and where each piece maps:

| Domo object | What it is | Sigma equivalent |
|---|---|---|
| **Instance** | `*.domo.com` tenant | Sigma org |
| **DataSet** | A flat, materialized table (the queryable unit). Columns are typed. | Source table → DM element |
| **DataFlow** (Magic ETL, SQL DataFlow, Adrenaline/Redshift) | The transform graph that produces output DataSets from input DataSets | DM transforms / upstream warehouse logic — **mostly out of scope for v1** |
| **Dataflow → output DataSet** | join/aggregate/filter pipeline | DM relations + materialized tables |
| **Card** | One visualization (chart, table, KPI). Bound to **one** DataSet. | Workbook element (chart / table / KPI) |
| **Beast Mode** | A calculated field on a card or DataSet, written in **MySQL SQL** | Calculated column / formula |
| **Page (Dashboard)** | A screen holding a layout of cards, organized into **Collections** | Workbook page |
| **Collection** | A titled group of cards within a page | Page section / container in layout grid |
| **App / Domo App (DDX brick)** | Custom HTML/JS widget | **Drop** — out of scope, no Sigma analog |
| **PDP (Personalized Data Permissions)** | Row-level security policies on a DataSet | DM column-level / row-level security |
| **Page filter / card filter** | filter shelf on the dashboard / card | Workbook control / DM filter |

**Key structural difference from Tableau/Power BI:** there is no rich relational
model to extract. A DataSet is already a single wide table. Relationships, joins,
and most aggregations were resolved *upstream* in a DataFlow before the data
landed. So:
- The Sigma **data model** we build is usually one element per DataSet (plus Beast
  Mode calc columns), not a star schema. Easy.
- The transform logic that produced the DataSet is *gone* from the card's
  perspective — recovering it (if the customer wants the pipeline migrated, not
  just the dashboard) means parsing **DataFlow** definitions, which is a separate,
  larger effort. **v1 treats DataSets as opaque source tables.**

---

## API access

Two distinct API surfaces. **You need both**, and the interesting one is undocumented.

### 1. Public OAuth API — `api.domo.com` (documented, stable)

- **Auth:** OAuth2 client-credentials.
  `curl -u {CLIENT_ID}:{CLIENT_SECRET} "https://api.domo.com/oauth/token?grant_type=client_credentials&scope=data%20user%20dashboard%20account"`
  → bearer token, `expires_in` 3599s. Create the client at
  [developer.domo.com/manage-clients](https://developer.domo.com/manage-clients)
  or Admin → API Clients (needs **API Client Management** enabled + admin role).
- **Scopes:** `data`, `user`, `account`, `dashboard`, `audit`, `buzz`, `workflow`.
- **What it gives us:**
  - `GET /v1/datasets` / `GET /v1/datasets/{id}` — DataSet list + schema (column names + types). ✅
  - `GET /v1/datasets/{id}/data?includeHeader=true` (Accept: `text/csv`) — **full DataSet export to CSV.** ✅ This is our parity-data + value source.
  - `POST /v1/datasets/query/execute/{id}` — run SQL against a DataSet (MySQL dialect). ✅ Great for parity aggregations.
  - `GET /v1/pages` / `GET /v1/pages/{id}` — page hierarchy + **card IDs on the page** (NOT card definitions). ⚠️ thin
  - `GET /v1/users`, `GET /v1/groups` — for PDP / sharing context. ✅
- **What it does NOT give us:** card visualization definitions (chart type, axes,
  series, sort, color), Beast Mode formula text, page layout geometry, card-level
  filters. The Page API returns card *IDs* only.

Docs: [API Reference overview](https://www.domo.com/docs/portal/API-Reference/overview),
[API Authentication](https://www.domo.com/docs/portal/1845fc11bbe5d-api-authentication),
[Page API](https://developer.domo.com), [llms.txt index](https://www.domo.com/docs/llms.txt).

### 2. Private / internal UI API — `{instance}.domo.com/api/...` (undocumented)

This is what the Domo web app itself calls. Auth is a **session token**
(`X-DOMO-Developer-Token` from Admin → Security → Access Tokens, or a session
cookie + CSRF). Endpoints seen in the wild / community forums:

- `GET /api/content/v1/cards?urns={cardId}&parts=metadata,datasources,...` — **the card definition**: chart type, columns, Beast Modes, series, sort. ⭐ this is the prize.
- `GET /api/content/v1/cards/kpi/definition/{cardId}` — full KPI/chart definition incl. Beast Mode SQL.
- `GET /api/content/v1/pages/{pageId}` — page layout incl. collections + card geometry.
- `GET /api/content/v1/datasources/{datasetId}/cards` — cards using a DataSet.
- `GET /api/data/v3/datasources/{datasetId}?parts=core,permission` — DataSet metadata + PDP.
- `POST /api/query/v1/execute/{datasetId}` — internal query endpoint.
- `GET /api/dataprocessing/v1/dataflows/{id}` — **DataFlow definition** (Magic ETL graph / SQL), if/when we tackle pipeline migration.

⚠️ **These are undocumented and may change without notice.** The skill must treat
them as best-effort and degrade gracefully (e.g. fall back to PNG-read of the card
when the definition can't be parsed). Access-token auth is the realistic path for
a migration engagement — the customer admin issues a developer token.

**Prior art (use as reference, don't depend on):**
- [`domoinc/domo-python-sdk`](https://github.com/domoinc/domo-python-sdk), [`domo-java-sdk`](https://github.com/domoinc/domo-java-sdk) — public API only.
- [`domojupyter` / `pydomo`] community wrappers around the private API.
- Domo Java CLI has a `search-replace-bm` command → confirms Beast Mode definitions are programmatically reachable.

---

## Translation surface

| Domo concept | Sigma equivalent | Difficulty |
|---|---|---|
| DataSet (schema + CSV) | Source table → DM element | **easy** — flat table, typed columns |
| DataSet column | DM column | easy |
| **Beast Mode (MySQL SQL)** | Calculated column / formula via `convert_sql_to_sigma_formula` | **easy–medium** — direct, see below |
| Aggregate Beast Mode (`SUM(...)`, `COUNT(DISTINCT ...)`) | Aggregate in workbook/element context | easy |
| "Fixed" Beast Mode (partition-scoped) | Sigma `*Over` window functions | medium |
| Page | Workbook page | easy |
| Collection (card group on a page) | Layout container / section | easy |
| Card → table | Table element | easy |
| Card → bar/line/pie/etc. | Chart element | medium — chart-type map + axis/series binding |
| Card → KPI / Single Value | KPI element | easy |
| Card → pivot table | Pivot element (`rowsBy` + `columnsBy` arrays) | medium — see `feedback_sigma_pivot_rowsby_columnsby` |
| Page filter / card filter | Workbook control / DM filter | medium — filter defs only in private API |
| Sort / Top-N on card | Element sort + limit | easy |
| Conditional formatting (color rules) | Conditional formatting | partial |
| PDP policy | DM row-level security | medium — map policy predicates |
| DataFlow (Magic ETL / SQL) | Upstream warehouse / DM transforms | **hard** — out of scope v1 |
| DDX brick / custom app | — | **drop** |
| Domo Stories / scrollable layout | Workbook page (best-effort layout) | medium |

### Beast Mode → Sigma (the easy win)

Beast Mode is **MySQL 5.x-dialect SQL**. Domo's own docs: "A Beast Mode in Domo is
a calculated field written in SQL syntax." That means the existing
`mcp__sigma-data-model__convert_sql_to_sigma_formula` tool does most of the work.

Representative mappings (see `domo-to-sigma/refs/beast-mode-to-sigma.md` for the full table):

| Beast Mode (MySQL) | Sigma formula |
|---|---|
| `CASE WHEN [Status]='OK' THEN 1 ELSE 0 END` | `If([Status]="OK", 1, 0)` |
| `SUM(`Sales`) / SUM(`Units`)` | `Sum([Sales]) / Sum([Units])` |
| `IFNULL([Region], 'Unknown')` | `Coalesce([Region], "Unknown")` |
| `CONCAT([First],' ',[Last])` | `[First] & " " & [Last]` |
| `SUBSTRING([SKU], 1, 3)` | `Left([SKU], 3)` |
| `DATEDIFF([Ship],[Order])` | `DateDiff("day", [Order], [Ship])` |
| `DATE_FORMAT([Order],'%Y-%m')` | `DateFormat([Order], "YYYY-MM")` |
| `COUNT(DISTINCT [Customer])` | `CountDistinct([Customer])` |

Known Beast Mode gotchas to encode in the converter:
- `WEEKDAY` is silently replaced by `DAYOFWEEK` in Beast Mode — normalize before translating.
- Backtick-quoted identifiers (`` `Sales` ``) → strip to `[Sales]`.
- Beast Mode aggregate-vs-row context is implicit (decided by the card's grouping).
  When translating, decide whether the result is a DM-level row calc or a
  workbook-level aggregate. Default: row-level unless the Beast Mode contains an
  aggregate function at top level.

---

## Reverse-engineering difficulty

- **Formula layer: easiest of any source.** MySQL SQL + existing converter.
- **Definition extraction: the real risk.** Card defs / Beast Mode text / layout
  are private-API only and undocumented. Mitigations:
  1. Require a customer-issued **developer access token** (Admin → Security).
  2. Always capture a **card PNG** as a fallback so we can hand-verify chart kind
     when the private def can't be parsed (mirrors `feedback_phase1d_dashboard_png`).
  3. Use the **CSV export + SQL execute** public endpoints for parity data — those
     are stable and documented, so Phase 6 verification doesn't depend on the
     fragile private API.
- **No flat semantic layer to reconstruct** — unlike Cognos FM or LookML — because
  Domo pushed modeling into DataFlows. Good for v1 (less to build), but means we
  can't recover the "why" behind a DataSet without the DataFlow.
- No prior Domo → Sigma work (OSS or commercial) found.

---

## MVP scope (estimate ~3–4 focused weeks)

Phase 0: **OAuth + access-token auth + discovery.** `domo-discover.rb` —
enumerate DataSets, pages, card IDs. Public API where possible; access token for
private endpoints. (mirror `tableau-assessment`).

Phase 1: **DataSet → Sigma DM element.** Schema from `GET /v1/datasets/{id}`;
one element per DataSet. Pull Beast Modes (private API) and translate via
`convert_sql_to_sigma_formula` into calc columns. Highest leverage, cleanest input.

Phase 2: **Card → workbook element.** Card def (private API) → chart-type map,
axis/series/sort binding. KPI + table + bar/line/pie first; pivot next.

Phase 3: **Page → workbook page + layout.** Collections → containers; card
geometry → 24-col grid XML (reuse `build-dashboard-layout.rb`).

Phase 4: **Parity verification.** Use public `query/execute` + CSV export to pull
ground-truth aggregations; compare to Sigma `query`. Hard-gate à la
`assert-phase6-ran.rb`.

Phase 5: **`domo-assessment` skill** — instance inventory + per-card complexity
scan, same shape as `tableau-assessment`. Useful for scoping which cards to migrate.

### Long-tail (later iteration)
- DataFlow (Magic ETL / SQL) → DM transforms or warehouse pipeline.
- PDP → row-level security mapping.
- Domo Stories / scrollable narrative layouts.
- Conditional formatting full coverage, drill paths, card-link interactions.
- DDX bricks / custom apps (likely permanent drop).

---

## Effort estimate

**Smaller than Power BI, comparable to or slightly under Tableau core** —
*if* private-API extraction proves reliable.

- Tableau core converter: ~2–3 weeks
- **Domo core converter MVP: ~3–4 weeks**
- Long-tail parity: ~1–2 months iteration

Why it can be small:
1. **Formula layer is nearly free** — Beast Mode = MySQL → existing SQL converter.
2. **No relational model to reconstruct** — DataSets are flat tables.
3. Public API gives clean parity data (CSV export + SQL execute).

The one thing that could blow up the estimate: if the customer won't issue a
developer token and we're stuck with public-API-only, card defs + Beast Modes +
layout become unavailable and the converter degrades to "rebuild from PNG +
column list" — much more manual. **De-risk by confirming private-API/token
access at the start of any engagement.**

---

## What's reusable from `tableau-to-sigma` / `powerbi-to-sigma`

- `scripts/lib/` auth wrapper pattern → `domo-to-sigma/scripts/lib/domo_rest.rb`
- `convert_sql_to_sigma_formula` MCP tool → Beast Mode translation (no new converter file needed, unlike powerbi's `powerbi.ts`)
- `post-and-readback.rb`, `put-layout.rb`, `verify-parity.rb` — symlink/vendor as-is
- `build-dashboard-layout.rb` (24-col grid) — card geometry → grid
- Phase-6 hard-gate pattern (`assert-phase6-ran.rb`)
- Cluster / DM-reuse orchestration (leader/follower)
- PNG-read step (`feedback_phase1d_dashboard_png`) — critical fallback when private card def is unparseable
- `package.sh` vendoring pattern (powerbi) if we reuse tableau scripts

Not reusable:
- `.twb`/`.tds` and TMSL parsers (different formats)
- VizQL Data Service / Fabric getDefinition (Domo equivalent is CSV export + `query/execute` for data, private `content/v1` for defs)

---

## Open questions — resolve once we have instance + API access

1. Can we get a **developer access token** that reaches `/api/content/v1/cards`?
   (Determines whether card defs + Beast Modes are auto-extractable or manual.)
2. Exact JSON shape of the card definition (`/api/content/v1/cards?parts=...`) —
   where chart type, axes, series, sort, and Beast Mode SQL actually live.
3. Page layout geometry units in `/api/content/v1/pages/{id}` — grid coords vs px,
   so we can map to Sigma's 24-col grid.
4. Whether `query/execute` (public) and the private query endpoint agree, so we can
   trust the public one for parity.
5. PDP policy JSON shape → mapping to Sigma row-level security.
6. Do customers typically want **just the dashboard** rebuilt, or the **DataFlow
   pipeline** too? (Scopes whether Phase: DataFlow is in or out.)
