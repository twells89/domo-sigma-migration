# Privacy posture — domo-assessment

**Surface this to the customer before running.**

## What this skill reads
- **Instance metadata** via DomoStats / Governance datasets: DataSet/DataFlow/Page/Card/User/Group inventories, PDP policy definitions.
- **Usage** (optional, requires `audit` scope): the Activity Log — who viewed/exported which card or page, and when (rolling ~1-year window).
- **Card definitions + Beast Mode SQL** (optional, Tier A only): the calc-field text and chart configuration, via the private API.

## What it does NOT do
- **Never writes to Domo.** No creates, edits, deletes, or schedule changes. Read-only.
- Does **not** export the underlying business **data rows** of customer DataSets.
  (The converter, `domo-to-sigma`, may export CSV for parity checks — that is a
  separate, explicitly-invoked step, not part of assessment.)
- Does not transmit anything to third parties. Output stays local.

## What it produces
Local files in `/tmp/domo-assessment-<instance>/`: `inventory.json`,
`usage.json`, `complexity.json`, `shortlist.json`, `migration-plan.json`,
`readout.md`. **The user decides** what, if anything, to share.

## Sensitive fields to be aware of
- The Activity Log and `Users` dataset contain **user names / emails / login times** (personal data). The readout aggregates these (counts, distinct viewers) but raw `usage.json` / `inventory.json` retain identifiers. Treat as confidential; delete after the engagement if required by the customer's policy.
- PDP policy predicates may encode sensitive segmentation rules.

## Credentials
- Public API: OAuth client (`DOMO_CLIENT_ID`/`SECRET`) — scopes `data user account dashboard` (+ `audit` for usage).
- Private API (Tier A): a developer access token issued by a customer admin.
Store via environment variables only; never commit. See `../domo-to-sigma/refs/connection.md`.
