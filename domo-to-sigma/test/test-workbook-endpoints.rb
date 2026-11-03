#!/usr/bin/env ruby
# Offline tests for scripts/lib/workbook_endpoints.rb — the paths and wire bodies
# for the (non-deprecated) workbook code-rep endpoints. Also checks that the
# scripts that talk to Sigma no longer call the deprecated workbook /spec paths.
#   ruby test/test-workbook-endpoints.rb
$LOAD_PATH.unshift File.expand_path('../scripts/lib', __dir__)
require 'workbook_endpoints'

$failures = 0
def eq(a, b, m) if a == b then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end end

W = WorkbookEndpoints
flat = { 'name' => 'N', 'folderId' => 'F', 'description' => 'D', 'schemaVersion' => 1,
         'pages' => [{ 'id' => 'p', 'name' => 'Page', 'elements' => [{ 'id' => 'e' }] }],
         'layout' => '<Page id="p"><LayoutElement elementId="e"/></Page>',
         'themeName' => 'Light',
         'themeOverrides' => { 'categoricalScheme' => %w[#111111 #222222],
                               'colorOverrides' => { 'backgroundCanvas' => '#ffffff' } } }

eq W.create_path, '/v2/workbooks', 'create path'
eq W.read_path('w1'), '/v2/workbooks/w1?includeContents=true', 'read path asks for contents'
eq W.update_path('w1'), '/v2/workbooks/w1/contents', 'update path'

body = W.create_body(flat)
eq body.keys.sort, %w[contents description folderId name], 'create body: metadata beside contents'
eq body['contents'].keys.sort, %w[elements kind layout pages schemaVersion settings], 'create body: contents uses the current document shape'
eq body['contents']['pages'], [{ 'id' => 'p', 'name' => 'Page' }], 'create body: pages contain metadata only'
eq body['contents']['elements'], [{ 'id' => 'e' }], 'create body: elements are flattened'
eq body['contents']['kind'], 'workbook', 'create body: document kind is workbook'
eq body['contents'].dig('settings', 'theme'),
   { 'name' => 'Light',
     'overrides' => { 'categoricalScheme' => %w[#111111 #222222],
                      'colorOverrides' => [{ 'name' => 'backgroundCanvas', 'color' => '#ffffff' }] } },
   'create body: legacy theme fields move under settings'
eq W.create_body(flat, dry_run: true)['dryRun'], true, 'dry run flag'
eq W.create_body({ 'name' => 'N', 'document' => { 'pages' => [] } })['contents'],
   { 'pages' => [], 'elements' => [], 'kind' => 'workbook' }, 'a document wrapper is normalized as contents'

upd = W.update_body(flat, document_version: 4)
eq upd, { 'contents' => body['contents'], 'documentVersion' => 4 },
   'update body: no name/folderId, optional documentVersion'
eq W.update_body(flat).key?('documentVersion'), false, 'update body omits an unset documentVersion'

current = { 'schemaVersion' => 1, 'kind' => 'workbook',
            'pages' => [{ 'id' => 'p', 'name' => 'Page' }],
            'elements' => [{ 'id' => 'e' }],
            'layout' => '<Page id="p"><GridContainer elementId="c"><LayoutElement elementId="e"/></GridContainer></Page>' }
eq W.contents_of({ 'workbookId' => 'w', 'contents' => current }), current, 'contents_of unwraps a read'
eq W.contents_of(flat).key?('pages'), true, 'contents_of keeps a flat spec as is'
eq W.legacy_spec({ 'contents' => current })['pages'][0]['elements'], [{ 'id' => 'e' }],
   'legacy_spec assigns flat elements to pages from layout'

partially_assigned = current.merge('elements' => current['elements'] + [{ 'id' => 'unassigned' }])
legacy = W.legacy_spec({ 'contents' => partially_assigned })
legacy['pages'][0]['elements'] << { 'id' => 'injected' }
eq W.wire_contents(legacy)['elements'], [{ 'id' => 'e' }, { 'id' => 'injected' }, { 'id' => 'unassigned' }],
   'wire_contents preserves flat elements not assigned to a page'

scripts = File.expand_path('../scripts', __dir__)
deprecated = /workbooks(?:\/\{[^}]*\}|\/#\{[^}]*\}|\/%s)?\/spec\b/
offenders = Dir[File.join(scripts, '**', '*.rb')].reject { |f| f.end_with?('lib/sigma_rest.rb') }.flat_map do |f|
  File.readlines(f).each_with_index.select { |l, _| l =~ deprecated && l !~ /^\s*#/ }.map { |l, i| "#{File.basename(f)}:#{i + 1}: #{l.strip}" }
end
eq offenders, [], 'no script calls a deprecated workbook /spec endpoint'

puts $failures.zero? ? "\nALL PASS" : "\n#{$failures} FAILURE(S)"
exit($failures.zero? ? 0 : 1)
