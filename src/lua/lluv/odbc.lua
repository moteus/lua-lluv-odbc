local zth    = require "lzmq.threads"
local uv     = require "lluv"
local ut     = require "lluv.utils"
uv.poll_zmq  = require "lluv.poll_zmq"
local mp     = require "cmsgpack.safe"
local common = require "lluv.odbc.common"
local worker = require "lluv.odbc.thread"

local OK       = common.OK
local RES_TERM = common.RES_TERM
local RES_CMD  = common.RES_CMD
local REQ_CMD  = common.REQ_CMD

local function dummy()end

local function is_callable(f) return (type(f) == 'function') and f end

local function pack_cmd(cmd, ...)
  local n    = select("#", ...)
  local args = {...}
  local cb   = args[n]
  if is_callable(cb) then
    args[n] = nil
    n = n - 1
  else
    cb = dummy
  end

  return cb, cmd, unpack(args, 1, n)
end

local function wrap_cb(fn, cb, ...)
  return function(...)
    return cb(fn(...))
  end, ...
end

---------------------------------------------------------------
local ODBCError = ut.class() do

function ODBCError:__init(code, state, msg, ext)
  self._code  = code
  self._state = state
  self._msg   = msg
  self._ext   = ext
  return self
end

function ODBCError:cat()  return 'ODBC' end

function ODBCError:no()   return self._code  end

function ODBCError:name() return self._state end

function ODBCError:msg() return self._msg    end

function ODBCError:ext()  return self._ext   end

function ODBCError:__eq(rhs)
  return (self._no == rhs._no) and (self._name == rhs._name)
end

function ODBCError:__tostring()
  local err = string.format("[%s][%s] %s (%d)",
    self:cat(), self:name(), self:msg(), self:no()
  )
  if self:ext() then
    err = string.format("%s - %s", err, self:ext())
  end
  return err
end

end
---------------------------------------------------------------

local ODBCConnection, ODBCStatement

---------------------------------------------------------------
ODBCConnection = ut.class() do

function ODBCConnection:__init()
  self._terminated = false
  self._queue      = ut.List.new()
  self._actor      = assert(zth.xactor(worker):start())
  self._poller     = uv.poll_zmq(self._actor)
  self._busy       = false

  self._actor:set_linger(1000)
  self._actor:set_sndtimeo(1000)

  return self:_start()
end

function ODBCConnection:destroy(cb)
  if self._actor  then
    if self._terminated then
      self._actor:close()
      self._poller:close(function()
        if cb then cb(self) end
      end)
      self._actor, self._poller = nil
      return
    end

    if self._actor:alive() then
      local timer

      self:_command(false, function(...)
        if self._poller then
          self._actor:close()
          self._poller:close()
          timer:close()
          self._actor, self._poller = nil
        end
        if cb then cb(...) cb = nil end
      end, '$TERM')

      timer = uv.timer():start(2000, function()
        if self._poller then
          self._actor:close()
          self._poller:close()
          timer:close()
          self._actor, self._poller = nil
        end
        if cb then cb(self) cb = nil end
      end)
    end
  end
end

local function decode_cmd_reponse(res, info)
  if res == OK then
    if info then return nil, mp.unpack(info) end
    return
  end

  if res == 'ODBC' then
    return ODBCError.new(mp.unpack(info))
  end

  return mp.unpack(info)
end

function ODBCConnection:_send_command(cb, cmd, args)
  self._busy = cb or true
  local ok, err = self._actor:sendx(REQ_CMD, cmd, args)
  if not ok then uv.defer(cb, self, err) end

  return self
end

function ODBCConnection:_command(front, cb, cmd, ...)
  local ok, args, err
  if select('#', ...) == 0 then args = '' else
    args, err = mp.pack(...)
  end

  if not args then
    uv.defer(cb, self, err)
    return self
  end

  if self._busy then
    local task = {cmd, args, cb}
    if front then
      self._queue:push_front(task)
    else
      self._queue:push_back(task)
    end
    return self
  end

  return self:_send_command(cb, cmd, args)
end

