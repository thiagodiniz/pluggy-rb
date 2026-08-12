# frozen_string_literal: true

# Shim so `gem "pluggy-rb"` auto-requires cleanly under Bundler.
# `require "pluggy"` is the canonical form.
require_relative "pluggy"
