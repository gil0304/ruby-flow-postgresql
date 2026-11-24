# frozen_string_literal: true

require "json"
require "rack"

module RubyFlow
  # 可視化用 API（ローカル専用・読み取り専用）。
  #   GET /__flow/events?after=N  … カーソル以降のイベント（JSON polling）
  #   GET /__flow/source          … 閲覧可能なファイル ID 一覧
  #   GET /__flow/source?file=ID  … 許可したソースのみ（実パスは返さない）
  #   GET /__flow/health          … 計測状態
  # Host / 接続元を検証し、CORS ヘッダは付けない。すべて no-store。
  class Api
    LOOPBACK_HOSTS = %w[127.0.0.1 localhost ::1 [::1]].freeze
    LOOPBACK_ADDRS = %w[127.0.0.1 ::1 ::ffff:127.0.0.1].freeze

    def initialize(collector:)
      @collector = collector
    end

    def call(env)
      return json(403, "error" => "forbidden", "reason" => "ローカル(127.0.0.1)からのみ利用できます") unless local?(env)
      return json(405, "error" => "method_not_allowed") unless %w[GET HEAD].include?(env["REQUEST_METHOD"])

      request = Rack::Request.new(env)
      case env["PATH_INFO"]
      when "/__flow/events" then events(request)
      when "/__flow/source" then source(request)
      when "/__flow/health" then health
      when "/__flow", "/__flow/" then redirect("/visualizer/index.html")
      else json(404, "error" => "not_found")
      end
    end

    private

    def local?(env)
      host = env["SERVER_NAME"].to_s
      host_header = env["HTTP_HOST"].to_s.sub(/:\d+\z/, "")
      remote = env["REMOTE_ADDR"].to_s
      LOOPBACK_HOSTS.include?(host_header.empty? ? host : host_header) &&
        (remote.empty? || LOOPBACK_ADDRS.include?(remote))
    end

    def events(request)
      after = request.params["after"].to_s
      return json(400, "error" => "invalid_cursor") unless after.match?(/\A\d{0,18}\z/)

      limit = request.params["limit"].to_s.match?(/\A\d{1,4}\z/) ? request.params["limit"].to_i.clamp(1, 1000) : 500
      json(200, @collector.store.since(after.to_i, limit: limit))
    end

    def source(request)
      id = request.params["file"]
      return json(200, "files" => @collector.registry.list) if id.nil?

      text = @collector.registry.read(id.to_s)
      return json(404, "error" => "not_allowed_or_missing") unless text

      json(200, "id" => id.to_s, "lines" => text.lines.map(&:chomp))
    end

    def health
      db = begin
        if defined?(ActiveRecord::Base)
          ActiveRecord::Base.connection_pool.with_connection do |conn|
            { "adapter" => conn.adapter_name, "connected" => conn.select_value("SELECT 1").to_i == 1 }
          end
        else
          { "adapter" => nil, "connected" => false }
        end
      rescue StandardError => e
        # 接続情報（ホスト・DB名・ユーザー）は出さず、例外クラスのみ
        { "adapter" => nil, "connected" => false, "error_class" => e.class.name }
      end
      json(200, "status" => "ok", "tracing" => @collector.enabled?, "schema_version" => EventStore::SCHEMA_VERSION,
                "server_ruby_version" => RUBY_VERSION, "store" => @collector.store.stats,
                "server_id" => @collector.store.server_id,
                "internal_errors" => @collector.internal_errors, "database" => db)
    end

    def json(status, body)
      [status, { "Content-Type" => "application/json; charset=utf-8", "Cache-Control" => "no-store",
                 "X-Content-Type-Options" => "nosniff" }, [JSON.generate(body)]]
    end

    def redirect(path)
      [302, { "Location" => path, "Cache-Control" => "no-store" }, []]
    end
  end
end
