# frozen_string_literal: true

# Ruby Flow 可視化：p5.rb による描画（ブラウザの ruby.wasm 上で実行）
# createCanvas / fill / rect / text などは p5.rb が p5.js へ橋渡しする。
module RubyFlowViz
  class Sketch
    COLORS = {
      browser: [47, 111, 221], ruby: [204, 52, 45], db: [36, 132, 84], erb: [196, 124, 0], html: [91, 107, 127]
    }.freeze
    TONES = {
      error: [196, 30, 30], commit: [36, 132, 84], internal: [150, 150, 150], transaction: [110, 90, 170]
    }.freeze

    def initialize(app, host_id: "canvas-host")
      @app = app
      @host_id = host_id
      @t = 0.0
    end

    def host_size
      host = JS.global[:document].getElementById(@host_id)
      w = host[:clientWidth].to_i
      h = host[:clientHeight].to_i
      [[w, 480].max, [h, 360].max]
    end

    def setup
      w, h = host_size
      canvas = createCanvas(w, h)
      canvas.parent(@host_id)
      frameRate(30)
      textFont("system-ui, -apple-system, 'Hiragino Sans', sans-serif")
      @app.resize(w, h)
    end

    def window_resized
      w, h = host_size
      # 第3引数 true = その場で再描画しない（Ruby→JS→Ruby の入れ子呼び出しを避ける。次の draw で描かれる）
      resizeCanvas(w, h, true)
      @app.resize(w, h)
    end

    def mouse_pressed
      x = mouseX
      y = mouseY
      return if x.negative? || y.negative? || x > width || y > height

      @app.click(x, y)
    end

    def draw
      dt = deltaTime.to_f
      dt = 33.0 if dt <= 0 || dt > 500
      @t += dt
      @app.tick(dt)

      layout = @app.layout
      background(251, 251, 250)
      step = @app.current_step
      draw_edges(layout, step)
      draw_nodes(layout, step)
      if step
        draw_motion(layout, step)
      else
        draw_empty(layout)
      end
      draw_timeline(layout)
      draw_legend(layout)
    end

    private

    def kind_color(node)
      COLORS[NODES[node][:kind]]
    end

    def step_color(step, node)
      TONES[step.tone] || kind_color(node)
    end

    def ease(t)
      t = t.clamp(0.0, 1.0)
      t < 0.5 ? 2 * t * t : 1 - ((-2 * t + 2)**2) / 2
    end

    def draw_edges(layout, step)
      noFill
      Layout::EDGES.each do |a, b|
        active = step&.transfer? && ((step.from == a && step.to == b) || (step.from == b && step.to == a) ||
                 (step.kind == :roundtrip && [a, b].include?(:db) && [a, b].include?(step.from)))
        if active
          c = step_color(step, step.kind == :roundtrip ? :db : step.to)
          stroke(c[0], c[1], c[2])
          strokeWeight(3)
        else
          stroke(214, 218, 223)
          strokeWeight(1.5)
        end
        curve_between(layout, a, b)
      end
    end

    def curve_between(layout, a, b)
      x1, y1 = layout.center(a)
      x2, y2 = layout.center(b)
      cx, cy = layout.control_point(a, b)
      # 2 次ベジェ → 3 次ベジェ
      bezier(x1, y1, x1 + (cx - x1) * 2 / 3.0, y1 + (cy - y1) * 2 / 3.0,
             x2 + (cx - x2) * 2 / 3.0, y2 + (cy - y2) * 2 / 3.0, x2, y2)
    end

    def active_node(step)
      return nil unless step

      if step.transfer?
        pr = @app.player.progress
        if step.kind == :roundtrip
          pr >= 1.0 || (pr >= 0.25 && pr < 0.75) ? :db : step.from
        else
          pr >= 0.5 ? step.to : step.from
        end
      else
        step.node
      end
    end

    def draw_nodes(layout, step)
      active = active_node(step)
      NODES.each_key do |node|
        x, y, w, h = layout.rect(node)
        c = kind_color(node)
        is_active = node == active
        if is_active
          pulse = 4 + 3 * Math.sin(@t / 160.0)
          noStroke
          tone = step ? step_color(step, node) : c
          fill(tone[0], tone[1], tone[2], 38)
          rect(x - pulse, y - pulse, w + pulse * 2, h + pulse * 2, 12)
        end
        stroke(c[0], c[1], c[2])
        strokeWeight(is_active ? 3.2 : 1.4)
        fill(255)
        draw_shape(NODES[node][:kind], x, y, w, h, c)
        noStroke
        fill(31, 35, 40)
        textAlign(CENTER, CENTER)
        textSize(14)
        textStyle(is_active ? BOLD : NORMAL)
        text(NODES[node][:label], x + w / 2, y + h / 2 - 7)
        textStyle(NORMAL)
        textSize(11)
        fill(89, 99, 110)
        text(sublabel(node), x + w / 2, y + h / 2 + 12)
      end
    end

    def draw_shape(kind, x, y, w, h, c)
      case kind
      when :browser
        rect(x, y, w, h, 6)
        line(x, y + 13, x + w, y + 13)
        noStroke
        fill(c[0], c[1], c[2])
        3.times { |i| circle(x + 9 + i * 9, y + 7, 5) }
      when :ruby
        rect(x, y, w, h, 10)
        noStroke
        fill(c[0], c[1], c[2])
        quad(x + 12, y + 6, x + 18, y + 12, x + 12, y + 18, x + 6, y + 12) # ルビー（宝石）の印
      when :db
        e = 14
        rect(x, y + e / 2, w, h - e, 0)
        ellipse(x + w / 2, y + h - e / 2, w, e)
        noStroke
        rect(x + 1.5, y + e / 2, w - 3, h - e - 1)
        stroke(c[0], c[1], c[2])
        ellipse(x + w / 2, y + e / 2, w, e)
        line(x, y + e / 2, x, y + h - e / 2)
        line(x + w, y + e / 2, x + w, y + h - e / 2)
      when :erb
        f = 14
        rect(x, y, w, h, 2)
        fill(c[0], c[1], c[2], 60) # 右上の折り返し（文書＝テンプレートの印）
        triangle(x + w - f, y, x + w, y + f, x + w - f, y + f)
      else
        rect(x, y, w, h, 2)
        noStroke
        fill(c[0], c[1], c[2])
        textSize(10)
        textAlign(LEFT, TOP)
        text("</>", x + 6, y + 4)
      end
    end

    def sublabel(node)
      trace = @app.selected
      return "" unless trace

      case node
      when :browser then trace.label[0, 26]
      when :app, :models
        file = NODES[node][:file]
        last = last_event_for(trace) { |e| e.file == file && e.type.start_with?("ruby.") }
        last ? "#{last.payload['method']}"[0, 24] : "（このステップまで未到達）"
      when :db then "SQL #{trace.sql_count} 件"
      when :erb
        last = last_event_for(trace) { |e| e.type == "erb.start" }
        last ? "views/#{last.payload['template']}.erb" : "（未到達）"
      when :html
        last = last_event_for(trace) { |e| e.type == "erb.end" }
        last ? "#{last.payload['html_bytes']} バイト" : ""
      end
    end

    def last_event_for(trace)
      upto = @app.current_step&.event&.seq || 0
      trace.events.reverse_each { |e| return e if e.seq <= upto && yield(e) }
      nil
    end

    def draw_motion(layout, step)
      progress = @app.player.progress
      t = @app.reduced_motion? ? 1.0 : ease(progress)
      c = step_color(step, step.kind == :roundtrip ? :db : (step.to || step.node || :app))
      if step.transfer?
        if step.kind == :roundtrip
          # 往路で DB へ、復路で戻る（SQL 完了通知の実測時間をラベルに表示。開始時刻は捏造しない）
          # 停止中・選択時（progress=1）は問い合わせ先の PostgreSQL 上に表示する
          x, y = if @app.reduced_motion? || progress >= 1.0 then layout.center(:db)
                 elsif t < 0.5 then layout.point(step.from, :db, t * 2)
                 else layout.point(:db, step.from, (t - 0.5) * 2)
                 end
        else
          x, y = layout.point(step.from, step.to, t)
        end
        noStroke
        fill(c[0], c[1], c[2], 60)
        circle(x, y, 26)
        fill(c[0], c[1], c[2])
        circle(x, y, 13)
        tag(step.label, x, y - 24, c)
        tag(step.detail.to_s, x, y + 26, [120, 120, 120], small: true) if step.detail && !step.detail.to_s.empty?
      else
        node = step.node || :app
        cx, cy = layout.center(node)
        noFill
        stroke(c[0], c[1], c[2], 200 * (1 - (progress % 1.0)) + 40)
        strokeWeight(2)
        r = layout.node_w * (0.7 + 0.5 * (@app.reduced_motion? ? 0.5 : progress))
        ellipse(cx, cy, r * 1.25, r * 0.75)
        tag(step.label, cx, cy + layout.node_h / 2 + 22, c)
        tag(step.detail.to_s, cx, cy + layout.node_h / 2 + 46, [120, 120, 120], small: true) if step.detail && !step.detail.to_s.empty?
      end
    end

    def tag(label, x, y, c, small: false)
      s = label.to_s
      s = "#{s[0, 54]}…" if s.length > 55
      textSize(small ? 11 : 12.5)
      tw = textWidth(s) + 16
      th = small ? 18 : 22
      x = x.clamp(tw / 2 + 4, width - tw / 2 - 4)
      stroke(c[0], c[1], c[2])
      strokeWeight(1)
      fill(255, 255, 255, 235)
      rect(x - tw / 2, y - th / 2, tw, th, 4)
      noStroke
      fill(small ? 90 : 31, small ? 99 : 35, small ? 110 : 40)
      textAlign(CENTER, CENTER)
      text(s, x, y)
    end

    def draw_empty(layout)
      lines = if @app.connection == :error
                ["サーバーに接続できません（切断）。", "再接続を試みています…"]
              elsif @app.log.empty?
                ["まだイベントがありません。", "対象アプリ（別タブ）で投稿の作成・編集・削除をしてください。"]
              else
                ["左の一覧からリクエストを選んでください。"]
              end
      cy = layout.graph_height / 2
      noStroke
      fill(251, 251, 250, 235)
      rect(16, cy - 30, layout.width - 32, 64, 6)
      fill(89, 99, 110)
      textAlign(CENTER, CENTER)
      textSize(15)
      lines.each_with_index do |msg, i|
        text(msg, layout.width / 2, cy - 10 * (lines.size - 1) + i * 22)
      end
    end

    def draw_timeline(layout)
      tx, ty, tw, th = layout.timeline_rect
      steps = @app.steps
      noStroke
      fill(240, 241, 243)
      rect(tx, ty, tw, th, 4)
      n = steps.size
      if n.positive?
        bw = tw / n
        steps.each_with_index do |s, i|
          node = s.transfer? ? (s.kind == :roundtrip ? :db : s.to) : (s.node || :app)
          c = step_color(s, node)
          alpha = i <= @app.player.index ? 230 : 70
          fill(c[0], c[1], c[2], alpha)
          h = s.kind == :line ? th * 0.45 : th
          rect(tx + i * bw + 0.5, ty + (th - h), [bw - 1, 1].max, h)
          if s.tone == :error
            fill(196, 30, 30)
            triangle(tx + i * bw + bw / 2, ty - 7, tx + i * bw + bw / 2 - 5, ty - 1, tx + i * bw + bw / 2 + 5, ty - 1)
          end
        end
        mx = tx + (@app.player.index + @app.player.progress.clamp(0.0, 1.0)) * bw
        stroke(31, 35, 40)
        strokeWeight(2)
        line(mx, ty - 4, mx, ty + th + 4)
      end
      noStroke
      fill(89, 99, 110)
      textSize(11)
      textAlign(LEFT, TOP)
      label = n.positive? ? "タイムライン（クリックで移動）: #{@app.player.index + 1}/#{n} ステップ  速度 ×#{@app.player.speed}" : "タイムライン"
      text(label, tx, ty + th + 5)
    end

    def draw_legend(layout)
      noStroke
      textSize(11)
      textAlign(LEFT, TOP)
      fill(89, 99, 110)
      text("● 点の移動は説明用の補間。到着点・ラベル・行番号・時間は実測イベント", 12, 8)
      x = layout.width - 12
      textAlign(RIGHT, TOP)
      text("p5.rb + ruby.wasm #{@app.wasm_ruby_version}", x, 8)
    end
  end
end
