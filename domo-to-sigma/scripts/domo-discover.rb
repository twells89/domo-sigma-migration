#!/usr/bin/env ruby
# Phase 1 discovery for domo-to-sigma.
#
#   ruby scripts/domo-discover.rb --probe              # detect extraction tier (A/B)
#   ruby scripts/domo-discover.rb --pages 123,456      # discover specific dashboards
#   ruby scripts/domo-discover.rb --datasets           # list all DataSets
#
# Writes discovery/*.json. The PUBLIC-API paths below follow Domo's documented
# API and should work as-is once credentials are set. The PRIVATE-API paths
# (card defs, Beast Modes, layout) are STUBS — they call lib/domo_rest.rb's
# private_* methods, whose response shapes must be CONFIRMED on first contact
# with a live instance. Search this file for TODO(on-access).
#
# Prereqs (see refs/connection.md):
#   export DOMO_CLIENT_ID=... DOMO_CLIENT_SECRET=... DOMO_INSTANCE=acme
#   export DOMO_DEV_TOKEN=...        # omit for Tier B (public only)
#   eval "$(scripts/get-token.sh)"   # sets DOMO_ACCESS_TOKEN

require 'json'
require 'fileutils'
require 'optparse'
require_relative 'lib/domo_rest'

OUT = File.expand_path('../discovery', __dir__)
FileUtils.mkdir_p(OUT)

def dump(name, obj)
  path = File.join(OUT, name)
  File.write(path, JSON.pretty_generate(obj))
  warn "  wrote #{path} (#{obj.is_a?(Array) ? obj.size : obj.keys.size} entries)"
end

opts = {}
OptionParser.new do |o|
  o.on('--probe')          { opts[:probe] = true }
  o.on('--datasets')       { opts[:datasets] = true }
  o.on('--pages IDS', Array) { |v| opts[:pages] = v }
end.parse!(ARGV)

# --- Tier probe -------------------------------------------------------------
# Tier A = private API reachable (full fidelity). Tier B = public only.
if opts[:probe]
  public_ok = begin
    Domo.list_datasets(limit: 1); true
  rescue => e
    warn "PUBLIC API: FAIL — #{e.message}"; false
  end
  warn "PUBLIC API: OK" if public_ok

  if Domo.dev_token.nil?
    warn "PRIVATE API: skipped (DOMO_DEV_TOKEN unset) => TIER B (public only)."
    warn "  Card defs, Beast Modes, and layout will NOT be auto-extractable."
    warn "  Fall back to PNG-read per card (see feedback_phase1d_dashboard_png)."
  else
    # TODO(on-access): pick a real card id to probe; confirm the endpoint/shape.
    private_ok = begin
      Domo.private_get('/api/content/v1/cards', query: { urns: 'PROBE', parts: 'metadata' })
      true
    rescue => e
      warn "PRIVATE API: FAIL — #{e.message}"; false
    end
    warn(private_ok ? "PRIVATE API: OK => TIER A (full fidelity)" : "PRIVATE API: unreachable => TIER B")
  end
  exit 0
end

# --- DataSet inventory ------------------------------------------------------
if opts[:datasets]
  all = []
  offset = 0
  loop do
    batch = Domo.list_datasets(limit: 50, offset: offset)
    break if batch.nil? || batch.empty?
    all.concat(batch)
    offset += 50
    break if batch.size < 50
  end
  dump('datasets.json', all)
end

# --- Per-page discovery -----------------------------------------------------
if opts[:pages]
  pages_out = []
  cards_out = []
  beast_out = []

  opts[:pages].each do |pid|
    page = Domo.page(pid) # PUBLIC: page hierarchy + card IDs
    pages_out << page

    # PUBLIC gives card IDs; layout geometry + collections need PRIVATE.
    layout = Domo.page_layout(pid)  # nil on Tier B
    page['_layout'] = layout if layout

    card_ids = Array(page['cardIds'] || page['cards']) # TODO(on-access): confirm field name
    card_ids.each do |cid|
      defn = Domo.card_definition(cid) # nil on Tier B
      if defn
        cards_out << defn
        # TODO(on-access): confirm where Beast Mode SQL lives in the card JSON.
        # Likely under a "calculatedFields" / "beastModes" array on the datasource.
        Array(dig_beast_modes(defn)).each { |bm| beast_out << bm }
      else
        cards_out << { 'id' => cid, '_tierB' => true,
                       '_note' => 'no private API — capture PNG + transcribe Beast Modes manually' }
      end
    end
  end

  dump('pages.json', pages_out)
  dump('cards.json', cards_out)
  dump('beast-modes.json', beast_out)
  warn "\nNext: ruby scripts/convert-beast-modes.rb   (translate Beast Mode SQL -> Sigma formulas)"
end

BEGIN {
  # TODO(on-access): implement against the real card JSON shape.
  def dig_beast_modes(card_def)
    # Placeholder: walk the card def for calculated-field nodes carrying SQL text.
    # Expected output: [{ "cardId"=>, "name"=>, "sql"=>, "dataSourceId"=> }, ...]
    []
  end
}
