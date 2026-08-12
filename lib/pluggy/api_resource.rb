# frozen_string_literal: true

module Pluggy
  # Base for the top-level API resources. Adds the client back-reference that
  # makes navigation (account.transactions, bill.transactions, item.accounts)
  # possible.
  #
  # Objects built by a requestor always carry a client. Objects a caller
  # constructs by hand do not, so ensure_client! explains that rather than
  # letting a NoMethodError on nil surface.
  class APIResource < PluggyObject
    private

    def ensure_client!
      return @client if @client

      raise Error,
        "#{self.class.name}##{caller_locations(1, 1)[0].label} needs a client. This object was " \
        "built without one; fetch it through Pluggy::Client (e.g. client.accounts.retrieve(id)) " \
        "to use navigation methods."
    end
  end
end
