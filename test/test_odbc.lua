local uv   = require "lluv"
local odbc = require "lluv.odbc"

local cnn = odbc.connection.new()

local CNN = {
  {Driver = IS_WINDOWS and '{MySQL ODBC 5.2 ANSI Driver}' or 'MySQL'};
  {db='test'};
  {uid='root'};
};

cnn:connect(CNN, function(...)
  print(...)
  cnn:close()
end)

uv.run()
