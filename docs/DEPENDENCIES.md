# 依存関係の記録（版・取得元・ライセンス・ハッシュ）

## サーバー側（Gemfile / Gemfile.lock）
原本の制約はすべて維持。追加したのはテスト用の `group :test` のみ（`minitest ~> 5.20`, `rack-test ~> 2.1`）。

| gem | 原本の制約 | lock 版 | 備考 |
|---|---|---|---|
| Ruby | `ruby '3.4.1'` | 3.4.1 (2024-12-25 revision 48d4efcb85) | rbenv |
| sinatra / sinatra-contrib | `~> 3.2` | 3.2.0 | classic style のまま |
| activerecord | `~> 7.0` | 7.2.4 | 原本添付の Gemfile.lock の版（制約 `~> 7.0` の範囲内）。変更していない |
| pg | `~> 1.5` | 1.7.0 | 原本添付の lock のまま（`~> 1.5` の範囲内） |
| sinatra-activerecord | `~> 2.0` | 2.0.28 | |
| puma | `~> 6.4` | 6.6.1 | |
| rack | （sinatra 経由） | 2.2.26 | |
| minitest（追加・test） | `~> 5.20` | 5.27.0 | 既に activesupport 経由で lock 済みだった版 |
| rack-test（追加・test） | `~> 2.1` | 2.3.0 | 新規 |

> 注: ActiveRecord は「7.0系」と指示されていますが、原本に添付された Gemfile.lock が既に 7.2.4 を固定していました。
> 制約 `~> 7.0` の範囲内であり、無断変更を避けるため lock の版はそのまま使っています（7.0.x へ下げる場合は指示ください）。

## ブラウザ側（public/visualizer/vendor/ にローカル固定。実行時に外部 CDN へはアクセスしない）

| 物 | 版 | 取得元 | ライセンス | 配置ファイル | SHA-256 |
|---|---|---|---|---|---|
| ruby.wasm（Ruby 3.4 + stdlib） | `@ruby/3.4-wasm-wasi@2.7.1`（中身は **ruby 3.4.1 (2024-12-25 revision 48d4efcb85) [wasm32-wasi]**） | https://registry.npmjs.org/@ruby/3.4-wasm-wasi/-/3.4-wasm-wasi-2.7.1.tgz | MIT（ruby.wasm）/ Ruby・同梱物は NOTICE 参照 | `ruby-wasm/ruby+stdlib.wasm` | f740c650d434d5d2e3ad7fe21af411b05ad2e75810dead2bdce3c873744369bb |
| ruby.wasm JS ランタイム（DefaultRubyVM） | 同上 2.7.1 の `dist/browser.umd.js`（`@ruby/wasm-wasi@2.7.1` と同一バイト） | 同上 | MIT | `ruby-wasm/browser.umd.js` | ec115e61febfdb95118fb7b50470ebdb0376cd60f42127925db6cb6165cdae67 |
| ruby.wasm ライセンス | — | 同上 | — | `ruby-wasm/LICENSE`, `ruby-wasm/NOTICE` | 90357d37…, 343c246a… |
| p5.js | 1.5.0（p5.rb upstream の例が使用している版） | https://registry.npmjs.org/p5/-/p5-1.5.0.tgz | LGPL-2.1 | `p5/p5.min.js`, `p5/LICENSE.txt` | 9299cb44c85ae804df74c2b75e9de524222d99402a7a79421f7a5670a1288524 |
| **p5.rb 本体** | upstream master `ed48e93f17cd7326c852bfe3eea29e7984d5ba35`（2025-02-06）の `docs/lib/p5.rb` を無改変で使用 | https://github.com/ongaeshi/p5rb （https://p5rb.ongaeshi.me/） | LGPL-2.1（リポジトリの license.txt） | `p5rb/p5.rb`, `p5rb/LICENSE.txt` | ba3b4da291e4e3eb5d3da847f5b2c2151ed30e1eb0d9ab5ae494500e04575e20 |

確認コマンド: `cd public/visualizer/vendor && find . -type f | sort | xargs shasum -a 256`

### ブラウザ側 Ruby の版
- 実ブラウザ（Google Chrome）で `RUBY_VERSION` を Ruby 側から取得し画面上部に表示。**3.4.1 (wasm32-wasi, 2024-12-25)** を確認し、サーバー側 3.4.1 と一致表示。
- 配布物の版選定: `@ruby/3.4-wasm-wasi` の 2.7.1（2025-01-23 公開）は Ruby 3.4.1 を内蔵。以降の 2.7.2 / 2.8.x / 2.10.x は 3.4 系の新しいパッチ版の可能性があるため採用していない（厳密一致のため）。

### p5.rb の使い方について
upstream master の `p5.rb` は `P5.init(p5インスタンス)` を受け取り、JS 側が p5 のコールバック（setup/draw 等）を Ruby に転送する方式（upstream の `docs/editor/main.js` と同じ）。本プロジェクトの `boot.js` も同方式で、描画命令（createCanvas/fill/rect/text/bezier …）はすべて Ruby（`public/visualizer/ruby/flow_sketch.rb`）から p5.rb 経由で呼んでいる。
