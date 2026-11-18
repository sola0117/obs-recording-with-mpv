local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error(string.format(
            "%s\nexpected: %s\nactual:   %s",
            message or "values differ",
            tostring(expected),
            tostring(actual)
        ))
    end
end

local timers = {}
local logs = {}
local frontend_callback

local obs = {
    LOG_INFO = 200,
    LOG_WARNING = 300,
    OBS_FRONTEND_EVENT_RECORDING_STOPPED = 1,
    OBS_PATH_FILE = 1,
    OBS_TEXT_DEFAULT = 1,
}

function obs.script_log(level, message)
    logs[#logs + 1] = { level = level, message = message }
end

function obs.timer_add(callback, interval)
    timers[callback] = interval
end

function obs.timer_remove(callback)
    timers[callback] = nil
end

function obs.remove_current_callback() end

function obs.obs_frontend_add_event_callback(callback)
    frontend_callback = callback
end

function obs.obs_frontend_remove_event_callback(callback)
    if frontend_callback == callback then frontend_callback = nil end
end

local last_recording
function obs.obs_frontend_get_last_recording()
    return last_recording
end

function obs.obs_data_get_int(settings, key) return settings[key] end
function obs.obs_data_get_string(settings, key) return settings[key] end
function obs.obs_data_get_bool(settings, key) return settings[key] end

-- script_defaults/script_properties用の最小スタブ
function obs.obs_data_set_default_int() end
function obs.obs_data_set_default_string() end
function obs.obs_data_set_default_bool() end
function obs.obs_properties_create() return {} end
function obs.obs_properties_add_int() end
function obs.obs_properties_add_path() end
function obs.obs_properties_add_bool() end
function obs.obs_properties_add_text() end

_G.obslua = obs

local server = { clients = {} }

function server:listen() end
function server:set_blocking() end
function server:close() end
function server:accept()
    return table.remove(self.clients, 1)
end

local function new_http_client(request)
    local client = { request = request, response = nil }
    function client:set_blocking() end
    function client:receive()
        local value = self.request
        self.request = nil
        if value then return value end
        return nil, "tryagain"
    end
    function client:send(response)
        self.response = response
        return #response
    end
    function client:close() end
    return client
end

package.loaded.ljsocket = {
    bind = function() return server end,
}

local files = {
    ["C:\\Tools\\mpv.exe"] = true,
    ["C:\\Recordings\\original.mkv"] = true,
}
local moves = {}
local pipes = {}
local connected_pipe_name
local current_time = 1000
local connect_available = true
local launched = false
local launch_arguments

local function new_pipe()
    local pipe = { writes = {}, chunks = {}, closed = false }
    function pipe:write_line(line)
        self.writes[#self.writes + 1] = line
        return true
    end
    function pipe:read_available()
        return table.remove(self.chunks, 1) or ""
    end
    function pipe:close()
        self.closed = true
    end
    pipes[#pipes + 1] = pipe
    return pipe
end

package.loaded.mpv_control = {
    is_supported = function() return true end,
    file_exists = function(path) return files[path] == true end,
    move_file = function(source, destination)
        if not files[source] or files[destination] then return false, 183 end
        files[source] = nil
        files[destination] = true
        moves[#moves + 1] = { source = source, destination = destination }
        return true
    end,
    monitor_count = function() return 2 end,
    now_ms = function() return current_time end,
    launch = function(_, arguments)
        launched = true
        launch_arguments = arguments
        return true, 4321
    end,
    connect = function(pipe_name)
        connected_pipe_name = pipe_name
        if not connect_available and not launched then return nil, 2 end
        return new_pipe()
    end,
}

dofile("open-recording-with-mpv.lua")

local settings = {
    server_port = 4050,
    mpv_executable = "C:\\Tools\\mpv.exe",
    playback_monitor = 1,
    auto_playback = true,
    ipc_pipe = "mpvsocket",
    delay_ms = 0,
    enabled = true,
}

script_update(settings)
script_load(settings)

local http_poll
for callback, interval in pairs(timers) do
    if interval == 100 then http_poll = callback end
end
assert(http_poll, "HTTP poll timer was not registered")

local set_client = new_http_client(
    "POST /set HTTP/1.1\r\nContent-Type: application/json\r\n\r\n" ..
    '{"filename":"テスト (A)","take":1}'
)
server.clients[#server.clients + 1] = set_client
http_poll()
assert(set_client.response and set_client.response:find("200 OK", 1, true), "dock set failed")

last_recording = "C:\\Recordings\\original.mkv"
frontend_callback(obs.OBS_FRONTEND_EVENT_RECORDING_STOPPED)

assert_equal(#moves, 1, "recording should be renamed once")
local renamed_path = "C:\\Recordings/テスト (A)_t01.mkv"
assert_equal(moves[1].destination, renamed_path, "take filename differs")
assert_equal(connected_pipe_name, "\\\\.\\pipe\\mpvsocket", "pipe name was not normalized")

local playback_timer
for callback, interval in pairs(timers) do
    if interval == 50 then playback_timer = callback end
end
assert(playback_timer, "playback timer was not registered")

local pipe = pipes[#pipes]
pipe.chunks[#pipe.chunks + 1] = table.concat({
    '{"request_id":1,"error":"success"}',
    '{"request_id":2,"error":"success"}',
    '{"request_id":3,"error":"success"}',
    '{"request_id":4,"error":"success"}',
    '{"request_id":5,"error":"success"}',
    '{"request_id":10,"error":"success"}',
    '{"event":"file-loaded"}',
    '{"request_id":31,"error":"success"}',
    '{"request_id":32,"error":"success"}',
    '{"data":true,"request_id":33,"error":"success"}',
    '{"data":"C:\\\\Recordings/テスト (A)_t01.mkv","request_id":34,"error":"success"}',
}, "\n") .. "\n"
playback_timer()

assert(pipe.closed, "IPC connection should close after verification")
local writes = table.concat(pipe.writes, "\n")
assert(writes:find('"fs-screen",1', 1, true), "monitor property was not set")
assert(writes:find('"loadfile","C:\\\\Recordings/テスト (A)_t01.mkv","replace"', 1, true),
       "renamed recording was not loaded")
assert(writes:find('"seek",0,"absolute+exact"', 1, true), "first-frame seek was not sent")
assert(writes:find('"get_property","pause"', 1, true), "pause was not verified")

local state_client = new_http_client("GET /state HTTP/1.1\r\n\r\n")
server.clients[#server.clients + 1] = state_client
http_poll()
assert(state_client.response:find('"take":2', 1, true), "take number was not incremented")

-- Auto Playbackを無効にしてもリネーム処理は行い、衝突時は上書きしない。
settings.auto_playback = false
script_update(settings)
files["C:\\Recordings\\second.mkv"] = true
files["C:\\Recordings/テスト (A)_t02.mkv"] = true
last_recording = "C:\\Recordings\\second.mkv"
frontend_callback(obs.OBS_FRONTEND_EVENT_RECORDING_STOPPED)
assert(files["C:\\Recordings\\second.mkv"], "source recording was lost on collision")
assert_equal(#moves, 1, "collision must not overwrite destination")

state_client = new_http_client("GET /state HTTP/1.1\r\n\r\n")
server.clients[#server.clients + 1] = state_client
http_poll()
assert(state_client.response:find('"take":3', 1, true), "take number should advance after collision")

-- IPCが存在しない場合はmpvを直接起動し、起動後のpath応答で準備を完了する。
settings.auto_playback = true
script_update(settings)
set_client = new_http_client(
    "POST /set HTTP/1.1\r\nContent-Type: application/json\r\n\r\n" ..
    '{"filename":"","take":1}'
)
server.clients[#server.clients + 1] = set_client
http_poll()

local new_path = "C:\\new folder\\新規 (3).mkv"
files[new_path] = true
last_recording = new_path
connect_available = false
launched = false
launch_arguments = nil
current_time = 5000
frontend_callback(obs.OBS_FRONTEND_EVENT_RECORDING_STOPPED)

for callback, interval in pairs(timers) do
    if interval == 50 then playback_timer = callback end
end
assert(playback_timer, "new-instance playback timer was not registered")
current_time = 5300
playback_timer()
assert(launched, "mpv was not launched after the IPC probe")
local launch_command = table.concat(launch_arguments, "\n")
assert(launch_command:find("--fullscreen", 1, true), "fullscreen launch option is missing")
assert(launch_command:find("--fs-screen=1", 1, true), "monitor launch option is missing")
assert(launch_command:find("--input-ipc-server=\\\\.\\pipe\\mpvsocket", 1, true),
       "IPC launch option is missing")
assert_equal(launch_arguments[#launch_arguments], new_path, "Unicode launch path differs")

current_time = 5400
playback_timer() -- 起動したmpvへ接続
pipe = pipes[#pipes]
pipe.chunks[#pipe.chunks + 1] = table.concat({
    '{"request_id":1,"error":"success"}',
    '{"request_id":2,"error":"success"}',
    '{"request_id":3,"error":"success"}',
    '{"request_id":4,"error":"success"}',
    '{"request_id":5,"error":"success"}',
    '{"data":"C:\\\\new folder\\\\新規 (3).mkv","request_id":20,"error":"success"}',
    '{"request_id":31,"error":"success"}',
    '{"request_id":32,"error":"success"}',
    '{"data":true,"request_id":33,"error":"success"}',
    '{"data":"C:\\\\new folder\\\\新規 (3).mkv","request_id":34,"error":"success"}',
}, "\n") .. "\n"
playback_timer()
assert(pipe.closed, "new mpv IPC connection should close after verification")

script_unload()
print("ok")
