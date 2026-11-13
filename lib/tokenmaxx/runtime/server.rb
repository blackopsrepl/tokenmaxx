# frozen_string_literal: true

require "json"
require "socket"
require "time"

module TokenMaxx
  module Runtime
    module Server
      ROUTES = %w[/health /usage /status /cost /history /storage].freeze

      module_function

      def run(config_path, host: nil, port: nil)
        config = Core::Config.load_config(config_path)
        bind_host = host || config.dig(:server, :host)
        bind_port = (port || config.dig(:server, :port)).to_i
        server = TCPServer.new(bind_host, bind_port)
        shutdown = proc do
          server.close rescue nil
          ::Process.exit!(0)
        end
        trap("INT", &shutdown)
        trap("TERM", &shutdown)

        loop do
          client = server.accept
          serve_client(config, client)
        rescue IOError, SystemExit, Interrupt
          break
        ensure
          client&.close
        end
      end

      def serve_client(config, client)
        request_line = client.gets.to_s
        method, path, = request_line.split(/\s+/, 3)
        read_headers(client)
        unless method == "GET" && ROUTES.include?(path)
          write_response(client, 404, { error: "Not found" })
          return
        end

        write_response(client, 200, payload(config, path))
      end

      def read_headers(client)
        loop do
          line = client.gets
          break if line.nil? || line == "\r\n" || line == "\n"
        end
      end

      def write_response(client, status, payload)
        body = "#{JSON.pretty_generate(payload)}\n"
        reason = status == 200 ? "OK" : "Not Found"
        client.write("HTTP/1.1 #{status} #{reason}\r\n")
        client.write("Content-Type: application/json\r\n")
        client.write("Content-Length: #{body.bytesize}\r\n")
        client.write("Connection: close\r\n")
        client.write("\r\n")
        client.write(body)
      end

      def payload(config, route)
        case route
        when "/health"
          health_payload(config)
        when "/usage"
          State.snapshot_for_display(config, State.read_snapshot(config))
        when "/status"
          State.status_payload(config)
        when "/cost"
          State.read_local_usage(config)
        when "/history"
          State.read_history(config)
        when "/storage"
          State.read_storage(config)
        else
          { error: "Unknown route" }
        end
      end

      def health_payload(config)
        snapshot = State.read_snapshot(config)
        {
          ok: true,
          generatedAt: Time.now.utc.iso8601,
          snapshotPresent: !snapshot.nil?,
          stale: State.stale?(snapshot, config),
          stateDir: State.state_dir(config)
        }
      end
    end
  end
end
