# Output shapes — domo-assessment

All files land in `/tmp/domo-assessment-<instance>/`. Shapes deliberately mirror
`tableau-assessment` / `powerbi-assessment` so `build-shortlist.rb`,
`render-readout.rb`, and `migration-plan.rb` can be reused with minimal changes.

## inventory.json
```json
{
  "instance": "acme",
  "generated_at": "2026-06-02T00:00:00Z",
  "source": "governance-datasets | thin-public-fallback",
  "environment": {
    "datasets": 0, "dataflows": 0, "pages": 0, "cards": 0,
    "apps": 0, "users": 0, "groups": 0
  },
  "licenses": [{ "role": "Admin|Privileged|Participant|Social", "count": 0, "avg_days_since_login": 0 }],
  "datasets": [{ "id": "", "name": "", "owner": "", "connector": "", "rows": 0,
                 "last_updated": "", "schedule": "" }],
  "dataflows": [{ "id": "", "name": "", "type": "Magic ETL|SQL|Adrenaline",
                  "inputs": [""], "outputs": [""], "last_run": "", "status": "" }],
  "pages": [{ "id": "", "title": "", "owner": "", "parent": "", "card_ids": [""] }],
  "cards": [{ "id": "", "title": "", "type": "", "page_ids": [""], "dataset_id": "", "owner": "" }],
  "pdp_policies": [{ "id": "", "dataset_id": "", "name": "", "predicates": [""] }]
}
```

## usage.json   (audit mode only)
```json
{ "by_object": [{ "object_id": "", "object_type": "CARD|PAGE",
                  "views": 0, "distinct_viewers": 0 }],
  "window_days": 365 }
```

## complexity.json   (keyed by card id, rolled up per page)
```json
{
  "tier": "A | B",
  "value_basis": "activity-log | complexity-proxy",
  "cards": {
    "<cardId>": {
      "title": "", "type": "", "page_id": "", "dataset_id": "",
      "n_auto": 0, "n_hint": 0, "n_manual": 0, "n_unhandled": 0,
      "beast_mode_buckets": { "a": 0, "b": 0, "c": 0 },
      "card_type_tier": "auto|manual|unhandled",
      "flags": ["pdp", "dataflow-magic-etl", "ddx", "card-filter"],
      "features": [{ "name": "", "tier": "", "note": "" }]
    }
  },
  "pages": { "<pageId>": { "n_auto": 0, "n_hint": 0, "n_manual": 0, "n_unhandled": 0 } }
}
```

## shortlist.json
```json
{ "value_basis": "activity-log | complexity-proxy",
  "items": [{ "id": "", "kind": "page|card", "title": "",
              "value": 0.0, "cost": 0, "score": 0.0,
              "tag": "migrate-first|easy-win|moderate|needs-gap-scout|retire" }] }
```

## migration-plan.json   (handoff contract to domo-to-sigma)
```json
{ "clusters": [{ "cluster_id": "", "shared_dataset_id": "",
                 "pages": [{ "id": "", "title": "", "recommended_path": "convert|gap-scout|retire" }] }],
  "notes": "" }
```
