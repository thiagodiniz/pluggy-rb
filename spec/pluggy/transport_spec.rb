# frozen_string_literal: true

require "zlib"
require "stringio"

# Exercised against a real socket rather than WebMock: keep-alive and
# Content-Encoding are both handled inside Net::HTTP, below the layer WebMock
# replaces.
RSpec.describe "transport" do
  around do |example|
    WebMock.allow_net_connect!
    example.run
  ensure
    WebMock.disable_net_connect!(allow_localhost: false)
  end

  def gzip(string)
    io = StringIO.new(+"")
    Zlib::GzipWriter.new(io).tap { |gz| gz.write(string) }.close
    io.string
  end

  def client_for(server)
    Pluggy::Client.new(api_key: "static-key", api_base: server.base_url)
  end

  describe "keep-alive" do
    it "reuses one socket across requests" do
      LocalServer.run(body: fixture_raw("accounts/list")) do |server|
        client = client_for(server)
        3.times { client.accounts.list(item_id: "item-1") }

        expect(server.connections).to eq(1)
      end
    end

    it "opens a fresh socket after the pool is cleared" do
      LocalServer.run(body: fixture_raw("accounts/list")) do |server|
        client = client_for(server)
        client.accounts.list(item_id: "item-1")
        Pluggy::ConnectionManager.current.clear!
        client.accounts.list(item_id: "item-1")

        expect(server.connections).to eq(2)
      end
    end
  end

  describe "compressed responses" do
    it "decodes a gzipped body" do
      LocalServer.run(body: gzip(fixture_raw("accounts/list")),
        headers: { "Content-Encoding" => "gzip" }) do |server|
        accounts = client_for(server).accounts.list(item_id: "item-1")

        expect(accounts.first).to be_a(Pluggy::Resources::Account)
      end
    end

    it "hands the error builder a readable body" do
      LocalServer.run(body: gzip({ code: 404, message: "Bill not found" }.to_json),
        status: "404 Not Found",
        headers: { "Content-Encoding" => "gzip" }) do |server|
        client = client_for(server)

        expect { client.bills.retrieve("bill-1") }.to raise_error(Pluggy::NotFoundError) do |e|
          expect(e.http_body).to include("Bill not found")
        end
      end
    end
  end
end
