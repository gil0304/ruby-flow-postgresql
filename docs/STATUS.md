# 進捗

最終更新: 2026-11-25（P0〜P5 実装・テスト・実ブラウザ検証済み。未達・制約は末尾に記載）

## 原本の保護（開始時・完了時に確認）
| 確認 | 開始時 | 完了時 |
|---|---|---|
| `shasum -a 256 config/database.yml` | `21cd29a0…cdba79f8`（TEMPLATE_BASELINE と一致） | `21cd29a0…cdba79f8`（一致） |
| `config.yml` | 存在しない | 存在しない（新設していない） |
| config/ 配下 | database.yml のみ | database.yml のみ（変更・移動・追加なし） |
| app.rb / models.rb / Rakefile / Gemfile / Gemfile.lock | — | 原本行の削除・変更 0（追記のみ。`get '/'` 内に `@posts = …` の 1 行を追加） |

database.yml の内容は読み取り・表示していない（構造確認のみ: env キー形式で development あり・test なし）。

### 追記（2026-11-25 完了報告後）
- `config/database.yml` が **2026-11-25 01:10:18 に変更**されていた（148 → 147 バイト、SHA-256 `2877179b1960364854144c1b1b1c9de05a817003b26a1d78abf947d4cd53f5e1`）。
  前回完了時（01:08 頃）の確認では原本と一致しており、Claude はこの時刻にコマンドを実行していない。利用者側の編集と思われるため、復元も内容確認もしていない。
  TEMPLATE_BASELINE.md の原本ハッシュ（`21cd29a0…`）は原本の記録として変更していない。
- 利用者の指示により、`DATABASE_URL` なし（現在の設定）で `bundle exec rake db:create db:migrate` を実行 → 成功（DB 作成、CreatePosts 適用）。

## DB の状況とブロッカー
- 既存設定（DATABASE_URL なし）での接続確認: PostgreSQL サーバーには到達するが **`ActiveRecord::NoDatabaseError`**（設定上の DB がこのサーバーに未作成）。
  → 設定は変更せず、そのDBの作成もしていない（**ブロッカーとして記録**）。この状態で起動するとアプリは 503「データベースに接続できません」を返す（実機確認済み、接続情報は表示しない）。
- 専用DBを新規作成して使用（既存DBには一切触れていない）:
  - `ruby_flow_test`（テスト専用）/ `ruby_flow_dev`（ブラウザ検証用）。`createdb -h 127.0.0.1 …` で作成。
  - マイグレーションは `rake flow:migrate`（DATABASE_URL の DB 名が `ruby_flow_*`、ホストがローカル、接続後の `current_database` と adapter=PostgreSQL を検証してから `db:migrate`）。
  - テストは `DATABASE_URL` が `ruby_flow_*_test` でなければ即中止。接続後も `current_database` を照合（不一致なら中止）。原本設定へのフォールバックなし。
- 注意: 原本に test セクションがなく `RACK_ENV=test` だと sinatra-activerecord の読込が失敗するため、テストは development として読み込み→接続先検証→test 設定へ切替、という手順にしている。

