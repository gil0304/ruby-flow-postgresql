# frozen_string_literal: true

require "rack"
require "uri"

module RubyFlow
  # Rack ミドルウェア：リクエスト単位の計測スコープを作る。
  # - request_id を発行し、開始/終了/例外/所要時間/レスポンスを記録
  # - TracePoint はこのスレッドでのみ有効化
  # - /__flow（API）、/visualizer、静的ファイルは計測しない
  # - MVP は非ストリーミング応答のみ対象（body は列挙せず Content-Length を読む）
  class Middleware
    PARENT_COOKIE = "ruby_flow_parent"
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

    def initialize(app, collector)
      @app = app
      @collector = collector
      @api = Api.new(collector: collector)
    end

    def call(env)
      path = env["PATH_INFO"].to_s
      return @api.call(env) if path.start_with?("/__flow")
      return @app.call(env) if !@collector.enabled? || excluded?(path)

      traced_call(env)
    end

    private

    def excluded?(path)
      @collector.config.excluded_prefixes.any? { |p| path.start_with?(p) } ||
        path.match?(/\.(css|js|png|jpg|svg|ico|wasm|map|rb|txt)\z/)
    end

    def traced_call(env)
      request = Rack::Request.new(env)
      parent = request.cookies[PARENT_COOKIE]
      parent = nil unless parent&.match?(UUID)
      context = RequestContext.new(related_request_id: parent)
      env["ruby_flow.request_id"] = context.request_id
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      status = headers = body = nil
      RequestContext.with(context) do
        record_start(context, request, parent)
        begin
          status, headers, body = @collector.tracer.trace(context) { @app.call(env) }
        rescue Exception => e # rubocop:disable Lint/RescueException
          @collector.safely do
            file, line = @collector.app_location(e.backtrace_locations)
            @collector.emit_for(context, "ruby.raise", file: file, line: line,
                                payload: @collector.exception_payload(e, origin: "unhandled").merge("handled" => false))
            finish(context, started, 500, nil)
          end
          raise
        end
        @collector.safely { record_response(context, request, status, headers) }
        @collector.safely { finish(context, started, status, headers) }
      end
      headers = decorate_headers(headers, context, status, parent)
      [status, headers, body]
    ensure
      @collector.store.finish_request(context.request_id) if context
    end

    def record_start(context, request, parent)
      @collector.safely do
        payload = {
          "method" => request.request_method,
          "path" => @collector.sanitizer.truncate(request.path_info),
          "query_keys" => safe_keys(request.GET),
          "params" => visible_params(request),
          "tracing" => "TracePoint(call/return/line/raise) 対象: #{@collector.registry.ruby_ids.join(', ')}"
        }
        payload["correlation"] = "redirect_cookie" if parent
        @collector.emit_for(context, "request.start", payload: payload,
                                                      related_request_id: parent)
      end
    end

    # 許可したデモ項目（title/body）だけ値を出す。それ以外はキー名のみ、機密キーは除去
    def visible_params(request)
      form = request.form_data? || request.parseable_data? ? request.POST : {}
      all = request.GET.merge(form)
      visible = {}
      hidden = []
      all.each do |k, v|
        key = k.to_s
        next if @collector.sanitizer.sensitive_key?(key)

        if @collector.config.visible_params.include?(key)
          visible[key] = @collector.sanitizer.describe(v)
        else
          hidden << @collector.sanitizer.truncate(key)
        end
      end
      { "visible" => visible, "hidden_keys" => hidden }
    rescue StandardError
      { "visible" => {}, "hidden_keys" => [], "error" => "params_unavailable" }
    end

    def safe_keys(hash)
      hash.keys.map(&:to_s).reject { |k| @collector.sanitizer.sensitive_key?(k) }.first(20)
    end

    def record_response(context, request, status, headers)
      h = Rack::Utils::HeaderHash[headers || {}]
      if (300..399).cover?(status.to_i) && h["Location"]
        @collector.emit_for(context, "response.redirect",
                            payload: { "status" => status.to_i, "location" => local_location(h["Location"], request) })
      elsif h["Content-Type"].to_s.include?("text/html")
        @collector.emit_for(context, "response.html",
                            payload: { "status" => status.to_i, "content_type" => "text/html",
                                       "bytes" => h["Content-Length"]&.to_i,
                                       "streaming" => h["Content-Length"].nil? })
      end
    end

    def finish(context, started, status, _headers)
      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0).round(3)
      @collector.emit_for(context, "request.end", payload: { "status" => status.to_i, "duration_ms" => ms })
    end

    # 同一オリジンならパスだけ、他オリジンなら隠す
    def local_location(location, request)
      uri = URI.parse(location.to_s)
      return @collector.sanitizer.truncate(uri.path.to_s) if uri.host.nil? || uri.host == request.host

      "(外部URL)"
    rescue URI::InvalidURIError
      "(不正なURL)"
    end

    # リダイレクト先の GET と親子関係を結ぶ「実際の根拠」として、短命の Cookie を使う。
    # 値は request_id のみ（利用者情報は含まない）。次のリクエストで消す。
    def decorate_headers(headers, context, status, parent)
      return headers unless headers

      headers["X-Ruby-Flow-Request-Id"] = context.request_id
      if (300..399).cover?(status.to_i)
        Rack::Utils.set_cookie_header!(headers, PARENT_COOKIE,
                                       { value: context.request_id, path: "/", max_age: "30",
                                         httponly: true, same_site: :strict })
      elsif parent
        Rack::Utils.delete_cookie_header!(headers, PARENT_COOKIE, { path: "/" })
      end
      headers
    end
  end
end
