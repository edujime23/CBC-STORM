-- install.lua
-- CBC-STORM v4.0 :: Master Installer (wizard UI)
-- Small TUI wizard + hashless fetch (manifest-driven)

local function dl(url)
  local r = http.get(url)
  if not r then return nil, "http_fail" end
  local s = r.readAll() r.close()
  return s
end

local function writeFile(path, data)
  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local f = fs.open(path, "w")
  if not f then return false, "fs_open" end
  f.write(data) f.close()
  return true
end

local function clr()
  term.clear() term.setCursorPos(1,1)
end

local function centerY(y, text)
  local w,_ = term.getSize()
  term.setCursorPos(math.max(1, math.floor((w - #text)/2)), y)
  term.write(text)
end

local function box(x, y, w, h, title)
  for i=0,h-1 do
    term.setCursorPos(x, y+i)
    if i==0 or i==h-1 then
      term.write(("+"..string.rep("-", w-2).."+"))
    else
      term.write("|"..string.rep(" ", w-2).."|")
    end
  end
  if title then
    term.setCursorPos(x+2, y)
    term.write(title)
  end
end

local function footer(msg)
  local _,h = term.getSize()
  term.setCursorPos(1,h)
  term.clearLine()
  term.write(msg or "[Enter] Continue  [Esc] Cancel")
end

local function waitEnterOrEsc()
  while true do
    local ev, key = os.pullEvent("key")
    if key == keys.enter then return true
    elseif key == keys.escape then return false end
  end
end

local function menuSelect(title, options, startIdx)
  clr()
  local w,h = term.getSize()
  local bw, bh = math.min(46, w-4), math.min(10 + #options, h-4)
  local bx, by = math.floor((w-bw)/2), math.floor((h-bh)/2)
  box(bx, by, bw, bh, " "..title.." ")
  local sel = startIdx or 1
  while true do
    for i,opt in ipairs(options) do
      term.setCursorPos(bx+3, by+2+i)
      term.clearLine()
      if i == sel then
        term.write(("> %s"):format(opt))
      else
        term.write(("  %s"):format(opt))
      end
    end
    footer("[Up/Down] Select  [Enter] OK  [Esc] Cancel")
    local ev,key = os.pullEvent("key")
    if key == keys.up then sel = (sel-2) % #options + 1
    elseif key == keys.down then sel = (sel) % #options + 1
    elseif key == keys.enter then return sel
    elseif key == keys.escape then return nil end
  end
end

local function progress(title, items)
  clr()
  local w,h = term.getSize()
  local bw, bh = math.min(54, w-4), math.min(10 + math.min(#items,8), h-4)
  local bx, by = math.floor((w-bw)/2), math.floor((h-bh)/2)
  box(bx, by, bw, bh, " "..title.." ")
  local barW = bw - 6
  local function drawBar(i, n)
    local y = by + bh - 2
    term.setCursorPos(bx+2, y-1)
    term.clearLine()
    term.write(("File %d/%d"):format(i, n))
    local ratio = n>0 and (i/n) or 0
    local fill = math.floor(barW*ratio)
    term.setCursorPos(bx+2, y)
    term.write("["..string.rep("=", fill)..string.rep(" ", barW-fill).."]")
  end
  return drawBar
end

local function ensureHttp()
  if not http then
    clr()
    centerY(3, "HTTP API is disabled.")
    centerY(5, "Enable it in the ComputerCraft config or ask server admin.")
    footer("Press any key to exit")
    os.pullEvent("key")
    return false
  end
  return true
end

local function install_node(node_type, paths)
  local repo = paths.repo
  local node = paths.node_types[node_type]
  if not node then
    printError("Unknown node type: "..tostring(node_type))
    return false
  end
  local files = node.files or {}
  local drawBar = progress("Installing "..node_type, files)
  local ok, err
  for i, rel in ipairs(files) do
    drawBar(i-1, #files)
    term.setCursorPos(3, 3)
    term.clearLine()
    term.write("Downloading: "..rel)
    local url = repo .. rel
    local data, e = dl(url)
    if not data then
      drawBar(i-1, #files)
      term.setCursorPos(3, 5)
      term.clearLine()
      term.write("Download failed. [R]etry [S]kip [C]ancel")
      while true do
        local ev,k = os.pullEvent("key")
        if k == keys.r then data, e = dl(url); if data then break end
        elseif k == keys.s then data = "" break
        elseif k == keys.c or k == keys.escape then return false end
      end
    end
    ok, err = writeFile(rel, data)
    if not ok then
      printError("Write failed: "..tostring(err))
      return false
    end
    drawBar(i, #files)
  end

  local verURL = paths.repo .. (paths.version_file or "version.json")
  local verData = dl(verURL)
  if verData then writeFile(paths.version_file or "version.json", verData) end

  clr()
  centerY(3, "Installation complete for "..node_type.."!")
  if node_type == "controller" then
    centerY(5, "Next: edit configs in /storm/config/")
    centerY(6, "Run: lua /storm/core/kernel.lua")
  elseif node_type == "worker" then
    centerY(5, "Next: connect modem + peripheral")
    centerY(6, "Run: lua /storm/worker_payloads/worker_cannon.lua")
  else
    centerY(5, "Seed prepared. Power down until needed.")
  end
  footer("Press any key to close")
  os.pullEvent("key")
  return true
end

-- MAIN
local args = { ... }
clr()
centerY(3, "CBC-STORM v4.0 Installer")
centerY(5, "Wizard mode starting...")
footer("Press Enter to continue  (or provide arg: 1/2/3)")
if not ensureHttp() then return end

-- Fast path via args
if args[1] and (args[1] == "1" or args[1] == "2" or args[1] == "3") then
  local choice = (args[1] == "1") and "controller" or (args[1] == "2") and "worker" or "seed"
  local paths_url = "https://raw.githubusercontent.com/edujime23/CBC-STORM/main/paths.json"
  local s, e = dl(paths_url)
  if not s then printError("Manifest download failed: "..tostring(e)) return end
  local ok, data = pcall(textutils.unserializeJSON, s)
  if not ok or not data then printError("Manifest parse failed") return end
  install_node(choice, data)
  return
end

if not waitEnterOrEsc() then return end

-- Load manifest
local paths_url = "https://raw.githubusercontent.com/edujime23/CBC-STORM/main/paths.json"
local s, e = dl(paths_url)
if not s then
  clr()
  centerY(3, "Could not download manifest.")
  centerY(5, "Check URL or internet connection.")
  footer("Press any key to exit")
  os.pullEvent("key")
  return
end
local ok, paths = pcall(textutils.unserializeJSON, s)
if not ok or not paths then
  clr()
  centerY(3, "Manifest parse error.")
  footer("Press any key to exit")
  os.pullEvent("key")
  return
end

-- Node selection
local choices = { "Controller (Master Node)", "Worker (Cannon/Detector)", "Seed (Recovery Node)" }
local idx = menuSelect("Select Node Type", choices, 1)
if not idx then return end
local nodeKey = (idx == 1) and "controller" or (idx == 2) and "worker" or "seed"

-- Confirm
clr()
centerY(3, "Ready to install: "..nodeKey)
centerY(5, "Repo: "..(paths.repo or "?"))
centerY(6, "Version file: "..(paths.version_file or "version.json"))
footer("[Enter] Install  [Esc] Cancel")
if not waitEnterOrEsc() then return end

install_node(nodeKey, paths)