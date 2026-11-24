# frozen_string_literal: true

require "uri"

module RubyFlow
  # 専用DBであることを確認するためのガード。
  # - DATABASE_URL が明示されていること
  # - 接続先ホストがローカル、DB名が ruby_flow_* であること（テストは *_test 必須）
  # - 実際に接続した current_database / アダプタが期待どおりであること
  # 接続情報（ユーザー・パスワード等）は表示しない。DB名のみ表示する。
  module DbGuard
    class UnsafeDatabase < StandardError; end

    LOCAL_HOSTS = [nil, "", "127.0.0.1", "localhost", "::1"].freeze

    module_function

    def expected_database(url = ENV["DATABASE_URL"], require_test: false)
      raise UnsafeDatabase, "DATABASE_URL が未設定です（既存設定へのフォールバックは行いません）" if url.to_s.empty?

      uri = URI.parse(url)
      raise UnsafeDatabase, "PostgreSQL の URL ではありません" unless %w[postgres postgresql].include?(uri.scheme)
      raise UnsafeDatabase, "ローカル以外のホストは対象外です" unless LOCAL_HOSTS.include?(uri.host)

      name = uri.path.to_s.delete_prefix("/")
      raise UnsafeDatabase, "専用DB名は ruby_flow_ で始めてください" unless name.start_with?("ruby_flow_")
      raise UnsafeDatabase, "テスト用DB名は _test で終わる必要があります" if require_test && !name.end_with?("_test")

      name
    end

    def verify_connection!(connection, expected)
      adapter = connection.adapter_name
      raise UnsafeDatabase, "PostgreSQL 以外のアダプタです: #{adapter}" unless adapter == "PostgreSQL"

      actual = connection.current_database
      raise UnsafeDatabase, "接続先DBが想定と異なります（想定: #{expected}）" unless actual == expected

      actual
    end
  end
end
