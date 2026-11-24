# Ruby Flow — プロジェクト共通指示
回答・質問・報告は日本語。目的は実際の Ruby Web アプリの処理を Ruby で観測し、p5.rb で描くこと。教育者・初学者向け。
## 必読
- docs/PRODUCT_SPEC.md
- docs/ARCHITECTURE.md
- docs/EVENT_PROTOCOL.md
- docs/IMPLEMENTATION_PLAN.md
- docs/ACCEPTANCE.md
- docs/DESIGN.md
- docs/STATUS.md
## 絶対条件
- サーバー Ruby 3.4.1 固定。ブラウザ側も Ruby 3.4.1 を目標に実際の RUBY_VERSION を検証する。利用可能な WASM 配布物の版が異なる場合は黙って変更せず、技術的理由と代案を報告し、厳密一致を要する受入は未達とする。
- p5.rb 本体を利用。p5.js 直接描画や JS による可視化ロジックへの置換禁止。JS は起動・通信・DOM ブリッジのみ。バージョン・取得元・ライセンスを記録し、動作確認後固定。
- Sinatra / ActiveRecord / PostgreSQL / ERB。初期はローカル 127.0.0.1 のみ。Rails/Gem 公開は MVP 後。
- 実計測を必須とする。架空イベント、固定アニメーション、サンプル専用の偽ログで合格扱いしない。fixture は明示したテスト専用。
- パスワード・Cookie・認証情報・SQL bind 値などをデフォルトで収集しない。許可されたデモの項目のみ値を表示。任意コード実行や外部送信は禁止。
- 仕様→小さな実装→テスト→実ブラウザ検証→STATUS 更新。既存ファイルを尊重し、不必要な質問はしない。破壊的操作、push、公開は指示なしに行わない。
- テスト未実施や実機未検証を合格と呼ばない。最終報告に実行コマンド、結果、残課題、起動手順、スクリーンショットの所在を記載。

## 添付テンプレートの継承（最優先）
- 原本の app.rb、models.rb、Rakefile、Gemfile、views/index.erb、public/css/style.css を土台とする。既存の Sinatra classic style、Bundler.require、ActiveRecord::Base.establish_connection、Rake の構成を維持する。必要な機能は追記・拡張で実装する。
- Ruby 3.4.1、Sinatra 3.2系、ActiveRecord 7.0系（原本の Gemfile の制約 `~> 7.0`）、pg 1.5系（原本 `~> 1.5`）、sinatra-activerecord 2系、Puma 6系を維持する。テスト用依存の追加は可。無断で主要依存の制約を変更しない。
- 添付には config.yml という名前のファイルはなく、実際の設定は config/database.yml。両方および既存 config 配下の設定を変更・生成・移動・削除しない。config/database.yml はバイト単位で原本のまま保護する。内容をログ、UI、報告書、外部へ出さない。SHA-256 は docs/TEMPLATE_BASELINE.md を参照し、変更前後で検証する。
- DB は PostgreSQL のみ。既存設定での接続確認を先に実施し、接続不能なら設定を変更せずブロッカーを記録。必要な専用テストDBは環境変数 DATABASE_URL で別途指定し、実接続先を安全に確認してからマイグレーション・テストを行う。設定に test セクションがないため、テスト時に既存DBへフォールバックしない。既存DBに対する drop/reset/truncate・破壊的マイグレーションは禁止。既存DBへのスキーマ変更は専用DBであることを確認した場合のみ。
- 起動は原本の `bundle exec ruby app.rb -o 127.0.0.1 -p 9292` を基本とする。Sinatra 4 用 rackup への移行を前提にしない。
