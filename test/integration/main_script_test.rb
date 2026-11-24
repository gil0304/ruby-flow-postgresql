# frozen_string_literal: true

# 実際の起動方法（bundle exec ruby app.rb ...）と同じく app.rb をメインスクリプト（相対パス）として
# 読み込んだ場合でも、ルート（app.rb）の実行が計測されることを確認する回帰テスト。
# 別プロセスで実行し、専用テストDBのみを使う。
require "minitest/autorun"
require "open3"
require_relative "../../lib/ruby_flow/db_guard"

class MainScriptTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_routes_are_traced_when_app_rb_is_main_script
    RubyFlow::DbGuard.expected_database(require_test: true)
    script = <<~'RUBY'
      load "app.rb" # 相対パスで読み込む（source_location が "app.rb" になる。ruby app.rb と同じ）
      Sinatra::Application.set :run, false
      require "rack/mock"
      ActiveRecord::Base.logger = nil
      Sinatra::Application.set :logging, false
      env = Rack::MockRequest.env_for("http://127.0.0.1:9292/posts/new", "REMOTE_ADDR" => "127.0.0.1")
      Sinatra::Application.call(env)
      evs = RubyFlow.collector.store.since(0)["events"]
      call = evs.find { |e| e["type"] == "ruby.call" && e["payload"]["method"] == "GET /posts/new" }
      puts(call ? "TRACED #{call['file']}:#{call['line']}" : "NOT_TRACED")
      $stdout.flush
      exit! 0 # Sinatra の at_exit（サーバー自動起動）を走らせない
    RUBY
    out, err, status = Open3.capture3({ "RACK_ENV" => "development" }, "bundle", "exec", "ruby", "-e", script, chdir: ROOT)
    assert status.success?, err[-2000..]
    assert_match(/TRACED app\.rb:\d+/, out)
  end
end
