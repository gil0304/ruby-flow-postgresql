# frozen_string_literal: true

require "time"

module RubyFlow
  # 観測値を「表示してよい形」に変換する。
  # - inspect / to_json / 任意メソッド呼び出しは行わない
  # - 機密らしいキーは再帰的に除去
  # - 許可したモデル属性だけを読む（SQL を発行しない read_attribute のみ）
  # - 文字列長・要素数・深さを制限
  class Sanitizer
    SENSITIVE_KEY = /pass(word)?|secret|token|cookie|session|auth|credential|csrf|api[_-]?key|private|bind/i

    attr_reader :max_string

    def initialize(max_string: 256, max_items: 20, max_depth: 4, model_attributes: {})
      @max_string = max_string
      @max_items = max_items
      @max_depth = max_depth
      @model_attributes = model_attributes.transform_keys(&:to_s)
    end

    def sensitive_key?(key)
      SENSITIVE_KEY.match?(key.to_s)
    end

    # 値を {type:, value:} 形式で返す（UI 表示用）
    def describe(value)
      { "type" => type_name(value), "value" => clean(value, 0) }
    end

    def truncate(str)
      s = str.to_s
      s = s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?") unless s.encoding == Encoding::UTF_8 && s.valid_encoding?
      s.length > @max_string ? "#{s[0, @max_string - 1]}…" : s
    end

    # Ruby の型名（Array<Post> のように中身の型も示す）
    def type_name(value)
      case value
      when Array
        inner = value.first(@max_items).map { |v| short_class(v) }.uniq
        inner.empty? ? "Array" : "Array<#{inner.join('|')}>"
      else
        if relation?(value)
          "#{short_class(value)}(#{value.klass.name})"
        else
          short_class(value)
        end
      end
    end

    # 再帰的に安全な JSON 互換値へ変換
    def clean(value, depth = 0)
      return "…" if depth > @max_depth

      case value
      when nil, true, false, Integer then value
      when Float then value.finite? ? value.round(4) : value.to_s
      when String then truncate(value)
      when Symbol then truncate(":#{value}")
      when Time, DateTime, Date then value.respond_to?(:iso8601) ? value.iso8601 : truncate(value.to_s)
      when Hash then clean_hash(value, depth)
      when Array then clean_array(value, depth)
      else
        clean_object(value, depth)
      end
    end

    private

    def short_class(value)
      value.class.name || "Object"
    end

    def clean_hash(hash, depth)
      out = {}
      hash.each do |k, v|
        break if out.size >= @max_items
        key = k.to_s
        next if sensitive_key?(key)
        out[truncate(key)] = clean(v, depth + 1)
      end
      out["…"] = "残り #{hash.size - @max_items} 件" if hash.size > @max_items
      out
    end

    def clean_array(array, depth)
      items = array.first(@max_items).map { |v| clean(v, depth + 1) }
      items << "…残り #{array.size - @max_items} 件" if array.size > @max_items
      items
    end

    def clean_object(value, depth)
      if model?(value)
        clean_model(value, depth)
      elsif relation?(value)
        # 未ロードの Relation を数えると SQL が走るため、ロード済みのときだけ件数を出す
        if value.loaded?
          { "__type" => type_name(value), "count" => value.size,
            "records" => clean_array(value.to_a, depth) }
        else
          { "__type" => type_name(value), "loaded" => false }
        end
      elsif errors?(value)
        { "__type" => "ActiveModel::Errors", "messages" => clean_array(value.full_messages, depth) }
      else
        # 任意オブジェクトは型名のみ（inspect はしない）
        { "__type" => short_class(value) }
      end
    end

    def clean_model(record, depth)
      attrs = @model_attributes[record.class.name] || ["id"]
      out = { "__type" => short_class(record) }
      attrs.each do |name|
        next if sensitive_key?(name)
        next unless record.has_attribute?(name)
        out[name] = clean(record.read_attribute(name), depth + 1)
      end
      out["persisted"] = record.persisted?
      out["changed"] = record.changed.select { |n| attrs.include?(n) } if record.changed?
      out["errors"] = clean_array(record.errors.full_messages, depth + 1) if record.errors.any?
      out
    end

    def model?(value)
      defined?(ActiveRecord::Base) && value.is_a?(ActiveRecord::Base)
    end

    def relation?(value)
      defined?(ActiveRecord::Relation) && value.is_a?(ActiveRecord::Relation)
    end

    def errors?(value)
      defined?(ActiveModel::Errors) && value.is_a?(ActiveModel::Errors)
    end
  end
end
