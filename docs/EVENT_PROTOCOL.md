# イベント契約 v1
JSON envelope: {"schema_version":1,"events":[],"next_cursor":0,"oldest_cursor":1,"gap":false}
各イベント: seq (単調増加整数), request_id (UUID), type, time_ms (monotonic基準), file (許可済み相対IDまたはnull), line (整数またはnull), payload (制限済みobject)。任意 span_id / parent_span_id / related_request_id。
種別: request.start, request.end, ruby.call, ruby.line, ruby.return, ruby.raise, sql.query, db.snapshot, erb.start, erb.expression, erb.end, response.redirect, response.html, trace.drop。
例（仕様説明用で実測ではない）:
```json
{"seq":12,"request_id":"demo-id","type":"sql.query","time_ms":18.2,"file":null,"line":null,"payload":{"operation":"INSERT","table":"posts","duration_ms":0.4}}
```
時系列は seq を正とする。HTTPリダイレクト先は別 request_id。関連付けは実際の相関根拠がある場合のみ。SQL終了通知だけなら往復時間は実測 duration として表示し、開始イベントを捏造しない。描画上の移動は説明用補間と明記。機密キーは再帰的に除去し、任意オブジェクトの inspect や to_json を呼ばない。