## フェーズ
### P0 環境 ✅
- Ruby 3.4.1（server）、`bundle install` 済み、lock 保存（追加はテスト用 gem のみ）。
- ruby.wasm `@ruby/3.4-wasm-wasi@2.7.1`（内蔵 Ruby 3.4.1）、p5.js 1.5.0、p5.rb（upstream ed48e93）をローカルに固定。版・取得元・ライセンス・SHA-256 は `docs/DEPENDENCIES.md`。
- 実ブラウザ（Google Chrome + Claude in Chrome）で p5.rb の setup/draw 実行、**WASM の RUBY_VERSION = 3.4.1** を確認（スクショ 00）。
### P1 描画 ✅
- `public/visualizer/ruby/`: flow_model.rb（イベント解釈・ステップ生成・再生状態・配置）、flow_panels.rb（DOM パネル HTML、全エスケープ）、flow_app.rb（状態・コマンド）、flow_sketch.rb（p5.rb 描画）、flow_boot.rb（DOM/JS 橋渡し）。
- ノード: ブラウザ（青・ウィンドウ形）/ app.rb・models.rb（赤・ルビー印）/ PostgreSQL（緑・円柱）/ ERB（琥珀・文書形）/ HTML（灰青）。色＋形＋ラベルで区別。
- fixture（`test/fixtures/`、テスト専用と明記）で CRuby 上の単体テスト。
### P2 CRUD ✅
- 投稿 CRUD（一覧/作成/表示/編集/削除、削除は POST）、検証失敗 422（日本語メッセージ）、404、DB 未接続 503。出力はすべて `h`/`flow_h` でエスケープ。
- マイグレーション `db/migrate/20261125000000_create_posts.rb` を専用DBへ適用。
### P3 Collector ✅
- Rack ミドルウェア（request_id、開始/終了/例外/時間、/__flow・静的ファイルは除外、非ストリーミング前提）。
- TracePoint（call/return/line/raise）を **app.rb・models.rb で定義されたメソッドだけに `enable(target:)`**。gem 内部ではフックが呼ばれない。リクエスト分離はスレッドローカルの RequestContext で判定。ERB の生成コード行は採らない。
- `sql.active_record` 購読（bind 値・リテラル・コメントを除いた正規化 SQL、種別、表、schema/cache/transaction 区別、実測時間、発生元の app.rb 行）。
- ERB は Sinatra の render 境界（開始/終了/許可 ivar）と明示ヘルパー `flow_h` の式のみ。
- DB 行の確定/取消は after_commit / after_rollback で許可列のみ記録（ロールバックは「取り消し」）。
- EventStore（Mutex リングバッファ、5000 件、1 リクエスト 500 件、文字列 256 文字、超過は gap / trace.drop）。
- API: `/__flow/events?after=N`、`/__flow/source[?file=ID]`（許可リスト・実パス非公開）、`/__flow/health`。Host/接続元検証、no-store、CORS なし、GET のみ。
### P4 統合 ✅
- 400ms polling（失敗時は最大 4 秒まで後退）、切断表示、サーバー再起動検出（server_id）、gap 表示。
- POST → 303 → GET を別 request_id で表示し、短命 Cookie（値は request_id のみ）による実際の相関で親子リンク（↳）。
- コードのリアルタイムハイライト、変数（実行直前の値・変化前）、title/body の変遷、DB（SQL 一覧・確定行）、ERB・HTML（渡したデータ・式→エスケープ後 HTML）、イベント一覧（読み上げ可能な DOM）。
- 再生/一時停止/前後ステップ/速度 0.5・1・2/最初へ/リクエスト履歴選択/タイムラインクリック/ライブ追従/内部SQL表示切替/動きを減らす、キーボード操作、パネル折りたたみ、縮小時の縦並び。
### P5 品質 ✅（未達項目は下記）

## 実行コマンドと結果（2026-11-25）
```
DATABASE_URL=postgres://127.0.0.1/ruby_flow_test bundle exec rake test
→ 56 runs, 330 assertions, 0 failures, 0 errors, 0 skips
```
内訳: collector 単体 16 / 可視化ロジック 17 / 統合（実 PostgreSQL・Rack）23（API 6、CRUD・計測 16、起動形態の回帰 1）。

### 性能（計測あり/なし、`script/benchmark.rb 200`、Rack 直呼び・専用テストDB・各 200 回の中央値）
| シナリオ | OFF | ON | 倍率 |
|---|---|---|---|
| GET /（20件一覧） | 0.90ms | 2.67ms | 2.96x |
| GET /posts/:id | 0.44ms | 0.72ms | 1.62x |
| POST /posts（作成→303） | 1.86ms | 2.67ms | 1.44x |
| POST /posts（検証失敗→422） | 0.26ms | 0.81ms | 3.13x |

改善経緯: 当初のスレッド全体 TracePoint 方式は +9〜31ms（19〜56 倍）だったため、対象メソッド限定（`enable(target:)`）に変更。
ブラウザ側描画: 待機時 29.8 fps（frameRate 30 指定、Chrome で実測）。

## 実ブラウザ検証（Google Chrome、http://127.0.0.1:9292）
作成・表示・編集・検証失敗・削除・404・切断/再接続・再生操作をすべて実際に操作。スクリーンショット: `docs/screenshots/`
| ファイル | 内容 |
|---|---|
| 00_boot_wasm_ruby_3.4.1_empty.jpg | 起動直後・空状態・WASM Ruby 3.4.1 とサーバー側一致表示 |
| 02_app_create_result_escaped.jpg | 作成結果（`<b>` がエスケープされ文字として表示） |
| 03_flow_post_create_app_line.jpg | POST /posts 再生中、app.rb:26 ハイライト |
| 04_flow_models_return_to_app.jpg | models.rb の normalize_fields から app.rb へ戻り値 |
| 05_flow_get_erb_escaped_html.jpg | GET /posts/:id の ERB 式（show.erb:15）→ エスケープ後 HTML |
| 06_vars_title_transformation.jpg | 変数と title の変遷（params → ローカル変数 → strip → PostgreSQL） |
| 07_flow_update_sql.jpg | 更新（UPDATE、bind 値なし） |
| 08_app_after_delete.jpg / 09_flow_delete_commit.jpg | 削除後の一覧 / DELETE と確定行 |
| 10_app_validation_error_ja.jpg | 検証失敗（422、日本語メッセージ） |
| 11_flow_404_exception.jpg | 404 と RecordNotFound（app.rb:40） |
| 12_disconnected.jpg | サーバー停止中の切断表示 |
| 13_app_index_list.jpg | 一覧画面 |
| 14_final_create_insert_db.jpg / 15_final_delete_vars.jpg | 最終版（対象限定 TracePoint）での作成 INSERT・削除 DELETE |

