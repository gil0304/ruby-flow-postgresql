# 実装フェーズ
P0 環境: Ruby 3.4.1、bundle lock、p5.rb最小スケッチの実ブラウザ表示、WASMバージョン確認、依存ライセンス記録。
P1 描画: Ruby側ノード・粒子・再生状態、fixtureを明記してテスト、マウス/キーボード。
P2 CRUD: Sinatra/ActiveRecord/PostgreSQL/ERB、実DB、入力検証・エスケープ、Rackテスト。
P3 Collector: Rack/TracePoint/SQL/ERB、相関ID、安全なイベントストア・API。実計測テスト。
P4 統合: polling、アニメーション、ソースハイライト、実データ、タイムライン、切断/gap、POST→GET。
P5 品質: 全受入、スクリーンショット、性能計測、README、再現可能な起動。ここまでがMVP。
P6 拡張: Gem化、既存Sinatraアプリ導入、Rails対応は別途設計・承認。
各フェーズで STATUS.md にチェック、実行コマンド、テスト結果、未達理由を追記。P0 が未達でも独立作業は継続可、実環境合格は保留。

P0で原本の設定ハッシュ、Gemfile制約、PostgreSQL 接続と専用テストDBを確認する。P2で追加マイグレーションを専用DBに適用し、P5で原本設定の同一性を再検証する。接続不可なら設定変更で回避せず未達とする。
