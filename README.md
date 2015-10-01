# lua-lluv-odbc
ODBC binding to lua-lluv library

##Usage
```Lua
local odbc = require "lluv.odbc"
local cnn = odbc.connection.new()

cnn:connect("EmptyDB", "DBA", "sql", function(cnn, err)
  if err then
    print (err)
    return cnn:close()
  end

  cnn:first_irow("select 'HELLO' where 1=?", {1}, function(self, err, row)
    if err then
      return print(err)
    end
    print(row[1] or '<NONE>')
  end)

  cnn:close()
end)
```