00〜13 は対象限定 TracePoint へ変更する前の実装、14〜15 は最終版で撮影（いずれも実測イベント）。

## 受入チェック（docs/ACCEPTANCE.md 対応）
| 項目 | 結果 |
|---|---|
| Ruby 3.4.1 で bundle install・起動・テスト、lockfile | ✅ |
| p5.rb の setup/draw 実行・WASM RUBY_VERSION 確認 | ✅ 3.4.1 |
| CRUD・検証失敗が実DBとHTMLに反映 | ✅ テスト＋実ブラウザ |
| POST と GET が別 request_id、SQL/ERB/Ruby が正しいリクエストに属する | ✅ テスト＋実ブラウザ |
| ノード・移動・コード行が実イベントに対応、補間を区別 | ✅（画面上に「点の移動は説明用の補間」と常時表示、ステップ表示にも明記） |
| 値が変わると描画も変わる | ✅ テスト（値の異なる 2 投稿）＋実ブラウザ |
| 一時停止/再生/前後/速度/リセット/履歴選択 | ✅ 実ブラウザ（キー・ボタン・タイムライン） |
| 同時リクエスト・例外・欠落・切断・空状態 | ✅ テスト（同時 4 リクエスト、404、上限 trace.drop、gap、切断/不正 JSON、空）。切断・空・例外は実ブラウザでも確認 |
| 機密値・任意ファイル・外部アクセス・XSS 対策 | ✅ テスト（password/token/Cookie/Authorization 非収集、bind 非収集、source 許可リスト・トラバーサル拒否、Host/接続元検証、出力・パネルのエスケープ） |
| 計測あり/なしの比較・件数上限 | ✅ 上表・テスト |
| 実ブラウザで作成・編集・削除・スクショ | ✅ |
| README で再現可能 | ✅ README 更新 |
| database.yml SHA-256 一致・config.yml 非新設 | ✅ |
| 実接続アダプタが PostgreSQL（接続情報非表示） | ✅ `/__flow/health`・`rake flow:verify_db` |
| 専用テストDB明示・誤接続時停止・既存データ非破壊 | ✅ |
| トランザクション成功・ロールバック・bind マスキング | ✅ テスト |

## 未達・制約・残課題
- ~~原本設定の DB が未作成（ブロッカー）~~ → 利用者の指示で `rake db:create db:migrate` を実行し解消。原本の起動コマンド `bundle exec ruby app.rb -o 127.0.0.1 -p 9292`（DATABASE_URL なし）で接続（PostgreSQL）、GET / 200、POST /posts 303（BEGIN→INSERT→COMMIT）を確認。動作確認用に投稿 1 件（「原本設定での確認」）を作成済み。
- **ブラウザ E2E の自動テストは未整備**: 実ブラウザ検証は Claude in Chrome による手動操作。Playwright 等の自動テストは未導入（依存追加になるため）。
- **gap（5000 件超えの取りこぼし）の実ブラウザ再現は未実施**: サーバー側・可視化ロジックの単体テストのみ。
- **同時リクエストの混線防止は自動テストのみ**（実ブラウザでの同時操作は未実施）。
- SSE は未実装（仕様どおり JSON polling）。
- lib/ の変更はサーバー再起動が必要（sinatra/reloader は app.rb のみ再読込。app.rb 再読込時は TracePoint の対象を自動で取り直す）。
- 例外発生時、例外で抜けたメソッドの `ruby.return`（戻り値 nil）が `ruby.raise`（Sinatra が受け取った時点）より先に並ぶ。TracePoint の実際の順序どおりで捏造はしていない。
- development では原本の sinatra-activerecord 設定により ActiveRecord のログ（bind 値を含む）がサーバーの標準出力に出る。Ruby Flow はこれを収集・表示しない。
- リダイレクトの親子付けに短命 Cookie `ruby_flow_parent`（値は request_id のみ、HttpOnly・SameSite=Strict・30 秒）を使う。
- ActiveRecord は lock 済みの 7.2.4（制約 `~> 7.0` 内）。7.0.x 固定が必要なら指示を。
- WASM（約 30MB）は初回読込に数秒かかる（2 回目以降は 304 で再検証）。
