# Paths and wire bodies for Sigma's workbook code representation.
#
# The /v2/workbooks/spec, /v2/workbooks/{id}/spec and /v2/workbooks/spec/verify
# endpoints are DEPRECATED (OpenAPI 2.0.0+20261030). The replacements:
#
#   create / dry run  POST /v2/workbooks  {name, folderId, description?, contents, dryRun?}
#   read              GET  /v2/workbooks/{id}?includeContents=true  (document under `contents`, no folderId)
#   update            PUT  /v2/workbooks/{id}/contents  {contents, documentVersion?}
#
# The build scripts in this repo keep the workbook spec flat (name / folderId
# beside pages, elements, layout); the helpers split it at the API boundary.
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

  # Wire body for POST /v2/workbooks from a flat (or wrapped) spec Hash.
  def create_body(spec, dry_run: false)
    body = spec.select { |k, _| CREATE_METADATA_KEYS.include?(k) }
    body['contents'] = contents_of(spec)
    body['dryRun'] = true if dry_run
    body
  end

  # Wire body for PUT /v2/workbooks/{id}/contents.
  def update_body(spec, document_version: nil)
    body = { 'contents' => contents_of(spec) }
    body['documentVersion'] = document_version unless document_version.nil?
    body
  end
end
