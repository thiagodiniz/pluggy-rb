#!/usr/bin/env ruby
# frozen_string_literal: true

# End-to-end walkthrough of everything this gem covers.
#
#   PLUGGY_CLIENT_ID=... PLUGGY_CLIENT_SECRET=... ruby examples/walkthrough.rb [ITEM_ID]
#
# Without an ITEM_ID it does the parts that need no connection (connect token,
# connectors, categories). With one it walks accounts, transactions, bills and
# loans. Read-only throughout.

require "bundler/setup"
require "pluggy"
require "logger"

client = Pluggy::Client.new(
  client_id: ENV.fetch("PLUGGY_CLIENT_ID"),
  client_secret: ENV.fetch("PLUGGY_CLIENT_SECRET"),
  logger: ENV["DEBUG"] ? Logger.new($stdout) : nil,
  log_level: :debug
)

item_id = ARGV[0]

def section(title)
  puts "\n\e[1m#{title}\e[0m"
  puts "-" * title.length
end

section "Authentication"
key = Pluggy::ApiKey.new(client.api_key)
puts "apiKey expires at #{key.expires_at} (in #{((key.expires_at - Time.now) / 60).round} min)"

section "Connect token (for the frontend widget)"
token = client.create_connect_token(options: { client_user_id: "walkthrough" })
puts "accessToken: #{token.access_token[0, 24]}... (valid 30 min, frontend only)"

section "Sandbox connectors"
client.connectors.list(sandbox: true).first(5).each do |c|
  flags = [c.mfa? ? "MFA" : nil, c.oauth? ? "OAuth" : nil,
           c.open_finance? ? "OpenFinance" : nil].compact.join(" ")
  puts format("  %-4d %-32s %s", c.id, c.name, flags)
end

section "Categories"
categories = client.categories.list
puts "  #{categories.length} categories (#{categories.class.name.split("::").last})"
categories.select(&:root?).first(5).each { |c| puts "  #{c.id}  #{c.description}" }

unless item_id
  puts "\nPass an item id to walk accounts, transactions, bills and loans."
  exit
end

section "Item"
item = client.items.retrieve(item_id)
puts "  #{item.connector.name} — status=#{item["status"]} execution=#{item["executionStatus"]}"
puts "  waiting on user input: #{item.user_action.instructions}" if item.waiting_user_input?
puts "  products: #{(item.products || []).join(", ")}"

section "Accounts"
accounts = client.accounts.list(item_id: item_id)
accounts.each do |a|
  puts format("  %-8s %-18s %-22s %12s %s",
    a["type"], a["subtype"], a.name, a.balance, a.currency_code)
end

accounts.each do |account|
  section "Transactions — #{account.name}"

  # Lazy: only the pages needed for these 10 rows are fetched.
  rows = account.transactions.auto_paging_each.first(10)
  if rows.empty?
    puts "  (none)"
  else
    rows.each do |t|
      extra = [
        t.installment_label,
        t.pix? ? "PIX->#{t.counterparty&.name}" : nil,
        t.pending? ? "PENDING" : nil
      ].compact.join(" ")
      puts format("  %s %12s  %-40s %s",
        t.date.strftime("%F"), t.amount, t.description.to_s[0, 40], extra)
    end
  end

  next unless account.credit?

  section "Bills — #{account.name}"
  client.bills.list(account_id: account.id).each do |bill|
    puts format("  closing %s  due %s  %12s %s",
      bill.bill_closing_date, bill.due_date, bill.total_amount,
      bill.paid? ? "(paid)" : "")

    # Reconstructed from creditCardMetadata.billId over the cycle window.
    lines = bill.transactions.to_a
    puts "    #{lines.length} line items, summing #{lines.sum(&:amount)}"
    lines.first(3).each do |t|
      puts format("    %s %12s  %s", t.date.strftime("%F"), t.amount, t.description.to_s[0, 40])
    end
  end
end

section "Loans (scoped to the item, not an account)"
loans = client.loans.list(item_id: item_id)
if loans.empty?
  puts "  (none)"
else
  loans.each do |loan|
    puts "  #{loan.product_name} — #{loan.contract_amount} #{loan.currency_code}, CET #{loan.cet}"
    if (i = loan.installments)
      puts "    #{i.paid_installments} paid / #{i.due_installments} due" \
           "#{" / #{i.past_due_installments} OVERDUE" if i.overdue?}"
    end
    puts "    outstanding: #{loan.outstanding_balance}" if loan.outstanding_balance
  end
end
