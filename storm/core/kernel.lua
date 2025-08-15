-- /storm/core/kernel.lua
package.path = "/?.lua;/?/init.lua;" .. package.path

local UI   = require("/storm/modules/ui")
local Join = require("/storm/core/join_service")

print("CBC-STORM v4.0 — Controller")

local function run_ui() UI.run() end
local function run_join() Join.run() end

parallel.waitForAny(run_ui, run_join)
print("Controller exiting.")