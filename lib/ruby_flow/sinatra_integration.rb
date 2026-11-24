# frozen_string_literal: true

require "rack/utils"

module RubyFlow
  # Sinatra のレンダリング境界と例外処理の境界をラップする。
  module SinatraHooks
    private

    # Sinatra::Templates#render(engine, data, options, locals, &block)
    def render(engine, data, options = {}, locals = {}, &block)
      collector = RubyFlow.collector
      return super unless collector&.enabled? && RubyFlow.collector.current

      name, template_id = RubyFlow.template_identity(engine, data, settings)
      # 存在しない layout の探索など、実際に描画されないものは記録しない
      return super if data.is_a?(Symbol) && template_id.nil?

      span_id = collector.safely { collector.erb_start(template_id, name, self, locals.keys) }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      output = nil
      begin
        output = super
      ensure
        collector.safely do
          ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0
          collector.erb_end(template_id, name, output, ms, span_id, completed: !output.nil?)
        end
      end
      output
    end

    # 例外が Sinatra に届いた瞬間を記録（error ハンドラで処理されるものも含む）
    def handle_exception!(boom)
      collector = RubyFlow.collector
      if collector&.enabled? && collector.current
        collector.safely do
          file, line = collector.app_location(boom.backtrace_locations)
          collector.emit("ruby.raise", file: file, line: line,
                                       payload: collector.exception_payload(boom, origin: "sinatra")
                                                         .merge("handled_by" => "Sinatra"))
        end
      end
      super
    end
  end

  # ERB から使うヘルパー
  module Helpers
    # HTML エスケープ（Sinatra の ERB は自動エスケープしないため明示的に使う）
    def h(value)
      Rack::Utils.escape_html(value.to_s)
    end

    # 明示的に計測する ERB 式。値を記録し、エスケープ済み HTML を返す。
    # 計測していないときは h と同じ。
    def flow_h(label, value)
      output = Rack::Utils.escape_html(value.to_s)
      collector = RubyFlow.collector
      if collector&.enabled? && collector.current
        location = caller_locations(1, 1).first
        collector.safely { collector.erb_expression(label, value, output, location) }
      end
      output
    end
  end
end
