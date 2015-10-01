local function worker_thread(pipe)
  pipe:set_linger(1000)
  pipe:set_sndtimeo(1000)

  local LogLib = require "log"
  local zmq    = require "lzmq"
  local mp     = require "cmsgpack.safe"
  local odbc   = require "odbc.dba"
  local common = require "lluv.odbc.common"

  local OK       = common.OK
  local RES_TERM = common.RES_TERM
  local RES_CMD  = common.RES_CMD
  local REQ_CMD  = common.REQ_CMD

  local LOG, log_writer, escape, dump do
    local base_formatter = require "log.formatter.concat".new(' ')

    local log_formatter = function(...)
      return base_formatter(...)
    end

    log_writer = require "log.writer.stdout".new()

    LOG = LogLib.new('trace',
      function(...) return log_writer and log_writer(...) end,
      log_formatter
    )

    escape = function(str)
      return (str
        :gsub("\r", "\\r")
        :gsub("\n", "\\n")
        :gsub("\t", "\\t")
        :gsub("[%z\001-\031\127-\255]", function(ch)
          return string.format("\\%.3d", string.byte(ch))
        end))
    end

    dump = function(typ, data)
      return "[" .. port_name .. "] " .. typ .. " " .. escape(data)
    end

  end

  local interrupt = false

  local cnn, err

  local function ret_odbc_err(err)
    return nil, 'ODBC', err.code, err.state, err.message
  end

  local function ret_odbc_not_connected()
    return nil, 'ODBC', -101, '08003', 'Not connected to a database'
  end

  local function odbc_null2nil(row)
    for k, v in pairs(row) do
      if v == odbc.NULL then
        row[k] = nil
      end
    end
    return row
  end

  local API = {} do

    API[ "$TERM"          ] = function ()
      interrupt = true
    end

    API[ "$ECHO"          ] = function (...)
      return ...
    end

    API[ "SET VERBOSE"    ] = function (level)
      if level then LOG.set_lvl(level)
      else LOG.set_lvl('none') end
    end

    API[ "SET LOG WRITER" ] = function (writer)
      if not writer then return end

      local loadstring, err = loadstring or load

      writer, err = loadstring(writer)
      if not writer then
        return nil, 'LOG', tostring(err)
      end
      
      writer, err = writer()
      if not writer then
        return nil, 'LOG', tostring(err)
      end

      log_writer = writer
    end

    API[ "CONNECT"        ] = function(...)
      if cnn then
        LOG.warning("Try connect do DB but already connected.")
        return
      end

      LOG.info('Try connecting to DB', (...))
      cnn, err = odbc.Connect(...)
      if not cnn then
        LOG.error("Can not connect to DB:", err)
        return ret_odbc_err(err)
      end
      LOG.info('Connected to', (...))
    end

    API[ "EXEC"           ] = function(...)
      if not cnn then
        LOG.error("Try execute command on closed connection")
        return ret_odbc_not_connected()
      end

      local ret, err = cnn:exec(...)
      if not ret then
        LOG.error("Can not execute command:", err)
        return ret_odbc_err(err)
      end

      LOG.trace("Execute command done:", ret)
      return ret
    end

    API[ "FIRST_IROW"     ] = function(...)
      if not cnn then
        LOG.error("Try execute command on closed connection")
        return ret_odbc_not_connected()
      end

      local ret, err = cnn:first_irow(...)
      if not ret and err then
        LOG.error("Can not execute command:", err)
        return ret_odbc_err(err)
      end

      LOG.trace("Execute command done:", ret)
      if ret then 
        return odbc_null2nil(ret)
      end
    end

  end

  local function pass_api(...)
    if select('#', ...) > 0 then
      local args, err = mp.pack(...)
      if not args then
        LOG.alert("Can not serialize arguments: ", err)
        pipe:sendx(RES_CMD, 'MSGPACK', tostring(err))
      else
        pipe:sendx(RES_CMD, OK, args)
      end
    else
      pipe:sendx(RES_CMD, OK)
    end
  end

  local function fail_api(ret, cat, ...)
    if select('#', ...) > 0 then
      local args, err = mp.pack(...)
      if not args then
        LOG.alert("Can not serialize arguments: ", err)
        pipe:sendx(RES_CMD, 'MSGPACK', tostring(err))
      else
        pipe:sendx(RES_CMD, cat, args)
      end
    else
      pipe:sendx(RES_CMD, cat)
    end
  end

  local function check_api(...)
    if (...) or (select('#', ...) == 0) then 
      return pass_api(...)
    end
    return fail_api(...)
  end

  local function do_api(msg, args)
    local api = API[msg]
    assert(api, msg)
    if not args then check_api(api())
    else check_api(api(mp.unpack(args))) end
  end
  
  local function poll_socket()
    -- can return nil/flase/true
    local ok, err = pipe:poll(reading and 1 or 1000)

    -- we get error
    if ok == nil then
      if err:no() == zmq.ETERM then return end
      if err:no() ~= zmq.EAGAIN then
        LOG.fatal("ZMQ Unexpected poll error:", err)
        return nil, err
      end
    end

    if not ok then return true end

    local typ, msg, a, b, c, d = pipe:recvx(zmq.DONTWAIT)
    if not typ then
      if msg:no() ~= zmq.ETERM then
        LOG.fatal("ZMQ Unexpected recv error:", msg)
      else msg = nil end
      return nil, msg
    end

    if typ == REQ_CMD then
      return do_api(msg, a, b, c, d)
    end
  end

  local function main()
    while not interrupt do
      poll_socket()
    end
  end

  local ok, err, err2 = pcall(main)
  if ok then err = err2 or '' end

  if err and #err ~= 0 then
    LOG.fatal("abnormal close thread:", err)
  else
    LOG.info("Worker thread closed")
  end

  pipe:sendx(RES_TERM, tostring(err))
end

return worker_thread