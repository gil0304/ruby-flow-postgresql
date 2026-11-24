# Claude Code 初回指示
CLAUDE.md と docs 全ファイルを読み、Ruby Flow の MVP を P0〜P5 まで実装してください。Ruby 3.4.1 は固定。p5.rb を実際に使い、描画と再生の主要ロジックを Ruby に置いてください。実際の CRUD を計測して表示し、固定されたデモで完成扱いしないでください。各フェーズでテストし STATUS.md を更新してください。利用可能な実ブラウザで受入を実行し、スクリーンショットを保存してください。途中で仕様上の軽微な判断は合理的に行い記録してください。重大な環境ブロッカーは明記し独立作業を進めてください。最後に起動方法、実装内容、テスト結果、未達、次の作業を日本語で報告してください。pushや公開は不要です。

## 添付テンプレートの継承（最優先）
- 原本の app.rb、models.rb、Rakefile、Gemfile、views/index.erb、public/css/style.css を土台とする。既存の Sinatra classic style、Bundler.require、ActiveRecord::Base.establish_connection、Rake の構成を維持する。必要な機能は追記・拡張で実装する。
- Ruby 3.4.1、Sinatra 3.2系、ActiveRecord 7.0系（原本の Gemfile の制約 `~> 7.0`）、pg 1.5系（原本 `~> 1.5`）、sinatra-activerecord 2系、Puma 6系を維持する。テスト用依存の追加は可。無断で主要依存の制約を変更しない。
- 添付には config.yml という名前のファイルはなく、実際の設定は config/database.yml。両方および既存 config 配下の設定を変更・生成・移動・削除しない。config/database.yml はバイト単位で原本のまま保護する。内容をログ、UI、報告書、外部へ出さない。SHA-256 は docs/TEMPLATE_BASELINE.md を参照し、変更前後で検証する。
- DB は PostgreSQL のみ。既存設定での接続確認を先に実施し、接続不能なら設定を変更せずブロッカーを記録。必要な専用テストDBは環境変数 DATABASE_URL で別途指定し、実接続先を安全に確認してからマイグレーション・テストを行う。設定に test セクションがないため、テスト時に既存DBへフォールバックしない。既存DBに対する drop/reset/truncate・破壊的マイグレーションは禁止。既存DBへのスキーマ変更は専用DBであることを確認した場合のみ。
- 起動は原本の `bundle exec ruby app.rb -o 127.0.0.1 -p 9292` を基本とする。Sinatra 4 用 rackup への移行を前提にしない。
