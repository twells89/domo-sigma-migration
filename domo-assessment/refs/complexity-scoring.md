# Domo complexity scoring rubric

Same framework as `tableau-assessment` / `powerbi-assessment` — features classed
**auto / hint / manual / unhandled**, then:

```
cost  = 10·n_unhandled + 3·n_manual + 1·n_hint
value = views × sqrt(distinct_viewers)              # audit (Activity Log) mode
      = 10 × (cards + beast_modes/4)                 # complexity-only proxy
score = value / (1 + cost)
```

Tags (identical vocabulary to the other assessments):
- `views == 0` (audit mode) → **retire**
- `n_unhandled >= 1` → **needs-gap-scout**
- `score >= 20 and (n_manual + n_unhandled) == 0` → **migrate-first**
- `score >= 10` → **easy-win**
- else → **moderate**

What's Domo-specific is the **signals** that produce the feature counts. Three
inputs: Beast Mode buckets, card-type coverage, and structural flags (PDP / DataFlow / DDX).

---

## 1. Beast Mode buckets → tiers

Beast Mode is MySQL SQL routed through `convert_sql_to_sigma_formula`, so **most
Beast Modes are bucket-a (auto)** — convertibility is far flatter than Power BI DAX.
Bucket each Beast Mode using `../domo-to-sigma/refs/beast-mode-to-sigma.md`:

| Bucket | Tier | Examples |
|---|---|---|
| **a — auto** | `auto` | `SUM/AVG/COUNT/COUNT(DISTINCT)/CASE/IFNULL/COALESCE/NULLIF/CONCAT/SUBSTRING/LEFT/RIGHT/LENGTH/UPPER/LOWER/TRIM/REPLACE/INSTR`, most date funcs (`YEAR/MONTH/DAY/DATE_ADD/DATE_SUB/DATEDIFF/DATE_FORMAT/STR_TO_DATE`), `ABS/MOD/POWER/ROUND/RAND` |
| **b — restructure** | `manual` | aggregate `CEILING`/`FLOOR` (rounded MAX/MIN trap); `col IN (...)` (→ `or` chains, no `IsIn`); period-over-period (`PERIOD_ADD`/`PERIOD_DIFF` on `YYYYMM`); `WEEK`/`YEARWEEK` modes; "fixed"/partition Beast Modes → `*Over` window funcs (mind `feedback_sigma_window_functions`); HLL sketch funcs → collapse to `CountDistinct` |
| **c — no equivalent** | `unhandled` | legacy unsupported funcs if present (`SQRT`, `CONVERT_TZ`, `MICROSECOND`); genuinely inexpressible logic (rare) |

(No `hint` tier — like Power BI, bucket-a is already mechanical.)

---

## 2. Card type → element coverage

| Tier | Domo card types |
|---|---|
| `auto` | table, bar, line, pie/donut, stacked bar, grouped bar, area, single-value/KPI, combo (bar+line) |
| `manual` | pivot table (needs `rowsBy`+`columnsBy`, see `feedback_sigma_pivot_rowsby_columnsby`), gauge, funnel, waterfall, map/geo, sankey, period-over-period card, bubble |
| `unhandled` | DDX brick / custom app, Domo-proprietary viz with no Sigma analog |

Build a per-page histogram; each card contributes one count to its tier.

---

## 3. Structural flags (added to feature counts)

| Signal | Adds |
|---|---|
| Card's DataSet has a **PDP policy** | +1 `manual` (row-level security to recreate in the DM) |
| Card sits on a heavily-transformed **DataFlow output** AND pipeline migration is in scope | +1 `manual` (or `unhandled` if Magic ETL with no SQL — DataFlow is v1-out-of-scope) |
| Card-level **filter / drill path / card-to-card link** | +1 `manual` |
| **DDX brick / custom app** | +1 `unhandled` |

---

## 4. Tier degradation (Domo-specific, critical)

- **Tier A** — dev token reaches `/api/content/v1/cards` (or a `Beast Modes`
  Governance dataset exists). Full per-card scoring as above.
- **Tier B** — public API only, no Beast Mode / card-config text. **Default every
  card to `manual`** and replace cost with a proxy:
  ```
  cost_proxy = 3 × cards_on_page + 1 × (known_beast_mode_count)
  ```
  Set `complexity.json.tier = "B"` and surface "complexity-only proxy (Tier B)" in
  the readout's caveats section. The shortlist is directional, not precise, in Tier B.

---

## Output
Per card (and rolled up per page): `{ n_auto, n_hint, n_manual, n_unhandled,
features: [...], beast_mode_buckets: {a,b,c}, card_types: {...}, flags: [...],
tier: "A"|"B" }`. See `refs/output-shapes.md`.
