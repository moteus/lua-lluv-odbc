package = "lluv-odbc"
version = "scm-0"

source = {
  url = "https://github.com/moteus/lua-lluv-odbc/archive/master.zip",
  dir = "lua-lluv-odbc-master",
}

description = {
  summary    = "ODBC binding to lua-lluv library",
  homepage   = "https://github.com/moteus/lua-lluv-odbc",
  license    = "MIT/X11",
  maintainer = "Alexey Melnichuk",
  detailed   = [[
  ]],
}

dependencies = {
  "lua >= 5.1, < 5.4",
  "lluv > 0.1.1",
  "odbc >= 2.2",
  "lzmq >= 0.4.3",
  "lluv-poll-zmq",
  "lua-log",
  "lua-cmsgpack",
  "lua-llthreads2",
}

build = {
  copy_directories = {'examples', 'test'},

  type = "builtin",

  modules = {
    ["lluv.odbc"        ] = "src/lua/lluv/odbc.lua",
    ["lluv.odbc.common" ] = "src/lua/lluv/odbc/common.lua",
    ["lluv.odbc.thread" ] = "src/lua/lluv/odbc/thread.lua",
  }
}
