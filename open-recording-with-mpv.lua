-- open-recording-with-mpv.lua
-- 録画終了後にmpvを直接起動またはJSON IPC経由で再利用するOBSスクリプト
-- 必要OBSバージョン: 29.0.0以上 (obs_frontend_get_last_recording使用)

obs = obslua

local mpv_control = require("mpv_control")

-- スクリプト設定のデフォルト値
local mpv_executable  = ""                        -- mpv.exeのフルパス
local playback_monitor = 0                        -- mpvのモニター番号（0始まり）
local auto_playback   = true                      -- 録画終了後の自動プレイバック
local ipc_pipe        = "\\\\.\\pipe\\mpvsocket" -- mpv JSON IPCの名前付きパイプ
local delay_ms        = 2000                      -- 録画停止から後処理までの遅延（ミリ秒）
local enabled         = true                      -- スクリプトの有効/無効トグル
local preset_filename = ""                        -- 録画ファイルのリネーム先ファイル名（拡張子なし、空欄でスキップ）
local take_number     = 1                         -- テイク番号（録画終了ごとに自動インクリメント）
local state_ver       = 0                         -- 状態変化を通知するバージョン番号
local server_port     = 4050                      -- ブラウザドック連携用ローカルHTTPサーバーのポート番号

-- HTTPサーバー状態
local http_server     = nil
local pending_clients = {}

-- ---------------------------------------------------------------
-- ユーティリティ
-- ---------------------------------------------------------------

--- ログ出力ヘルパー
local function log(msg)
    obs.script_log(obs.LOG_INFO, msg)
end

local function warn(msg)
    obs.script_log(obs.LOG_WARNING, msg)
end

local function json_escape(value)
    return tostring(value)
        :gsub("\\", "\\\\")
        :gsub('"', '\\"')
        :gsub("\b", "\\b")
        :gsub("\f", "\\f")
        :gsub("\n", "\\n")
        :gsub("\r", "\\r")
        :gsub("\t", "\\t")
        :gsub("[%z\1-\31]", function(ch)
            return string.format("\\u%04x", ch:byte())
        end)
end

