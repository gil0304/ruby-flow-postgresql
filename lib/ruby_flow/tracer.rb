# frozen_string_literal: true

module RubyFlow
  # TracePoint による Ruby 実行の観測。
  # - 対象は SourceRegistry に登録した Ruby ファイル（app.rb / models.rb）で定義されたメソッドだけ。
  #   TracePoint#enable(target:) でそのメソッドの命令列にだけフックを掛けるので、gem 内部の行では
  #   フックが一切呼ばれない（全行を拾ってパスで捨てる方式より大幅に軽い）。
  # - リクエストの分離: フック内で「現在のスレッド（Fiber）の RequestContext」を見て、
  #   計測中のリクエストに属する場合だけ記録する → 同時リクエストでも混線しない。
  # - 変数は許可リストの名前だけを binding から読む（binding.inspect や全変数収集はしない）
  # - 計測中に例外が起きてもアプリは止めない（エラー件数だけ数える）
  # - 開発時の自動リロードに備え、対象ファイルの更新時刻が変わったら対象メソッドを数え直す
  class Tracer
    EVENTS = %i[call return line raise].freeze

    attr_reader :internal_errors

    def initialize(collector:, registry:, sanitizer:, watch_locals: [], watch_ivars: [], watch_self_classes: [])
      @collector = collector
      @registry = registry
      @sanitizer = sanitizer
      @watch_locals = watch_locals.map(&:to_sym)
      @watch_ivars = watch_ivars.map(&:to_sym)
      @watch_self_classes = watch_self_classes.map(&:to_s)
      @internal_errors = 0
      @mutex = Mutex.new
      @tracepoints = []
      @signature = nil
    end

    def trace(_context = nil)
      refresh_targets!
      yield
    end

    # 有効化しているメソッド数（テスト・診断用）
    def target_count
      @tracepoints.size
    end

    def refresh_targets!
      sig = signature
      return if sig == @signature

      @mutex.synchronize do
        return if sig == @signature

        @tracepoints.each(&:disable)
        line_targets, call_targets = collect_targets
        # 行・例外は命令列（iseq）ごとに 1 回、呼び出し・戻りはメソッドごと（同じブロックを共有する
        # Sinatra の GET/HEAD ルートはそれぞれ別メソッドなので両方に付ける）
        @tracepoints = line_targets.map { |t| enable_on(t, %i[line raise]) } +
                       call_targets.map { |t| enable_on(t, %i[call return]) }
        @tracepoints.compact!
        @signature = sig
      end
    end

    private

    def signature
      @registry.ruby_ids.map do |id|
        path = File.join(@registry.root, id)
        File.exist?(path) ? File.mtime(path).to_f : 0
      end
    end

    def enable_on(target, events)
      tp = TracePoint.new(*events) { |t| handle(t) }
      tp.enable(target: target)
      tp
    rescue ArgumentError, RuntimeError
      @internal_errors += 1
      nil
    end

    # 許可ファイルで定義されたメソッド（Sinatra のルートは "GET /posts" のような UnboundMethod）
    # 戻り値: [行・例外用（iseq ごとに 1 つ）, 呼び出し・戻り用（メソッドごと）]
    def collect_targets
      paths = @registry.ruby_ids.map { |id| File.join(@registry.root, id) }
      by_iseq = {}
      by_method = {}
      add = lambda do |meth|
        loc = meth.source_location
        # `ruby app.rb` で起動するとメインスクリプトの位置は相対パス "app.rb" になるため正規化して比較
        next unless loc && paths.include?(File.expand_path(loc[0]))

        iseq = RubyVM::InstructionSequence.of(meth)
        next unless iseq

        key = [File.expand_path(iseq.path), iseq.first_lineno, iseq.label]
        by_iseq[key] ||= meth
        by_method[key + [meth.owner, meth.name]] ||= meth
      end
      ObjectSpace.each_object(Module) do |mod|
        [mod, mod.singleton_class].each do |m|
          (m.instance_methods(false) + m.private_instance_methods(false)).each do |name|
            add.call(m.instance_method(name))
          rescue NameError
            next
          end
        end
      rescue StandardError
        next
      end
      ObjectSpace.each_object(UnboundMethod) { |um| add.call(um) }
      [by_iseq.values, by_method.values]
    end

    def handle(tp)
      context = RequestContext.current
      return unless context && @collector.enabled?

      file_id = @registry.ruby_id_for_path(tp.path)
      return unless file_id

      case tp.event
      when :call then on_call(tp, context, file_id)
      when :return then on_return(tp, context, file_id)
      when :line then on_line(tp, context, file_id)
      when :raise then on_raise(tp, context, file_id)
      end
    rescue StandardError
      @internal_errors += 1
    end

    def method_label(tp)
      name = tp.method_id.to_s
      owner = tp.defined_class
      owner_name = owner.respond_to?(:name) ? owner.name : nil
      owner_name = owner_name.to_s.sub(/\A#<Class:(.+)>\z/, '\1.') if owner&.singleton_class?
      # Sinatra のルートは "GET /posts" という名前のメソッドになる
      return name if name.match?(/\A(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS) /)
      # error / not_found ブロックは "ERROR (正規表現)" という名前になるので読みやすくする
      return "error ハンドラ" if name.start_with?("ERROR")

      owner_name && !owner_name.empty? ? "#{owner_name.end_with?('.') ? owner_name : "#{owner_name}#"}#{name}" : name
    end

    def on_call(tp, context, file_id)
      span_id, parent = context.push_span
      @collector.emit_for(context, "ruby.call", file: file_id, line: tp.lineno,
                          payload: { "method" => method_label(tp), "args" => capture_args(tp) },
                          span_id: span_id, parent_span_id: parent)
    end

    def on_return(tp, context, file_id)
      span_id = context.pop_span
      payload = { "method" => method_label(tp),
                  "return" => @sanitizer.describe(tp.return_value),
                  "vars" => capture_vars(tp.binding) }
      @collector.emit_for(context, "ruby.return", file: file_id, line: tp.lineno,
                          payload: payload, span_id: span_id, parent_span_id: context.current_span_id)
    end

    def on_line(tp, context, file_id)
      @collector.emit_for(context, "ruby.line", file: file_id, line: tp.lineno,
                          payload: { "method" => method_label(tp), "vars" => capture_vars(tp.binding) },
                          parent_span_id: context.current_span_id)
    end

    def on_raise(tp, context, file_id)
      @collector.emit_for(context, "ruby.raise", file: file_id, line: tp.lineno,
                          payload: @collector.exception_payload(tp.raised_exception, origin: "app"),
                          parent_span_id: context.current_span_id)
    end

    def capture_args(tp)
      b = tp.binding
      return {} unless b

      tp.parameters.each_with_object({}) do |(_kind, name), out|
        next unless name && @watch_locals.include?(name)
        next if @sanitizer.sensitive_key?(name)

        out[name.to_s] = @sanitizer.describe(b.local_variable_get(name))
      end
    end

    # 許可した名前だけを読む。「この行を実行する直前」の値
    def capture_vars(binding)
      return [] unless binding

      vars = []
      defined_locals = binding.local_variables
      @watch_locals.each do |name|
        next unless defined_locals.include?(name)

        vars << var_entry(name.to_s, "local", binding.local_variable_get(name))
      end
      receiver = binding.receiver
      @watch_ivars.each do |ivar|
        next unless receiver.instance_variable_defined?(ivar)

        vars << var_entry(ivar.to_s, "ivar", receiver.instance_variable_get(ivar))
      end
      if @watch_self_classes.include?(receiver.class.name)
        vars << var_entry("self", "self", receiver)
      end
      vars
    end

    def var_entry(name, scope, value)
      described = @sanitizer.describe(value)
      { "name" => name, "scope" => scope, "type" => described["type"], "value" => described["value"] }
    end
  end
end
