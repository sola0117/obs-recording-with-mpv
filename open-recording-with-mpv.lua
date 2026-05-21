-- open_recording_with_mpv.lua
-- 録画終了後に指定のps1ファイルを使ってmpvで動画を再生するOBSスクリプト
-- 必要OBSバージョン: 29.0.0以上 (obs_frontend_get_last_recording使用)

obs = obslua

-- スクリプト設定のデフォルト値
local ps1_path       = ""   -- 起動オプションを仕込んだps1ファイルのフルパス
local delay_ms       = 2000 -- 録画停止からmpv起動までの遅延（ミリ秒）
                             -- mkv→mp4リマックス等の後処理がある場合は長めに設定
local enabled        = true -- スクリプトの有効/無効トグル
local preset_filename = ""  -- 録画ファイルのリネーム先ファイル名（拡張子なし、空欄でスキップ）

-- ---------------------------------------------------------------
-- ユーティリティ
-- ---------------------------------------------------------------

--- パスをダブルクォートで囲む（スペース対策）
local function q(path)
    return '"' .. path .. '"'
end

--- ログ出力ヘルパー
local function log(msg)
    obs.script_log(obs.LOG_INFO, msg)
end

local function warn(msg)
    obs.script_log(obs.LOG_WARNING, msg)
end

-- ---------------------------------------------------------------
-- mpv起動
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

    -- PowerShell呼び出しコマンドを組み立てる
    -- ps1ファイルへ動画パスを引数として渡す
    -- -WindowStyle Hidden: PowerShellウィンドウを非表示
    -- Start-Process powershell で呼ぶことでOBSをブロックしない
    local cmd = string.format(
        'powershell.exe -NoProfile -WindowStyle Hidden -Command "Start-Process powershell -ArgumentList \'-NoProfile -ExecutionPolicy Bypass -File %s %s\' -WindowStyle Hidden"',
        q(ps1_path),
        q(video_path)
    )

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
        -- リネームが設定されていれば先に実行し、mpvには新しいパスを渡す
        local final_path = rename_recording(pending_path, preset_filename)
        launch_mpv(final_path)
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

    obs.obs_properties_add_text(
        props,
        "preset_filename",
        "録画ファイル名（拡張子なし、空欄でスキップ）",
        obs.OBS_TEXT_DEFAULT
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
    obs.obs_data_set_default_string(settings, "preset_filename", "")
    obs.obs_data_set_default_string(settings, "ps1_path",        "")
    obs.obs_data_set_default_int   (settings, "delay_ms",       2000)
    obs.obs_data_set_default_bool  (settings, "enabled",         true)
end

function script_update(settings)
    preset_filename = obs.obs_data_get_string(settings, "preset_filename")
    ps1_path        = obs.obs_data_get_string(settings, "ps1_path")
    delay_ms        = obs.obs_data_get_int   (settings, "delay_ms")
    enabled         = obs.obs_data_get_bool  (settings, "enabled")

    log(string.format(
        "設定を更新しました: preset=%s, ps1=%s, delay=%dms, enabled=%s",
        preset_filename, ps1_path, delay_ms, tostring(enabled)
    ))
end

-- ---------------------------------------------------------------
-- スクリプトの説明
-- ---------------------------------------------------------------

function script_description()
    return [[<b>録画終了後にmpvで再生</b><br><br>
録画が終了すると、指定したPowerShellスクリプト (.ps1) を使ってmpvを起動し、
録画した動画を再生します。<br><br>
<b>録画ファイル名について:</b><br>
「録画ファイル名」に値を入力しておくと、録画終了後に自動でリネームします。<br>
拡張子は元のファイルと同じものが使われます。空欄の場合はリネームをスキップします。<br><br>
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
    log("open_recording_with_mpv.lua を読み込みました")
end

function script_unload()
    obs.obs_frontend_remove_event_callback(on_obs_frontend_event)
    pending_path = nil
    log("open_recording_with_mpv.lua をアンロードしました")
end