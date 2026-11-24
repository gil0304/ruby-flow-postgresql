# frozen_string_literal: true

require "securerandom"

module RubyFlow
  # Mutex で保護したメモリ内リングバッファ。
  # - seq は単調増加（時系列の正）
  # - 全体 max_events 件を超えると古いものから捨てる（クライアントには gap で通知）
  # - 1 リクエスト max_per_request 件を超えた分は捨て、件数を trace.drop で通知
  class EventStore
    SCHEMA_VERSION = 1
    TYPES = %w[
      request.start request.end ruby.call ruby.line ruby.return ruby.raise
      sql.query db.snapshot erb.start erb.expression erb.end
      response.redirect response.html trace.drop
    ].freeze
    # 上限に達しても必ず残す種別（リクエストの骨格）
    ESSENTIAL = %w[request.start request.end response.redirect response.html trace.drop ruby.raise].freeze
    OPTIONAL_KEYS = %i[span_id parent_span_id related_request_id].freeze

    attr_reader :max_events, :max_per_request, :server_id

    def initialize(clock: Clock.new, max_events: 5000, max_per_request: 500)
      @clock = clock
      @max_events = max_events
      @max_per_request = max_per_request
      @mutex = Mutex.new
      @events = []
      @seq = 0
      @per_request = Hash.new(0)
      @dropped = Hash.new(0)
      @evicted_total = 0
      @server_id = SecureRandom.hex(8)
    end

    # 追加できたら seq、上限で捨てたら nil
    def append(request_id:, type:, file: nil, line: nil, payload: {}, **extra)
      raise ArgumentError, "unknown event type: #{type}" unless TYPES.include?(type)

      @mutex.synchronize do
        unless ESSENTIAL.include?(type)
          if @per_request[request_id] >= @max_per_request
            @dropped[request_id] += 1
            return nil
          end
        end
        @per_request[request_id] += 1
        push_locked(request_id, type, file, line, payload, extra)
      end
    end

    # リクエスト終了時に呼ぶ。捨てた件数があれば trace.drop を記録し、カウンタを解放
    def finish_request(request_id)
      @mutex.synchronize do
        dropped = @dropped.delete(request_id)
        @per_request.delete(request_id)
        if dropped && dropped.positive?
          push_locked(request_id, "trace.drop", nil, nil,
                      { "reason" => "per_request_limit", "dropped" => dropped, "limit" => @max_per_request }, {})
        end
      end
    end

    # after より新しいイベント。gap=true はクライアントの取りこぼし（古いイベントが既に捨てられた）
    def since(after, limit: 1000)
      after = after.to_i
      @mutex.synchronize do
        oldest = @events.first ? @events.first["seq"] : @seq + 1
        gap = after.positive? && after < oldest - 1
        # 単調増加なので二分探索で開始位置を求める
        start = @events.bsearch_index { |e| e["seq"] > after } || @events.size
        events = @events[start, limit] || []
        {
          "schema_version" => SCHEMA_VERSION,
          "server_id" => @server_id,
          "events" => events,
          "next_cursor" => events.empty? ? [after, @seq].min : events.last["seq"],
          "oldest_cursor" => oldest,
          "latest_cursor" => @seq,
          "gap" => gap
        }
      end
    end

    def stats
      @mutex.synchronize do
        { "size" => @events.size, "max_events" => @max_events, "max_per_request" => @max_per_request,
          "latest_cursor" => @seq, "evicted_total" => @evicted_total }
      end
    end

    def size
      @mutex.synchronize { @events.size }
    end

    def clear
      @mutex.synchronize do
        @events.clear
        @per_request.clear
        @dropped.clear
      end
    end

    private

    def push_locked(request_id, type, file, line, payload, extra)
      @seq += 1
      event = {
        "seq" => @seq,
        "request_id" => request_id,
        "type" => type,
        "time_ms" => @clock.now_ms,
        "file" => file,
        "line" => line,
        "payload" => payload
      }
      OPTIONAL_KEYS.each { |k| event[k.to_s] = extra[k] if extra[k] }
      @events << event
      if @events.size > @max_events
        @events.shift
        @evicted_total += 1
      end
      @seq
    end
  end
end
