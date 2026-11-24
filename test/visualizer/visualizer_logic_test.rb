# frozen_string_literal: true

# 可視化（p5.rb 側）の純粋ロジックを CRuby でテストする。
# 入力は test/fixtures の「テスト専用」データ（実測ではない）。ブラウザでの実測表示は別途実ブラウザで検証する。
require "minitest/autorun"
require "json"
VIZ = File.expand_path("../../public/visualizer/ruby", __dir__)
require File.join(VIZ, "flow_model")
require File.join(VIZ, "flow_panels")
require File.join(VIZ, "flow_app")

class FakeDom
  attr_reader :html, :text, :attrs, :scrolls

  def initialize
    @html = {}
    @text = {}
    @attrs = {}
    @scrolls = []
  end

  def set_html(id, v) = @html[id] = v
  def set_text(id, v) = @text[id] = v
  def set_attr(id, name, v) = @attrs["#{id}@#{name}"] = v
  def scroll_into_view(id, sel = nil) = @scrolls << [id, sel]
end

module FixtureData
  PATH = File.expand_path("../fixtures/events_post_redirect_get.json", __dir__)

  def fixture_text
    File.read(PATH, encoding: "UTF-8")
  end

  def fixture
    JSON.parse(fixture_text)
  end
end

class EventLogTest < Minitest::Test
  include FixtureData

  def test_groups_by_request_and_links_redirect
    log = RubyFlowViz::EventLog.new
    r = log.ingest(fixture)
    assert_equal 16, r[:new_events]
    assert_equal 2, log.requests.size
    post, get = log.requests
    assert_equal "POST /posts", post.label
    assert_equal 302, post.status
    assert_equal post.id, get.related_request_id
    assert_equal [get], log.children_of(post.id)
    assert_equal 16, log.cursor
  end

  def test_duplicates_ignored_and_gap_and_restart_detected
    log = RubyFlowViz::EventLog.new
    log.ingest(fixture)
    assert_equal 0, log.ingest(fixture)[:new_events], "同じ seq は二重に取り込まない"
    r = log.ingest({ "schema_version" => 1, "server_id" => "fixture-server", "events" => [], "gap" => true, "next_cursor" => 16 })
    assert r[:gap]
    assert_equal 1, log.gap_count
    r = log.ingest({ "schema_version" => 1, "server_id" => "restarted", "events" => [], "gap" => false, "next_cursor" => 0 })
    assert r[:reset], "server_id が変わったら再起動として状態を捨てる"
    assert log.empty?
  end

  def test_rejects_unknown_schema
    assert_raises(RubyFlowViz::ProtocolError) { RubyFlowViz::EventLog.new.ingest({ "schema_version" => 2, "events" => [] }) }
    assert_raises(RubyFlowViz::ProtocolError) { RubyFlowViz::EventLog.new.ingest({ "schema_version" => 1, "events" => [{ "seq" => "x" }] }) }
  end
end

class StepBuilderTest < Minitest::Test
  include FixtureData

  def steps_for(index, **opts)
    log = RubyFlowViz::EventLog.new
    log.ingest(fixture)
    RubyFlowViz::StepBuilder.new(**opts).build(log.requests[index])
  end

  def test_post_flow_nodes
    steps = steps_for(0)
    assert_equal [:browser, :app], [steps[0].from, steps[0].to]
    call_models = steps.find { |s| s.event.type == "ruby.call" && s.event.file == "models.rb" }
    assert_equal [:app, :models], [call_models.from, call_models.to]
    ret = steps.find { |s| s.event.type == "ruby.return" }
    assert_equal [:models, :app], [ret.from, ret.to]
    insert = steps.find { |s| s.event.type == "sql.query" }
    assert_equal :roundtrip, insert.kind
    assert_equal :db, insert.node
    assert_includes insert.label, "INSERT posts"
    assert_includes insert.label, "0.40ms"
    snap = steps.find { |s| s.event.type == "db.snapshot" }
    assert_equal [:db, :app], [snap.from, snap.to]
    redirect = steps.find { |s| s.event.type == "response.redirect" }
    assert_equal :browser, redirect.to
  end

  def test_every_step_is_backed_by_a_real_event
    steps = steps_for(0)
    assert(steps.all? { |s| s.event.is_a?(RubyFlowViz::Event) })
    assert_equal steps.map { |s| s.event.seq }.sort, steps.map { |s| s.event.seq }
  end

  def test_internal_sql_hidden_by_default
    refute(steps_for(0).any? { |s| s.event.internal_sql? })
    assert(steps_for(0, include_internal_sql: true).any? { |s| s.event.internal_sql? })
  end

  def test_get_flow_through_erb_to_browser
    steps = steps_for(1)
    assert_equal [:app, :erb], [steps[1].from, steps[1].to]
    assert_equal [:erb, :html], steps.find { |s| s.event.type == "erb.end" }.then { |s| [s.from, s.to] }
    assert_equal [:html, :browser], steps.find { |s| s.event.type == "response.html" }.then { |s| [s.from, s.to] }
  end
end

