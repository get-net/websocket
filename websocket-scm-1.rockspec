package = "websocket"
version = "scm-1"

source = {
    url = "git://github.com/get-net/websocket.git",
    branch = 'ssl-fix',
}

description = {
    summary = "Lua websocket implementation",
    detailed = [[
        Provides websocket server
          - socket style api
          - hook for custom http handshake
          - ping/pong
          - graceful shutdown
    ]],
    homepage = "https://github.com/get-net/websocket",
    license = "MIT",
}

dependencies = {
    'lua == 5.1',
}

build = {
    type = "builtin",
    modules = {
        ["websocket.init"] = "websocket.lua",
        ["websocket.ssl"] = "websocket/ssl.lua",
        ["websocket.frame"] = "websocket/frame.lua",
        ["websocket.handshake"] = "websocket/handshake.lua",
        ["websocket.utf8_validator"] = "websocket/utf8_validator.lua",
    },
}
