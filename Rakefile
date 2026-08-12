# frozen_string_literal: true

require "rspec/core/rake_task"
require "rubocop/rake_task"

RSpec::Core::RakeTask.new(:spec)
RuboCop::RakeTask.new(:rubocop)

task default: %i[rubocop spec]

SPEC_PATH = "spec/support/openapi/pluggy-oas3.json"

# Which OpenAPI response examples become which fixture files. Keyed by
# [path, method] so the two /accounts/{id} examples (bank and credit) can be
# split into separate files.
FIXTURE_MAP = {
  ["/accounts", "get"] => "accounts/list",
  ["/accounts/{id}", "get"] => "accounts/retrieve",
  ["/accounts/{id}/balance", "get"] => "accounts/balance",
  ["/accounts/{id}/statements", "get"] => "accounts/statements",
  ["/transactions", "get"] => "transactions/v1_list",
  ["/v2/transactions", "get"] => "transactions/v2_list",
  ["/bills", "get"] => "bills/list",
  ["/bills/{id}", "get"] => "bills/retrieve",
  ["/loans", "get"] => "loans/list",
  ["/loans/{id}", "get"] => "loans/retrieve",
  # The spec's /categories example is a page envelope even though its schema
  # declares a bare array, so it lands in list_envelope. The matching
  # list_array.json is derived from it by hand -- see spec/fixtures/README.md.
  ["/categories", "get"] => "categories/list_envelope",
  ["/merchants", "get"] => "merchants/search"
}.freeze

namespace :fixtures do
  desc "Extract 200-response examples from the vendored OpenAPI spec into spec/fixtures"
  task :extract do
    require "json"
    require "fileutils"

    spec = JSON.parse(File.read(SPEC_PATH))
    written = []
    missing = []

    FIXTURE_MAP.each do |(path, verb), dest|
      body = spec.dig("paths", path, verb, "responses", "200", "content", "application/json")
      unless body
        missing << "#{verb.upcase} #{path} (no 200 body)"
        next
      end

      # An operation carries either a single `example` or a named `examples` map.
      examples =
        if body.key?("example")
          { nil => body["example"] }
        elsif body.key?("examples")
          body["examples"].transform_values { |v| v.fetch("value", v) }
        else
          missing << "#{verb.upcase} #{path} (no example)"
          next
        end

      examples.each do |name, value|
        # A single unnamed example, or one conventionally named "response",
        # keeps the base filename; anything else is suffixed.
        suffix = name.nil? || name == "response" ? "" : "_#{name}"
        file = "spec/fixtures/#{dest}#{suffix}.json"
        FileUtils.mkdir_p(File.dirname(file))
        File.write(file, "#{JSON.pretty_generate(value)}\n")
        written << file
      end
    end

    puts "wrote #{written.length} fixtures:"
    written.sort.each { |f| puts "  #{f}" }

    unless missing.empty?
      puts "\nno example in the spec (hand-write these):"
      missing.each { |m| puts "  #{m}" }
    end
  end
end

namespace :schema do
  desc "Print a `fields`/`nested` DSL block for a component schema, e.g. rake schema:fields[Transaction]"
  task :fields, [:name] do |_t, args|
    require "json"
    abort "usage: rake schema:fields[Transaction]" unless args[:name]

    spec = JSON.parse(File.read(SPEC_PATH))
    schema = spec.dig("components", "schemas", args[:name]) or abort "no such schema: #{args[:name]}"
    props = schema["properties"] or abort "#{args[:name]} has no properties"

    scalars, objects = props.partition do |_k, v|
      ref = v["$ref"] || v.dig("items", "$ref") || v["anyOf"]&.find { |a| a["$ref"] }&.fetch("$ref", nil)
      ref.nil?
    end

    puts "      fields #{scalars.map { |k, _| k.match?(/\A[a-z]/) ? ":#{k}" : k.inspect }.join(", ")}"
    objects.each do |k, v|
      ref = v["$ref"] || v.dig("items", "$ref") || v["anyOf"].find { |a| a["$ref"] }["$ref"]
      puts "      nested #{k}: #{ref.split("/").last} # #{v["type"] == "array" ? "array" : "object"}"
    end

    # `required` minus `properties` is the spec-bug signal (Bill.accountId etc).
    undeclared = (schema["required"] || []) - props.keys
    puts "\n      # required but NOT in properties (spec bug, present at runtime):" if undeclared.any?
    puts "      fields #{undeclared.map { |k| ":#{k}" }.join(", ")}" if undeclared.any?
  end
end
