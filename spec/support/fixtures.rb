# frozen_string_literal: true

require "json"

# Loads spec/fixtures/*.json.
#
# Most are generated from the vendored OpenAPI spec by `rake fixtures:extract`;
# the error fixtures and the eight endpoints the spec gives no example for are
# hand-written. Either way they are committed, so the suite never reads the
# 525KB spec at runtime.
module Fixtures
  ROOT = File.expand_path("../fixtures", __dir__)

  def fixture_raw(name)
    path = File.join(ROOT, "#{name}.json")
    raise ArgumentError, "no fixture at #{path}" unless File.exist?(path)

    File.read(path)
  end

  def fixture(name)
    JSON.parse(fixture_raw(name))
  end
end
