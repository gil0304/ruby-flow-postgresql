# 技術設計
- Rack middleware: request_id、開始・終了・例外、処理時間。リクエストごとにスコープを分離し ensure で解放。レスポンスの body close/列挙を考慮し MVP は非ストリーミング対象と明記。
- TracePoint: :call/:return/:line/:raise を対象 app.rb/models.rb 等の許可パスに限定。可視化自身・gem・静的ファイル・API を除外。スレッド/リクエスト混線防止。無制限 binding.inspect は禁止。値の観測は許可された型・キーのみ。計測失敗でアプリを壊さない。
- ActiveSupport::Notifications: sql.active_record を購読し現在の request_id に紐付ける。SQL は bind を含めず安全に正規化、リテラルやコメントを露出しない。分類に失敗したら種別のみ。内部 schema/cache は区別。DB 行の変更は実結果を安全な明示的観測で取得。
- ERB: Sinatra のレンダリング境界をラップし template 名、開始終了、許可済み変数を記録。式ごとのイベントは明示的 helper 経由のみ。ERB内部生成コードの行を実テンプレート行と偽らない。
- EventStore: Mutex 保護のリングバッファ、連番、最大5000件、1リクエスト最大500件、文字列最大256文字。超過時は gap/drop を通知。メモリのみ。最初は JSON polling (250〜500ms) でカーソル取得、後から SSE に拡張可。接続状態を表示。
- Visualizer: public/visualizer の Ruby スケッチがノード配置、補間、タイムライン、再生状態を担当。JS は JSON取得・Rubyへの受け渡し・DOM連携のみ。WASM とサーバーは独立環境。p5.rb upstream https://github.com/ongaeshi/p5rb および https://p5rb.ongaeshi.me/ を確認。WASM配布物の実バージョンを記録。
- API: GET /__flow/events?after=N, GET /__flow/source?file=ID (allowlist、実パスを外部に出さない)、GET /__flow/health。ローカルのみ、Host検証、CORS開放なし、no-store。ソース閲覧は対象の許可済みデモファイルのみ。
- テスト: Minitest/Rack::Test、Ruby純粋ロジック、実ブラウザ（利用可能な Playwright 等）。

## PostgreSQL / 原本統合
既存 models.rb の接続方式と Rakefile を利用。db/migrate に追加マイグレーションを置き、専用DBで `bundle exec rake db:migrate` を検証。SQLイベントは PostgreSQL の bind（$1 等）、引用識別子、トランザクション BEGIN/COMMIT/ROLLBACK、RETURNING、schema/cache を区別する。SQLの生文字列や bind 値は表示しない。実DBの結果を許可項目に限り取得し、ロールバックした変更を確定扱いしない。既存設定ファイルはソース閲覧・トレース対象外。
