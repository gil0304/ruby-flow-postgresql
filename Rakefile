require 'sinatra/activerecord'
require 'sinatra/activerecord/rake'
require './models.rb'

# ---- Ruby Flow: 専用DB用タスクとテスト（以下を原本に追記） ----
require 'rake/testtask'
require_relative 'lib/ruby_flow/db_guard'

Rake::TestTask.new(:test) do |t|
  t.libs << 'test'
  t.test_files = FileList['test/**/*_test.rb']
  t.warning = false
end

# sinatra-contrib が namespace を上書きするため、"flow:xxx" という名前で直接定義する
desc '接続先が専用DB（DATABASE_URL で明示した ruby_flow_*）であることを確認する'
task 'flow:verify_db' do
  expected = RubyFlow::DbGuard.expected_database
  name = RubyFlow::DbGuard.verify_connection!(ActiveRecord::Base.connection, expected)
  puts "OK: 専用DB #{name} (adapter=#{ActiveRecord::Base.connection.adapter_name})"
end

desc '専用DBであることを確認してからマイグレーションする'
task 'flow:migrate' => 'flow:verify_db' do
  Rake::Task['db:migrate'].invoke
end
