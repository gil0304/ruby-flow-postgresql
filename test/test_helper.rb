# frozen_string_literal: true

# テストは「DATABASE_URL で明示した専用テストDB（ruby_flow_*_test）」でのみ動かす。
# 原本の config/database.yml には test セクションがないため、そこへフォールバックしない。
require_relative "../lib/ruby_flow/db_guard"

begin
  EXPECTED_DB = RubyFlow::DbGuard.expected_database(require_test: true)
rescue RubyFlow::DbGuard::UnsafeDatabase => e
  warn "テストを中止しました: #{e.message}"
  warn "例: DATABASE_URL=postgres://127.0.0.1/ruby_flow_test bundle exec rake test"
  exit 1
end

# 原本の設定に test セクションがなく RACK_ENV=test では sinatra-activerecord の読込が失敗するため、
# 読込時は development として DATABASE_URL を適用し、読込後にテスト用の設定へ切り替える。
ENV["RACK_ENV"] = "development"
ENV["APP_ENV"] = "development"

require "minitest/autorun"
require "rack/test"
require "json"

Dir.chdir(File.expand_path("..", __dir__)) do
  require_relative "../app"
end

begin
  RubyFlow::DbGuard.verify_connection!(ActiveRecord::Base.connection, EXPECTED_DB)
rescue RubyFlow::DbGuard::UnsafeDatabase, StandardError => e
  warn "テストを中止しました（接続先の検証に失敗）: #{e.class}: #{e.message}"
  exit 1
end

ActiveRecord::Base.logger = nil
Sinatra::Application.set :environment, :test
Sinatra::Application.set :reloader, false
Sinatra::Application.set :raise_errors, false
Sinatra::Application.set :show_exceptions, false
Sinatra::Application.set :dump_errors, false
Sinatra::Application.set :logging, false

module FlowTestHelpers
  include Rack::Test::Methods

  def app
    Sinatra::Application
  end

  def collector
    RubyFlow.collector
  end

  # 専用テストDB上の posts だけを空にする（接続先は起動時に検証済み）
  def reset_db!
    raise "unsafe" unless ActiveRecord::Base.connection.current_database == EXPECTED_DB

    Post.delete_all
  end

  def local_env
    { "HTTP_HOST" => "127.0.0.1:9292", "REMOTE_ADDR" => "127.0.0.1" }
  end

  def all_events
    collector.store.since(0, limit: 5000)["events"]
  end

  def events_for(request_id)
    all_events.select { |e| e["request_id"] == request_id }
  end

  def last_request_id
    last_response.headers["X-Ruby-Flow-Request-Id"]
  end

  def types_for(request_id)
    events_for(request_id).map { |e| e["type"] }
  end
end
