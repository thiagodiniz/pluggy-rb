# frozen_string_literal: true

require "forwardable"

require_relative "pluggy/version"
require_relative "pluggy/errors"
require_relative "pluggy/util"
require_relative "pluggy/configuration"
require_relative "pluggy/pluggy_object"
require_relative "pluggy/api_resource"
require_relative "pluggy/api_key"
require_relative "pluggy/credential_store"
require_relative "pluggy/connection_manager"
require_relative "pluggy/lists"

require_relative "pluggy/resources/merchant"
require_relative "pluggy/resources/transaction"
require_relative "pluggy/resources/account"
require_relative "pluggy/resources/bill"
require_relative "pluggy/resources/loan"
require_relative "pluggy/resources/connector"
require_relative "pluggy/resources/item"
require_relative "pluggy/resources/misc"

require_relative "pluggy/api_requestor"
require_relative "pluggy/services/base_service"
require_relative "pluggy/services/transaction_service"
require_relative "pluggy/services/other_services"
require_relative "pluggy/client"

# Unofficial Ruby client for the Pluggy open-finance API.
#
#   client = Pluggy::Client.new(client_id: "...", client_secret: "...")
#   client.accounts.list(item_id: item_id).each { |a| puts a.name }
#
# Configuration is per-client. The module-level accessors below set defaults
# that new clients inherit; they are not a way to make calls without a client.
module Pluggy
  class << self
    extend Forwardable

    attr_accessor :config

    def_delegators :config,
      *Configuration::DEFAULTS.keys,
      *Configuration::DEFAULTS.keys.map { |key| :"#{key}=" }

    def configure
      yield config
      config
    end
  end

  self.config = Configuration.new
end