class PlayerTest < Minitest::Test
  def test_play_pause_step_speed_reset
    p = RubyFlowViz::Player.new
    p.load(4)
    p.play
    assert p.playing?
    p.update(10_000) # 1 ステップ分の表示＋小休止を終えて次へ
    assert_equal 1, p.index
    assert_equal 0.0, p.progress
    p.pause
    refute p.playing?
    p.step_forward
    assert_equal 1, p.index
    assert_equal 1.0, p.progress
    p.step_forward
    assert_equal 2, p.index
    p.step_back
    assert_equal 1, p.index
    p.speed = 2.0
    assert_equal 2.0, p.speed
    p.speed = 7
    assert_equal 1.0, p.speed, "0.5/1/2 以外は 1 に戻す"
    p.faster
    p.faster
    assert_equal 2.0, p.speed
    p.reset
    assert_equal [0, 0.0], [p.index, p.progress]
  end

  def test_speed_changes_duration
    slow = RubyFlowViz::Player.new
    fast = RubyFlowViz::Player.new
    [slow, fast].each { |pl| pl.load(2) && pl.play }
    slow.speed = 0.5
    fast.speed = 2.0
    slow.update(500)
    fast.update(500)
    assert_operator fast.progress, :>, slow.progress
  end

  def test_finishes_at_end
    p = RubyFlowViz::Player.new
    p.load(1)
    p.play
    3.times { p.update(5000) }
    assert p.finished?
    refute p.playing?
  end

  def test_empty_is_safe
    p = RubyFlowViz::Player.new
    p.load(0)
    p.play
    p.step_forward
    p.step_back
    assert_nil p.update(100)
  end
end

class LayoutTest < Minitest::Test
  def test_points_and_hits
    l = RubyFlowViz::Layout.new(1000, 600)
    x, y = l.point(:browser, :app, 0.0)
    assert_equal l.center(:browser), [x, y]
    assert_equal l.center(:app), l.point(:browser, :app, 1.0).map { |v| v.round(6) }
    cx, cy = l.center(:db)
    assert_equal :db, l.hit(cx, cy)
    assert_nil l.hit(-5, -5)
    tx, ty, tw, = l.timeline_rect
    assert_equal 0, l.timeline_index_at(tx + 1, ty + 5, 10)
    assert_equal 9, l.timeline_index_at(tx + tw - 1, ty + 5, 10)
  end
end

class DataFlowTest < Minitest::Test
  include FixtureData

  def test_variable_change_and_field_trail
    log = RubyFlowViz::EventLog.new
    log.ingest(fixture)
    trace = log.requests[0]
    steps = RubyFlowViz::StepBuilder.new.build(trace)
    idx = steps.index { |s| s.event.seq == 4 }
    title = RubyFlowViz::DataFlow.variables(steps, idx).find { |v| v[:name] == "title" }
    assert_equal " Hi ", title[:value]
    assert_equal "NilClass", title[:prev_type], "nil → String の変化を記録"
    trail = RubyFlowViz::DataFlow.field_trail(trace, "title")
    values = trail.map { |s| s[:value] }
    assert_equal [" Hi ", " Hi ", "Hi", "Hi"], values
    assert_match(/PostgreSQL/, trail.last[:where])
  end
end

class PanelsAndAppTest < Minitest::Test
  include FixtureData

  def app
    @app ||= RubyFlowViz::App.new(dom: FakeDom.new)
  end

  def test_panels_escape_everything
    log = RubyFlowViz::EventLog.new
    log.ingest(fixture)
    html = RubyFlowViz::Panels.events(log.requests[1], 14)
    refute_includes html, "<b>Hi</b>"
    assert_includes html, "&lt;b&gt;Hi&lt;/b&gt;"
    code = RubyFlowViz::Panels.code("x.rb", ["<script>alert(1)</script>"], 1, [1], nil)
    refute_includes code, "<script>"
    reqs = RubyFlowViz::Panels.requests(log, nil)
    refute_includes reqs, "<b>"
  end

  def test_app_ingest_live_select_and_commands
    dom = FakeDom.new
    a = RubyFlowViz::App.new(dom: dom)
    a.ingest(fixture_text)
    assert_equal :ok, a.connection
    assert_equal "22222222-2222-4222-8222-222222222222", a.selected_id, "ライブ追従では最新リクエストを選ぶ"
    assert a.player.playing?
    a.command("select_request", "11111111-1111-4111-8111-111111111111")
    refute a.live?
    a.command("step_forward")
    a.command("step_forward")
    assert_equal 1, a.player.index
    a.command("speed", "0.5")
    assert_equal 0.5, a.player.speed
    a.command("tab", "db")
    a.tick(16)
    assert_includes dom.html["panel-db"], "INSERT"
    a.command("tab", "evil")
    assert_equal "db", a.tab
    assert a.command("key", "ArrowRight")
    refute a.command("key", "x")
    a.command("play")
    a.command("seek_event", "9")
    assert_equal 9, a.current_step.event.seq
    refute a.player.playing?, "イベントを選んだらそこで止まる"
  end

  def test_connection_error_and_bad_json_are_reported
    a = app
    a.connection_error("HTTP 500")
    assert_equal :error, a.connection
    assert_includes a.status_text, "切断"
    assert_nil a.ingest("{not json")
    assert_includes a.last_error, "解釈できません"
  end

  def test_empty_state
    dom = FakeDom.new
    a = RubyFlowViz::App.new(dom: dom)
    a.ingest(JSON.generate({ "schema_version" => 1, "events" => [], "next_cursor" => 0, "gap" => false }))
    a.tick(16)
    assert_includes dom.html["request-list"], "まだリクエストがありません"
    assert_nil a.current_step
  end
end
