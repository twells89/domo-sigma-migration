#!/usr/bin/env ruby
# Phase 0 access probe for domo-assessment.
#
#   ruby scripts/probe-governance.rb
#
# Detects which assessment mode is available and prints a summary:
#   - public API reachable?
#   - which DomoStats/Governance system datasets are installed?
#   - is `audit` scope granted (Activity Log present)?
#   - Tier A (private card API reachable) vs Tier B (public only)?
#
# Prereqs (see ../domo-to-sigma/refs/connection.md):
#   export DOMO_CLIENT_ID=... DOMO_CLIENT_SECRET=... DOMO_INSTANCE=acme
#   export DOMO_DEV_TOKEN=...        # omit for Tier B
#   eval "$(scripts/get-token.sh)"
#
# NOTE: governance dataset NAME matching below is best-effort. CONFIRM the exact
# names + column schemas on first contact (see refs/governance-datasets.md).

require_relative 'lib/domo_rest'

# Governance/DomoStats datasets we look for, by name regex => readout role.
WANTED = {
  /cards/i        => 'Cards (inventory + complexity)',
  /pages/i        => 'Pages (inventory + priority)',
  /data\s*sets?/i => 'DataSets (patterns + refresh)',
  /data\s*flows?/i=> 'DataFlows (lineage)',
  /users/i        => 'Users (licenses)',
  /groups/i       => 'Groups',
  /pdp|personalized/i => 'PDP Policies (RLS complexity)',
  /activity\s*log/i   => 'Activity Log (usage/value)',
  /beast\s*mode/i     => 'Beast Modes (Tier-A-on-public!)'
}

def section(t)
  warn("\n== #{t} ==")
end

section 'PUBLIC API'
datasets = begin
  Domo.list_datasets(limit: 200)
rescue => e
  warn "FAIL — #{e.message}"
  warn "Fix credentials (DOMO_CLIENT_ID/SECRET) and re-run scripts/get-token.sh."
  exit 1
end
warn "OK — #{datasets.size} DataSets visible (first page)."

section 'GOVERNANCE / DOMOSTATS DATASETS'
found = {}
WANTED.each do |rx, role|
  hit = datasets.find { |d| d['name'].to_s =~ rx }
  if hit
    found[role] = hit['id']
    warn "  [✓] #{role.ljust(40)} #{hit['name']} (#{hit['id']})"
  else
    warn "  [ ] #{role.ljust(40)} not found"
  end
end
unless found.keys.any? { |r| r.start_with?('Cards', 'Pages', 'DataSets') }
  warn "  WARNING: core Governance datasets missing — ask admin to install the"
  warn "  'Domo Governance Datasets' + 'DomoStats' connectors. Falling back to"
  warn "  thin public endpoints gives a reduced inventory only."
end

section 'AUDIT SCOPE (Activity Log)'
warn(found.key?('Activity Log (usage/value)') ?
  "  [✓] Activity Log present — usage/value ranking available." :
  "  [ ] No Activity Log — shortlist will use the complexity-only value proxy.")

section 'TIER (deep card complexity)'
if Domo.dev_token.nil? && !found.key?('Beast Modes (Tier-A-on-public!)')
  warn "  TIER B — no DOMO_DEV_TOKEN and no Beast Modes governance dataset."
  warn "  Card defs + Beast Modes NOT auto-extractable; complexity will be a proxy."
elsif found.key?('Beast Modes (Tier-A-on-public!)')
  warn "  TIER A (public) — a Beast Modes governance dataset exists; no private API needed for formulas."
else
  # TODO(on-access): replace 'PROBE' with a real card id and confirm the shape.
  ok = begin
    Domo.private_get('/api/content/v1/cards', query: { urns: 'PROBE', parts: 'metadata' }); true
  rescue => e
    warn "  private API check failed: #{e.message}"; false
  end
  warn(ok ? "  TIER A — private card API reachable; full complexity available." :
            "  TIER B — dev token set but private card API unreachable.")
end

section 'SUMMARY'
warn "  Inventory source : #{found.empty? ? 'thin public fallback' : 'governance datasets'}"
warn "  Governance datasets found: #{found.size}/#{WANTED.size}"
warn "\n  Next: ruby scripts/inventory.rb"
