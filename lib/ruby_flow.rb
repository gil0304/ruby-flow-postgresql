# frozen_string_literal: true

require_relative "ruby_flow/clock"
require_relative "ruby_flow/sanitizer"
require_relative "ruby_flow/event_store"
require_relative "ruby_flow/source_registry"
require_relative "ruby_flow/request_context"
require_relative "ruby_flow/sql_classifier"
require_relative "ruby_flow/tracer"
require_relative "ruby_flow/collector"
require_relative "ruby_flow/api"
require_relative "ruby_flow/middleware"
require_relative "ruby_flow/sinatra_integration"

# Ruby Flow: 実際の Sinatra / ActiveRecord / PostgreSQL / ERB の処理を観測する。
module RubyFlow
  Config = Struct.new(
    :enabled, :root, :ruby_files, :template_globs, :watch_locals, :watch_ivars, :watch_self_classes,
    :model_attributes, :visible_params, :excluded_prefixes, :max_events, :max_per_request, :max_string,
    keyword_init: true
  )

  def self.default_config(root:)
    Config.new(
      # RUBY_FLOW=off で計測を完全に無効化（比較・本番相当の確認用）
      enabled: ENV.fetch("RUBY_FLOW", "on") != "off",
      root: root,
      ruby_files: %w[app.rb models.rb],
      template_globs: %w[views/*.erb],
      # 値を表示してよい変数名（許可リスト）。これ以外は読まない
      watch_locals: %w[title body post posts id saved],
      watch_ivars: %w[@post @posts],
      watch_self_classes: %w[Post],
      # モデルごとに表示してよい列。デモで許可するのは title / body と識別用の列のみ
      model_attributes: { "Post" => %w[id title body created_at updated_at] },
      visible_params: %w[title body],
      excluded_prefixes: %w[/__flow /visualizer /css /favicon.ico],
      max_events: 5000,
      max_per_request: 500,
      max_string: 256
    )
  end

  class << self
    attr_reader :collector

    # Sinatra アプリへ導入する（ミドルウェア・テンプレート境界・ヘルパー・SQL 購読）
    def install(app, root:, config: default_config(root: root))
      @collector = Collector.new(config: config)
      app.use Middleware, @collector
      # 可視化の静的ファイルを更新したら確実に反映されるよう、毎回再検証させる（変更なしなら 304）
      app.set :static_cache_control, [:no_cache]
      app.prepend SinatraHooks
      app.helpers Helpers
      subscribe_sql
      @collector
    end

    # モデルの after_commit / after_rollback から呼ぶ明示的な観測
    def record_db_change(record, action:, committed:)
      c = @collector
      return unless c&.enabled?

      c.safely { c.record_db_change(record, action: action, committed: committed) }
    end

    def template_identity(engine, data, settings)
      if data.is_a?(Symbol)
        path = File.expand_path("#{data}.#{engine}", settings.views.to_s)
        [data.to_s, @collector.registry.id_for_path(path)]
      else
        ["(inline)", nil]
      end
    end

    private

    def subscribe_sql
      return if @sql_subscribed

      @sql_subscribed = true
      ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
        c = @collector
        next unless c&.enabled? && c.current

        event = ActiveSupport::Notifications::Event.new(*args)
        c.safely { c.record_sql(event.payload, event.duration) }
      end
    end
  end
end
