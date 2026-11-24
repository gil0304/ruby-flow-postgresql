# frozen_string_literal: true

module RubyFlow
  # sql.active_record の SQL 文を「安全な要約」にする。
  # - bind 値（$1 等の中身）は受け取らない・表示しない
  # - 文字列/数値リテラルとコメントは ? に置換（値の露出防止）
  # - 分類に失敗したら種別 OTHER のみ
  class SqlClassifier
    OPERATIONS = %w[SELECT INSERT UPDATE DELETE BEGIN COMMIT ROLLBACK SAVEPOINT RELEASE SET SHOW CREATE ALTER DROP].freeze

    def initialize(max_length: 256)
      @max_length = max_length
    end

    def classify(sql, name: nil, cached: false)
      text = sql.to_s
      normalized = normalize(text)
      op = operation(normalized)
      {
        "operation" => op,
        "table" => table(normalized, op),
        "kind" => kind(name, op, cached),
        "returning" => normalized.match?(/\bRETURNING\b/i),
        "bind_params" => normalized.scan(/\$\d+/).uniq.size,
        "statement" => truncate(normalized)
      }
    rescue StandardError
      { "operation" => "OTHER", "kind" => "unknown" }
    end

    def normalize(sql)
      s = sql.dup
      s = s.gsub(%r{/\*.*?\*/}m, " ")            # ブロックコメント
      s = s.gsub(/--[^\n]*/, " ")                # 行コメント
      s = s.gsub(/E?'(?:[^']|'')*'/, "?")        # 文字列リテラル
      s = s.gsub(/(?<![\w$".])-?\d+(?:\.\d+)?(?![\w"])/, "?") # 数値リテラル（$1 や識別子は除く）
      s.gsub(/\s+/, " ").strip
    end

    private

    def operation(normalized)
      word = normalized[/\A\(?\s*([A-Za-z]+)/, 1].to_s.upcase
      return "SELECT" if word == "WITH"

      OPERATIONS.include?(word) ? word : "OTHER"
    end

    def table(normalized, op)
      ident = /("?[A-Za-z_][\w]*"?(?:\."?[A-Za-z_][\w]*"?)?)/
      t = case op
          when "SELECT", "DELETE" then normalized[/\bFROM\s+#{ident}/i, 1]
          when "INSERT" then normalized[/\bINTO\s+#{ident}/i, 1]
          when "UPDATE" then normalized[/\AUPDATE\s+#{ident}/i, 1]
          end
      t&.delete('"')
    end

    def kind(name, op, cached)
      return "cache" if cached
      return "schema" if name.to_s == "SCHEMA" || name.to_s.include?("Schema")
      return "transaction" if %w[BEGIN COMMIT ROLLBACK SAVEPOINT RELEASE].include?(op)

      "query"
    end

    def truncate(str)
      str.length > @max_length ? "#{str[0, @max_length - 1]}…" : str
    end
  end
end
