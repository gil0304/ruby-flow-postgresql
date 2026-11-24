# frozen_string_literal: true

# 計測あり/なしの処理時間比較（専用テストDB上で実行。Rack を直接呼ぶので HTTP 通信時間は含まない）
#   DATABASE_URL=postgres://127.0.0.1/ruby_flow_test bundle exec ruby script/benchmark.rb [回数]
require_relative "../lib/ruby_flow/db_guard"
expected = RubyFlow::DbGuard.expected_database(require_test: true)
ENV["RACK_ENV"] = "development"
Dir.chdir(File.expand_path("..", __dir__)) { require_relative "../app" }
RubyFlow::DbGuard.verify_connection!(ActiveRecord::Base.connection, expected)
ActiveRecord::Base.logger = nil
Sinatra::Application.set :logging, false
Sinatra::Application.set :reloader, false

N = (ARGV[0] || 200).to_i
app = Sinatra::Application
env = ->(method, path, params = {}) {
  Rack::MockRequest.env_for("http://127.0.0.1:9292#{path}", method: method, params: params, "REMOTE_ADDR" => "127.0.0.1")
}

Post.delete_all
20.times { |i| Post.create!(title: "ベンチ#{i}", body: "本文#{i}" * 5) }
show_id = Post.first.id

scenarios = {
  "GET / (20件の一覧)" => -> { app.call(env.("GET", "/")) },
  "GET /posts/:id" => -> { app.call(env.("GET", "/posts/#{show_id}")) },
  "POST /posts (作成→303)" => -> { app.call(env.("POST", "/posts", "title" => "b", "body" => "x")) },
  "POST /posts (検証失敗→422)" => -> { app.call(env.("POST", "/posts", "title" => "", "body" => "x")) }
}

def measure(n)
  times = []
  n.times do
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    times << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000.0
  end
  times.sort!
  { median: times[times.size / 2], p95: times[(times.size * 0.95).floor - 1], mean: times.sum / times.size }
end

puts "Ruby #{RUBY_VERSION} / #{ActiveRecord::Base.connection.adapter_name} / N=#{N}（各シナリオ、ウォームアップ 20 回後）"
puts format("%-28s %12s %12s %10s %12s %12s", "シナリオ", "OFF中央値ms", "ON中央値ms", "倍率", "OFF p95", "ON p95")
scenarios.each do |name, run|
  results = {}
  [false, true].each do |enabled|
    RubyFlow.collector.enabled = enabled
    20.times { run.call }
    results[enabled] = measure(N) { run.call }
    RubyFlow.collector.store.clear
  end
  off = results[false]
  on = results[true]
  puts format("%-28s %12.2f %12.2f %9.2fx %12.2f %12.2f", name, off[:median], on[:median], on[:median] / off[:median], off[:p95], on[:p95])
end
RubyFlow.collector.enabled = true
Post.delete_all
