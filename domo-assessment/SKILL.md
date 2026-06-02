---
name: domo-assessment
description: >-
  Take inventory of a Domo instance and produce a migration-readiness readout —
  environment counts, licenses, DataSet/DataFlow mix, refresh cadence, per-card
  usage, per-card complexity (Beast Mode convertibility + card-type coverage +
  PDP), and a value/cost-ranked migration shortlist. Use to scope a Domo→Sigma
  migration or audit BI sprawl. Lightweight, public-API driven; hands off to
  domo-to-sigma.
user-invocable: true
---

# Domo Assessment

> **STATUS: DRAFT / BLOCKED ON API ACCESS.** Scaffolded from research, not yet
> validated against a live Domo instance. The *inventory* half runs on the
> documented public API against DomoStats/Governance datasets and is ready to
> wire; the *deep per-card complexity* half depends on the private API (Tier A)
> with a public proxy fallback (Tier B). Design + open questions:
> `../research/domo-assessment.md`. Resolve the open questions before customer use.

**Read ALL of the following before replying or taking any action:**
- `../research/domo-assessment.md` — design, scoring rationale, open questions
- `refs/governance-datasets.md` — the DomoStats/Governance system datasets (inventory source)
- `refs/complexity-scoring.md` — Domo complexity rubric (Beast Mode buckets, card-type coverage, tiers)
- `refs/output-shapes.md` — JSON contract for inventory/complexity/shortlist/migration-plan
- `../domo-to-sigma/refs/beast-mode-to-sigma.md` — Beast Mode bucketer (shared)
- `../domo-to-sigma/refs/connection.md` — auth (public OAuth + private dev token)
- `PRIVACY.md` — read-first; surface to the customer

## Privacy posture
Read-only inventory. Pulls instance metadata + (optionally) the Activity Log and
card definitions. Never writes back to Domo. Output is local markdown + JSON; the
user controls what is shared. See `PRIVACY.md`.

---

## The key idea
Domo's **DomoStats / Governance datasets** (Cards, Pages, Users, DataFlows,
DataSets, PDP, Activity Log) are ordinary DataSets, queryable via the documented
public `POST /v1/datasets/query/execute/{id}`. So the inventory runs on the
**public API** — no private-API scraping. Private API is only for deep Beast
Mode / card-config complexity (Tier A); a public proxy covers Tier B.

---

## Scripts overview

| Script | Phase | Purpose |
|---|---|---|
| `scripts/lib/domo_rest.rb` *(reuse from domo-to-sigma)* | — | REST wrapper (public + private) |
| `scripts/get-token.sh` *(reuse)* | — | OAuth public token |
| `scripts/probe-governance.rb` | 0 | Detect: public OK? Governance datasets installed? audit scope? Tier A/B? |
| `scripts/inventory.rb` | 1–3 | Query Governance datasets → `inventory.json` |
| `scripts/fetch-usage.rb` | 2 | Activity Log → per-card/page views + distinct viewers → `usage.json` |
| `scripts/score-complexity.rb` | 4 | Beast Mode buckets + card-type histogram + PDP → `complexity.json` |
| `build-shortlist.rb` *(reuse from tableau/powerbi-assessment)* | 5 | `score = value/(1+cost)`, tag |
| `render-readout.rb` *(reuse)* | 6 | 12-section `readout.md` |
| `migration-plan.rb` *(reuse, adapt clustering)* | 7 | per-page `recommended_path` + DataSet-reuse clusters |

> *(reuse)* scripts are symlinked/vendored from the sibling assessment skills.
> Domo-specific scripts are currently **stubs** with `TODO(on-access)` markers.

---

## Modes
- **Full** (admin + audit scope + Governance datasets + Tier A dev token): every section.
- **Inventory-only** (no audit scope): drop usage; shortlist uses complexity-only value proxy.
- **Tier B** (no dev token): no Beast Mode / card-config extraction; complexity is a proxy, flagged in the readout.

---

## Phase 0 — Probe access
`ruby scripts/probe-governance.rb` →
- public token works?
- are the DomoStats/Governance datasets installed? (list `/v1/datasets`, match names — see `refs/governance-datasets.md`)
- is `audit` scope granted (Activity Log)?
- Tier A vs B (does the dev token reach `/api/content/v1/cards`?)
Gates which downstream phases run.

## Phase 1–3 — Environment inventory (always runs, public API)
`ruby scripts/inventory.rb` → query Governance datasets for DataSets, DataFlows,
Pages, Cards, Users, Groups, PDP. Emit `inventory.json` (see `refs/output-shapes.md`).

## Phase 2 — Usage (needs audit scope)
`ruby scripts/fetch-usage.rb` → Activity Log → per-card/page `views` + `distinct_viewers`. Emit `usage.json`.

## Phase 4 — Per-card complexity
`ruby scripts/score-complexity.rb` →
- **Tier A**: pull card defs + Beast Modes (private API), bucket Beast Modes via `../domo-to-sigma/refs/beast-mode-to-sigma.md`, build card-type histogram, flag PDP/DDX.
- **Tier B**: proxy from card count + page structure; mark every card `manual`.
Emit `complexity.json` (`n_auto/n_hint/n_manual/n_unhandled` + feature lists + `tier`).

## Phase 5 — Shortlist
Reuse `build-shortlist.rb`. `cost = 10·unhandled + 3·manual + 1·hint`;
`value = views × √(distinct_viewers)` (audit) or `10×(cards + beast_modes/4)` (proxy);
`score = value/(1+cost)`. Tags: retire / needs-gap-scout / migrate-first / easy-win / moderate.

## Phase 6 — Render readout
Reuse `render-readout.rb` + `refs/readout-template.md` (the tableau/powerbi 12-section template, Domo field names).

## Phase 7 — Migration plan
Reuse/adapt `migration-plan.rb`: per-page `recommended_path` + DM-reuse clusters
keyed on **shared DataSet** (the Domo analog of shared datasource / semantic model).

## Phase 8 — Hand off (MANDATORY: ask the user)
Offer: single page conversion / batch / readout-only. Hand the migration-plan to `domo-to-sigma`.

---

## Open questions — resolve on first access
See `../research/domo-assessment.md`: exact Governance-dataset schemas, whether
Activity Log gives per-card (not just per-page) views, whether a `Beast Modes`
Governance dataset exists (would make Tier A reachable on the public API), and PDP
policy shape. Until confirmed, treat inventory queries + complexity as unvalidated.
