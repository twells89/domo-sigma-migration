# Beast Mode → Sigma formula mapping

Beast Mode is **MySQL-dialect SQL**. The primary translation path is the existing
`mcp__sigma-data-model__convert_sql_to_sigma_formula` tool — feed it the Beast
Mode string and it emits a Sigma formula. This doc is the **pre-processing +
verification layer**: normalizations to apply first, the function-by-function map
to sanity-check the converter's output, and the gotchas that the generic SQL
converter won't know are Domo-specific.

Source of truth: Domo "Beast Mode Functions Reference Guide" (captured 2026-06-02).

---

## Normalize BEFORE translating

Apply these to the raw Beast Mode string first:

1. **Strip backtick / bracket identifier quoting** → Sigma uses `[Column Name]`.
   `` `Sales` `` and `` `Operating Budget` `` → `[Sales]`, `[Operating Budget]`.
2. **`WEEKDAY` → `DAYOFWEEK`.** Beast Mode silently does this substitution itself;
   replicate it so behavior matches. (`WEEKDAY` is in the unsupported list.)
3. **Reject / flag unsupported functions** (no longer supported in Beast Mode, so
   they shouldn't appear, but guard anyway): `SQRT`, `CONVERT_TZ`, `MICROSECOND`,
   `WEEKDAY`. If present, warn — likely a legacy formula.
4. **Flag the aggregate `CEILING` / `FLOOR` trap** — see below. These are NOT math
   rounding in Beast Mode.
5. **Decide row vs aggregate context.** If a top-level aggregate (`SUM`, `AVG`,
   `COUNT`, …) wraps the expression, the result is a workbook/element aggregate;
   otherwise it's a row-level DM calc column. Domo decides this implicitly by the
   card's grouping — we must make it explicit.

---

## ⚠️ Top gotchas (Domo-specific, the SQL converter won't catch these)

| Beast Mode | Looks like | Actually is | Sigma |
|---|---|---|---|
| `CEILING(Budget)` | math ceiling | **aggregate**: rounded `MAX` | `Round(Max([Budget]))` |
| `FLOOR(Budget)` | math floor | **aggregate**: rounded `MIN` | `Round(Min([Budget]))` |
| `POWER(Values,2)` | per-row power | per-row power, but **sums per series** if multi-series | `Power([Values],2)` (handle series via grouping) |
| `WEEKDAY(d)` | MySQL WEEKDAY (0=Mon) | replaced with `DAYOFWEEK` (1=Sun) | `Weekday([d])` — mind the 1=Sunday base |
| `SQRT(x)` | square root | **unsupported** in Beast Mode | use `Power([x], 0.5)` if it appears |
| Summary Number Beast Mode | a column | must be aggregated to be a summary | maps to a Sigma KPI element |

---

## Aggregate functions

| Beast Mode | Sigma | Notes |
|---|---|---|
| `SUM(x)` | `Sum([x])` | |
| `SUM(DISTINCT x)` | `Sum(Distinct ...)` | no direct Sigma form — pre-distinct then sum, or warn |
| `AVG(x)` | `Avg([x])` | |
| `COUNT(x)` | `Count([x])` | |
| `COUNT(DISTINCT x)` | `CountDistinct([x])` | |
| `APPROXIMATE_COUNT_DISTINCT(x)` | `CountDistinct([x])` | Sigma has no approx-distinct; exact is fine for parity |
| `MIN(x)` | `Min([x])` | unrounded |
| `MAX(x)` | `Max([x])` | unrounded |
| `CEILING(x)` | `Round(Max([x]))` | **aggregate = rounded MAX** |
| `FLOOR(x)` | `Round(Min([x]))` | **aggregate = rounded MIN** |
| `STDDEV_POP(x)` | `StdDevPop([x])` | |
| `VAR_POP(x)` | `VarPop([x])` | |
| `HLL_SKETCH_INIT/EXTRACT/MERGE/MERGE_PARTIAL` | `CountDistinct([x])` (collapse) | HLL++ approx-distinct sketches; Sigma has no sketch type — collapse the whole sketch pipeline to an exact distinct count, warn |

---

## Mathematical functions

| Beast Mode | Sigma |
|---|---|
| `ABS(x)` | `Abs([x])` |
| `MOD(x, n)` | `[x] % n` or `Mod([x], n)` |
| `POWER(x, n)` | `Power([x], n)` |
| `RAND()` | `Random()` |
| `ROUND(x)` / `ROUND(x, d)` | `Round([x])` / `Round([x], d)` |

(`SQRT` removed from Beast Mode — if seen, `Power([x], 0.5)`.)

---

## Logical functions

| Beast Mode | Sigma |
|---|---|
| `CASE WHEN c THEN a ELSE b END` | `If(c, a, b)` |
| `CASE WHEN c1 THEN 1 WHEN c2 THEN 2 END` | `Switch`/nested `If` — Sigma `If(c1,1,If(c2,2,null))` |
| `CASE col WHEN x THEN a WHEN y THEN b END` | `If([col]=x, a, If([col]=y, b, null))` |
| `col IN (v1, v2, ...)` | **`[col]=v1 or [col]=v2 ...`** — Sigma has **no `IsIn`** (see `feedback_sigma_formula_isin`) |
| `col LIKE '%TX%'` | `Contains([col], "TX")` |
| `col LIKE 'TX%'` | `StartsWith([col], "TX")` |
| `col LIKE '%TX'` | `EndsWith([col], "TX")` |
| `col LIKE '_hn%'` | regex: `RegexpMatch([col], "^.hn.*")` (`_`→`.`, `%`→`.*`) |
| `IFNULL(x, d)` | `Coalesce([x], d)` |
| `NULLIF(a, b)` | `If([a]=[b], null, [a])` |

---

## String functions

| Beast Mode | Sigma |
|---|---|
| `CONCAT(a, ' ', b)` | `[a] & " " & [b]` |
| `INSTR(col, 's')` | `Find([col], "s")` (1-based, mind index base) |
| `LEFT(col, n)` | `Left([col], n)` |
| `RIGHT(col, n)` | `Right([col], n)` |
| `LENGTH(col)` | `Length([col])` |
| `LOWER(col)` | `Lower([col])` |
| `UPPER(col)` | `Upper([col])` |
| `REPLACE(col, 'a', 'b')` | `Replace([col], "a", "b")` |
| `SUBSTRING(col, pos, len)` | `Mid([col], pos, len)` (1-based pos in both) |
| `TRIM(col)` | `Trim([col])` |

---

## Date and time functions

Beast Mode date functions are MySQL-flavored. Sigma date functions take a **unit
string** (`"day"`, `"month"`, `"year"`, …) and use **format tokens** (`YYYY`,
`MM`, `DD`) rather than MySQL `%` specifiers — see the specifier table below.

| Beast Mode | Sigma |
|---|---|
| `NOW()` / `CURRENT_TIMESTAMP()` / `SYSDATE()` | `Now()` |
| `CURDATE()` / `CURRENT_DATE()` | `Today()` |
| `CURTIME()` / `CURRENT_TIME()` | `Now()` (time-of-day; Sigma has no pure time type) |
| `DATE(d)` | `DateTrunc("day", [d])` |
| `TIME(d)` | extract via format; no pure time type |
| `YEAR(d)` | `Year([d])` |
| `MONTH(d)` | `Month([d])` |
| `MONTHNAME(d)` | `DateFormat([d], "MMMM")` |
| `DAY(d)` / `DAYOFMONTH(d)` | `Day([d])` |
| `DAYNAME(d)` | `DateFormat([d], "dddd")` |
| `DAYOFWEEK(d)` | `Weekday([d])` (1=Sunday) |
| `DAYOFYEAR(d)` | `DateDiff("day", DateTrunc("year",[d]), [d]) + 1` |
| `HOUR(d)` / `MINUTE(d)` / `SECOND(d)` | `Hour([d])` / `Minute([d])` / `Second([d])` |
| `QUARTER(d)` | `Quarter([d])` |
| `WEEK(d, mode)` | `Week([d])` — Sigma week start is config; mode 11=Sun, 22=Mon, map accordingly |
| `YEARWEEK(d, mode)` | `Year([d]) & DateFormat([d],"WW")` (compose) |
| `DATE_ADD(d, interval n unit)` / `ADDDATE` | `DateAdd("unit", n, [d])` |
| `DATE_SUB(d, interval n unit)` / `SUBDATE` | `DateAdd("unit", -n, [d])` |
| `ADDTIME(t, secs)` | `DateAdd("second", secs, [t])` |
| `SUBTIME(t, secs)` | `DateAdd("second", -secs, [t])` |
| `DATEDIFF(a, b)` | `DateDiff("day", [b], [a])` (mind arg order: BM is `(end, start)`) |
| `TIMEDIFF(a, b)` | `DateDiff("second", [b], [a])` |
| `PERIOD_ADD(YYYYMM, n)` | add months then reformat `YYYYMM` |
| `PERIOD_DIFF(YYYYMM1, YYYYMM2)` | `DateDiff("month", ...)` after parsing the YYYYMM ints to dates |
| `LAST_DAY(d)` | `DateAdd("day", -1, DateAdd("month", 1, DateTrunc("month", [d])))` |
| `DATE_FORMAT(d, fmt)` | `DateFormat([d], <translated tokens>)` — see specifier table |
| `TIME_FORMAT(d, fmt)` | `DateFormat([d], <translated tokens>)` (hours/min/sec only) |
| `STR_TO_DATE(s, fmt)` | `DateParse([s], <translated tokens>)` |
| `UNIX_TIMESTAMP(d)` | `DateDiff("second", Date(1970,1,1), [d])` |
| `FROM_UNIXTIME(n, fmt)` | `DateFormat(DateAdd("second", [n], Date(1970,1,1)), <tokens>)` |
| `TO_DAYS(d)` / `FROM_DAYS(n)` | `DateDiff("day", Date(0,1,1), [d])` / inverse — rarely needed; warn |
| `TIME_TO_SEC(d)` / `SEC_TO_TIME(n)` | arithmetic; no pure time type — warn |
| `TIMESTAMP(d)` | `[d]` cast to datetime — usually a no-op in Sigma |

### MySQL `DATE_FORMAT` specifier → Sigma `DateFormat` token

| MySQL | Means | Sigma token |
|---|---|---|
| `%Y` | 4-digit year | `YYYY` |
| `%y` | 2-digit year | `YY` |
| `%m` | month 01–12 | `MM` |
| `%c` | month 1–12 | `M` |
| `%b` | abbr month | `MMM` |
| `%M` | full month | `MMMM` |
| `%d` | day 01–31 | `DD` |
| `%e` | day 1–31 | `D` |
| `%a` | abbr weekday | `ddd` |
| `%W` | full weekday | `dddd` |
| `%H` | hour 00–23 | `HH` |
| `%h` / `%I` | hour 01–12 | `hh` |
| `%i` | minute | `mm` |
| `%s` | second | `ss` |
| `%p` | AM/PM | `A` |
| `%T` | `%H:%i:%s` | `HH:mm:ss` |
| `%j` | day of year | (compute) |

---

## Translation workflow (per Beast Mode)

1. Normalize (backticks, WEEKDAY, unsupported, aggregate CEILING/FLOOR, context).
2. Call `convert_sql_to_sigma_formula` with the normalized string.
3. Cross-check the result against the tables above; apply the Domo-specific
   gotchas the generic SQL converter misses (CEILING/FLOOR aggregates, `IN`→`or`,
   `DATEDIFF` arg order, format-specifier translation).
4. Validate the column posts without an error type (`diagnose_sigma_save_error`
   if it fails; remember `*Over` window-function limits per
   `feedback_sigma_window_functions`).
