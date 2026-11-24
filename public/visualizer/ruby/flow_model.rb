# frozen_string_literal: true

# Ruby Flow 可視化：純粋ロジック（ブラウザの ruby.wasm でも、サーバーの CRuby テストでも動く）
# JS や p5 には依存しない。イベント契約 v1（docs/EVENT_PROTOCOL.md）を解釈する。
module RubyFlowViz
  class ProtocolError < StandardError; end

  SUPPORTED_SCHEMA = 1

  Event = Struct.new(:seq, :request_id, :type, :time_ms, :file, :line, :payload,
                     :span_id, :parent_span_id, :related_request_id, keyword_init: true) do
    def self.from_hash(h)
      raise ProtocolError, "event must be an object" unless h.is_a?(Hash)

      seq = h["seq"]
      raise ProtocolError, "seq must be integer" unless seq.is_a?(Integer)
      raise ProtocolError, "type missing" unless h["type"].is_a?(String)

      new(seq: seq, request_id: h["request_id"].to_s, type: h["type"], time_ms: h["time_ms"].to_f,
          file: h["file"], line: h["line"].is_a?(Integer) ? h["line"] : nil,
          payload: h["payload"].is_a?(Hash) ? h["payload"] : {},
          span_id: h["span_id"], parent_span_id: h["parent_span_id"],
          related_request_id: h["related_request_id"])
    end

    def p
      payload
    end

    def internal_sql?
      type == "sql.query" && %w[schema cache].include?(payload["kind"])
    end
  end

  # 1 リクエスト分のイベント
  class RequestTrace
    attr_reader :id, :events
    attr_accessor :related_request_id

    def initialize(id)
      @id = id
      @events = []
      @related_request_id = nil
    end

    def add(event)
      @events << event
      @related_request_id ||= event.related_request_id
    end

    def start_event
      @events.find { |e| e.type == "request.start" }
    end

    def end_event
      @events.reverse_each.find { |e| e.type == "request.end" }
    end

    def http_method
      start_event&.p&.fetch("method", nil) || "?"
    end

    def path
      start_event&.p&.fetch("path", nil) || "?"
    end

    def status
      end_event&.p&.fetch("status", nil)
    end

    def duration_ms
      end_event&.p&.fetch("duration_ms", nil)
    end

    def finished?
      !end_event.nil?
    end

    def first_seq
      @events.first&.seq || 0
    end

    def error?
      @events.any? { |e| e.type == "ruby.raise" } || status.to_i >= 500
    end

    def dropped?
      @events.any? { |e| e.type == "trace.drop" }
    end

    def sql_count
      @events.count { |e| e.type == "sql.query" && !e.internal_sql? }
    end

    def label
      "#{http_method} #{path}"
    end
  end

  # サーバーから受け取ったイベントの集積（カーソル・欠落・再起動の検出）
  class EventLog
    attr_reader :cursor, :server_id, :gap_count, :requests_order, :total_events, :last_error

    def initialize(max_requests: 60)
      @max_requests = max_requests
      reset!
    end

    def reset!
      @cursor = 0
      @requests = {}
      @requests_order = []
      @gap_count = 0
      @total_events = 0
      @server_id = nil
    end

    # envelope（Hash）を取り込む。戻り値: { new_requests:, new_events:, gap:, reset: }
    def ingest(envelope)
      raise ProtocolError, "envelope must be an object" unless envelope.is_a?(Hash)

      version = envelope["schema_version"]
      raise ProtocolError, "unsupported schema_version: #{version.inspect}" unless version == SUPPORTED_SCHEMA

      result = { new_requests: [], new_events: 0, gap: false, reset: false }
      sid = envelope["server_id"]
      if @server_id && sid && sid != @server_id
        reset!
        result[:reset] = true
      end
      @server_id ||= sid

      if envelope["gap"] == true
        @gap_count += 1
        result[:gap] = true
      end

      events = envelope["events"]
      raise ProtocolError, "events must be an array" unless events.is_a?(Array)

      events.each do |raw|
        event = Event.from_hash(raw)
        next if event.seq <= @cursor # 重複は無視（seq が時系列の正）

        trace = @requests[event.request_id]
        unless trace
          trace = RequestTrace.new(event.request_id)
          @requests[event.request_id] = trace
          @requests_order << event.request_id
          result[:new_requests] << event.request_id
        end
        trace.add(event)
        @cursor = event.seq
        @total_events += 1
        result[:new_events] += 1
      end
      nc = envelope["next_cursor"]
      @cursor = nc if nc.is_a?(Integer) && nc > @cursor
      trim!
      result
    end

    def request(id)
      @requests[id]
    end

    def requests
      @requests_order.map { |id| @requests[id] }
    end

    def latest_request
      @requests_order.empty? ? nil : @requests[@requests_order.last]
    end

    def next_request_after(id)
      i = @requests_order.index(id)
      i && @requests_order[i + 1] ? @requests[@requests_order[i + 1]] : nil
    end

    def children_of(id)
      requests.select { |r| r.related_request_id == id }
    end

    def empty?
      @requests_order.empty?
    end

    private

    def trim!
      while @requests_order.size > @max_requests
        old = @requests_order.shift
        @requests.delete(old)
      end
    end
  end

  NODES = {
    browser: { label: "ブラウザ", kind: :browser },
    app: { label: "app.rb", kind: :ruby, file: "app.rb" },
    models: { label: "models.rb", kind: :ruby, file: "models.rb" },
    db: { label: "PostgreSQL", kind: :db },
    erb: { label: "ERB", kind: :erb },
    html: { label: "HTML", kind: :html }
  }.freeze

  # 描画の 1 ステップ。event は必ず実イベント。移動（from→to）の動きは説明用の補間。
  Step = Struct.new(:index, :event, :kind, :from, :to, :node, :label, :detail, :file, :line,
                    :weight, :tone, keyword_init: true) do
    def transfer?
      %i[transfer roundtrip].include?(kind)
    end
  end

  # リクエストのイベント列 → 描画ステップ列
  class StepBuilder
    def initialize(include_internal_sql: false)
      @include_internal_sql = include_internal_sql
    end

    def self.node_for_file(file)
      case file.to_s
      when "models.rb" then :models
      when /\.erb\z/ then :erb
      else :app
      end
    end

    def build(trace)
      steps = []
      current = :browser
      stack = []
      trace.events.each do |e|
        next if e.internal_sql? && !@include_internal_sql

        step = step_for(e, current, stack)
        next unless step

        step.index = steps.size
        steps << step
        current = step.to || step.node || current
      end
      steps
    end

    private

    def mk(e, **attrs)
      Step.new(event: e, file: e.file, line: e.line, weight: 1.0, tone: :normal, detail: nil, **attrs)
    end

    def step_for(e, current, stack)
      p = e.payload
      case e.type
      when "request.start"
        mk(e, kind: :transfer, from: :browser, to: :app, label: "#{p['method']} #{p['path']}",
              detail: params_detail(p["params"]))
      when "ruby.call"
        node = self.class.node_for_file(e.file)
        stack.push(node)
        if node != current
          mk(e, kind: :transfer, from: current, to: node, label: "呼び出し #{p['method']}")
        else
          mk(e, kind: :focus, node: node, label: "開始 #{p['method']}", weight: 0.6)
        end
      when "ruby.line"
        node = self.class.node_for_file(e.file)
        if node != current && current != :browser
          mk(e, kind: :transfer, from: current, to: node, label: "#{e.file}:#{e.line}", weight: 0.6)
        else
          mk(e, kind: :line, node: node, label: "#{e.file}:#{e.line} を実行", weight: 0.35)
        end
      when "ruby.return"
        node = self.class.node_for_file(e.file)
        stack.pop
        back = stack.last
        ret = p["return"].is_a?(Hash) ? p["return"]["type"] : nil
        if back && back != node
          mk(e, kind: :transfer, from: node, to: back, label: "戻り値 #{ret}", detail: p["method"])
        else
          mk(e, kind: :focus, node: node, label: "#{p['method']} 終了 → #{ret}", weight: 0.5)
        end
      when "sql.query"
        from = current == :db ? :app : current
        from = :app if %i[browser html erb].include?(from)
        dur = p["duration_ms"] ? format("%.2fms", p["duration_ms"]) : ""
        label = [p["operation"], p["table"], dur].compact.reject(&:empty?).join(" ")
        tone = %w[schema cache].include?(p["kind"]) ? :internal : (p["kind"] == "transaction" ? :transaction : :normal)
        tone = :error if p["operation"] == "ROLLBACK"
        mk(e, kind: :roundtrip, from: from, to: from, node: :db, label: label, detail: p["statement"], tone: tone,
              weight: tone == :internal ? 0.5 : 1.0)
      when "db.snapshot"
        to = self.class.node_for_file(e.file)
        to = :app if to == :erb
        row = p["row"].is_a?(Hash) ? p["row"] : {}
        verb = p["committed"] ? "確定" : "取り消し"
        mk(e, kind: :transfer, from: :db, to: to, label: "#{verb} #{p['action']} #{p['table']} id=#{row['id']}",
              tone: p["committed"] ? :commit : :error)
      when "erb.start"
        names = Array(p["assigns"]).map { |a| "#{a['name']}(#{a['type']})" }.join(", ")
        from = current == :erb ? :app : current
        from = :app if %i[browser html db].include?(from)
        mk(e, kind: :transfer, from: from, to: :erb, label: "#{p['template']}.erb へ #{names}".strip)
      when "erb.expression"
        mk(e, kind: :focus, node: :erb, label: "#{p['label']}: #{p['type']} → HTML",
              detail: "#{p['value']} → #{p['html']}", weight: 0.7)
      when "erb.end"
        mk(e, kind: :transfer, from: :erb, to: :html, label: "HTML #{p['html_bytes']}B (#{p['template']})")
      when "ruby.raise"
        mk(e, kind: :focus, node: self.class.node_for_file(e.file), label: "例外 #{p['class']}", tone: :error,
              detail: p["message"])
      when "response.html"
        mk(e, kind: :transfer, from: :html, to: :browser, label: "#{p['status']} HTML #{p['bytes']}B")
      when "response.redirect"
        mk(e, kind: :transfer, from: current == :browser ? :app : current, to: :browser,
              label: "#{p['status']} リダイレクト → #{p['location']}")
      when "request.end"
        mk(e, kind: :focus, node: :browser, label: "完了 #{p['status']} (#{p['duration_ms']}ms 実測)",
              tone: p["status"].to_i >= 400 ? :error : :normal, weight: 0.6)
      when "trace.drop"
        mk(e, kind: :marker, node: current, label: "イベント欠落 #{p['dropped']}件 (上限 #{p['limit']})",
              tone: :error)
      end
    end

    def params_detail(params)
      return nil unless params.is_a?(Hash)

      visible = params["visible"].is_a?(Hash) ? params["visible"] : {}
      parts = visible.map { |k, v| "#{k}=#{v.is_a?(Hash) ? v['value'].inspect : v.inspect}" }
      parts.empty? ? nil : parts.join(" ")
    end
  end

  # 再生状態（再生/一時停止/前後/速度/リセット）
  class Player
    SPEEDS = [0.5, 1.0, 2.0].freeze
    BASE_MS = 1100.0

    attr_reader :index, :progress, :speed, :count
    attr_accessor :reduced_motion

    def initialize
      @index = 0
      @progress = 0.0
      @speed = 1.0
      @playing = false
      @count = 0
      @reduced_motion = false
    end

    def playing?
      @playing
    end

    def load(count, keep: false)
      @count = count
      unless keep
        @index = 0
        @progress = 0.0
      end
      @index = [[@index, count - 1].min, 0].max
    end

    # 新しいステップが増えたとき（ライブ中の同一リクエスト）
    def extend_to(count)
      @count = count
    end

    def play
      return if @count.zero?

      if at_end? && @progress >= 1.0
        @index = 0
        @progress = 0.0
      end
      @playing = true
    end

    def pause
      @playing = false
    end

    def toggle
      playing? ? pause : play
    end

    def step_forward
      pause
      return if @count.zero?

      if @progress < 1.0
        @progress = 1.0
      elsif @index < @count - 1
        @index += 1
        @progress = 1.0
      end
    end

    def step_back
      pause
      return if @count.zero?

      @index -= 1 if @index.positive?
      @progress = 1.0
    end

    def reset
      pause
      @index = 0
      @progress = 0.0
    end

    def seek(i)
      pause
      return if @count.zero?

      @index = i.clamp(0, @count - 1)
      @progress = 1.0
    end

    def speed=(value)
      v = value.to_f
      @speed = SPEEDS.include?(v) ? v : 1.0
    end

    def faster
      i = SPEEDS.index(@speed) || 1
      @speed = SPEEDS[[i + 1, SPEEDS.size - 1].min]
    end

    def slower
      i = SPEEDS.index(@speed) || 1
      @speed = SPEEDS[[i - 1, 0].max]
    end

    def at_end?
      @count.zero? || @index >= @count - 1
    end

    def finished?
      at_end? && @progress >= 1.0
    end

    # dt_ms 経過させる。weight はステップの重み（短い行実行は速く進む）
    # 戻り値: :advanced（次のステップへ）/ :finished / nil
    def update(dt_ms, weight = 1.0)
      return nil unless @playing && @count.positive?

      duration = BASE_MS * weight / @speed
      duration = 1.0 if duration < 1.0
      @progress += @reduced_motion ? 1.0 : dt_ms / duration
      return nil if @progress < 1.0

      # 1 ステップ表示後、少し止めてから次へ（hold）
      @hold = (@hold || 0.0) + dt_ms
      return nil if @hold < 250.0 / @speed && !@reduced_motion

      @hold = 0.0
      if at_end?
        @progress = 1.0
        @playing = false
        :finished
      else
        @index += 1
        @progress = 0.0
        :advanced
      end
    end
  end

  # ノード配置と移動経路（キャンバスサイズから計算）
  class Layout
    POSITIONS = {
      browser: [0.11, 0.30], app: [0.38, 0.30], models: [0.64, 0.30], db: [0.88, 0.30],
      erb: [0.38, 0.76], html: [0.11, 0.76]
    }.freeze
    EDGES = [%i[browser app], %i[app models], %i[models db], %i[app db], %i[app erb], %i[erb html],
             %i[html browser]].freeze

    attr_reader :width, :height, :graph_height, :node_w, :node_h

    def initialize(width, height, timeline_height: 64)
      resize(width, height, timeline_height: timeline_height)
    end

    def resize(width, height, timeline_height: 64)
      @width = width.to_f
      @height = height.to_f
      @timeline_height = timeline_height
      @graph_height = @height - timeline_height
      @node_w = [[@width * 0.15, 150.0].min, 96.0].max
      @node_h = [[@graph_height * 0.17, 72.0].min, 50.0].max
    end

    def center(node)
      fx, fy = POSITIONS.fetch(node)
      [fx * @width, 28 + fy * (@graph_height - 28)]
    end

    def rect(node)
      cx, cy = center(node)
      [cx - @node_w / 2, cy - @node_h / 2, @node_w, @node_h]
    end

    def hit(x, y)
      POSITIONS.keys.find do |n|
        rx, ry, rw, rh = rect(n)
        x >= rx && x <= rx + rw && y >= ry && y <= ry + rh
      end
    end

    # 経路の制御点（隣接しないノード間は弧を描く）
    def control_point(from, to)
      x1, y1 = center(from)
      x2, y2 = center(to)
      mx = (x1 + x2) / 2
      my = (y1 + y2) / 2
      bend = adjacent?(from, to) ? 0.0 : -(@node_h * 1.4)
      bend = @node_h * 0.6 if %i[html browser].include?(from) && %i[html browser].include?(to)
      [mx, my + bend]
    end

    def adjacent?(a, b)
      pair = [a, b]
      [%i[browser app], %i[app models], %i[models db], %i[app erb], %i[erb html], %i[html browser]]
        .any? { |e| e == pair || e.reverse == pair }
    end

    # t(0..1) における位置（2 次ベジェ）
    def point(from, to, t)
      x1, y1 = center(from)
      x2, y2 = center(to)
      cx, cy = control_point(from, to)
      u = 1 - t
      [u * u * x1 + 2 * u * t * cx + t * t * x2, u * u * y1 + 2 * u * t * cy + t * t * y2]
    end

    def timeline_rect
      [16.0, @height - @timeline_height + 18, @width - 32, 22.0]
    end

    def timeline_index_at(x, y, count)
      tx, ty, tw, th = timeline_rect
      return nil if count.zero? || y < ty - 10 || y > ty + th + 10 || x < tx || x > tx + tw

      (((x - tx) / tw) * count).floor.clamp(0, count - 1)
    end
  end

  # 変数とデータの変遷（ステップ index までのイベントから計算）
  module DataFlow
    module_function

    # 変数ごとの最新値と、直前の値からの変化
    def variables(steps, upto)
      vars = {}
      order = []
      steps[0..upto].to_a.each do |s|
        e = s.event
        next unless %w[ruby.line ruby.return].include?(e.type)

        Array(e.payload["vars"]).each do |v|
          name = v["name"]
          prev = vars[name]
          changed = prev && (prev[:value] != v["value"] || prev[:type] != v["type"])
          order << name unless vars.key?(name)
          vars[name] = { name: name, scope: v["scope"], type: v["type"], value: v["value"],
                         prev_type: changed ? prev[:type] : prev&.dig(:prev_type),
                         prev_value: changed ? prev[:value] : prev&.dig(:prev_value),
                         changed_now: changed && s.index == upto,
                         where: "#{e.file}:#{e.line}" }
        end
      end
      order.map { |n| vars[n] }
    end

    # 許可されたデモ項目（title / body）が、どこでどう変わったか
    def field_trail(trace, field, upto_seq = nil)
      trail = []
      trace.events.each do |e|
        break if upto_seq && e.seq > upto_seq

        p = e.payload
        case e.type
        when "request.start"
          v = p.dig("params", "visible", field)
          trail << stage("ブラウザ → params[:#{field}]", v["type"], v["value"], e) if v.is_a?(Hash)
        when "ruby.line", "ruby.return"
          Array(p["vars"]).each do |var|
            if var["name"] == field
              next if var["value"].nil? # 代入前（ローカル変数は nil で見える）は変遷に含めない

              trail << stage("ローカル変数 #{field}", var["type"], var["value"], e)
            elsif var["value"].is_a?(Hash) && var["value"].key?(field) && var["value"]["__type"]
              trail << stage("#{var['name']}.#{field}", "#{var['value']['__type']}##{field}", var["value"][field], e)
            end
          end
        when "db.snapshot"
          row = p["row"]
          if row.is_a?(Hash) && row.key?(field)
            trail << stage("PostgreSQL #{p['table']}.#{field}（#{p['committed'] ? '確定' : '取り消し'}）",
                           "列", row[field], e)
          end
        when "erb.start"
          Array(p["assigns"]).each do |a|
            if a["value"].is_a?(Hash) && a["value"].key?(field)
              trail << stage("ERB に渡した #{a['name']}.#{field}", a["type"], a["value"][field], e)
            end
          end
        when "erb.expression"
          if p["label"] == field
            trail << stage("ERB 式 → HTML#{p['escaped'] ? '（エスケープ）' : ''}", "HTML", p["html"], e)
          end
        end
      end
      dedupe(trail)
    end

    def stage(where, type, value, e)
      { where: where, type: type, value: value, seq: e.seq, location: e.file ? "#{e.file}:#{e.line}" : nil }
    end

    # 同じ場所・同じ値の連続は 1 つにまとめる（変化点だけを見せる）
    def dedupe(trail)
      trail.each_with_object([]) do |s, out|
        last = out.last
        next if last && last[:where] == s[:where] && last[:value] == s[:value] && last[:type] == s[:type]

        out << s
      end
    end
  end
end
