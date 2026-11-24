# frozen_string_literal: true

# 実際の Sinatra / ActiveRecord / PostgreSQL（専用テストDB）/ ERB を通したテスト
require_relative "../test_helper"

class CrudFlowTest < Minitest::Test
  include FlowTestHelpers

  BASE = "http://127.0.0.1:9292"

  def setup
    reset_db!
    collector.store.clear
    collector.enabled = true
  end

  def create_post(title: "最初の投稿", body: "本文です", extra: {})
    post "#{BASE}/posts", { "title" => title, "body" => body }.merge(extra), local_env
    last_response
  end

  # ---- CRUD が実DBとHTMLに反映される ----
  def test_create_read_update_delete_reflect_in_db_and_html
    create_post(title: "  タイトルA  ", body: "本文A")
    assert_equal 302, last_response.status
    post = Post.last
    assert_equal "タイトルA", post.title, "models.rb の normalize_fields で strip されて保存"

    get "#{BASE}/posts/#{post.id}", {}, local_env
    assert_equal 200, last_response.status
    assert_includes last_response.body, "タイトルA"

    post "#{BASE}/posts/#{post.id}", { "title" => "更新後", "body" => "本文B" }, local_env
    assert_equal 302, last_response.status
    assert_equal "更新後", post.reload.title

    get "#{BASE}/", {}, local_env
    assert_includes last_response.body, "更新後"

    post "#{BASE}/posts/#{post.id}/delete", {}, local_env
    assert_equal 302, last_response.status
    assert_nil Post.find_by(id: post.id)
    get "#{BASE}/", {}, local_env
    assert_includes last_response.body, "まだ投稿がありません"
  end

  def test_validation_failure_renders_errors_and_does_not_insert
    create_post(title: "   ", body: "x")
    assert_equal 422, last_response.status
    assert_includes last_response.body, "role=\"alert\""
    assert_equal 0, Post.count
    rid = last_request_id
    types = types_for(rid)
    assert_includes types, "erb.start"
    refute(events_for(rid).any? { |e| e["type"] == "sql.query" && e["payload"]["operation"] == "INSERT" })
    refute(events_for(rid).any? { |e| e["type"] == "db.snapshot" })
  end

  def test_html_output_is_escaped
    create_post(title: "<script>alert(1)</script>", body: "<b>x</b>")
    follow_redirect!
    refute_includes last_response.body, "<script>alert(1)</script>"
    assert_includes last_response.body, "&lt;script&gt;alert(1)&lt;&#x2F;script&gt;"
    expr = events_for(last_request_id).find { |e| e["type"] == "erb.expression" && e["payload"]["label"] == "title" }
    assert expr["payload"]["escaped"]
    assert_equal "&lt;script&gt;alert(1)&lt;&#x2F;script&gt;", expr["payload"]["html"]
  end

  def test_missing_record_is_404_with_raise_event
    get "#{BASE}/posts/999999", {}, local_env
    assert_equal 404, last_response.status
    raise_ev = events_for(last_request_id).find { |e| e["type"] == "ruby.raise" }
    assert_equal "ActiveRecord::RecordNotFound", raise_ev["payload"]["class"]
    assert_equal "app.rb", raise_ev["file"]
    assert_kind_of Integer, raise_ev["line"]
    assert_equal 404, events_for(last_request_id).last["payload"]["status"]
  end

  # ---- POST と リダイレクト後の GET は別 request_id。Cookie による実際の相関 ----
  def test_post_and_redirected_get_are_separate_and_linked
    create_post
    post_id = last_request_id
    follow_redirect!
    get_id = last_request_id
    refute_equal post_id, get_id
    start = events_for(get_id).first
    assert_equal "request.start", start["type"]
    assert_equal post_id, start["related_request_id"]
    assert_equal "redirect_cookie", start["payload"]["correlation"]

    # SQL / ERB / Ruby イベントがそれぞれ正しいリクエストに属する
    post_types = types_for(post_id)
    get_types = types_for(get_id)
    assert_includes post_types, "response.redirect"
    refute_includes post_types, "erb.start"
    assert(events_for(post_id).any? { |e| e["type"] == "sql.query" && e["payload"]["operation"] == "INSERT" })
    assert(events_for(get_id).any? { |e| e["type"] == "sql.query" && e["payload"]["operation"] == "SELECT" && e["payload"]["table"] == "posts" })
    assert_includes get_types, "erb.start"
    assert_includes get_types, "response.html"
  end

  def test_event_order_and_real_locations_for_create
    create_post(title: " Hello ", body: "World")
    ev = events_for(last_request_id)
    types = ev.map { |e| e["type"] }
    assert_equal "request.start", types.first
    assert_equal "request.end", types.last
    seqs = ev.map { |e| e["seq"] }
    assert_equal seqs.sort, seqs

    call = ev.find { |e| e["type"] == "ruby.call" && e["payload"]["method"] == "POST /posts" }
    assert_equal "app.rb", call["file"]
    src = File.readlines(File.expand_path("../../app.rb", __dir__), encoding: "UTF-8")
    assert_match(/post '\/posts' do/, src[call["line"] - 1], "ruby.call の行は実際の app.rb のルート定義行")

    norm = ev.find { |e| e["type"] == "ruby.call" && e["payload"]["method"] == "Post#normalize_fields" }
    assert_equal "models.rb", norm["file"]
    models = File.readlines(File.expand_path("../../models.rb", __dir__), encoding: "UTF-8")
    assert_match(/def normalize_fields/, models[norm["line"] - 1])

    insert = ev.find { |e| e["type"] == "sql.query" && e["payload"]["operation"] == "INSERT" }
    assert_equal "app.rb", insert["file"]
    assert_match(/@post\.save/, src[insert["line"] - 1], "SQL の発生元は @post.save の行")
    assert insert["payload"]["duration_ms"].is_a?(Numeric)

    # 実際の値の変化（strip の前後）が観測される
    vars = ev.select { |e| e["type"] == "ruby.line" && e["file"] == "app.rb" }.flat_map { |e| e["payload"]["vars"] }
    assert(vars.any? { |v| v["name"] == "title" && v["value"] == " Hello " && v["type"] == "String" })
    snap = ev.find { |e| e["type"] == "db.snapshot" }
    assert_equal "Hello", snap["payload"]["row"]["title"]
    assert snap["payload"]["committed"]
    assert_equal Post.last.id, snap["payload"]["row"]["id"]
  end

  # ---- 値が変われば記録内容も変わる（固定データでない）----
  def test_different_values_produce_different_events
    create_post(title: "りんご", body: "1")
    a = events_for(last_request_id).find { |e| e["type"] == "db.snapshot" }["payload"]["row"]
    create_post(title: "みかん", body: "2")
    b = events_for(last_request_id).find { |e| e["type"] == "db.snapshot" }["payload"]["row"]
    assert_equal %w[りんご みかん], [a["title"], b["title"]]
    refute_equal a["id"], b["id"]
  end

  def test_erb_expression_lines_are_real_template_lines
    create_post(title: "行番号", body: "テスト")
    follow_redirect!
    exprs = events_for(last_request_id).select { |e| e["type"] == "erb.expression" }
    refute_empty exprs
    exprs.each do |e|
      assert_equal "views/show.erb", e["file"]
      line = File.readlines(File.expand_path("../../views/show.erb", __dir__), encoding: "UTF-8")[e["line"] - 1]
      assert_includes line, "flow_h(:#{e['payload']['label']}", "ERB 式の行番号がテンプレートの実際の行と一致"
    end
    refute(events_for(last_request_id).any? { |e| e["type"] == "ruby.line" && e["file"].to_s.end_with?(".erb") },
           "ERB の生成コードの行は ruby.line として出さない")
  end

  # ---- 機密値を収集しない ----
  def test_sensitive_values_are_not_collected
    marker = "S3CRET-#{rand(1_000_000)}"
    create_post(title: "公開タイトル", body: "公開本文",
                extra: { "password" => marker, "nickname" => marker, "api_token" => marker })
    post "#{BASE}/posts", { "title" => "t2", "body" => "b" }, local_env.merge("HTTP_COOKIE" => "session=#{marker}")
    get "#{BASE}/", {}, local_env.merge("HTTP_AUTHORIZATION" => "Bearer #{marker}")
    dump = JSON.generate(all_events)
    refute_includes dump, marker, "パスワード・Cookie・認証情報・任意フィールドの値は記録しない"
    start = all_events.find { |e| e["type"] == "request.start" && e["payload"]["method"] == "POST" }
    assert_equal ["nickname"], start["payload"]["params"]["hidden_keys"], "許可外の項目はキー名のみ（機密キーは名前も出さない）"
  end

  def test_sql_bind_values_are_not_in_sql_events
    marker = "BIND-#{rand(1_000_000)}"
    create_post(title: marker, body: marker)
    sqls = all_events.select { |e| e["type"] == "sql.query" }
    refute_empty sqls
    refute_includes JSON.generate(sqls), marker
  end

  # ---- トランザクションの成功・ロールバック ----
  def test_transaction_commit_and_rollback_are_distinguished
    ctx = RubyFlow::RequestContext.new
    RubyFlow::RequestContext.with(ctx) do
      Post.transaction do
        Post.create!(title: "ロールバックされる", body: "x")
        raise ActiveRecord::Rollback
      end
    end
    collector.store.finish_request(ctx.request_id)
    ev = events_for(ctx.request_id)
    ops = ev.select { |e| e["type"] == "sql.query" }.map { |e| e["payload"]["operation"] }
    assert_includes ops, "BEGIN"
    assert_includes ops, "INSERT"
    assert_includes ops, "ROLLBACK"
    refute_includes ops, "COMMIT"
    snap = ev.find { |e| e["type"] == "db.snapshot" }
    assert_equal false, snap["payload"]["committed"], "ロールバックした変更を確定扱いしない"
    assert_equal 0, Post.where(title: "ロールバックされる").count
  end

  # ---- 同時リクエストでも混線しない ----
  def test_concurrent_requests_do_not_mix
    titles = %w[並行A 並行B 並行C 並行D]
    results = titles.map do |t|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          env = Rack::MockRequest.env_for("#{BASE}/posts", method: "POST", params: { "title" => t, "body" => t },
                                                              "REMOTE_ADDR" => "127.0.0.1")
          status, headers, _ = Sinatra::Application.call(env)
          [t, status, headers["X-Ruby-Flow-Request-Id"]]
        end
      end
    end.map(&:value)
    results.each do |title, status, rid|
      assert_equal 302, status
      ev = events_for(rid)
      snaps = ev.select { |e| e["type"] == "db.snapshot" }
      assert_equal [title], snaps.map { |s| s["payload"]["row"]["title"] }, "#{title} のリクエストに他リクエストの行が混ざらない"
      line_titles = ev.select { |e| e["type"] == "ruby.line" }.flat_map { |e| e["payload"]["vars"] }
                      .select { |v| v["name"] == "title" && v["value"] }.map { |v| v["value"] }.uniq
      assert_equal [title], line_titles
      assert_equal 1, ev.count { |e| e["type"] == "request.start" }
      assert_equal 1, ev.count { |e| e["type"] == "request.end" }
    end
  end

  # ---- GET/HEAD でブロックを共有するルートも含め、各ルートの呼び出しが記録される ----
  def test_every_route_call_is_traced
    create_post(title: "ルート確認")
    id = Post.last.id
    { "/" => "GET /", "/posts/new" => "GET /posts/new", "/posts/#{id}" => "GET /posts/:id",
      "/posts/#{id}/edit" => "GET /posts/:id/edit" }.each do |path, route|
      get "#{BASE}#{path}", {}, local_env
      calls = events_for(last_request_id).select { |e| e["type"] == "ruby.call" }.map { |e| e["payload"]["method"] }
      assert_includes calls, route, path
      lines = events_for(last_request_id).select { |e| e["type"] == "ruby.line" && e["file"] == "app.rb" }
      refute_empty lines, path
    end
  end

  # ---- 計測オフ ----
  def test_tracing_off_records_nothing_but_app_works
    collector.enabled = false
    create_post(title: "計測なし")
    assert_equal 302, last_response.status
    assert_equal 0, collector.store.size
    assert_nil last_response.headers["X-Ruby-Flow-Request-Id"]
  ensure
    collector.enabled = true
  end

  # ---- 件数上限 ----
  def test_per_request_limit_emits_drop
    original = collector.store
    small = RubyFlow::EventStore.new(max_events: 5000, max_per_request: 10)
    collector.instance_variable_set(:@store, small)
    5.times { |i| Post.create!(title: "上限#{i}", body: "x") }
    get "#{BASE}/", {}, local_env
    assert_equal 200, last_response.status
    ev = small.since(0)["events"]
    drop = ev.find { |e| e["type"] == "trace.drop" }
    assert drop, "上限超過時は trace.drop を記録"
    assert_equal "request.end", ev.reject { |e| e["type"] == "trace.drop" }.last["type"]
  ensure
    collector.instance_variable_set(:@store, original)
  end

  # ---- 静的ファイル・API は計測しない ----
  def test_static_and_api_are_not_traced
    get "#{BASE}/css/style.css", {}, local_env
    get "#{BASE}/visualizer/index.html", {}, local_env
    get "#{BASE}/__flow/health", {}, local_env
    assert_equal 0, collector.store.size
  end
end
