# frozen_string_literal: true

module RubyFlow
  # 単調増加クロック。time_ms はこの基準からの経過ミリ秒（壁時計ではない）。
  class Clock
    def initialize
      @origin = now_raw
    end

    def now_ms
      ((now_raw - @origin) * 1000.0).round(3)
    end

    private

    def now_raw
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
