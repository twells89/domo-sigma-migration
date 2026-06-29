# Domo connection — auth for both API surfaces

Domo exposes **two** API surfaces. A high-fidelity migration needs both. The
public one is documented and stable; the private one is undocumented and is the
risk in this whole skill.

> Status note: only the **public** OAuth path below has been verified against
> Domo docs. The **private** endpoints are reconstructed from community forums and
> must be confirmed on first contact with a live instance.

---

## 1. Public API — `api.domo.com` (documented, stable)

### Create a client
Admin → **API Clients**, or [developer.domo.com/manage-clients](https://developer.domo.com/manage-clients).
Requires admin role + the **API Client Management** feature enabled on the instance.
Note the `client_id` / `client_secret`. Pick scopes: `data user account dashboard`
(add `audit` if you need activity logs).

### Get a token (client-credentials)
```bash
curl -s -u "$DOMO_CLIENT_ID:$DOMO_CLIENT_SECRET" \
  "https://api.domo.com/oauth/token?grant_type=client_credentials&scope=data%20user%20account%20dashboard" \
  | jq -r .access_token
```
Token TTL is ~3599s. `scripts/get-token.sh` wraps this and exports
`DOMO_ACCESS_TOKEN`. The Ruby wrapper (`lib/domo_rest.rb`) auto-refreshes on 401.

### Endpoints this surface gives us
| Call | Use |
|---|---|
| `GET /v1/datasets?limit=50&offset=0` | enumerate DataSets |
| `GET /v1/datasets/{id}` | DataSet schema (columns + types) |
| `GET /v1/datasets/{id}/data?includeHeader=true` (`Accept: text/csv`) | **full CSV export** — parity values |
| `POST /v1/datasets/query/execute/{id}` body `{"sql":"SELECT ..."}` | **run MySQL SQL** — parity aggregations |
| `GET /v1/pages` / `GET /v1/pages/{id}` | page hierarchy + **card IDs** (not defs) |
| `GET /v1/users`, `GET /v1/groups` | sharing / PDP context |

⚠️ Public API does **not** return: card viz definitions, Beast Mode text, layout
geometry, card filters. For those, you need the private API below.

---

## 2. Private / internal API — `{instance}.domo.com/api/...` (undocumented)

This is what the Domo web app calls. **Undocumented, may change without notice.**

### Auth — developer access token
Admin → **Security → Access Tokens** → generate a token. Send it as a header:
```bash
curl -s -H "X-DOMO-Developer-Token: $DOMO_DEV_TOKEN" \
  "https://$DOMO_INSTANCE.domo.com/api/content/v1/cards?urns=$CARD_ID&parts=metadata,datasources"
```
(Some instances accept a session cookie + `X-XSRF-Token` instead — token is cleaner
for automation and is what we standardize on.)

### Confirmed `parts` values for card definition (June 2026)

A customer engagement confirmed that the GET-by-urn variant returns the full card definition. The public docs only document a render endpoint at this path — the structured definition is the `parts` form:

```bash
GET {instance}.domo.com/api/content/v1/cards?urns={cardId}&parts=metadata,properties,datasources
```

`parts` is additive — include all three for a migration. The response carries column/field list, filter clauses, sort specs, and Beast Mode formula references.
- `metadata` — card title, type, owner
- `properties` — viz config: chart type, axes, series, sort direction, applied filters
- `datasources` — DataSet binding + any Beast Mode calc references

To enumerate all cards bound to a DataSet before fetching definitions:
```bash
GET {instance}.domo.com/api/content/v1/datasources/{datasetId}/cards?drill=true
```

⚠️ The exact JSON field paths for sort/filter/series are **TODO(on-access)** — the endpoint and `parts` mechanism are confirmed, the field names need verifying on a live instance.

### Filter object shape (inferred from embed SDK — confirm on live instance)

Domo's embed filter docs reveal the filter schema the app uses internally. Stored card filters likely use the same shape:
```json
{ "column": "Status", "operator": "IN", "values": ["Active", "Pending"] }
```
Operators: `IN`, `NOT_IN`, `EQUALS`, `NOT_EQUALS`, `GREATER_THAN`, `LESS_THAN`, `GREATER_THAN_EQUALS_TO`, `LESS_THAN_EQUALS_TO`, `BETWEEN`, `CONTAINS`. Use this as a Rosetta Stone when parsing filter clauses out of the card definition response.

### Beast Mode formulas — also available on the DataSet object (Tier B path)

Beast Mode formula text is NOT only in the private card API. The DataSet response carries a `properties.formulas.formulas` block with each calc's `id`, `name`, and SQL formula text:

```bash
GET {instance}.domo.com/api/data/v3/datasources/{datasetId}?parts=core,permission,formulas
```

This means formula-layer extraction (Beast Mode → Sigma formula translation) can run on the **public** API path — no private token needed for that step. The private card API is needed for which columns/filters/sorts a specific card applies, not the formula definitions themselves.

### Third-party reference implementation

[`domolibrary`](https://github.com/jaewilson07/domo_library) (Jae Wilson / DataCrew) is an open-source Python SDK built specifically around these private endpoints — independent confirmation they're real and in active use. Its architecture separates raw "route functions" (one per API call) from higher-level class functions, so when Domo bumps an endpoint version you swap one route. Worth adopting the same pattern in `domo_rest.rb`.

### Endpoints (best-effort — CONFIRM shapes on first contact)
| Call | Use |
|---|---|
| `GET /api/content/v1/cards?urns={ids}&parts=metadata,properties,datasources` | **card definitions** ⭐ (confirmed endpoint + parts) |
| `GET /api/content/v1/datasources/{datasetId}/cards?drill=true` | enumerate cards per DataSet |
| `GET /api/content/v1/cards/kpi/definition/{cardId}` | full KPI/chart def incl. Beast Mode SQL (alt form) |
| `GET /api/content/v1/pages/{pageId}` | page layout — collections + card geometry |
| `PUT /api/content/v1/cards/kpi/{cardId}/render?parts=image` | **render card → PNG** ⭐ (visual reference) |
| `PUT /api/content/v1/cards/kpi/{cardId}/render?parts=imagePDF` | render card → PDF |
| `GET /api/data/v3/datasources/{datasetId}?parts=core,permission,formulas` | DataSet metadata + **Beast Mode SQL** via `properties.formulas` |
| `GET /api/data/v3/datasources/{datasetId}?parts=core,permission` | DataSet metadata + PDP |
| `GET /api/dataprocessing/v1/dataflows/{id}` | DataFlow graph (only if pipeline migration in scope) |

### Visual + layout capture (the design-fidelity lever)

A migration that rebuilds dashboards from DataSets + chart-type strings alone
produces generically-templated output (the recurring *"design is still a big
issue"* feedback). Two private-API captures close that gap, mirroring the proven
Tableau flow (read the source image before writing the spec, and feed it to the
mandatory layout-visual-qa gate — see `shared/refs/layout-visual-qa.md`,
`feedback_phase1d_dashboard_png`, `batch_converter_png_brief`):

1. **Layout geometry** — `GET /api/content/v1/pages/{pageId}` carries each card's
   position/size on Domo's page grid. Normalize it so `build-dashboard-layout.rb`
   places elements faithfully (hero viz keeps its weight) instead of auto-stacking
   into an equal-weight "spreadsheet of cards."
2. **Card render** — `PUT /api/content/v1/cards/kpi/{cardId}/render` returns the
   card exactly as the app shows it. Body params (all optional):
   ```json
   { "width": 1000, "height": 700, "scale": 2,
     "queryOverrides": { }, "filters": [ ] }
   ```
   `parts=image` → PNG, `parts=imagePDF` → PDF. Community sources report the
   response is a JSON body with base64 under an `image`/`imageData` field; some
   instances return raw image bytes. `lib/domo_rest.rb#decode_render` handles
   **both** — confirm the exact field on first contact and prune the unused branch.

`scripts/domo-capture-visuals.rb --pages <ids>` runs both: writes
`discovery/layout/<pageId>.json`, a per-card `discovery/png/cards/<cardId>.png`,
and a full-page `discovery/png/pages/<pageId>.pdf` (the source-fidelity reference
the QA gate compares the Sigma render against).

⚠️ This is a **Tier A** capability (needs the dev token). It is the *automated
upgrade* of the manual-PNG fallback below — when a dev token exists, you no longer
hand-export cards from the UI.

### Compliance note

Paths 1 and 3 (private API + render) use Domo's undocumented surface. Before a production run, confirm with the customer's Domo account team that programmatic extraction for migration is acceptable — both to avoid surprise breaking changes and for contractual cleanliness. Flag this in Phase 0 of SKILL.md.

The session-token / developer-token auth has tighter rate limits and shorter token life than the public OAuth token. Build in token refresh + exponential backoff when looping over large card populations.

### Degradation when private API is unavailable (Tier B)
If the customer won't issue a dev token, fall back to:
- Public API for DataSet schema + CSV + page/card IDs.
- **Manual PNG capture** of each card (export from UI) into
  `discovery/png/cards/<cardId>.png` + a full-page UI "Export to PDF" into
  `discovery/png/pages/` → read the images to infer chart kind, axes, layout,
  and any visible Beast Mode results (see `feedback_phase1d_dashboard_png`).
  This is the same destination `domo-capture-visuals.rb` writes on Tier A, so the
  build + QA steps consume it identically — only the *capture* is manual.
- Beast Mode text must then be supplied by the customer or transcribed from the UI.

---

## Environment variables this skill expects
```bash
export DOMO_CLIENT_ID=...        # public API
export DOMO_CLIENT_SECRET=...    # public API
export DOMO_INSTANCE=acme        # → acme.domo.com  (private API host)
export DOMO_DEV_TOKEN=...        # private API (omit for Tier B)
eval "$(scripts/get-token.sh)"   # sets DOMO_ACCESS_TOKEN
```

Docs:
[API Authentication](https://www.domo.com/docs/portal/1845fc11bbe5d-api-authentication) ·
[API Reference overview](https://www.domo.com/docs/portal/API-Reference/overview) ·
[DataSet API](https://www.domo.com/docs/api-reference/datasets-api) ·
[Manage clients](https://developer.domo.com/manage-clients) ·
[llms.txt doc index](https://www.domo.com/docs/llms.txt)
