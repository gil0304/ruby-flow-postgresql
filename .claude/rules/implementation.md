# 実装規約
小さな責務のRubyクラス、依存注入可能な設計。テストから着手し、実イベントとUIを分離する。擬似データはテストまたは明示的なデモモードのみ。通信失敗を握り潰さない。環境差を報告し、依存やRubyバージョンを無断変更しない。

## 添付テンプレートの継承（最優先）
- 原本の app.rb、models.rb、Rakefile、Gemfile、views/index.erb、public/css/style.css を土台とする。既存の Sinatra classic style、Bundler.require、ActiveRecord::Base.establish_connection、Rake の構成を維持する。必要な機能は追記・拡張で実装する。
- Ruby 3.4.1、Sinatra 3.2系、ActiveRecord 7.0系（原本の Gemfile の制約 `~> 7.0`）、pg 1.5系（原本 `~> 1.5`）、sinatra-activerecord 2系、Puma 6系を維持する。テスト用依存の追加は可。無断で主要依存の制約を変更しない。
- 添付には config.yml という名前のファイルはなく、実際の設定は config/database.yml。両方および既存 config 配下の設定を変更・生成・移動・削除しない。config/database.yml はバイト単位で原本のまま保護する。内容をログ、UI、報告書、外部へ出さない。SHA-256 は docs/TEMPLATE_BASELINE.md を参照し、変更前後で検証する。
- DB は PostgreSQL のみ。既存設定での接続確認を先に実施し、接続不能なら設定を変更せずブロッカーを記録。必要な専用テストDBは環境変数 DATABASE_URL で別途指定し、実接続先を安全に確認してからマイグレーション・テストを行う。設定に test セクションがないため、テスト時に既存DBへフォールバックしない。既存DBに対する drop/reset/truncate・破壊的マイグレーションは禁止。既存DBへのスキーマ変更は専用DBであることを確認した場合のみ。
- 起動は原本の `bundle exec ruby app.rb -o 127.0.0.1 -p 9292` を基本とする。Sinatra 4 用 rackup への移行を前提にしない。