local function json_unescape(value)
    local function utf8_char(codepoint)
        if codepoint <= 0x7f then
            return string.char(codepoint)
        elseif codepoint <= 0x7ff then
            return string.char(
                0xc0 + math.floor(codepoint / 0x40),
                0x80 + codepoint % 0x40
            )
        elseif codepoint <= 0xffff then
            return string.char(
                0xe0 + math.floor(codepoint / 0x1000),
                0x80 + math.floor(codepoint / 0x40) % 0x40,
                0x80 + codepoint % 0x40
            )
        end
        return string.char(
            0xf0 + math.floor(codepoint / 0x40000),
            0x80 + math.floor(codepoint / 0x1000) % 0x40,
            0x80 + math.floor(codepoint / 0x40) % 0x40,
            0x80 + codepoint % 0x40
        )
    end

    local escapes = {
        ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
        b = "\b", f = "\f", n = "\n", r = "\r", t = "\t",
    }
    local out = {}
    local i = 1
    while i <= #value do
        local ch = value:sub(i, i)
        if ch ~= "\\" or i == #value then
            out[#out + 1] = ch
            i = i + 1
        else
            local escaped = value:sub(i + 1, i + 1)
            if escaped == "u" then
                local first = tonumber(value:sub(i + 2, i + 5), 16)
                if first then
                    i = i + 6
                    if first >= 0xd800 and first <= 0xdbff
                       and value:sub(i, i + 1) == "\\u" then
                        local second = tonumber(value:sub(i + 2, i + 5), 16)
                        if second and second >= 0xdc00 and second <= 0xdfff then
                            first = 0x10000 + (first - 0xd800) * 0x400 + second - 0xdc00
                            i = i + 6
                        end
                    end
                    out[#out + 1] = utf8_char(first)
                else
                    out[#out + 1] = "\\u"
                    i = i + 2
                end
            else
                out[#out + 1] = escapes[escaped] or escaped
                i = i + 2
            end
        end
    end
    return table.concat(out)
end

local function normalize_pipe_name(value)
    value = tostring(value or "")
    if value == "" then return "\\\\.\\pipe\\mpvsocket" end
    if value:sub(1, 9):lower() == "\\\\.\\pipe\\" then return value end
    return "\\\\.\\pipe\\" .. value
end

local function normalized_windows_path(value)
    return tostring(value):gsub("/", "\\"):lower()
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
            json_escape(preset_filename), take_number, state_ver
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

--- ファイルをリネームし、新しいパスと成否を返す。失敗時は元のパスを返す。
--- @param orig_path string  元のファイルパス
--- @param new_name  string  新しいファイル名（拡張子なし）
local function rename_recording(orig_path, new_name)
    if new_name == "" then return orig_path, true end

    local dir  = dirname(orig_path)
    local ext  = extname(orig_path)
    local dest = dir .. "/" .. new_name .. ext

    -- 同名ファイルが既に存在する場合はリネームをスキップ
    if mpv_control.file_exists(dest) then
        warn("リネーム先に同名ファイルが存在するためスキップします: " .. dest)
        return orig_path, false
    end

    -- MoveFileWを使い、日本語を含むパスでもANSIコードページに依存しない。
    -- MoveFileWは既存ファイルを上書きしないため、存在確認との競合時も安全に失敗する。
    local ok, err = mpv_control.move_file(orig_path, dest)
    if not ok then
        warn("リネームに失敗しました (Windows error=" .. tostring(err) .. "): " .. orig_path)
        return orig_path, false
    end

    log("リネーム完了: " .. orig_path .. " → " .. dest)
    return dest, true
end

-- ---------------------------------------------------------------
-- mpv直接起動・JSON IPC
-- ---------------------------------------------------------------

local IPC_POLL_MS = 50
local IPC_PROBE_MS = 300
local IPC_STARTUP_TIMEOUT_MS = 8000
local IPC_LOAD_TIMEOUT_MS = 15000

local playback_job = nil
local playback_timer_running = false
local playback_tick

local function stop_playback_timer()
    if playback_timer_running then
        obs.timer_remove(playback_tick)
        playback_timer_running = false
    end
end

local function close_playback_pipe(job)
    if job and job.client then
        job.client:close()
        job.client = nil
    end
end

local function fail_playback(message)
    warn(message)
    close_playback_pipe(playback_job)
    playback_job = nil
    stop_playback_timer()
end

local function complete_playback()
    local reused = playback_job and playback_job.reused
    close_playback_pipe(playback_job)
    playback_job = nil
    stop_playback_timer()
    log(reused and "既存mpvへのプレイバック準備が完了しました"
               or "新規mpvのプレイバック準備が完了しました")
end

local function send_ipc(job, command, request_id)
    local payload = string.format(
        '{"command":%s,"request_id":%d}',
        command,
        request_id
    )
    local ok, err = job.client:write_line(payload)
    if not ok then
        fail_playback("mpv IPCへの送信に失敗しました: " .. tostring(err))
        return false
    end
    return true
end

local function path_matches(expected, actual)
    return normalized_windows_path(expected) == normalized_windows_path(actual)
end

local function parse_json_string_data(line)
    local value = line:match('"data"%s*:%s*"(.-)"%s*[,}]')
    if value == nil then return nil end
    return json_unescape(value)
end

local function check_playback_verified(job)
    if job.phase == "verifying"
       and job.seek_ok
       and job.pause_set_ok
       and job.pause_verified
       and job.path_verified then
        complete_playback()
    end
end

local function verify_loaded_file(job)
    if job.phase == "verifying" then return end
    job.phase = "verifying"
    job.deadline = mpv_control.now_ms() + IPC_LOAD_TIMEOUT_MS
    job.seek_ok = false
    job.pause_set_ok = false
    job.pause_verified = false
    job.path_verified = false
    job.playback_restart_seen = false

    -- file-loaded後に先頭へ正確にシークし、一時停止状態を応答で確認する。
    if not send_ipc(job, '["seek",0,"absolute+exact"]', 31) then return end
    if not send_ipc(job, '["set_property","pause",true]', 32) then return end
    if not send_ipc(job, '["get_property","pause"]', 33) then return end
    send_ipc(job, '["get_property","path"]', 34)
end

local function set_playback_mode(job)
    if not send_ipc(job, '["set_property","pause",true]', 1) then return false end
    if not send_ipc(job, '["set_property","loop-file","no"]', 2) then return false end
    if not send_ipc(job, '["set_property","keep-open","yes"]', 3) then return false end
    if not send_ipc(job, string.format('["set_property","fs-screen",%d]', playback_monitor), 4) then
        return false
    end
    return send_ipc(job, '["set_property","fullscreen",true]', 5)
end

local function use_existing_mpv(job)
    job.reused = true
    job.phase = "waiting-file-loaded"
    job.deadline = mpv_control.now_ms() + IPC_LOAD_TIMEOUT_MS
    if not set_playback_mode(job) then return end
    send_ipc(
        job,
        string.format('["loadfile","%s","replace"]', json_escape(job.path)),
        10
    )
end

local function verify_new_mpv(job)
    job.reused = false
    job.phase = "waiting-new-file"
    job.deadline = mpv_control.now_ms() + IPC_LOAD_TIMEOUT_MS
    job.last_path_query = 0
    if not set_playback_mode(job) then return end
end

local function launch_new_mpv(job)
    if mpv_executable == "" then
        fail_playback("mpv.exeのパスが設定されていません。スクリプト設定を確認してください。")
        return
    end
    if not mpv_control.file_exists(mpv_executable) then
        fail_playback("mpv.exeが見つかりません: " .. mpv_executable)
        return
    end

    local arguments = {
        "--fullscreen",
        "--fs-screen=" .. tostring(playback_monitor),
        "--pause=yes",
        "--keep-open=yes",
        "--loop-file=no",
        "--input-ipc-server=" .. ipc_pipe,
        "--",
        job.path,
    }
    local ok, result = mpv_control.launch(mpv_executable, arguments)
    if not ok then
        fail_playback("mpvを起動できませんでした (Windows error=" .. tostring(result) .. ")")
        return
    end

    log(string.format("mpvを直接起動しました (pid=%s): %s", tostring(result), job.path))
    job.phase = "waiting-startup"
    job.deadline = mpv_control.now_ms() + IPC_STARTUP_TIMEOUT_MS
    job.next_connect = 0
end

local function handle_ipc_line(job, line)
    local event = line:match('"event"%s*:%s*"([^"]+)"')
    if event == "file-loaded" then
        if job.phase == "waiting-file-loaded" or job.phase == "waiting-new-file" then
            verify_loaded_file(job)
        end
        return
    elseif event == "playback-restart" and job.phase == "verifying" then
        job.playback_restart_seen = true
        check_playback_verified(job)
        return
    elseif event == "shutdown" then
        fail_playback("プレイバック準備中にmpvが終了しました")
        return
    end

    local request_id = tonumber(line:match('"request_id"%s*:%s*(%d+)'))
    if not request_id then return end
    local ipc_error = line:match('"error"%s*:%s*"([^"]+)"')

    if request_id == 20 then
        if ipc_error == "success" then
            local actual_path = parse_json_string_data(line)
            if actual_path and path_matches(job.path, actual_path) then
                verify_loaded_file(job)
            end
        end
        return
    end

    if ipc_error ~= "success" then
        fail_playback(string.format(
            "mpv IPCコマンドが失敗しました (request_id=%d, error=%s)",
            request_id,
            tostring(ipc_error)
        ))
        return
    end

    if request_id == 31 then
        job.seek_ok = true
    elseif request_id == 32 then
        job.pause_set_ok = true
    elseif request_id == 33 then
        job.pause_verified = line:match('"data"%s*:%s*true') ~= nil
    elseif request_id == 34 then
        local actual_path = parse_json_string_data(line)
        job.path_verified = actual_path ~= nil and path_matches(job.path, actual_path)
        if not job.path_verified then
            fail_playback("mpvに読み込まれたファイルが要求した録画ファイルと一致しません")
            return
        end
    end
    check_playback_verified(job)
end

local function read_ipc(job)
    while playback_job == job and job.client do
        local chunk, err = job.client:read_available()
        if chunk == nil then
            fail_playback("mpv IPC接続が切断されました: " .. tostring(err))
            return
        end
        if chunk == "" then return end

        job.buffer = job.buffer .. chunk
        while true do
            local newline = job.buffer:find("\n", 1, true)
            if not newline then break end
            local line = job.buffer:sub(1, newline - 1):gsub("\r$", "")
            job.buffer = job.buffer:sub(newline + 1)
            handle_ipc_line(job, line)
            if playback_job ~= job then return end
        end
    end
end

playback_tick = function()
    local job = playback_job
    if not job then
        stop_playback_timer()
        return
    end

    local now = mpv_control.now_ms()
    if now > job.deadline then
        fail_playback("mpv IPCの応答がタイムアウトしました (phase=" .. job.phase .. ")")
        return
    end

    if job.phase == "probing" or job.phase == "waiting-startup" then
        if now >= job.next_connect then
            local client = mpv_control.connect(ipc_pipe)
            job.next_connect = now + 100
            if client then
                job.client = client
                job.buffer = ""
                if job.phase == "probing" then
                    use_existing_mpv(job)
                else
                    verify_new_mpv(job)
                end
            elseif job.phase == "probing" and now >= job.probe_deadline then
                launch_new_mpv(job)
            end
        end
    elseif job.phase == "waiting-new-file" then
        if now - job.last_path_query >= 250 then
            job.last_path_query = now
            if not send_ipc(job, '["get_property","path"]', 20) then return end
        end
        read_ipc(job)
    else
        read_ipc(job)
    end
end

local function begin_playback(video_path)
    if not mpv_control.is_supported() then
        warn("mpv直接起動はWindows版OBSでのみ利用できます")
        return
    end
    if not mpv_control.file_exists(video_path) then
        warn("プレイバック対象の録画ファイルが存在しません: " .. video_path)
        return
    end

    local monitor_count = mpv_control.monitor_count()
    if playback_monitor < 0 or playback_monitor >= monitor_count then
        warn(string.format(
            "指定されたmpvモニター番号 %d は利用できません（検出数: %d）。mpvはプライマリモニターへフォールバックします。",
            playback_monitor,
            monitor_count
        ))
    end

    if playback_job then
        warn("前回のプレイバック準備を中止し、最新の録画を読み込みます")
        close_playback_pipe(playback_job)
    end

    local now = mpv_control.now_ms()
    playback_job = {
        path = video_path,
        phase = "probing",
        deadline = now + IPC_PROBE_MS + 1000,
        probe_deadline = now + IPC_PROBE_MS,
        next_connect = 0,
        buffer = "",
    }
    if not playback_timer_running then
        obs.timer_add(playback_tick, IPC_POLL_MS)
        playback_timer_running = true
    end
    playback_tick()
end

-- ---------------------------------------------------------------
-- 録画後処理の遅延タイマー
-- ---------------------------------------------------------------

local pending_path = nil

local function process_recording(video_path)
    if not mpv_control.file_exists(video_path) then
        warn("録画ファイルが存在しません: " .. video_path)
        return
    end

    local new_name = ""
    if preset_filename ~= "" then
        new_name = preset_filename .. "_t" .. string.format("%02d", take_number)
    end
    local final_path = rename_recording(video_path, new_name)

    -- 既存仕様どおり、名前が設定された録画を処理した時点で次のテイクへ進む。
    if preset_filename ~= "" then
        take_number = take_number + 1
        state_ver = state_ver + 1
    end

    if auto_playback then
        begin_playback(final_path)
    end
end

local function on_timer()
    obs.remove_current_callback()
    if pending_path ~= nil then
        process_recording(pending_path)
        pending_path = nil
    end
end

--- 指定ミリ秒後に録画後処理を開始するタイマーをセット
local function schedule_launch(video_path, ms)
    obs.timer_remove(on_timer)
    pending_path = video_path

    if ms <= 0 then
        process_recording(video_path)
        pending_path = nil
    else
        obs.timer_add(on_timer, ms)
        log(string.format("%dms後に録画後処理を開始します...", ms))
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
        "mpv_executable",
        "MPV Executable Path (mpv.exe)",
        obs.OBS_PATH_FILE,
        "mpv executable (mpv.exe);;Executable files (*.exe)",
        nil
    )

    obs.obs_properties_add_int(
        props,
        "playback_monitor",
        "Playback Monitor (mpv番号・0始まり)",
        0,
        32,
        1
    )

    obs.obs_properties_add_bool(
        props,
        "auto_playback",
        "Auto Playback"
    )

    obs.obs_properties_add_text(
        props,
        "ipc_pipe",
        "IPC Pipe",
        obs.OBS_TEXT_DEFAULT
    )

    obs.obs_properties_add_int(
        props,
        "delay_ms",
        "Playback Delay / 録画後処理遅延（ミリ秒）",
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
    obs.obs_data_set_default_int   (settings, "server_port",      4050)
    obs.obs_data_set_default_string(settings, "mpv_executable",   "")
    obs.obs_data_set_default_int   (settings, "playback_monitor", 0)
    obs.obs_data_set_default_bool  (settings, "auto_playback",    true)
    obs.obs_data_set_default_string(settings, "ipc_pipe",         "\\\\.\\pipe\\mpvsocket")
    obs.obs_data_set_default_int   (settings, "delay_ms",         2000)
    obs.obs_data_set_default_bool  (settings, "enabled",          true)
end

function script_update(settings)
    local new_port  = obs.obs_data_get_int   (settings, "server_port")
    mpv_executable  = obs.obs_data_get_string(settings, "mpv_executable")
    playback_monitor = obs.obs_data_get_int  (settings, "playback_monitor")
    auto_playback   = obs.obs_data_get_bool  (settings, "auto_playback")
    ipc_pipe        = normalize_pipe_name(obs.obs_data_get_string(settings, "ipc_pipe"))
    delay_ms        = obs.obs_data_get_int   (settings, "delay_ms")
    enabled         = obs.obs_data_get_bool  (settings, "enabled")

    -- ポート番号が変わった場合はサーバーを再起動
    if new_port ~= server_port and http_server then
        server_port = new_port
        stop_server()
        start_server()
    else
        server_port = new_port
    end

    log(string.format(
        "設定を更新しました: port=%d, mpv=%s, monitor=%d, pipe=%s, delay=%dms, auto_playback=%s, enabled=%s",
        server_port,
        mpv_executable,
        playback_monitor,
        ipc_pipe,
        delay_ms,
        tostring(auto_playback),
        tostring(enabled)
    ))
end

-- ---------------------------------------------------------------
-- スクリプトの説明
-- ---------------------------------------------------------------

function script_description()
    return [[<b>録画終了後にmpvで再生</b><br><br>
録画が終了するとmpvを直接起動し、以後はJSON IPC経由で同じmpvウィンドウを再利用します。<br>
最初のフレームで一時停止し、その後の操作はremote_mpvなどのIPCクライアントへ委ねます。<br><br>
<b>ブラウザドック連携について:</b><br>
カスタムブラウザドックに http://127.0.0.1:4050/ を登録すると、
録画前にファイル名とテイク番号を設定できます。<br><br>
<b>Playback Monitor:</b><br>
mpvが使用する0始まりのモニター番号です。Windows設定画面の表示番号とは一致しない場合があります。<br><br>
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
    obs.timer_remove(on_timer)
    stop_playback_timer()
    close_playback_pipe(playback_job)
    playback_job = nil
    stop_server()
    obs.obs_frontend_remove_event_callback(on_obs_frontend_event)
    pending_path = nil
    log("open_recording_with_mpv.lua をアンロードしました")
end
