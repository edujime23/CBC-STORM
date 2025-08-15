-- /storm/core/kernel.lua
-- Entry point: Controller — run UI and JoinService concurrently

package.path = "/?.lua;/?/init.lua;" .. package.path

local L = require("/storm/lib/logger")
local Join = require("/storm/core/join_service")
local UI = require("/storm/modules/ui")

print("CBC-STORM v4.0 — Controller")

local function run_ui() UI.run() end
local function run_join() Join.run() end

parallel.waitForAny(run_ui, run_join)
print("Controller exiting.")