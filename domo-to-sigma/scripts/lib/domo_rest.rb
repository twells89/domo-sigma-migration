# Domo REST wrapper for domo-to-sigma. Covers BOTH API surfaces:
#   - PUBLIC  api.domo.com           (OAuth bearer, DOMO_ACCESS_TOKEN)   — documented, stable
#   - PRIVATE {instance}.domo.com    (X-DOMO-Developer-Token header)     — undocumented, best-effort
#
# Requires in ENV:
#   DOMO_ACCESS_TOKEN  (public; set by scripts/get-token.sh)
#   DOMO_CLIENT_ID / DOMO_CLIENT_SECRET  (for auto-refresh on 401)
#   DOMO_INSTANCE      (private host: {DOMO_INSTANCE}.domo.com)
#   DOMO_DEV_TOKEN     (private; optional — omit for Tier B / public-only)
#
# All methods return parsed Hash/Array (or raw String for csv export). HTTP errors
# raise Domo::Error with the response body included.
#
# STATUS: auth + public endpoints follow Domo's documented API. Private endpoints
# are reconstructed from community sources — CONFIRM response shapes on first
# contact with a live instance (see refs/connection.md "Open questions").

require 'net/http'
require 'uri'
require 'json'

module Domo
  class Error < StandardError; end
  class AuthError < Error; end

  PUBLIC_HOST = 'api.domo.com'

  @mutex = Mutex.new
  @token_override = nil

  module_function

  def access_token
    @mutex.synchronize { @token_override } ||
      ENV.fetch('DOMO_ACCESS_TOKEN') { raise Error, 'DOMO_ACCESS_TOKEN not set — run get-token.sh' }
  end

  def instance
    ENV.fetch('DOMO_INSTANCE') { raise Error, 'DOMO_INSTANCE not set (e.g. "acme" for acme.domo.com)' }
  end

  def dev_token
    ENV['DOMO_DEV_TOKEN'] # nil => Tier B (public only)
  end

  # Re-run client-credentials and update the in-memory public token. Thread-safe.
  def refresh_token!
    id     = ENV.fetch('DOMO_CLIENT_ID')     { raise AuthError, 'DOMO_CLIENT_ID not set — cannot refresh' }
    secret = ENV.fetch('DOMO_CLIENT_SECRET') { raise AuthError, 'DOMO_CLIENT_SECRET not set — cannot refresh' }
    scope  = (ENV['DOMO_SCOPE'] || 'data user account dashboard').gsub(' ', '%20')
    uri = URI("https://#{PUBLIC_HOST}/oauth/token?grant_type=client_credentials&scope=#{scope}")
    req = Net::HTTP::Get.new(uri)
    req.basic_auth(id, secret)
    res = http(uri).request(req)
    raise AuthError, "token refresh failed: #{res.code} #{res.body}" unless res.is_a?(Net::HTTPSuccess)
    tok = JSON.parse(res.body).fetch('access_token')
    @mutex.synchronize { @token_override = tok }
    ENV['DOMO_ACCESS_TOKEN'] = tok
    tok
  end

  # ---- PUBLIC API (api.domo.com) -------------------------------------------

  # GET against api.domo.com. Auto-refreshes once on 401. `accept` lets callers
  # request text/csv for the DataSet export endpoint.
  def public_get(path, query: nil, accept: 'application/json', _retried: false)
    uri = URI("https://#{PUBLIC_HOST}#{path}")
    uri.query = URI.encode_www_form(query) if query
    req = Net::HTTP::Get.new(uri)
    req['Authorization'] = "Bearer #{access_token}"
    req['Accept'] = accept
    res = http(uri).request(req)
    if res.is_a?(Net::HTTPUnauthorized) && !_retried
      refresh_token!
      return public_get(path, query: query, accept: accept, _retried: true)
    end
    handle(res, accept)
  end

  def public_post(path, body:, _retried: false)
    uri = URI("https://#{PUBLIC_HOST}#{path}")
    req = Net::HTTP::Post.new(uri)
    req['Authorization'] = "Bearer #{access_token}"
    req['Content-Type']  = 'application/json'
    req['Accept']        = 'application/json'
    req.body = body.is_a?(String) ? body : JSON.generate(body)
    res = http(uri).request(req)
    if res.is_a?(Net::HTTPUnauthorized) && !_retried
      refresh_token!
      return public_post(path, body: body, _retried: true)
    end
    handle(res, 'application/json')
  end

  # Convenience: documented public endpoints.
  def list_datasets(limit: 50, offset: 0)
    public_get('/v1/datasets', query: { limit: limit, offset: offset })
  end

  def dataset(id)
    public_get("/v1/datasets/#{id}")
  end

  def dataset_csv(id, header: true)
    public_get("/v1/datasets/#{id}/data", query: { includeHeader: header }, accept: 'text/csv')
  end

  def query_dataset(id, sql)
    public_post("/v1/datasets/query/execute/#{id}", body: { sql: sql })
  end

  def pages
    public_get('/v1/pages')
  end

  def page(id)
    public_get("/v1/pages/#{id}")
  end

  # ---- PRIVATE API ({instance}.domo.com/api/...) ---------------------------
  # Undocumented. Returns nil if DOMO_DEV_TOKEN is unset (Tier B). CONFIRM shapes.

  def private_get(path, query: nil)
    tok = dev_token or return nil
    uri = URI("https://#{instance}.domo.com#{path}")
    uri.query = URI.encode_www_form(query) if query
    req = Net::HTTP::Get.new(uri)
    req['X-DOMO-Developer-Token'] = tok
    req['Accept'] = 'application/json'
    handle(http(uri).request(req), 'application/json')
  end

  # TODO(on-access): confirm the `parts` values and the response JSON shape.
  def card_definition(card_id, parts: 'metadata,datasources,problems')
    private_get('/api/content/v1/cards', query: { urns: card_id, parts: parts })
  end

  def page_layout(page_id)
    private_get("/api/content/v1/pages/#{page_id}")
  end

  def dataset_meta(ds_id)
    private_get("/api/data/v3/datasources/#{ds_id}", query: { parts: 'core,permission' })
  end

  # ---- internals -----------------------------------------------------------

  def http(uri)
    h = Net::HTTP.new(uri.host, uri.port)
    h.use_ssl = (uri.scheme == 'https')
    h.read_timeout = 120
    h
  end

  def handle(res, accept)
    unless res.is_a?(Net::HTTPSuccess)
      raise Error, "#{res.code} #{res.message} for #{res.uri rescue '?'}: #{res.body}"
    end
    return res.body if accept == 'text/csv'
    res.body.to_s.empty? ? {} : JSON.parse(res.body)
  end
end
