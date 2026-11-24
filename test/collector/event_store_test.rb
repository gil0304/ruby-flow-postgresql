# frozen_string_literal: true

# DB を使わない純粋ロジックのテスト（EventStore / Sanitizer / SqlClassifier / SourceRegistry）
require "minitest/autorun"
require_relative "../../lib/ruby_flow"

class EventStoreTest < Minitest::Test
  def store(**opts)
    RubyFlow::EventStore.new(**opts)
  end

  def test_seq_is_monotonic_and_cursor_works
    s = store
    3.times { s.append(request_id: "r1", type: "ruby.line", file: "app.rb", line: 1) }
    env = s.since(0)
    assert_equal [1, 2, 3], env["events"].map { |e| e["seq"] }
    assert_equal 3, env["next_cursor"]
    assert_equal 1, env["schema_version"]
    assert_equal false, env["gap"]
    assert_empty s.since(3)["events"]
    assert_equal [3], s.since(2)["events"].map { |e| e["seq"] }
  end

  def test_rejects_unknown_type
    assert_raises(ArgumentError) { store.append(request_id: "r", type: "made.up") }
  end

  def test_ring_buffer_evicts_and_reports_gap
    s = store(max_events: 5)
    10.times { |i| s.append(request_id: "r#{i}", type: "request.start") }
    assert_equal 5, s.size
    env = s.since(2)
    assert env["gap"], "古いイベントが捨てられたら gap=true"
    assert_equal 6, env["oldest_cursor"]
    refute s.since(5)["gap"]
  end

  def test_per_request_limit_and_drop_notice
    s = store(max_per_request: 3)
    s.append(request_id: "r", type: "request.start")
    5.times { s.append(request_id: "r", type: "ruby.line", line: 1) }
    s.append(request_id: "r", type: "request.end") # 骨格イベントは上限を超えても残す
    s.finish_request("r")
    types = s.since(0)["events"].map { |e| e["type"] }
    assert_equal 2, types.count("ruby.line")
    assert_includes types, "request.end"
    drop = s.since(0)["events"].find { |e| e["type"] == "trace.drop" }
    assert_equal 3, drop["payload"]["dropped"]
  end

  def test_thread_safety
    s = store(max_events: 10_000)
    threads = 8.times.map { |t| Thread.new { 200.times { s.append(request_id: "r#{t}", type: "ruby.line") } } }
    threads.each(&:join)
    seqs = s.since(0, limit: 5000)["events"].map { |e| e["seq"] }
    assert_equal 1600, s.size
    assert_equal seqs.sort, seqs
    assert_equal seqs.uniq.size, seqs.size
  end
end

class SanitizerTest < Minitest::Test
  def setup
    @s = RubyFlow::Sanitizer.new(max_string: 10, max_items: 3)
  end

  def test_removes_sensitive_keys_recursively
    v = @s.clean({ "title" => "a", "password" => "x", "nested" => { "api_key" => "k", "Cookie" => "c", "ok" => 1 } })
    assert_equal({ "title" => "a", "nested" => { "ok" => 1 } }, v)
  end

  def test_truncates_strings_and_collections
    assert_equal "abcdefghi…", @s.clean("abcdefghijklmn")
    assert_equal [1, 2, 3, "…残り 2 件"], @s.clean([1, 2, 3, 4, 5])
  end

  def test_unknown_objects_never_inspected
    obj = Object.new
    def obj.inspect = raise("inspect must not be called")
    def obj.to_s = raise("to_s must not be called")
    assert_equal({ "__type" => "Object" }, @s.clean(obj))
  end

  def test_type_names
    assert_equal "Array<Integer|String>", @s.type_name([1, "a"])
    assert_equal "NilClass", @s.type_name(nil)
  end
end

class SqlClassifierTest < Minitest::Test
  def c
    RubyFlow::SqlClassifier.new
  end

  def test_insert_with_binds_and_returning
    r = c.classify('INSERT INTO "posts" ("title", "body") VALUES ($1, $2) RETURNING "id"', name: "Post Create")
    assert_equal "INSERT", r["operation"]
    assert_equal "posts", r["table"]
    assert r["returning"]
    assert_equal 2, r["bind_params"]
    assert_equal "query", r["kind"]
  end

  def test_literals_and_comments_are_hidden
    r = c.classify("SELECT * FROM posts WHERE title = 'secret value' AND id = 42 /* app:demo */ -- note")
    refute_includes r["statement"], "secret value"
    refute_includes r["statement"], "42"
    refute_includes r["statement"], "app:demo"
    refute_includes r["statement"], "note"
    assert_equal "posts", r["table"]
  end

  def test_transaction_schema_cache
    assert_equal "transaction", c.classify("BEGIN", name: "TRANSACTION")["kind"]
    assert_equal "ROLLBACK", c.classify("ROLLBACK")["operation"]
    assert_equal "schema", c.classify("SELECT a.attname FROM pg_attribute a", name: "SCHEMA")["kind"]
    assert_equal "cache", c.classify('SELECT "posts".* FROM "posts"', cached: true)["kind"]
    assert_equal "UPDATE", c.classify('UPDATE "posts" SET "title" = $1 WHERE "posts"."id" = $2')["operation"]
    assert_equal "posts", c.classify('DELETE FROM "posts" WHERE "posts"."id" = $1')["table"]
  end

  def test_unclassifiable_is_other
    assert_equal "OTHER", c.classify("VACUUM")["operation"]
  end
end

class SourceRegistryTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def reg
    RubyFlow::SourceRegistry.new(root: ROOT, ruby_files: %w[app.rb models.rb], template_globs: %w[views/*.erb])
  end

  def test_only_allowlisted_files_are_readable
    r = reg
    assert r.read("app.rb")
    assert r.read("views/index.erb")
    assert_nil r.read("config/database.yml")
    assert_nil r.read("../config/database.yml")
    assert_nil r.read("/etc/passwd")
    assert_nil r.read("Gemfile")
  end

  def test_config_cannot_be_registered
    assert_raises(ArgumentError) { reg.add("config/database.yml", kind: "ruby") }
    assert_raises(ArgumentError) { reg.add("../x.rb", kind: "ruby") }
  end

  def test_ruby_only_for_tracepoint
    r = reg
    assert_equal "app.rb", r.ruby_id_for_path(File.join(ROOT, "app.rb"))
    assert_nil r.ruby_id_for_path(File.join(ROOT, "views/index.erb"))
    assert_nil r.ruby_id_for_path(File.join(ROOT, "lib/ruby_flow.rb"))
  end
end
