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

### Endpoints (best-effort — CONFIRM shapes on first contact)
| Call | Use |
|---|---|
| `GET /api/content/v1/cards?urns={ids}&parts=metadata,datasources,problems,...` | **card definitions** ⭐ |
| `GET /api/content/v1/cards/kpi/definition/{cardId}` | full KPI/chart def incl. Beast Mode SQL |
| `GET /api/content/v1/pages/{pageId}` | page layout — collections + card geometry |
| `GET /api/content/v1/datasources/{datasetId}/cards` | cards using a DataSet |
| `GET /api/data/v3/datasources/{datasetId}?parts=core,permission` | DataSet metadata + PDP |
| `GET /api/dataprocessing/v1/dataflows/{id}` | DataFlow graph (only if pipeline migration in scope) |

### Degradation when private API is unavailable (Tier B)
If the customer won't issue a dev token, fall back to:
- Public API for DataSet schema + CSV + page/card IDs.
- **Manual PNG capture** of each card (export from UI) → read the image to infer
  chart kind, axes, and any visible Beast Mode results (see
  `feedback_phase1d_dashboard_png`).
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
