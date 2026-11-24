# frozen_string_literal: true

module RubyFlow
  # 観測・ソース閲覧してよいファイルの許可リスト。
  # 外部には相対 ID（"app.rb" など）だけを出し、実パスは出さない。
  # config/ 配下、lib/、gem、可視化自身は登録しない。
  class SourceRegistry
    FORBIDDEN = %r{\A(config/|lib/|public/|vendor/|db/|test/|\.)|\.\.|\.yml\z|\.env}

    attr_reader :root

    def initialize(root:, ruby_files: [], template_globs: [])
      @root = File.expand_path(root)
      @by_id = {}
      @by_path = {}
      ruby_files.each { |rel| add(rel, kind: "ruby") }
      template_globs.each do |glob|
        Dir.glob(File.join(@root, glob)).sort.each do |abs|
          add(abs.delete_prefix("#{@root}/"), kind: "erb")
        end
      end
    end

    def add(relative_id, kind:)
      raise ArgumentError, "forbidden source: #{relative_id}" if FORBIDDEN.match?(relative_id)

      abs = File.expand_path(relative_id, @root)
      raise ArgumentError, "outside root: #{relative_id}" unless abs.start_with?("#{@root}/")

      @by_id[relative_id] = { "id" => relative_id, "kind" => kind, "path" => abs }
      @by_path[abs] = relative_id
    end

    # TracePoint の path（絶対パス）→ 許可 ID。許可外なら nil
    def id_for_path(path)
      return nil if path.nil?

      @by_path[path] || @by_path[File.expand_path(path)]
    end

    # TracePoint の対象は Ruby ファイルのみ。ERB は Tilt が生成したコードなので行番号を採用しない
    def ruby_id_for_path(path)
      id = id_for_path(path)
      id && @by_id[id]["kind"] == "ruby" ? id : nil
    end

    def ruby_ids
      @by_id.values.select { |v| v["kind"] == "ruby" }.map { |v| v["id"] }
    end

    def list
      @by_id.values.map { |v| { "id" => v["id"], "kind" => v["kind"] } }
    end

    # 許可 ID のみ読み込む。それ以外（パストラバーサル含む）は nil
    def read(id)
      entry = @by_id[id.to_s]
      return nil unless entry
      return nil unless File.file?(entry["path"])

      File.read(entry["path"], encoding: "UTF-8")
    end
  end
end
