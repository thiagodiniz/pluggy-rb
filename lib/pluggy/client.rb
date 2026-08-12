# frozen_string_literal: true

module Pluggy
  # The entry point.
  #
  #   client = Pluggy::Client.new(
  #     client_id: ENV["PLUGGY_CLIENT_ID"],
  #     client_secret: ENV["PLUGGY_CLIENT_SECRET"]
  #   )
  #   client.accounts.list(item_id: item_id)
  #
  # Authentication is handled for you: the apiKey is fetched lazily on the first
  # request, cached until the expiry in its own JWT, and renewed transparently
  # if the API rejects it mid-session.
  #
  # One client holds one credential set and is safe to share across threads.
  class Client
    attr_reader :config, :requestor

    def initialize(client_id: nil, client_secret: nil, api_key: nil, **options)
      @config = Pluggy.config.merge(
        client_id: client_id,
        client_secret: client_secret,
        api_key: api_key,
        **options
      )
      @config.validate!
      @requestor = APIRequestor.new(@config)
    end

    def accounts = @accounts ||= Services::AccountService.new(self)
    def transactions = @transactions ||= Services::TransactionService.new(self)
    def bills = @bills ||= Services::BillService.new(self)
    def loans = @loans ||= Services::LoanService.new(self)
    def items = @items ||= Services::ItemService.new(self)
    def connectors = @connectors ||= Services::ConnectorService.new(self)
    def categories = @categories ||= Services::CategoryService.new(self)
    def merchants = @merchants ||= Services::MerchantService.new(self)
    def connect_tokens = @connect_tokens ||= Services::ConnectTokenService.new(self)

    # The first call most integrations make.
    def create_connect_token(**kwargs) = connect_tokens.create(**kwargs)

    # The current apiKey, authenticating first if needed. Rarely useful directly
    # -- mostly for debugging and for the live smoke test.
    def api_key = @requestor.credentials.fetch(@requestor).to_s

    # Escape hatches for the endpoints this gem deliberately does not model
    # (payments, smart transfers, boletos, consents, webhooks, investments,
    # identity). Returns parsed JSON, not resource objects.
    def get(path, **params) = @requestor.request(:get, path, params: params)
    def post(path, **body) = @requestor.request(:post, path, body: body)
    def patch(path, **body) = @requestor.request(:patch, path, body: body)
    def delete(path, **params) = @requestor.request(:delete, path, params: params)

    def inspect
      "#<Pluggy::Client client_id=#{@config.client_id.to_s[0, 8]}... api_base=#{@config.api_base}>"
    end
    alias to_s inspect
  end
end
