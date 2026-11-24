# frozen_string_literal: true

module RubyFlow
  # 計測の中心。各フック（Rack / TracePoint / SQL / ERB / モデル）はここへイベントを送る。
  # 依存はすべて注入可能にし、テストで差し替えられるようにする。
  class Collector
    # message を表示してよい例外（値やSQLを含まないことが分かっているもの）
    SAFE_MESSAGE_EXCEPTIONS = %w[
      ActiveRecord::RecordNotFound ActiveRecord::RecordInvalid ArgumentError RuntimeError
      Sinatra::NotFound
    ].freeze

    attr_reader :store, :sanitizer, :registry, :tracer, :classifier, :config
    attr_accessor :enabled

    def initialize(config:, store: nil, sanitizer: nil, registry: nil, classifier: nil)
      @config = config
      @enabled = config.enabled
      @store = store || EventStore.new(max_events: config.max_events, max_per_request: config.max_per_request)
      @sanitizer = sanitizer || Sanitizer.new(max_string: config.max_string, model_attributes: config.model_attributes)
      @registry = registry || SourceRegistry.new(root: config.root, ruby_files: config.ruby_files,
                                                 template_globs: config.template_globs)
      @classifier = classifier || SqlClassifier.new(max_length: config.max_string)
      @tracer = Tracer.new(collector: self, registry: @registry, sanitizer: @sanitizer,
                           watch_locals: config.watch_locals, watch_ivars: config.watch_ivars,
                           watch_self_classes: config.watch_self_classes)
      @internal_errors = 0
    end

    def enabled?
      @enabled
    end

    def current
      RequestContext.current
    end

    def internal_errors
      @internal_errors + @tracer.internal_errors
    end

    # 現在のリクエストに属するイベントとして記録（リクエスト外なら何もしない）
    def emit(type, file: nil, line: nil, payload: {}, **extra)
      ctx = current
      return nil unless ctx

      emit_for(ctx, type, file: file, line: line, payload: payload, **extra)
    end

    def emit_for(context, type, file: nil, line: nil, payload: {}, **extra)
      @store.append(request_id: context.request_id, type: type, file: file, line: line,
                    payload: payload, **extra)
    rescue StandardError
      @internal_errors += 1
      nil
    end

    # 計測コード自身の失敗はアプリに伝播させない
    def safely
      yield
    rescue StandardError
      @internal_errors += 1
      nil
    end

    # 呼び出し元のうち、許可ファイル内で最も近いフレーム
    def app_location(locations = caller_locations(2, 200))
      Array(locations).each do |loc|
        id = @registry.id_for_path(loc.absolute_path || loc.path)
        return [id, loc.lineno] if id
      end
      [nil, nil]
    end

    def exception_payload(error, origin:)
      klass = error.class.name.to_s
      payload = { "class" => klass, "origin" => origin }
      if SAFE_MESSAGE_EXCEPTIONS.include?(klass) || origin == "app"
        payload["message"] = @sanitizer.truncate(error.message)
      else
        payload["message"] = nil
        payload["message_hidden"] = true
      end
      payload
    end

    # ---- SQL ----
    def record_sql(event_payload, duration_ms)
      ctx = current
      return unless ctx

      sql = event_payload[:sql]
      info = @classifier.classify(sql, name: event_payload[:name], cached: event_payload[:cached])
      info["name"] = @sanitizer.truncate(event_payload[:name]) if event_payload[:name]
      info["duration_ms"] = duration_ms.round(3)
      info["row_count"] = event_payload[:row_count] if event_payload.key?(:row_count)
      info["measured"] = "sql.active_record の完了通知（往復の実測時間）"
      file, line = app_location
      emit_for(ctx, "sql.query", file: file, line: line, payload: info, parent_span_id: ctx.current_span_id)
    end

    # ---- DB 行の確定/取り消し（モデルのコールバックから明示的に呼ぶ）----
    def record_db_change(record, action:, committed:)
      ctx = current
      return unless ctx

      file, line = app_location
      payload = {
        "table" => record.class.table_name,
        "action" => action,
        "committed" => committed,
        "row" => @sanitizer.clean(record)
      }
      emit_for(ctx, "db.snapshot", file: file, line: line, payload: payload, parent_span_id: ctx.current_span_id)
    end

    # ---- ERB ----
    def erb_start(template_id, name, scope, local_names)
      ctx = current
      return nil unless ctx

      span_id, parent = ctx.push_span
      assigns = []
      @config.watch_ivars.each do |ivar|
        next unless scope.instance_variable_defined?(ivar)

        d = @sanitizer.describe(scope.instance_variable_get(ivar))
        assigns << { "name" => ivar.to_s, "type" => d["type"], "value" => d["value"] }
      end
      payload = { "template" => name, "assigns" => assigns,
                  "locals" => Array(local_names).map(&:to_s).reject { |n| @sanitizer.sensitive_key?(n) } }
      emit_for(ctx, "erb.start", file: template_id, line: nil, payload: payload,
                                 span_id: span_id, parent_span_id: parent)
      span_id
    end

    def erb_end(template_id, name, output, duration_ms, span_id, completed: true)
      ctx = current
      return unless ctx

      ctx.pop_span if ctx.current_span_id == span_id
      payload = { "template" => name, "duration_ms" => duration_ms.round(3),
                  "html_bytes" => output.to_s.bytesize, "completed" => completed }
      emit_for(ctx, "erb.end", file: template_id, line: nil, payload: payload,
                               span_id: span_id, parent_span_id: ctx.current_span_id)
    end

    def erb_expression(label, value, output, location)
      ctx = current
      return unless ctx

      file = location && @registry.id_for_path(location.absolute_path || location.path)
      # テンプレートの実ファイル以外（生成コード等）の行番号は採用しない
      line = file&.end_with?(".erb") ? location.lineno : nil
      d = @sanitizer.describe(value)
      payload = { "label" => label.to_s, "type" => d["type"], "value" => d["value"],
                  "html" => @sanitizer.truncate(output), "escaped" => output.to_s != value.to_s }
      emit_for(ctx, "erb.expression", file: file, line: line, payload: payload,
                                      parent_span_id: ctx.current_span_id)
    end
  end
end
