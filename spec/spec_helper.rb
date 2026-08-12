# frozen_string_literal: true

require "logger"
require "webmock/rspec"
require "pluggy"

Dir[File.join(__dir__, "support", "*.rb")].each { |f| require f }

WebMock.disable_net_connect!(allow_localhost: false)

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.filter_run_when_matching :focus
  config.example_status_persistence_file_path = ".rspec_status"
  config.order = :random
  Kernel.srand config.seed

  config.include StubAPI
  config.include Fixtures

  # Live specs opt in only when real credentials are present, so the default
  # suite is always hermetic.
  config.filter_run_excluding :live unless ENV["PLUGGY_CLIENT_ID"] && ENV["PLUGGY_CLIENT_SECRET"]

  # Global config is process-wide; snapshot it so one example cannot leak into
  # the next.
  config.around do |example|
    saved = Pluggy.config
    Pluggy.config = Pluggy::Configuration.new
    example.run
  ensure
    Pluggy.config = saved
  end

  # Retry backoff must never actually sleep.
  config.before do |example|
    unless example.metadata[:allow_sleep] || example.metadata[:live]
      allow_any_instance_of(Pluggy::APIRequestor).to receive(:sleep)
    end
  end

  # Net::HTTP connections are pooled per thread and survive examples.
  config.after { Pluggy::ConnectionManager.current.clear! }
end
