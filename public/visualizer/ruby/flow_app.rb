# frozen_string_literal: true

require "json"

# Ruby Flow 可視化：アプリ状態とコマンド処理（DOM は注入されたアダプタ経由で操作）
module RubyFlowViz
  class App
    TABS = %w[code vars db html events].freeze
    FIELDS = %w[title body].freeze

    attr_reader :log, :player, :steps, :selected_id, :layout, :connection, :last_error,
                :health, :sources, :tab, :frames
    attr_accessor :wasm_ruby_version, :p5_version

    def initialize(dom:, width: 900, height: 560)
      @dom = dom
      @log = EventLog.new
      @player = Player.new
      @include_internal = false
      @builder = StepBuilder.new(include_internal_sql: @include_internal)
      @steps = []
      @selected_id = nil
      @live = true
      @tab = "code"
      @sources = {}
      @view_file = nil
      @connection = :connecting
      @last_error = nil
      @health = nil
      @layout = Layout.new(width, height)
      @dirty = true
      @last_rendered_index = nil
      @frames = 0
      @ingest_count = 0
    end

    def live?
      @live
    end

    def include_internal?
      @include_internal
    end

    def cursor
      @log.cursor
    end

    def selected
      @selected_id && @log.request(@selected_id)
    end

    def current_step
      @steps[@player.index]
    end

    # ---- サーバーからの入力 ----
    def ingest(json_text)
      envelope = JSON.parse(json_text.to_s)
      result = @log.ingest(envelope)
      @ingest_count += 1
      @connection = :ok
      @last_error = nil
      if result[:reset]
        @selected_id = nil
        @steps = []
        @player.load(0)
      end
      if @live && @selected_id.nil? && (latest = @log.latest_request)
        select(latest.id, play: true)
      elsif selected && result[:new_events].positive?
        rebuild_steps(keep: true)
        # ライブ中に同じリクエストのイベントが追加で届いたら続きを再生
        @player.play if @live && !@player.playing? && !@player.at_end?
      end
      @dirty = true if result[:new_events].positive? || result[:gap] || result[:reset]
      result
    rescue JSON::ParserError, ProtocolError => e
      @connection = :error
      @last_error = "イベントを解釈できません: #{e.class}: #{e.message}"
      @dirty = true
      nil
    end

    def connection_error(message)
      @connection = :error
      @last_error = message.to_s
      @dirty = true
    end

    def health=(json_text)
      @health = JSON.parse(json_text.to_s)
      @dirty = true
    rescue JSON::ParserError
      @health = nil
    end

    def load_source(id, json_text)
      data = JSON.parse(json_text.to_s)
      @sources[id.to_s] = Array(data["lines"]).map(&:to_s)
      @dirty = true
    end

    def reduced_motion=(flag)
      @player.reduced_motion = flag ? true : false
      @dirty = true
    end

    def reduced_motion?
      @player.reduced_motion
    end

    # ---- コマンド（ボタン・キーボード・クリック）----
    def command(name, arg = nil)
      case name.to_s
      when "toggle" then @player.toggle
      when "play" then @player.play
      when "pause" then @player.pause
      when "step_forward" then manual { @player.step_forward }
      when "step_back" then manual { @player.step_back }
      when "reset" then manual { @player.reset }
      when "speed" then @player.speed = arg.to_f
      when "faster" then @player.faster
      when "slower" then @player.slower
      when "live"
        @live = !@live
        select(@log.latest_request.id, play: true) if @live && @log.latest_request
      when "internal"
        @include_internal = !@include_internal
        @builder = StepBuilder.new(include_internal_sql: @include_internal)
        rebuild_steps(keep: false)
      when "select_request"
        @live = false
        select(arg.to_s, play: true)
      # 一覧は新しい順に並ぶので、↑ = より新しいリクエスト、↓ = より古いリクエスト
      when "newer_request", "older_request" then move_request(name.to_s == "newer_request" ? 1 : -1)
      when "tab" then @tab = arg.to_s if TABS.include?(arg.to_s)
      when "seek_event" then seek_event(arg.to_i)
      when "seek_step" then manual { @player.seek(arg.to_i) }
      when "view_file" then @view_file = arg.to_s if @sources.key?(arg.to_s)
      when "motion" then self.reduced_motion = !reduced_motion?
      when "key" then return key(arg.to_s)
      else return false
      end
      @dirty = true
      true
    end

    def key(k)
      case k
      when " " then command("toggle")
      when "ArrowRight" then command("step_forward")
      when "ArrowLeft" then command("step_back")
      when "ArrowUp" then command("newer_request")
      when "ArrowDown" then command("older_request")
      when "r", "R" then command("reset")
      when "1" then command("speed", 0.5)
      when "2" then command("speed", 1.0)
      when "3" then command("speed", 2.0)
      when "l", "L" then command("live")
      else false
      end
    end

    # ---- 毎フレーム ----
    def tick(dt_ms)
      @frames += 1
      step = current_step
      result = @player.update(dt_ms.to_f, step ? step.weight : 1.0)
      @dirty = true if result
      auto_advance if result == :finished || (@live && @player.finished?)
      render_panels if @dirty || @last_rendered_index != @player.index
    end

    def resize(width, height)
      @layout.resize(width, height)
    end

    def click(x, y)
      i = @layout.timeline_index_at(x, y, @steps.size)
      return command("seek_step", i) if i

      node = @layout.hit(x, y)
      if node && (file = NODES[node][:file]) && @sources.key?(file)
        @view_file = file
        @tab = "code"
        @dirty = true
      end
      false
    end

    # ---- 表示用の導出値 ----
    def code_focus
      return [@view_file, nil] if @view_file

      idx = @player.index
      @steps[0..idx].to_a.reverse_each do |s|
        return [s.file, s.line] if s.file
      end
      [nil, nil]
    end

    def visited_lines(file)
      @steps[0..@player.index].to_a.select { |s| s.file == file && s.line }.map(&:line).uniq
    end

    def status_text
      parts = []
      parts << case @connection
               when :ok then "接続中（250〜500ms ごとに取得）"
               when :error then "切断: #{@last_error}"
               else "接続待ち…"
               end
      if @health
        parts << (@health["tracing"] ? "計測 ON" : "計測 OFF（RUBY_FLOW=off）")
        db = @health["database"] || {}
        parts << (db["connected"] ? "DB: #{db['adapter']}" : "DB: 未接続#{db['error_class'] ? "（#{db['error_class']}）" : ''}")
      end
      parts << "イベント欠落を #{@log.gap_count} 回検出" if @log.gap_count.positive?
      parts.join(" ／ ")
    end

    private

    def manual
      @live = false
      yield
    end

    def select(id, play: false)
      trace = @log.request(id)
      return unless trace

      @selected_id = id
      @view_file = nil
      rebuild_steps(keep: false)
      play ? @player.play : @player.pause
    end

    def rebuild_steps(keep:)
      trace = selected
      @steps = trace ? @builder.build(trace) : []
      if keep
        @player.extend_to(@steps.size)
      else
        @player.load(@steps.size)
      end
      @dirty = true
    end

    def move_request(delta)
      ids = @log.requests_order
      return if ids.empty?

      i = ids.index(@selected_id) || ids.size - 1
      @live = false
      select(ids[(i + delta).clamp(0, ids.size - 1)], play: true)
    end

    # ライブ追従: 再生し終えたら次のリクエスト（POST の後の GET など）へ進む
    def auto_advance
      return unless @live
      return unless @player.finished?

      trace = selected
      return if trace && !trace.finished? # まだ届いていないイベントを待つ

      nxt = trace ? @log.next_request_after(trace.id) : @log.latest_request
      select(nxt.id, play: true) if nxt
    end

    def seek_event(seq)
      @live = false
      idx = @steps.index { |s| s.event.seq >= seq }
      @player.seek(idx || @steps.size - 1)
    end

    def render_panels
      @dirty = false
      @last_rendered_index = @player.index
      trace = selected
      step = current_step
      current_seq = step&.event&.seq

      @dom.set_text("status-text", status_text)
      @dom.set_attr("app-root", "data-connection", @connection.to_s)
      @dom.set_html("request-list", Panels.requests(@log, @selected_id))
      file, line = code_focus
      @dom.set_html("file-list", Panels.files(@sources, file))
      @dom.set_attr("btn-play", "aria-pressed", @player.playing?.to_s)
      @dom.set_text("btn-play", @player.playing? ? "⏸ 一時停止" : "▶ 再生")
      @dom.set_attr("btn-live", "aria-pressed", @live.to_s)
      @dom.set_attr("btn-internal", "aria-pressed", @include_internal.to_s)
      @dom.set_attr("btn-motion", "aria-pressed", reduced_motion?.to_s)
      Player::SPEEDS.each do |s|
        @dom.set_attr("speed-#{s.to_s.tr('.', '_')}", "aria-pressed", (@player.speed == s).to_s)
      end
      @dom.set_text("step-text", step_text(step))
      TABS.each do |t|
        @dom.set_attr("tab-#{t}", "aria-selected", (@tab == t).to_s)
        @dom.set_attr("panel-#{t}", "data-active", (@tab == t).to_s)
      end

      case @tab
      when "code"
        note = step && step.file.nil? && file ? "（このステップはファイル外: 直前の位置を表示）" : nil
        note = "（手動で選択したファイル）" if @view_file
        @dom.set_html("panel-code", Panels.code(file, file && @sources[file], line, file ? visited_lines(file) : [], note))
        @dom.scroll_into_view("code-line-#{line}") if line
      when "vars"
        vars = trace ? DataFlow.variables(@steps, @player.index) : []
        trails = trace ? FIELDS.map { |f| [f, DataFlow.field_trail(trace, f, current_seq)] } : []
        @dom.set_html("panel-vars", Panels.variables(vars, trails))
      when "db"
        events = trace ? trace.events : []
        loaded = loaded_rows(events, current_seq)
        @dom.set_html("panel-db", Panels.database(events.select { |e| e.type == "sql.query" },
                                                  events.select { |e| e.type == "db.snapshot" && (current_seq.nil? || e.seq <= current_seq) },
                                                  current_seq, loaded))
      when "html"
        events = trace ? trace.events : []
        erb = events.select { |e| e.type.start_with?("erb.") }
        resp = events.find { |e| %w[response.html response.redirect].include?(e.type) }
        open = trace && trace.http_method == "GET" ? trace.path : nil
        @dom.set_html("panel-html", Panels.html_output(erb, resp, current_seq, open))
      when "events"
        @dom.set_html("panel-events", Panels.events(trace, current_seq))
        @dom.scroll_into_view("panel-events", ".current") if current_seq
      end
    end

    def loaded_rows(events, current_seq)
      events.each do |e|
        next unless e.type == "erb.start"
        next if current_seq && e.seq > current_seq

        Array(e.payload["assigns"]).each do |a|
          v = a["value"]
          return v.select { |r| r.is_a?(Hash) } if v.is_a?(Array)
          return [v] if v.is_a?(Hash) && v["__type"]
        end
      end
      []
    end

    def step_text(step)
      return "ステップなし" unless step

      e = step.event
      kind = step.transfer? ? "移動は説明用の補間（実イベントは到着点）" : "実イベント"
      "#{@player.index + 1}/#{@steps.size}  ##{e.seq} #{EventText.type_label(e.type)} — #{step.label}  [#{kind}]"
    end
  end
end
