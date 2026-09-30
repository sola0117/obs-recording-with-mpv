-- open_recording_with_mpv.lua
-- 録画終了後に指定のps1ファイルを使ってmpvで動画を再生するOBSスクリプト
-- 必要OBSバージョン: 29.0.0以上 (obs_frontend_get_last_recording使用)

obs = obslua

-- スクリプト設定のデフォルト値
local ps1_path       = ""   -- 起動オプションを仕込んだps1ファイルのフルパス
local delay_ms       = 2000 -- 録画停止からmpv起動までの遅延（ミリ秒）
                             -- mkv→mp4リマックス等の後処理がある場合は長めに設定
local enabled         = true -- スクリプトの有効/無効トグル
local preset_filename = ""   -- 録画ファイルのリネーム先ファイル名（拡張子なし、空欄でスキップ）
local take_number     = 1    -- テイク番号（録画終了ごとに自動インクリメント）
local state_ver       = 0    -- 状態変化を通知するバージョン番号
local server_port     = 4050 -- ブラウザドック連携用ローカルHTTPサーバーのポート番号

-- HTTPサーバー状態
local http_server     = nil
local pending_clients = {}

-- ---------------------------------------------------------------
-- ユーティリティ
-- ---------------------------------------------------------------

--- 文字列をBase64へ変換する。
--- PowerShellのコマンドラインへパスを直接埋め込まず、安全に受け渡すために使用する。
local function base64_encode(data)
    local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local result = {}

    for i = 1, #data, 3 do
        local a = data:byte(i)
        local b = data:byte(i + 1)
        local c = data:byte(i + 2)

        result[#result + 1] = alphabet:sub(math.floor(a / 4) + 1, math.floor(a / 4) + 1)
        result[#result + 1] = alphabet:sub(((a % 4) * 16 + math.floor((b or 0) / 16)) + 1,
                                           ((a % 4) * 16 + math.floor((b or 0) / 16)) + 1)

        if b then
            result[#result + 1] = alphabet:sub(((b % 16) * 4 + math.floor((c or 0) / 64)) + 1,
                                               ((b % 16) * 4 + math.floor((c or 0) / 64)) + 1)
        else
            result[#result + 1] = "="
        end

        if c then
            result[#result + 1] = alphabet:sub((c % 64) + 1, (c % 64) + 1)
        else
            result[#result + 1] = "="
        end
    end

    return table.concat(result)
end

--- PowerShellスクリプトを別プロセスで起動するコマンドを組み立てる。
--- パスはBase64化してPowerShell側で復元し、外側のシェルには直接渡さない。
local function build_launch_command(script_path, video_path)
    local script_b64 = base64_encode(script_path)
    local video_b64  = base64_encode(video_path)

    return string.format(
        'powershell.exe -NoProfile -WindowStyle Hidden -Command "' ..
        '$p=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(\'%s\'));' ..
        '$v=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(\'%s\'));' ..
        '$q=[char]34;' ..
        '$a=\'-NoProfile -ExecutionPolicy Bypass -File \'+$q+$p+$q+\' \'+$q+$v+$q;' ..
        'Start-Process -FilePath \'powershell.exe\' -ArgumentList $a -WindowStyle Hidden"',
        script_b64,
        video_b64
    )
end

--- ログ出力ヘルパー
local function log(msg)
    obs.script_log(obs.LOG_INFO, msg)
end

local function warn(msg)
    obs.script_log(obs.LOG_WARNING, msg)
end

-- ---------------------------------------------------------------
-- ローカル HTTP サーバー（ljsocket 経由、ブラウザドック連携）
-- ---------------------------------------------------------------

local function http_ok(body)
    local hdrs = table.concat({
        "HTTP/1.1 200 OK",
        "Content-Type: application/json",
        "Content-Length: " .. #body,
        "Access-Control-Allow-Origin: *",
        "Access-Control-Allow-Methods: POST, OPTIONS",
        "Access-Control-Allow-Headers: Content-Type",
        "Connection: close",
    }, "\r\n")
    return hdrs .. "\r\n\r\n" .. body
end

local function http_err(status, msg)
    local body = '{"error":"' .. msg .. '"}'
    local hdrs = table.concat({
        "HTTP/1.1 " .. status,
        "Content-Type: application/json",
        "Content-Length: " .. #body,
        "Access-Control-Allow-Origin: *",
        "Access-Control-Allow-Methods: POST, OPTIONS",
        "Access-Control-Allow-Headers: Content-Type",
        "Connection: close",
    }, "\r\n")
    return hdrs .. "\r\n\r\n" .. body
end

local DOCK_HTML = [[<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<title>録画ファイル名</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:"Segoe UI",sans-serif;background:#272a33;color:#fff;padding:10px}
label{display:block;font-size:11px;color:#969696;margin-bottom:4px}
input{padding:6px 8px;font-size:13px;background:#3C404D;color:#fff;border:1px solid #5B6273;border-radius:4px;outline:none}
input:focus{border-color:#284CB8}
.row{display:flex;gap:6px;align-items:center}
#f{flex:1}
#t{width:48px;text-align:center}
button{padding:7px 10px;font-size:13px;background:#3C404D;color:#fff;border:1px solid #3C404D;border-radius:4px;cursor:pointer;white-space:nowrap}
button:hover{background:#464B59;border-color:#5B6273}
button:active{background:#1D1F26}
.btn-row{display:flex;gap:6px;margin-top:6px}
#btn-set{flex:1}
#btn-dec,#btn-inc{width:36px}
#s{margin-top:6px;font-size:11px;color:#969696;min-height:16px}
#s.ok{color:#59D966}#s.err{color:#E85E75}
</style>
</head>
<body>
<div class="row" style="margin-bottom:4px">
  <label for="f" style="margin:0;flex:1">録画ファイル名（拡張子なし）</label>
  <label for="t" style="margin:0;color:#969696;font-size:11px">テイク</label>
</div>
<div class="row">
  <input type="text" id="f" placeholder="例: gameplay">
  <input type="text" id="t" value="01" maxlength="2">
</div>
<div class="btn-row">
  <button id="btn-set" onclick="doSet()">セット</button>
  <button id="btn-dec" onclick="adj(-1)">－</button>
  <button id="btn-inc" onclick="adj(+1)">＋</button>
</div>
<div id="s"></div>
<script>
const fi=()=>document.getElementById('f');
const ti=()=>document.getElementById('t');
const si=()=>document.getElementById('s');
function getTake(){return Math.max(1,parseInt(ti().value)||1);}
function setTakeDisplay(n){ti().value=String(n).padStart(2,'0');}
async function post(filename,take){
  return fetch('/set',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({filename,take})});
}
let lastFilename=null;
async function doSet(){
  const name=fi().value.trim();
  if(lastFilename!==null&&name!==lastFilename){setTakeDisplay(1);}
  lastFilename=name;
  const take=getTake();const s=si();
  s.textContent='送信中...';s.className='';
  try{
    const r=await post(name,take);
    if(r.ok){s.textContent=name===''?'クリアしました':'「'+name+'_t'+String(take).padStart(2,'0')+'」をセットしました';s.className='ok';}
    else{s.textContent='エラー: HTTP '+r.status;s.className='err';}
  }catch{s.textContent='接続失敗。スクリプトが起動しているか確認してください。';s.className='err';}
}
async function adj(d){
  const n=Math.max(1,getTake()+d);
  setTakeDisplay(n);
  await post(fi().value.trim(),n);
}
ti().addEventListener('change',()=>{setTakeDisplay(getTake());adj(0);});
fi().addEventListener('keydown',e=>{if(e.key==='Enter')doSet();});
// サーバーと定期同期（録画終了後の自動インクリメントを検知して自動セット）
let lastVer=-1;
setInterval(async()=>{
  try{
    const r=await fetch('/state');
    if(!r.ok)return;
    const d=await r.json();
    if(document.activeElement!==ti())setTakeDisplay(d.take);
    if(lastVer>=0&&d.ver!==lastVer){
      // 録画終了でインクリメントされたのでセットを自動実行
      await doSet();
    }
    lastVer=d.ver;
  }catch{}
},500);
</script>
</body>
</html>]]

local function http_html(body)
    local hdrs = table.concat({
        "HTTP/1.1 200 OK",
        "Content-Type: text/html; charset=utf-8",
        "Content-Length: " .. #body,
        "Connection: close",
    }, "\r\n")
    return hdrs .. "\r\n\r\n" .. body
end

local function handle_http(req)
    local method = req:match("^(%u+) ")
    if method == "OPTIONS" then return http_ok("") end

    if method == "GET" and req:match("^GET / ") then
        return http_html(DOCK_HTML)
    end

    if method == "GET" and req:match("^GET /state ") then
        local body = string.format(
            '{"filename":"%s","take":%d,"ver":%d}',
            preset_filename, take_number, state_ver
        )
        return http_ok(body)
    end

    if method == "POST" and req:match("^POST /set ") then
        local filename = req:match('"filename"%s*:%s*"([^"]*)"')
        local take     = req:match('"take"%s*:%s*(%d+)')
        if filename ~= nil then
            preset_filename = filename
        end
        if take ~= nil then
            take_number = math.max(1, tonumber(take))
        end
        log(string.format("ブラウザドックから設定: filename=\"%s\" take=%d", preset_filename, take_number))
        return http_ok('{"ok":true}')
    end

    return http_err("404 Not Found", "not found")
end

local function poll_server()
    if not http_server then return end

    local client = http_server:accept()
    if client then
        client:set_blocking(false)
        table.insert(pending_clients, { socket = client, buf = "", t = os.clock() })
    end

    local now = os.clock()
    local i = 1
    while i <= #pending_clients do
        local c = pending_clients[i]
        local remove = false

        if now - c.t > 3 then
            -- タイムアウト（3秒以内にリクエストが完了しなかった接続を破棄）
            remove = true
        else
            local data, err = c.socket:receive(4096)
            if data and #data > 0 then
                c.buf = c.buf .. data
                if c.buf:find("\r\n\r\n") then
                    c.socket:send(handle_http(c.buf))
                    remove = true
                end
            elseif err ~= "tryagain" then
                -- "closed" およびその他すべてのエラーで破棄
                remove = true
            end
        end

        if remove then
            pcall(function() c.socket:close() end)
            table.remove(pending_clients, i)
            i = i - 1
        end
        i = i + 1
    end
end

local function start_server()
    local ok, ljsocket = pcall(require, "ljsocket")
    if not ok then
        warn("ljsocket.lua が見つかりません。ブラウザドック連携は無効です。")
        return
    end

    local server, err = ljsocket.bind("127.0.0.1", tostring(server_port))
    if not server then
        warn("HTTPサーバーのバインドに失敗 (port=" .. server_port .. "): " .. tostring(err))
        return
    end

    server:listen(5)
    server:set_blocking(false)
    http_server = server
    obs.timer_add(poll_server, 100)
    log("HTTPサーバー起動: http://127.0.0.1:" .. server_port)
end

local function stop_server()
    obs.timer_remove(poll_server)
    for _, c in ipairs(pending_clients) do pcall(function() c.socket:close() end) end
    pending_clients = {}
    if http_server then
        http_server:close()
        http_server = nil
    end
end

-- ---------------------------------------------------------------
-- リネーム・mpv起動
-- ---------------------------------------------------------------

--- パスからディレクトリ部分を返す（末尾スラッシュなし）
local function dirname(path)
    return path:match("^(.*)[/\\][^/\\]*$") or "."
end

--- パスから拡張子（ドット含む）を返す
local function extname(path)
    return path:match("(%.[^./\\]+)$") or ""
end

--- ファイルをリネームし、新しいパスを返す。失敗時は元のパスを返す。
--- @param orig_path string  元のファイルパス
--- @param new_name  string  新しいファイル名（拡張子なし）
local function rename_recording(orig_path, new_name)
    if new_name == "" then return orig_path end

    local dir  = dirname(orig_path)
    local ext  = extname(orig_path)
    local dest = dir .. "/" .. new_name .. ext

    -- 同名ファイルが既に存在する場合はリネームをスキップ
    local f = io.open(dest, "r")
    if f ~= nil then
        f:close()
        warn("リネーム先に同名ファイルが存在するためスキップします: " .. dest)
        return orig_path
    end

    local ok, err = os.rename(orig_path, dest)
    if not ok then
        warn("リネームに失敗しました: " .. tostring(err))
        return orig_path
    end

    log("リネーム完了: " .. orig_path .. " → " .. dest)
    return dest
end

--- PowerShellスクリプト経由でmpvを起動する
--- @param video_path string  再生する動画ファイルのフルパス
local function launch_mpv(video_path)
    if ps1_path == "" then
        warn("ps1ファイルのパスが設定されていません。スクリプト設定を確認してください。")
        return
    end

    -- ps1ファイルの存在確認（Luaのio.openで代用）
    local f = io.open(ps1_path, "r")
    if f == nil then
        warn("ps1ファイルが見つかりません: " .. ps1_path)
        return
    end
    f:close()

    -- パスはbuild_launch_command内でBase64化してからPowerShell側で復元する。
    -- これにより、スペース、日本語、記号を含むOBS既定のファイル名も扱える。
    -- -WindowStyle Hidden: PowerShellウィンドウを非表示
    -- Start-Process powershell で呼ぶことでOBSをブロックしない
    local cmd = build_launch_command(ps1_path, video_path)

    log("mpvを起動します: " .. video_path)
    log("コマンド: " .. cmd)

    local ret = os.execute(cmd)
    if ret ~= 0 and ret ~= true then
        warn("コマンド実行に失敗しました (戻り値: " .. tostring(ret) .. ")")
    end
end

-- ---------------------------------------------------------------
-- 遅延タイマー（delay_sec後にmpvを起動）
-- ---------------------------------------------------------------

local pending_path = nil  -- 起動待ちのファイルパス

local function on_timer()
    obs.remove_current_callback()
    if pending_path ~= nil then
        local new_name = ""
        if preset_filename ~= "" then
            new_name = preset_filename .. "_t" .. string.format("%02d", take_number)
        end
        local final_path = rename_recording(pending_path, new_name)
        launch_mpv(final_path)
        if preset_filename ~= "" then
            take_number = take_number + 1
            state_ver   = state_ver + 1
        end
        pending_path = nil
    end
end

--- 指定ミリ秒後にmpvを起動するタイマーをセット
local function schedule_launch(video_path, ms)
    pending_path = video_path

    if ms <= 0 then
        -- 遅延なし：直接起動
        launch_mpv(video_path)
        pending_path = nil
    else
        obs.timer_add(on_timer, ms)
        log(string.format("%dms後にmpvを起動します...", ms))
    end
end

-- ---------------------------------------------------------------
-- OBS フロントエンドイベントハンドラ
-- ---------------------------------------------------------------

local function on_obs_frontend_event(event)
    if not enabled then return end

    if event == obs.OBS_FRONTEND_EVENT_RECORDING_STOPPED then
        -- OBS 29.0.0+: obs_frontend_get_last_recording() でファイルパスを取得
        local path = obs.obs_frontend_get_last_recording()

        if path == nil or path == "" then
            warn("録画ファイルのパスを取得できませんでした。OBS 29.0.0以上が必要です。")
            return
        end

        log("録画停止を検出: " .. path)
        schedule_launch(path, delay_ms)
    end
end

-- ---------------------------------------------------------------
-- スクリプト設定UI（Tools > Scripts のプロパティパネル）
-- ---------------------------------------------------------------

function script_properties()
    local props = obs.obs_properties_create()

    obs.obs_properties_add_int(
        props,
        "server_port",
        "ブラウザドック連携ポート番号",
        1024,  -- 最小
        65535, -- 最大
        1      -- ステップ
    )

    obs.obs_properties_add_path(
        props,
        "ps1_path",
        "PowerShellスクリプト (.ps1)",
        obs.OBS_PATH_FILE,
        "PowerShell Script (*.ps1)",
        nil
    )

    obs.obs_properties_add_int(
        props,
        "delay_ms",
        "起動遅延（ミリ秒）",
        0,     -- 最小
        60000, -- 最大（60秒）
        100    -- ステップ
    )

    obs.obs_properties_add_bool(
        props,
        "enabled",
        "スクリプトを有効にする"
    )

    return props
end

function script_defaults(settings)
    obs.obs_data_set_default_int   (settings, "server_port",  4050)
    obs.obs_data_set_default_string(settings, "ps1_path",     "")
    obs.obs_data_set_default_int   (settings, "delay_ms",     2000)
    obs.obs_data_set_default_bool  (settings, "enabled",      true)
end

function script_update(settings)
    local new_port = obs.obs_data_get_int   (settings, "server_port")
    ps1_path       = obs.obs_data_get_string(settings, "ps1_path")
    delay_ms       = obs.obs_data_get_int   (settings, "delay_ms")
    enabled        = obs.obs_data_get_bool  (settings, "enabled")

    -- ポート番号が変わった場合はサーバーを再起動
    if new_port ~= server_port and http_server then
        server_port = new_port
        stop_server()
        start_server()
    else
        server_port = new_port
    end

    log(string.format(
        "設定を更新しました: port=%d, ps1=%s, delay=%dms, enabled=%s",
        server_port, ps1_path, delay_ms, tostring(enabled)
    ))
end

-- ---------------------------------------------------------------
-- スクリプトの説明
-- ---------------------------------------------------------------

function script_description()
    return [[<b>録画終了後にmpvで再生</b><br><br>
録画が終了すると、指定したPowerShellスクリプト (.ps1) を使ってmpvを起動し、
録画した動画を再生します。<br><br>
<b>ブラウザドック連携について:</b><br>
filename-dock.html をカスタムブラウザドックに登録すると、
録画前にファイル名を素早くセットできます。<br>
ファイルを開く前に URL 欄に「file:///」+ フルパスを入力してください。<br><br>
<b>ps1ファイルの書き方例:</b><br>
<pre>param([string]$VideoPath)
& mpv $VideoPath --geometry=50% --ontop</pre>
<br>
<b>起動遅延について:</b><br>
録画後にリマックスやファイル名変更が行われる場合、
その処理が完了するまでの時間をミリ秒で設定してください。<br><br>
<b>必要なOBSバージョン: 29.0.0以上</b>]]
end

-- ---------------------------------------------------------------
-- スクリプトロード／アンロード
-- ---------------------------------------------------------------

function script_load(settings)
    obs.obs_frontend_add_event_callback(on_obs_frontend_event)
    start_server()
    log("open_recording_with_mpv.lua を読み込みました")
end

function script_unload()
    stop_server()
    obs.obs_frontend_remove_event_callback(on_obs_frontend_event)
    pending_path = nil
    log("open_recording_with_mpv.lua をアンロードしました")
end
