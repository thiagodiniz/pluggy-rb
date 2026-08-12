# frozen_string_literal: true

require_relative "lib/pluggy/version"

Gem::Specification.new do |spec|
  spec.name     = "pluggy-rb"
  spec.version  = Pluggy::VERSION
  spec.summary  = "Ruby SDK for the Pluggy open-finance API"
  spec.description = <<~DESC
    An unofficial, hand-written Ruby client for the Pluggy API (https://pluggy.ai),
    covering the read paths needed to identify every transaction reachable from a
    connected item: accounts, transactions, credit-card bills, loans, connectors,
    items, categories and merchants. Transparent API-key renewal, uniform
    pagination across Pluggy's three paging shapes, and BigDecimal money.
  DESC

  spec.authors  = ["Thiago Diniz"]
  spec.email    = ["thiago.diniz@verve.com"]
  spec.homepage = "https://github.com/thiagodiniz/pluggy-rb"
  spec.license  = "MIT"

  spec.required_ruby_version = ">= 3.1"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir[
    "lib/**/*.rb",
    "VERSION",
    "README.md",
    "CHANGELOG.md",
    "LICENSE.txt"
  ]
  spec.require_paths = ["lib"]

  # The only runtime dependency. `bigdecimal` is a *bundled* gem from Ruby 3.4
  # onward (it is absent from Gem::Specification.default_stubs), so it must be
  # declared even though it ships with every Ruby. It is maintained in
  # ruby/ruby and pulls in nothing transitively.
  #
  # Amounts are parsed straight off the wire with
  # JSON.parse(body, decimal_class: BigDecimal), which reads the lexical digits
  # and never routes money through a Float. Set `decimal_amounts = false` to get
  # plain Floats and a dependency-free install.
  spec.add_dependency "bigdecimal", ">= 3.0"
end
