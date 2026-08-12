# frozen_string_literal: true

require "json"

module StubAPI
  BASE = "https://api.pluggy.ai"
  JSON_HEADERS = { "Content-Type" => "application/json" }.freeze

  def stub_auth(api_key: test_jwt, times: nil)
    stub = stub_request(:post, "#{BASE}/auth")
           .with(body: { clientId: "test-client-id", clientSecret: "test-client-secret" })
    stub = stub.times(times) if times
    stub.to_return(status: 200, body: { apiKey: api_key }.to_json, headers: JSON_HEADERS)
  end

  # `fixture:` names a file under spec/fixtures; `body:` passes raw JSON.
  def stub_pluggy(method, path, status: 200, fixture: nil, body: nil, query: nil, headers: {})
    stub = stub_request(method, "#{BASE}#{path}")
    stub = stub.with(query: query) if query

    payload = body || (fixture && fixture_raw(fixture)) || "{}"
    payload = payload.to_json unless payload.is_a?(String)

    stub.to_return(status: status, body: payload, headers: JSON_HEADERS.merge(headers))
  end

  def test_client(**options)
    Pluggy::Client.new(
      client_id: "test-client-id",
      client_secret: "test-client-secret",
      **options
    )
  end

  # A base64url JWT whose payload carries `exp`. Unsigned -- ApiKey only reads
  # the claim, it never verifies.
  def test_jwt(exp: Time.now + 7200)
    encode = ->(s) { [s].pack("m0").tr("+/", "-_").delete("=") }
    header = encode.call({ alg: "HS256", typ: "JWT" }.to_json)
    payload = encode.call({ exp: exp.to_i, clientId: "test-client-id" }.to_json)
    "#{header}.#{payload}.not-a-real-signature"
  end

  def auth_requests_made
    a_request(:post, "#{BASE}/auth")
  end
end
