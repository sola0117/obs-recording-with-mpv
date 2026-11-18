local mpv_control = require("mpv_control")

local function assert_equal(actual, expected)
    if actual ~= expected then
        error(string.format("expected %q, got %q", expected, actual))
    end
end

assert_equal(mpv_control.windows_quote_arg("mpv.exe"), '"mpv.exe"')
assert_equal(
    mpv_control.windows_quote_arg("C:\\Program Files\\mpv\\mpv.exe"),
    '"C:\\Program Files\\mpv\\mpv.exe"'
)
assert_equal(
    mpv_control.windows_quote_arg("C:\\Recordings\\folder\\"),
    '"C:\\Recordings\\folder\\\\"'
)
assert_equal(
    mpv_control.windows_quote_arg('value "quoted"'),
    '"value \\"quoted\\""'
)

print("ok")
