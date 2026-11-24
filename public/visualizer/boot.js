// Ruby Flow 可視化の起動スクリプト。
// 役割は「起動・通信・DOM 連携」のみ。可視化のロジックと描画はすべて Ruby（p5.rb）側にある。
// - ruby.wasm を起動し、p5.rb と Ruby Flow の Ruby ファイルを評価する
// - p5.js のコールバックを Ruby の Bridge へ転送する
// - /__flow/events を polling し、受け取った JSON 文字列をそのまま Ruby に渡す
// - クリック/キー入力を Ruby の command に転送する
(async () => {
  "use strict";
  const $ = (id) => document.getElementById(id);
  const root = $("app-root");
  const setBoot = (message, state) => {
    $("boot-status").textContent = message;
    if (state) root.dataset.boot = state;
  };
  const showFatal = (message) => {
    setBoot(message, "error");
    console.error("[RubyFlow]", message);
  };

  let vm;
  let bridge;
  const call = (method, ...args) =>
    bridge.call(method, ...args.map((a) => vm.wrap(a === undefined || a === null ? "" : String(a))));

  try {
    const { DefaultRubyVM } = window["ruby-wasm-wasi"];
    setBoot("Ruby（WebAssembly）を読み込み中…", "loading");
    const res = await fetch("vendor/ruby-wasm/ruby+stdlib.wasm");
    if (!res.ok) throw new Error(`ruby+stdlib.wasm の取得に失敗しました（HTTP ${res.status}）`);
    const module = await WebAssembly.compile(await res.arrayBuffer());
    ({ vm } = await DefaultRubyVM(module));

    const rubyFiles = [
      "vendor/p5rb/p5.rb",
      "ruby/flow_model.rb",
      "ruby/flow_panels.rb",
      "ruby/flow_app.rb",
      "ruby/flow_sketch.rb",
      "ruby/flow_boot.rb",
    ];
    for (const file of rubyFiles) {
      const r = await fetch(file, { cache: "no-store" });
      if (!r.ok) throw new Error(`${file} の取得に失敗しました（HTTP ${r.status}）`);
      vm.eval(await r.text());
    }
    bridge = vm.eval("RubyFlowViz::Bridge.new");
    const rubyVersion = call("ruby_version").toString();
    window.__rubyFlowWasmRubyVersion = rubyVersion; // 検証用（表示は Ruby 側で行う）
    window.__rubyFlowFrames = () => Number(call("frames").toString()); // 性能確認用
    setBoot(`Ruby ${rubyVersion} (WASM) 起動完了`, "ready");
  } catch (e) {
    showFatal(`起動に失敗しました: ${e.message}`);
    return;
  }

  // 動きを減らす設定
  const motion = window.matchMedia("(prefers-reduced-motion: reduce)");
  call("set_reduced_motion", motion.matches ? "1" : "");

  // p5.js（インスタンスモード）→ Ruby
  new window.p5((p) => {
    vm.eval("P5").call("init", vm.wrap(p));
    const forward = (name) => () => {
      try {
        call(name);
      } catch (e) {
        p.noLoop();
        showFatal(`描画中にエラー（Ruby）: ${e.message}`);
      }
    };
    p.setup = forward("setup");
    p.draw = forward("draw");
    p.mousePressed = forward("mouse_pressed");
    p.windowResized = forward("window_resized");
  }, $("canvas-host"));

  // パネルの開閉などでキャンバス領域の大きさが変わったら Ruby 側に伝える
  let resizeTimer = null;
  new ResizeObserver(() => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => {
      try { call("window_resized"); } catch (e) { showFatal(`リサイズ処理でエラー（Ruby）: ${e.message}`); }
    }, 100);
  }).observe($("canvas-host"));

  // DOM → Ruby
  document.addEventListener("click", (ev) => {
    const el = ev.target.closest("[data-cmd]");
    if (!el) return;
    call("command", el.dataset.cmd, el.dataset.arg || "");
  });
  document.addEventListener("keydown", (ev) => {
    if (ev.metaKey || ev.ctrlKey || ev.altKey) return;
    if (ev.target.closest("input, textarea, select")) return;
    if (ev.target.closest("button, a") && (ev.key === " " || ev.key === "Enter")) return;
    if (call("command", "key", ev.key).toString() === "true") ev.preventDefault();
  });

  // ソース（許可されたファイルのみ）
  try {
    const list = await (await fetch("/__flow/source", { cache: "no-store" })).json();
    for (const f of list.files || []) {
      const r = await fetch(`/__flow/source?file=${encodeURIComponent(f.id)}`, { cache: "no-store" });
      if (r.ok) call("load_source", f.id, await r.text());
    }
  } catch (e) {
    call("connection_error", `ソースの取得に失敗しました（${e.message}）`);
  }

  // 計測状態（5 秒ごと）
  const health = async () => {
    try {
      const r = await fetch("/__flow/health", { cache: "no-store" });
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      call("health", await r.text());
    } catch (e) {
      call("connection_error", `状態の取得に失敗しました（${e.message}）`);
    }
    setTimeout(health, 5000);
  };
  health();

  // イベント polling（成功時 400ms、失敗時は最大 4 秒まで間隔を延ばす）
  let delay = 400;
  const poll = async () => {
    try {
      const cursor = call("cursor").toString();
      const r = await fetch(`/__flow/events?after=${encodeURIComponent(cursor)}`, { cache: "no-store" });
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      call("ingest", await r.text());
      delay = 400;
    } catch (e) {
      call("connection_error", `イベントの取得に失敗しました（${e.message}）。再接続を試みています`);
      delay = Math.min(delay * 2, 4000);
    }
    setTimeout(poll, delay);
  };
  poll();
})();
