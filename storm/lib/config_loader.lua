-- /storm/lib/config_loader.lua
local U = require("/storm/lib/utils")

local M = {}
M.system = U.read_json("/storm/config/system.cfg", {})
M.network = U.read_json("/storm/config/network.cfg", {})
M.security = U.read_json("/storm/config/security.cfg", {})

return M