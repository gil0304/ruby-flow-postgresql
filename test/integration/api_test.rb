# frozen_string_literal: true

require_relative "../test_helper"

class ApiTest < Minitest::Test
  include FlowTestHelpers

  BASE = "http://127.0.0.1:9292"

  def setup
    reset_db!
    collector.store.clear
  end

  def json
    JSON.parse(last_response.body)
  end

  def test_events_envelope_and_cursor
    get "#{BASE}/", {}, local_env
    get "#{BASE}/__flow/events?after=0", {}, local_env
    assert_equal 200, last_response.status
    assert_equal "no-store", last_response.headers["Cache-Control"]
    assert_nil last_response.headers["Access-Control-Allow-Origin"], "CORS を開放しない"
    body = json
    assert_equal 1, body["schema_version"]
    %w[events next_cursor oldest_cursor gap].each { |k| assert body.key?(k), k }
    cursor = body["next_cursor"]
    assert cursor.positive?
    get "#{BASE}/__flow/events?after=#{cursor}", {}, local_env
    assert_empty json["events"]
    e = body["events"].first
    %w[seq request_id type time_ms file line payload].each { |k| assert e.key?(k), k }
    assert_match(/\A[0-9a-f-]{36}\z/, e["request_id"])
  end

  def test_invalid_cursor
    get "#{BASE}/__flow/events?after=abc", {}, local_env
    assert_equal 400, last_response.status
  end

  def test_rejects_non_local_host_and_remote_addr
    get "#{BASE}/__flow/events", {}, { "HTTP_HOST" => "evil.example.com", "REMOTE_ADDR" => "127.0.0.1" }
    assert_equal 403, last_response.status
    get "#{BASE}/__flow/events", {}, { "HTTP_HOST" => "127.0.0.1:9292", "REMOTE_ADDR" => "192.168.1.20" }
    assert_equal 403, last_response.status
  end

  def test_rejects_write_methods
    post "#{BASE}/__flow/events", {}, local_env
    assert_equal 405, last_response.status
  end

  def test_source_allowlist
    get "#{BASE}/__flow/source", {}, local_env
    ids = json["files"].map { |f| f["id"] }
    assert_includes ids, "app.rb"
    assert_includes ids, "views/index.erb"
    refute(ids.any? { |i| i.start_with?("config") || i.start_with?("lib") })

    get "#{BASE}/__flow/source?file=app.rb", {}, local_env
    assert_equal 200, last_response.status
    assert_equal File.readlines(File.expand_path("../../app.rb", __dir__), encoding: "UTF-8").map(&:chomp), json["lines"]
    refute_includes last_response.body, File.expand_path("../..", __dir__), "実パスを出さない"

    ["config/database.yml", "../config/database.yml", "config.yml", "/etc/hosts", "Gemfile", "lib/ruby_flow.rb",
     "app.rb/../config/database.yml"].each do |bad|
      get "#{BASE}/__flow/source", { "file" => bad }, local_env
      assert_equal 404, last_response.status, bad
    end
  end

  def test_health_shows_adapter_without_connection_details
    get "#{BASE}/__flow/health", {}, local_env
    body = json
    assert_equal "PostgreSQL", body["database"]["adapter"]
    assert body["database"]["connected"]
    assert_equal "3.4.1", body["server_ruby_version"]
    refute_includes last_response.body, EXPECTED_DB, "DB 名などの接続情報を出さない"
    refute_includes last_response.body, "127.0.0.1"
  end
end
