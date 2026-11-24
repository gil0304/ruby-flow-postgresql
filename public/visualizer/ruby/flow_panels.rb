# frozen_string_literal: true

# Ruby Flow 可視化：DOM パネルの HTML を組み立てる（純粋ロジック・すべてエスケープ）
module RubyFlowViz
  module Html
    ESC = { "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", '"' => "&quot;", "'" => "&#39;" }.freeze

    module_function

    def e(value)
      value.to_s.gsub(/[&<>"']/, ESC)
    end

    # 値を読みやすい 1 行文字列にする（JSON 互換値のみ扱う）
    def show(value, limit = 120)
      s = case value
          when nil then "nil"
          when String then value.inspect
          when Hash
            if value["__type"]
              attrs = value.reject { |k, _| %w[__type].include?(k) }
              "#<#{value['__type']} #{attrs.map { |k, v| "#{k}: #{short(v)}" }.join(', ')}>"
            else
              "{" + value.map { |k, v| "#{k}: #{short(v)}" }.join(", ") + "}"
            end
          when Array then "[" + value.map { |v| short(v) }.join(", ") + "]"
          else value.to_s
          end
      s.length > limit ? "#{s[0, limit - 1]}…" : s
    end

    def short(v)
      case v
      when Hash then v["__type"] ? "#<#{v['__type']} id: #{v['id'].inspect}>" : "{…}"
      when Array then "[#{v.size}件]"
      when String then v.length > 30 ? "#{v[0, 29]}…".inspect : v.inspect
      when nil then "nil"
      else v.to_s
      end
    end
  end

  module EventText
    module_function

    TYPE_LABELS = {
      "request.start" => "リクエスト開始", "request.end" => "リクエスト完了",
      "ruby.call" => "メソッド呼び出し", "ruby.line" => "行の実行", "ruby.return" => "メソッド終了",
      "ruby.raise" => "例外", "sql.query" => "SQL", "db.snapshot" => "DB 行の確定/取消",
      "erb.start" => "ERB 開始", "erb.expression" => "ERB 式", "erb.end" => "ERB 終了",
      "response.redirect" => "リダイレクト応答", "response.html" => "HTML 応答", "trace.drop" => "イベント欠落"
    }.freeze

    def type_label(type)
      TYPE_LABELS[type] || type
    end

    def summary(e)
      p = e.payload
      case e.type
      when "request.start" then "#{p['method']} #{p['path']}"
      when "request.end" then "#{p['status']} / #{p['duration_ms']}ms"
      when "ruby.call", "ruby.line" then p["method"].to_s
      when "ruby.return" then "#{p['method']} → #{p.dig('return', 'type')}"
      when "ruby.raise" then "#{p['class']} #{p['message']}"
      when "sql.query"
        "#{p['operation']} #{p['table']} #{p['duration_ms']}ms#{%w[schema cache].include?(p['kind']) ? '（内部）' : ''}"
      when "db.snapshot" then "#{p['committed'] ? '確定' : '取り消し'} #{p['action']} #{p['table']} id=#{p.dig('row', 'id')}"
      when "erb.start" then "#{p['template']}.erb"
      when "erb.expression" then "#{p['label']}: #{Html.show(p['value'], 40)}"
      when "erb.end" then "#{p['template']}.erb #{p['html_bytes']}B"
      when "response.redirect" then "#{p['status']} → #{p['location']}"
      when "response.html" then "#{p['status']} #{p['bytes']}B"
      when "trace.drop" then "#{p['dropped']}件を破棄（上限 #{p['limit']}）"
      else ""
      end
    end
  end

  # 各パネルの HTML。h は Html.e（エスケープ）
  module Panels
    module_function

    def h(v)
      Html.e(v)
    end

    def requests(log, selected_id)
      return '<p class="empty-note">まだリクエストがありません。対象アプリを別タブで操作してください。</p>' if log.empty?

      items = log.requests.reverse.map do |r|
        cls = ["req"]
        cls << "selected" if r.id == selected_id
        cls << "error" if r.error?
        status = r.status ? r.status.to_s : "…"
        rel = r.related_request_id ? '<span class="rel" title="リダイレクト元とCookieで関連付け">↳</span>' : ""
        flags = []
        flags << '<span class="flag drop">欠落</span>' if r.dropped?
        flags << '<span class="flag err">例外</span>' if r.error?
        <<~HTML
          <li><button type="button" class="#{cls.join(' ')}" data-cmd="select_request" data-arg="#{h r.id}" aria-pressed="#{r.id == selected_id}">
            #{rel}<span class="m m-#{h r.http_method.downcase}">#{h r.http_method}</span>
            <span class="p">#{h r.path}</span>
            <span class="s s#{h status[0]}">#{h status}</span>
            <span class="d">#{r.duration_ms ? "#{h r.duration_ms.round(1)}ms" : ''} SQL #{r.sql_count}</span>#{flags.join}
          </button></li>
        HTML
      end
      %(<ol class="req-list">#{items.join}</ol>)
    end

    def files(sources, current_file)
      items = sources.keys.map do |id|
        cls = id == current_file ? "file current" : "file"
        kind = id.end_with?(".erb") ? "erb" : "ruby"
        %(<li><button type="button" class="#{cls} k-#{kind}" data-cmd="view_file" data-arg="#{h id}">#{h id}</button></li>)
      end
      %(<ul class="file-list">#{items.join}<li><span class="file k-db">PostgreSQL（posts テーブル）</span></li></ul>)
    end

    def code(file, lines, current_line, visited_lines, note)
      return %(<p class="empty-note">#{h(note || 'ステップを選ぶと、実行中のファイルと行がここに表示されます。')}</p>) if file.nil? || lines.nil?

      rows = lines.each_with_index.map do |text, i|
        n = i + 1
        cls = []
        cls << "current" if n == current_line
        cls << "visited" if visited_lines.include?(n)
        mark = n == current_line ? ' aria-current="true"' : ""
        %(<li id="code-line-#{n}" class="#{cls.join(' ')}"#{mark}><span class="ln">#{n}</span><code>#{h text}</code></li>)
      end
      header = %(<div class="code-head"><strong>#{h file}</strong>#{current_line ? " — #{current_line} 行目" : ''}#{note ? %(<span class="note">#{h note}</span>) : ''}</div>)
      %(#{header}<ol class="code">#{rows.join}</ol>)
    end

    def variables(vars, trails)
      parts = []
      parts << '<p class="caption">値は TracePoint の line イベント時点（その行を実行する直前）の実測値です。許可した変数のみ表示します。</p>'
      if vars.empty?
        parts << '<p class="empty-note">このステップまでに観測した変数はありません。</p>'
      else
        rows = vars.map do |v|
          had_prev = v[:prev_type] || !v[:prev_value].nil?
          change = had_prev ? %(<div class="prev">変化前: #{h Html.show(v[:prev_value], 60)}（#{h v[:prev_type]}）</div>) : ""
          cls = v[:changed_now] ? ' class="changed"' : ""
          %(<tr#{cls}><th scope="row">#{h v[:name]}</th><td class="type">#{h v[:type]}</td><td>#{h Html.show(v[:value])}#{change}</td><td class="where">#{h v[:where]}</td></tr>)
        end
        parts << %(<table class="vars"><thead><tr><th>名前</th><th>型</th><th>値</th><th>場所</th></tr></thead><tbody>#{rows.join}</tbody></table>)
      end
      trails.each do |field, trail|
        next if trail.empty?

        items = trail.map do |s|
          %(<li><span class="where">#{h s[:where]}</span> <span class="type">#{h s[:type]}</span> <code>#{h Html.show(s[:value], 80)}</code>#{s[:location] ? %( <span class="loc">#{h s[:location]}</span>) : ''}</li>)
        end
        parts << %(<h3>「#{h field}」の変遷（データの変換）</h3><ol class="trail">#{items.join}</ol>)
      end
      parts.join
    end

    def database(sqls, snapshots, current_seq, loaded)
      parts = []
      if sqls.empty?
        parts << '<p class="empty-note">このリクエストでは（まだ）SQL は実行されていません。</p>'
      else
        rows = sqls.map do |e|
          p = e.payload
          cls = []
          cls << "current" if e.seq == current_seq
          cls << "internal" if e.internal_sql?
          cls << "future" if current_seq && e.seq > current_seq
          %(<tr class="#{cls.join(' ')}"><td>#{e.seq}</td><td><span class="op op-#{h p['operation'].to_s.downcase}">#{h p['operation']}</span></td><td>#{h p['table']}</td><td>#{h p['kind']}</td><td class="num">#{h p['duration_ms']}</td><td class="num">#{h p['row_count']}</td><td><code>#{h p['statement']}</code></td></tr>)
        end
        parts << '<p class="caption">SQL は bind 値を含まない形で表示しています（$1 などは値の置き場所）。時間は sql.active_record の実測です。</p>'
        parts << %(<table class="sql"><thead><tr><th>#</th><th>種別</th><th>表</th><th>分類</th><th>ms</th><th title="sql.active_record が報告した結果セットの行数">返却行</th><th>SQL</th></tr></thead><tbody>#{rows.join}</tbody></table>)
      end
      unless snapshots.empty?
        rows = snapshots.map do |e|
          p = e.payload
          r = p["row"].is_a?(Hash) ? p["row"] : {}
          cls = p["committed"] ? "commit" : "rollback"
          %(<tr class="#{cls}"><td>#{p['committed'] ? '確定' : '取り消し'}</td><td>#{h p['action']}</td><td>#{h r['id']}</td><td>#{h Html.show(r['title'], 40)}</td><td>#{h Html.show(r['body'], 50)}</td></tr>)
        end
        parts << %(<h3>posts テーブルへの反映（after_commit / after_rollback で観測）</h3><table class="rows"><thead><tr><th>結果</th><th>操作</th><th>id</th><th>title</th><th>body</th></tr></thead><tbody>#{rows.join}</tbody></table>)
      end
      unless loaded.empty?
        rows = loaded.first(20).map do |r|
          %(<tr><td>#{h r['id']}</td><td>#{h Html.show(r['title'], 40)}</td><td>#{h Html.show(r['body'], 50)}</td></tr>)
        end
        parts << %(<h3>読み込んだ行（ERB に渡した #{loaded.size} 件）</h3><table class="rows"><thead><tr><th>id</th><th>title</th><th>body</th></tr></thead><tbody>#{rows.join}</tbody></table>)
      end
      parts.join
    end

    def html_output(erb_events, response, current_seq, open_path)
      parts = []
      if erb_events.empty?
        parts << '<p class="empty-note">このリクエストでは ERB は実行されていません（リダイレクトなど）。</p>'
      end
      erb_events.each do |e|
        p = e.payload
        future = current_seq && e.seq > current_seq ? " future" : ""
        cur = e.seq == current_seq ? " current" : ""
        case e.type
        when "erb.start"
          assigns = Array(p["assigns"]).map { |a| %(<li><code>#{h a['name']}</code> <span class="type">#{h a['type']}</span> #{h Html.show(a['value'], 80)}</li>) }
          parts << %(<div class="erb-block#{future}#{cur}"><h3>#{h p['template']}.erb に渡したデータ</h3><ul>#{assigns.join}</ul></div>)
        when "erb.expression"
          parts << %(<div class="erb-expr#{future}#{cur}"><span class="loc">#{h e.file}:#{h e.line}</span> <code>#{h p['label']}</code> <span class="type">#{h p['type']}</span> #{h Html.show(p['value'], 60)} → <code class="html">#{h p['html']}</code>#{p['escaped'] ? ' <span class="flag">エスケープ済み</span>' : ''}</div>)
        when "erb.end"
          parts << %(<div class="erb-end#{future}#{cur}">#{h p['template']}.erb → HTML #{h p['html_bytes']} バイト（#{h p['duration_ms']}ms）</div>)
        end
      end
      if response
        p = response.payload
        parts << if response.type == "response.redirect"
                   %(<p class="resp">応答: #{h p['status']} リダイレクト → <code>#{h p['location']}</code>（ブラウザは次に別のリクエストで GET します）</p>)
                 else
                   %(<p class="resp">応答: #{h p['status']} text/html #{h p['bytes']} バイト</p>)
                 end
      end
      if open_path
        parts << %(<p><a href="#{h open_path}" target="ruby-flow-app" rel="noopener">このページを実アプリで開く ↗</a></p>)
      end
      parts.join
    end

    def events(trace, current_seq)
      return '<p class="empty-note">リクエストを選択してください。</p>' unless trace

      items = trace.events.map do |e|
        cls = ["ev", "t-#{e.type.tr('.', '-')}"]
        cls << "current" if e.seq == current_seq
        cls << "internal" if e.internal_sql?
        loc = e.file ? "#{e.file}#{e.line ? ":#{e.line}" : ''}" : ""
        aria = e.seq == current_seq ? ' aria-current="step"' : ""
        %(<li#{aria}><button type="button" class="#{cls.join(' ')}" data-cmd="seek_event" data-arg="#{e.seq}"><span class="seq">#{e.seq}</span> <span class="ty">#{h EventText.type_label(e.type)}</span> <span class="loc">#{h loc}</span> <span class="sum">#{h EventText.summary(e)}</span></button></li>)
      end
      %(<ol class="event-list">#{items.join}</ol>)
    end
  end
end