function ODBCConnection:_next_command()
  assert(self._busy == nil)

  local task = self._queue:pop_front()
  if not task then return self end

  local cmd, args, cb = task[1],task[2],task[3]

  return self:_send_command(cb, cmd, args)
end

function ODBCConnection:_start()
  self._poller:start(function(handle, err, pipe)
    if err then
      self._poll_error = err
      --! @todo proceed error
      return
    end

    local typ, msg, data = self._actor:recvx()
    if not typ then
      self._poll_error = msg
      --! @todo proceed error
      return
    end

    if typ == RES_CMD then
      local cb = self._busy
      self._busy = nil
      self:_next_command()
      if cb ~= true then cb(self, decode_cmd_reponse(msg, data)) end
      return
    end

    if typ == RES_TERM then
      err = uv.error('LIBUV', uv.EOF)
      self._poll_error = err
      self._terminated = true
      while true do
        local task = self._queue:pop_front()
        if not task then break end
        local cb = task[3]
        if cb then cb(self, err) end
      end
      return
    end

  end)

  return self
end

function ODBCConnection:set_log_level(level, cb)
  if level == false then level = 'none' end

  self:_command(false, cb, 'SET VERBOSE', level)
end

function ODBCConnection:set_log_writer(writer, cb)
  assert(type(writer) == 'string')

  self:_command(false, cb, 'SET LOG WRITER', writer)
end

function ODBCConnection:echo(...)
  return self:_command(false, pack_cmd('$ECHO', ...))
end

function ODBCConnection:connect(...)
  return self:_command(false, pack_cmd('CONNECT', ...))
end

function ODBCConnection:disconnect(...)
  return self:_command(false, pack_cmd('DISCONNECT', ...))
end

function ODBCConnection:exec(...)
  return self:_command(false, pack_cmd('EXEC', ...))
end

function ODBCConnection:first_irow(...)
  return self:_command(false, pack_cmd('FIRST_IROW', ...))
end

function ODBCConnection:first_nrow(...)
  return self:_command(false, pack_cmd('FIRST_NROW', ...))
end

function ODBCConnection:first_row(...)
  return self:_command(false, wrap_cb(function(self, err, row)
    if err then return self, err, row end
    return self, nil, unpack(row, 1, row.n)
  end, pack_cmd('FIRST_ROW', ...)))
end

function ODBCConnection:fetch_all(...)
  return self:_command(false, pack_cmd('FETCH_ALL', ...))
end

function ODBCConnection:prepare(...)
  return self:_command(false, wrap_cb(function(self, err, ref)
    if err then return nil, err end
    return ODBCStatement.new(self, ref)
  end,pack_cmd('PREPARE', ...)))
end

end
---------------------------------------------------------------

---------------------------------------------------------------
ODBCStatement = ut.class() do

function ODBCStatement:__init(cnn, id)
  self._cnn = cnn
  self._ref = id
  return self
end

function ODBCStatement:_command(front, cb, cmd, ...)
  local stmt_cb
  if cb then stmt_cb = function(_, ...) return cb(self, ...) end end
  self._cnn:_command(front, stmt_cb, cmd, self._ref, ...)

  return self
end

function ODBCStatement:exec(...)
  return self:_command(false, pack_cmd('STMT EXEC', ...))
end

function ODBCStatement:close(...)
  return self:_command(false, pack_cmd('STMT CLOSE', ...))
end

function ODBCStatement:exec(...)
  return self:_command(false, pack_cmd('STMT EXEC', ...))
end

function ODBCStatement:first_irow(...)
  return self:_command(false, pack_cmd('STMT FIRST_IROW', ...))
end

function ODBCStatement:first_nrow(...)
  return self:_command(false, pack_cmd('STMT FIRST_NROW', ...))
end

function ODBCStatement:first_row(...)
  return self:_command(false, wrap_cb(function(self, err, row)
    if err then return self, err, row end
    return self, nil, unpack(row, 1, row.n)
  end, pack_cmd('STMT FIRST_ROW', ...)))
end

function ODBCStatement:fetch_all(...)
  return self:_command(false, pack_cmd('STMT FETCH_ALL', ...))
end

end
---------------------------------------------------------------

return {
  connection = ODBCConnection;
}
