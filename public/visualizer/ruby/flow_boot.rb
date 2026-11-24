# frozen_string_literal: true

require "js"

# Ruby Flow 可視化：ブラウザ（ruby.wasm）専用の入口。
# JS からはこの Bridge のメソッドだけを呼ぶ（引数はすべて文字列で受け取る）。
module RubyFlowViz
  # DOM 操作アダプタ（App からはこのインターフェースだけを使う）
  class JsDom
    def initialize
      @doc = JS.global[:document]
      @cache = {}
      @scroll_opts = JS.eval("return { block: 'nearest', inline: 'nearest' };")
    end

    def el(id)
      node = @doc.getElementById(id)
      node == JS::Null ? nil : node
    end

    def set_html(id, html)
      write(id, :innerHTML, html)
    end

    def set_text(id, text)
      write(id, :textContent, text)
    end

    def set_attr(id, name, value)
      key = "#{id}@#{name}"
      return if @cache[key] == value

      node = el(id)
      return unless node

      node.setAttribute(name, value.to_s)
      @cache[key] = value
    end

    def scroll_into_view(id, selector = nil)
      node = el(id)
      return unless node

      node = node.querySelector(selector) if selector
      return if node.nil? || node == JS::Null

      node.scrollIntoView(@scroll_opts)
    end

    private

    def write(id, prop, value)
      key = "#{id}.#{prop}"
      return if @cache[key] == value

      node = el(id)
      return unless node

      node[prop] = value.to_s
      @cache[key] = value
    end
  end

  class Bridge
    def initialize
      @dom = JsDom.new
      @app = App.new(dom: @dom)
      @app.wasm_ruby_version = RUBY_VERSION
      @sketch = Sketch.new(@app)
      @dom.set_text("wasm-ruby-version", "#{RUBY_VERSION} (#{RUBY_PLATFORM}, #{RUBY_RELEASE_DATE})")
    end

    def ruby_version
      RUBY_VERSION
    end

    # 描画したフレーム数（性能確認用）
    def frames
      @app.frames.to_s
    end

    # --- p5.js のコールバック（JS が転送する）---
    def setup
      @sketch.setup
    end

    def draw
      @sketch.draw
    end

    def mouse_pressed
      @sketch.mouse_pressed
    end

    def window_resized
      @sketch.window_resized
    end

    # --- 通信（JS が fetch した結果を渡す）---
    def cursor
      @app.cursor.to_s
    end

    def ingest(text)
      @app.ingest(text.to_s) ? "ok" : "error"
    end

    def connection_error(message)
      @app.connection_error(message.to_s)
    end

    def health(text)
      @app.health = text.to_s
      server = @app.health && @app.health["server_ruby_version"]
      if server
        match = server == RUBY_VERSION ? "一致" : "不一致"
        @dom.set_text("server-ruby-version", "#{server}（ブラウザ側と#{match}）")
      end
    end

    def load_source(id, text)
      @app.load_source(id.to_s, text.to_s)
    end

    # --- 操作 ---
    def command(name, arg)
      a = arg.to_s
      @app.command(name.to_s, a.empty? ? nil : a) ? "true" : "false"
    end

    def set_reduced_motion(flag)
      @app.reduced_motion = !flag.to_s.empty?
    end
  end
end
