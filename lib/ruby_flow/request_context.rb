# frozen_string_literal: true

require "securerandom"

module RubyFlow
  # 1 リクエスト分の計測状態。スレッド（Fiber）ローカルに置き、ensure で必ず外す。
  class RequestContext
    KEY = :__ruby_flow_request_context

    attr_reader :request_id, :related_request_id, :span_stack

    def self.current
      Thread.current[KEY]
    end

    # ブロック実行中だけ現在のコンテキストにする
    def self.with(context)
      previous = Thread.current[KEY]
      Thread.current[KEY] = context
      yield
    ensure
      Thread.current[KEY] = previous
    end

    def initialize(request_id: SecureRandom.uuid, related_request_id: nil)
      @request_id = request_id
      @related_request_id = related_request_id
      @span_stack = []
      @span_counter = 0
    end

    def next_span_id
      @span_counter += 1
      "#{@request_id[0, 8]}-#{@span_counter}"
    end

    def current_span_id
      @span_stack.last
    end

    def push_span
      id = next_span_id
      parent = @span_stack.last
      @span_stack.push(id)
      [id, parent]
    end

    def pop_span
      @span_stack.pop
    end
  end
end
