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
         'pages' => [{ 'id' => 'p' }], 'layout' => '<Page/>' }

eq W.create_path, '/v2/workbooks', 'create path'
eq W.read_path('w1'), '/v2/workbooks/w1?includeContents=true', 'read path asks for contents'
eq W.update_path('w1'), '/v2/workbooks/w1/contents', 'update path'

body = W.create_body(flat)
eq body.keys.sort, %w[contents description folderId name], 'create body: metadata beside contents'
eq body['contents'].keys.sort, %w[layout pages schemaVersion], 'create body: contents holds the document only'
eq W.create_body(flat, dry_run: true)['dryRun'], true, 'dry run flag'
eq W.create_body({ 'name' => 'N', 'document' => { 'pages' => [] } })['contents'], { 'pages' => [] }, 'a document wrapper is re-keyed to contents'

upd = W.update_body(flat, document_version: 4)
eq upd, { 'contents' => { 'schemaVersion' => 1, 'pages' => [{ 'id' => 'p' }], 'layout' => '<Page/>' }, 'documentVersion' => 4 },
   'update body: no name/folderId, optional documentVersion'
eq W.update_body(flat).key?('documentVersion'), false, 'update body omits an unset documentVersion'

eq W.contents_of({ 'workbookId' => 'w', 'contents' => { 'pages' => [1] } }), { 'pages' => [1] }, 'contents_of unwraps a read'
eq W.contents_of(flat).key?('pages'), true, 'contents_of keeps a flat spec as is'


scripts = File.expand_path('../scripts', __dir__)
deprecated = /workbooks(?:\/\{[^}]*\}|\/#\{[^}]*\}|\/%s)?\/spec\b/
offenders = Dir[File.join(scripts, '**', '*.rb')].reject { |f| f.end_with?('lib/sigma_rest.rb') }.flat_map do |f|
  File.readlines(f).each_with_index.select { |l, _| l =~ deprecated && l !~ /^\s*#/ }.map { |l, i| "#{File.basename(f)}:#{i + 1}: #{l.strip}" }
end
eq offenders, [], 'no script calls a deprecated workbook /spec endpoint'

puts $failures.zero? ? "\nALL PASS" : "\n#{$failures} FAILURE(S)"
exit($failures.zero? ? 0 : 1)
