# frozen_string_literal: true

require "json"
require "open3"

module TokenMaxx
  module Providers
    module Codex
      FIVE_HOUR_MINUTES = 300
      WEEKLY_MINUTES = 10_080

      module_function

      def fetch(config)
        source = config[:source] == "oauth" ? "oauth" : "codex-cli"
        rpc = nil

        begin
          rpc = RpcClient.new
          rpc.initialize_client("tokenmaxx-linux", "2.0.3")
          limits = rpc.fetch_rate_limits
          account = rpc.fetch_account rescue nil
          windows = rate_limit_windows(limits)
          plan_type = account_plan_type(account, limits)

          usage = {
            primary: make_window(windows[:primary]),
            secondary: make_window(windows[:secondary]),
            unavailableWindows: unavailable_windows(windows, plan_type),
            updatedAt: Time.now.utc.iso8601,
            identity: make_identity(account)
          }

          {
            provider: "codex",
            source: source,
            usage: usage,
            credits: make_credits(limits),
            notes: []
          }
        rescue StandardError => e
          {
            provider: "codex",
            source: source,
            notes: [],
            error: e.message
          }
        ensure
          rpc&.shutdown
        end
      end

      def make_window(window)
        return nil unless window

        resets_at = window[:resetsAt] ? Time.at(window[:resetsAt].to_i).utc.iso8601 : nil
        {
          usedPercent: window[:usedPercent].to_f,
          windowMinutes: window[:windowDurationMins],
          resetsAt: resets_at,
          resetDescription: nil
        }
      end

      def rate_limit_windows(response)
        snapshot = rate_limit_snapshot(response)
        windows = [snapshot[:primary], snapshot[:secondary]].compact

        primary = windows.find { |window| window[:windowDurationMins].to_i == FIVE_HOUR_MINUTES }
        secondary = windows.find { |window| window[:windowDurationMins].to_i == WEEKLY_MINUTES }
        remaining = windows.reject { |window| window.equal?(primary) || window.equal?(secondary) }

        primary ||= remaining.shift
        secondary ||= remaining.shift
        { primary: primary, secondary: secondary }
      end

      def rate_limit_snapshot(response)
        limits_by_id = response[:rateLimitsByLimitId]
        limits_by_id && (limits_by_id[:codex] || limits_by_id["codex"]) || response[:rateLimits] || {}
      end

      def account_plan_type(account, response)
        value = account&.dig(:account, :planType).to_s.downcase
        return value unless value.empty?

        rate_limit_snapshot(response)[:planType].to_s.downcase
      end

      def unavailable_windows(windows, plan_type)
        return [] if plan_type.to_s.empty? || plan_type.to_s == "pro"

        windows[:primary] ? [] : ["primary"]
      end

      def make_credits(response)
        credits = rate_limit_snapshot(response)[:credits]
        return nil unless credits && credits[:hasCredits]

        balance = credits[:balance]
        return nil unless balance

        remaining = balance.to_f
        return nil unless remaining.finite?

        {
          remaining: remaining,
          updatedAt: Time.now.utc.iso8601
        }
      end

      def make_identity(account)
        return nil unless account.dig(:account, :type).to_s.downcase == "chatgpt"

        {
          providerID: "codex",
          accountEmail: account.dig(:account, :email),
          loginMethod: account.dig(:account, :planType)
        }
      end

      class RpcClient
        def self.command
          ["codex", "--sandbox", "read-only", "--ask-for-approval", "never", "app-server", "--stdio"]
        end

        def initialize
          @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(*self.class.command)
          @stderr_thread = Thread.new { @stderr.read }
          @next_id = 1
        end

        def initialize_client(client_name, client_version)
          request("initialize", clientInfo: { name: client_name, version: client_version })
          send_payload(method: "initialized", params: {})
        end

        def fetch_account
          request("account/read")
        end

        def fetch_rate_limits
          request("account/rateLimits/read")
        end

        def shutdown
          @stdin.close unless @stdin.closed?
          return unless @wait_thread.alive?

          ::Process.kill("TERM", @wait_thread.pid)
          @wait_thread.join(1)
        rescue Errno::ESRCH, IOError
          nil
        ensure
          @stdout.close unless @stdout.closed?
          @stderr.close unless @stderr.closed?
          @stderr_thread&.kill
        end

        def request(method, params = {})
          id = @next_id
          @next_id += 1
          send_payload(id: id, method: method, params: params)

          loop do
            line = @stdout.gets
            raise "Codex app-server closed stdout" unless line

            next if line.strip.empty?

            message = JSON.parse(line, symbolize_names: true)
            next if message[:id].nil? || message[:id] != id
            raise(message.dig(:error, :message) || "Malformed Codex RPC response for #{method}") if message[:error]

            result = message[:result]
            raise "Malformed Codex RPC response for #{method}" if result.nil?

            return result
          rescue JSON::ParserError
            next
          end
        end

        def send_payload(payload)
          @stdin.write("#{JSON.generate(payload)}\n")
          @stdin.flush
        end
      end
    end
  end
end
