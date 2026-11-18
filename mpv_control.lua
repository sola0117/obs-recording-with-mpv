-- Windows向けmpvプロセス起動・名前付きパイプ通信ヘルパー。
-- OBS同梱のLuaJIT FFIだけを使用し、外部ランタイムを必要としない。

local ffi = require("ffi")
local bit = require("bit")

local M = {}

local is_windows = ffi.os == "Windows"

local function windows_quote_arg(value)
    value = tostring(value)
    local out = {'"'}
    local backslashes = 0

    for i = 1, #value do
        local ch = value:sub(i, i)
        if ch == "\\" then
            backslashes = backslashes + 1
        elseif ch == '"' then
            out[#out + 1] = string.rep("\\", backslashes * 2 + 1)
            out[#out + 1] = '"'
            backslashes = 0
        else
            if backslashes > 0 then
                out[#out + 1] = string.rep("\\", backslashes)
                backslashes = 0
            end
            out[#out + 1] = ch
        end
    end

    if backslashes > 0 then
        out[#out + 1] = string.rep("\\", backslashes * 2)
    end
    out[#out + 1] = '"'
    return table.concat(out)
end

M.windows_quote_arg = windows_quote_arg

if not is_windows then
    function M.is_supported() return false end
    function M.file_exists() return false end
    function M.move_file() return false, "Windowsでのみ利用できます" end
    function M.monitor_count() return 0 end
    function M.now_ms() return math.floor(os.clock() * 1000) end
    function M.launch() return false, "Windowsでのみ利用できます" end
    function M.connect() return nil, "Windowsでのみ利用できます" end
    return M
end

ffi.cdef([[
typedef struct {
    unsigned long cb;
    uint16_t *lpReserved;
    uint16_t *lpDesktop;
    uint16_t *lpTitle;
    unsigned long dwX;
    unsigned long dwY;
    unsigned long dwXSize;
    unsigned long dwYSize;
    unsigned long dwXCountChars;
    unsigned long dwYCountChars;
    unsigned long dwFillAttribute;
    unsigned long dwFlags;
    unsigned short wShowWindow;
    unsigned short cbReserved2;
    unsigned char *lpReserved2;
    void *hStdInput;
    void *hStdOutput;
    void *hStdError;
} ORWM_STARTUPINFOW;

typedef struct {
    void *hProcess;
    void *hThread;
    unsigned long dwProcessId;
    unsigned long dwThreadId;
} ORWM_PROCESS_INFORMATION;

int MultiByteToWideChar(unsigned int CodePage, unsigned long dwFlags,
                        const char *lpMultiByteStr, int cbMultiByte,
                        uint16_t *lpWideCharStr, int cchWideChar);
void *CreateFileW(const uint16_t *lpFileName, unsigned long dwDesiredAccess,
                  unsigned long dwShareMode, void *lpSecurityAttributes,
                  unsigned long dwCreationDisposition,
                  unsigned long dwFlagsAndAttributes, void *hTemplateFile);
int WriteFile(void *hFile, const void *lpBuffer, unsigned long nNumberOfBytesToWrite,
              unsigned long *lpNumberOfBytesWritten, void *lpOverlapped);
int ReadFile(void *hFile, void *lpBuffer, unsigned long nNumberOfBytesToRead,
             unsigned long *lpNumberOfBytesRead, void *lpOverlapped);
int PeekNamedPipe(void *hNamedPipe, void *lpBuffer, unsigned long nBufferSize,
                  unsigned long *lpBytesRead, unsigned long *lpTotalBytesAvail,
                  unsigned long *lpBytesLeftThisMessage);
int CloseHandle(void *hObject);
unsigned long GetLastError(void);
unsigned long GetFileAttributesW(const uint16_t *lpFileName);
int MoveFileW(const uint16_t *lpExistingFileName, const uint16_t *lpNewFileName);
int GetSystemMetrics(int nIndex);
uint64_t GetTickCount64(void);
int CreateProcessW(const uint16_t *lpApplicationName, uint16_t *lpCommandLine,
                   void *lpProcessAttributes, void *lpThreadAttributes,
                   int bInheritHandles, unsigned long dwCreationFlags,
                   void *lpEnvironment, const uint16_t *lpCurrentDirectory,
                   ORWM_STARTUPINFOW *lpStartupInfo,
                   ORWM_PROCESS_INFORMATION *lpProcessInformation);
]])

local kernel32 = ffi.load("kernel32")
local user32 = ffi.load("user32")

local CP_UTF8 = 65001
local GENERIC_READ = 0x80000000
local GENERIC_WRITE = 0x40000000
local OPEN_EXISTING = 3
local INVALID_FILE_ATTRIBUTES = 0xffffffff
local FILE_ATTRIBUTE_DIRECTORY = 0x10
local CREATE_NO_WINDOW = 0x08000000
local CREATE_UNICODE_ENVIRONMENT = 0x00000400
local SM_CMONITORS = 80
local invalid_handle = ffi.cast("void *", -1)

local function to_wide(value)
    value = tostring(value)
    local length = kernel32.MultiByteToWideChar(CP_UTF8, 0, value, #value, nil, 0)
    if length <= 0 then
        return nil, tonumber(kernel32.GetLastError())
    end

    local buffer = ffi.new("uint16_t[?]", length + 1)
    local converted = kernel32.MultiByteToWideChar(CP_UTF8, 0, value, #value, buffer, length)
    if converted ~= length then
        return nil, tonumber(kernel32.GetLastError())
    end
    buffer[length] = 0
    return buffer
end

function M.is_supported()
    return true
end

function M.file_exists(path)
    local wide_path = to_wide(path)
    if not wide_path then return false end
    local attributes = tonumber(kernel32.GetFileAttributesW(wide_path))
    return attributes ~= INVALID_FILE_ATTRIBUTES
       and bit.band(attributes, FILE_ATTRIBUTE_DIRECTORY) == 0
end

function M.move_file(source, destination)
    local wide_source, source_error = to_wide(source)
    if not wide_source then return false, source_error end
    local wide_destination, destination_error = to_wide(destination)
    if not wide_destination then return false, destination_error end

    if kernel32.MoveFileW(wide_source, wide_destination) == 0 then
        return false, tonumber(kernel32.GetLastError())
    end
    return true
end

function M.monitor_count()
    return tonumber(user32.GetSystemMetrics(SM_CMONITORS))
end

function M.now_ms()
    return tonumber(kernel32.GetTickCount64())
end

function M.launch(executable, arguments)
    local command = { windows_quote_arg(executable) }
    for _, argument in ipairs(arguments) do
        command[#command + 1] = windows_quote_arg(argument)
    end

    local wide_executable, executable_error = to_wide(executable)
    if not wide_executable then return false, executable_error end
    local wide_command, command_error = to_wide(table.concat(command, " "))
    if not wide_command then return false, command_error end

    local startup_info = ffi.new("ORWM_STARTUPINFOW")
    startup_info.cb = ffi.sizeof(startup_info)
    local process_info = ffi.new("ORWM_PROCESS_INFORMATION")
    local flags = bit.bor(CREATE_NO_WINDOW, CREATE_UNICODE_ENVIRONMENT)

    local ok = kernel32.CreateProcessW(
        wide_executable,
        wide_command,
        nil,
        nil,
        0,
        flags,
        nil,
        nil,
        startup_info,
        process_info
    )
    if ok == 0 then
        return false, tonumber(kernel32.GetLastError())
    end

    kernel32.CloseHandle(process_info.hThread)
    kernel32.CloseHandle(process_info.hProcess)
    return true, tonumber(process_info.dwProcessId)
end

local PipeClient = {}
PipeClient.__index = PipeClient

function PipeClient:write_line(line)
    if not self.handle then return false, "pipe closed" end
    local data = tostring(line) .. "\n"
    local offset = 0

    while offset < #data do
        local written = ffi.new("unsigned long[1]")
        local ptr = ffi.cast("const unsigned char *", data) + offset
        if kernel32.WriteFile(self.handle, ptr, #data - offset, written, nil) == 0 then
            return false, tonumber(kernel32.GetLastError())
        end
        local count = tonumber(written[0])
        if count <= 0 then return false, "zero-byte write" end
        offset = offset + count
    end
    return true
end

function PipeClient:read_available()
    if not self.handle then return nil, "pipe closed" end
    local available = ffi.new("unsigned long[1]")
    if kernel32.PeekNamedPipe(self.handle, nil, 0, nil, available, nil) == 0 then
        return nil, tonumber(kernel32.GetLastError())
    end

    local count = math.min(tonumber(available[0]), 65536)
    if count == 0 then return "" end

    local buffer = ffi.new("unsigned char[?]", count)
    local bytes_read = ffi.new("unsigned long[1]")
    if kernel32.ReadFile(self.handle, buffer, count, bytes_read, nil) == 0 then
        return nil, tonumber(kernel32.GetLastError())
    end
    return ffi.string(buffer, tonumber(bytes_read[0]))
end

function PipeClient:close()
    if self.handle then
        kernel32.CloseHandle(self.handle)
        self.handle = nil
    end
end

function M.connect(pipe_name)
    local wide_name, conversion_error = to_wide(pipe_name)
    if not wide_name then return nil, conversion_error end
    local access = bit.bor(GENERIC_READ, GENERIC_WRITE)
    local handle = kernel32.CreateFileW(wide_name, access, 0, nil, OPEN_EXISTING, 0, nil)
    if handle == invalid_handle then
        return nil, tonumber(kernel32.GetLastError())
    end
    return setmetatable({ handle = handle }, PipeClient)
end

return M
