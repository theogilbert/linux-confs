local Store = {}

local function run(conn)
  return conn
end

function Store.new(path)
  local self = setmetatable({}, { __index = Store })
  self.conn = path
  return self
end

function Store:query()
  return run(self.conn)
end

return Store
