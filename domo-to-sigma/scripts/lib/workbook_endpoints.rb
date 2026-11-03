# Paths and wire bodies for Sigma's workbook code representation.
#
# The /v2/workbooks/spec, /v2/workbooks/{id}/spec and /v2/workbooks/spec/verify
# endpoints are DEPRECATED (OpenAPI 2.0.0+20261030). The replacements:
#
#   create / dry run  POST /v2/workbooks  {name, folderId, description?, contents, dryRun?}
#   read              GET  /v2/workbooks/{id}?includeContents=true  (document under `contents`, no folderId)
#   update            PUT  /v2/workbooks/{id}/contents  {contents, documentVersion?}
#
# The build scripts in this repo keep the legacy workbook spec shape (name /
# folderId beside pages, with elements nested in each page); the helpers adapt
# it to the current API shape at the boundary.
# Data-model /v2/dataModels/.../spec endpoints are NOT deprecated; do not use
# these on data-model payloads.
require 'json'

module WorkbookEndpoints
  CREATE_METADATA_KEYS = %w[name folderId description].freeze

  module_function

  def create_path
    '/v2/workbooks'
  end

  # GET target; format with the workbook id.
  def read_path(id)
    "/v2/workbooks/#{id}?includeContents=true"
  end

  def update_path(id)
    "/v2/workbooks/#{id}/contents"
  end

  # The document of a flat spec, a `contents`-wrapped or a `document`-wrapped one.
  def contents_of(spec)
    return spec unless spec.is_a?(Hash)
    inner = spec['contents'].is_a?(Hash) ? spec['contents'] : spec['document']
    return inner if inner.is_a?(Hash)
    spec.reject { |k, _| CREATE_METADATA_KEYS.include?(k) }
  end

  # Current wire-format contents: elements are flat and pages hold metadata only.
  def wire_contents(spec)
    contents = contents_of(spec).dup
    pages = Array(contents['pages'])
    nested_elements = pages.flat_map { |page| Array(page['elements']) }
    contents['pages'] = pages.map { |page| page.reject { |key, _| key == 'elements' } }
    contents['elements'] = nested_elements unless nested_elements.empty? && contents.key?('elements')
    contents['elements'] ||= []
    contents['kind'] ||= 'workbook'

    if contents.key?('themeName') || contents.key?('themeOverrides')
      settings = (contents['settings'] || {}).dup
      theme = (settings['theme'] || {}).dup
      theme['name'] = contents.delete('themeName') if contents.key?('themeName')
      if contents.key?('themeOverrides')
        overrides = contents.delete('themeOverrides').dup
        if overrides['colorOverrides'].is_a?(Hash)
          overrides['colorOverrides'] = overrides['colorOverrides'].map do |name, color|
            { 'name' => name, 'color' => color }
          end
        end
        theme['overrides'] = overrides
      end
      settings['theme'] = theme
      contents['settings'] = settings
    end
    contents
  end

  # Legacy in-repo shape used by builders and lints. The layout assigns each
  # current-format element to its page.
  def legacy_spec(spec)
    contents = contents_of(spec)
    return contents unless contents.is_a?(Hash) && contents['elements'].is_a?(Array)

    elements_by_id = contents['elements'].each_with_object({}) { |element, out| out[element['id']] = element }
    page_elements = contents['layout'].to_s.scan(
      %r{<Page\b[^>]*\bid="([^"]*)"[^>]*>(.*?)</Page>}m
    ).to_h.transform_values do |body|
      body.scan(/\belementId="([^"]*)"/).flatten.filter_map { |id| elements_by_id[id] }.uniq
    end

    contents.merge(
      'pages' => Array(contents['pages']).map do |page|
        page.merge('elements' => page_elements.fetch(page['id'], []))
      end
    )
  end

  # Wire body for POST /v2/workbooks from a flat (or wrapped) spec Hash.
  def create_body(spec, dry_run: false)
    body = spec.select { |k, _| CREATE_METADATA_KEYS.include?(k) }
    body['contents'] = wire_contents(spec)
    body['dryRun'] = true if dry_run
    body
  end

  # Wire body for PUT /v2/workbooks/{id}/contents.
  def update_body(spec, document_version: nil)
    body = { 'contents' => wire_contents(spec) }
    body['documentVersion'] = document_version unless document_version.nil?
    body
  end
end
