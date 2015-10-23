local _NAME = "openLuup.init"
local revisionDate = "2015.10.19"
local banner = "     version " .. revisionDate .. "  @akbooer"

--
-- openLuup - Initialize Luup engine
--  

local loader = require "openLuup.loader" -- keep this first... it prototypes the global environment

local logs          = require "openLuup.logs"

--  local log
local function _log (msg, name) logs.send (msg, name or _NAME) end
_log ('',":: openLuup STARTUP ")
_log (banner, _NAME)   -- for version control

luup = require "openLuup.luup"       -- here's the GLOBAL luup environment

local requests      = require "openLuup.requests"
local server        = require "openLuup.server"
local scheduler     = require "openLuup.scheduler"
local timers        = require "openLuup.timers"
local rooms         = require "openLuup.rooms"
local scenes        = require "openLuup.scenes"
local userdata      = require "openLuup.userdata"
local devutil       = require "openLuup.devices"
local plugins       = require "openLuup.plugins"

-- save user_data (persistence for scenes and rooms)
local function save_user_data ()
  local ok, msg = userdata.save (luup)
  if not ok then
    _log (msg or "error writing user_data")
  end
end

-- load user_data (persistence for scenes and rooms)
local function load_user_data (user_data_json)  
  _log "loading user_data json..."
  local user_data, msg = userdata.parse (user_data_json)
  if msg then 
    _log (msg)
  else
    -- ATTRIBUTES
    local attr = userdata.attributes or {}
    for a,b in pairs (attr) do                    -- go through the template for names to restore
      luup.attr_set (a, user_data[a] or b)        -- use saved value or default
      -- note that attr_set also handles the "special" attributes which are mirrored in luup.XXX
    end
    
    -- ROOMS    
    _log "loading rooms..."
    for _,x in pairs (user_data.rooms or {}) do
      rooms.create (x.name, x.id)
      _log (("room#%d '%s'"): format (x.id,x.name)) 
    end
    _log "...room loading completed"

    -- DEVICES  
    _log "loading devices..."    
    for _, d in ipairs (user_data.devices or {}) do
      local v = {}
      -- states : table {id, service, variable, value}
      for i, s in ipairs (d.states) do
        v[i] = table.concat {s.service, ',', s.variable, '=', s.value}
      end
      local vars = table.concat (v, '\n')
      -- create (devNo, device_type, internal_id, description, upnp_file, upnp_impl, 
      --                  ip, mac, hidden, invisible, parent, room, pluginnum, statevariables...)
      _log  (("[%d] '%s', %s"): format (d.id, d.name, d.device_type))
      local dev = devutil.create (d.id, d.device_type, d.altid, d.name, d.device_file, d.impl_file or '',
                d.ip, d.mac, nil, d.invisible == "1", d.id_parent, tonumber (d.room), d.plugin, vars)
      dev:attr_set ("time_created", d.time_created)     -- set time_created to original, not current
      luup.devices[d.id] = dev                          -- save it
    end 
  
    -- SCENES 
    _log "loading scenes..."
    local scs = {}
    for _, scene in ipairs (user_data.scenes or {}) do
      local new, msg = scenes.create (scene)
      scs[#scs + 1] = new
      if not new then
        _log (table.concat {"error in scene id ", scene.id or '?', ": ", msg or "unknown error"})
      end
    end
    luup.scenes = scs
    _log ("number of scenes = " .. #luup.scenes)
    
    luup.scenes = user_data.scenes or {}
    for i,n in ipairs (luup.scenes) do _log (("scene#%d '%s'"):format (i,n.name)) end
    _log "...scene loading completed"
  
    -- PLUGINS
    _log "loading installed plugin info..."
    user_data.InstalledPlugins2 = plugins.installed (user_data.InstalledPlugins2)
    for _, plugin in ipairs (user_data.InstalledPlugins2) do
      _log (table.concat {"id: ", plugin.id, ", name: ", plugin.Title, 
                          ", installed: ", os.date ("%c", plugin.timestamp)})
    end
  end
  _log "...user_data loading completed"
  return not msg, msg
end

-- what it says...
local function compile_and_run_startup (lua)
  _log "running Startup Lua"
  local startup_env = loader.shared_environment    -- shared with scenes
  local startup_function = "_openLuup_STARTUP_"
  local source = table.concat {"function ", startup_function, " () ", lua, "end" }
  local code, error_msg = loader.compile_lua (source, "startup", startup_env) -- load, compile, instantiate
  if not code then 
    _log (error_msg, startup_function) 
  else
    local ok, err = scheduler.context_switch (nil, code[startup_function])  -- no device context
    if not ok then _log ("ERROR: " .. err, "openLuup.startup") end
    code[startup_function] = nil      -- remove it from the name space
  end
end

-- heartbeat monitor for memory usage and checkpointing

local function openLuupPulse ()
  timers.call_delay(openLuupPulse, 6*60)                      -- periodic pulse (6 minutes)
  local AppMemoryUsed =  math.floor(collectgarbage "count")   -- openLuup's memory usage in kB
  local now, cpu = os.time(), timers.cpu_clock()
  local uptime = now - timers.loadtime + 1
  local percent = ("%0.2f%%"): format (100 * cpu / uptime)
  local memory = ("%0.1fMb"): format (AppMemoryUsed / 1000)
  uptime = ("%0.2f days"): format (uptime / 24 / 60 / 60)
  userdata.attributes ["Stats_Memory"] = memory
  userdata.attributes ["Stats_CpuLoad"] = percent
  userdata.attributes ["Stats_Uptime"] = uptime
  local sfmt = "memory: %s, uptime: %s, cpu: %0.1f sec (%s)"
  local stats = sfmt: format (memory, uptime, cpu, percent)
  _log (stats, "openLuup.heartbeat")
  save_user_data()                          -- CHECKPOINT !
  collectgarbage()                          -- tidy up a bit
end

--
-- INIT STARTS HERE
--

do -- Devices 1 and 2 are the Vera standard ones
  local invisible = true
  luup.attr_set ("Device_Num_Next", 1)  -- this may get overwritten by a subsequent user_data load

  -- create (device_type, int_id, descr, upnp_file, upnp_impl, ip, mac, hidden, invisible, parent, room, ...)
  luup.create_device ("urn:schemas-micasaverde-com:device:ZWaveNetwork:1", '',
                      "ZWave", "D_ZWaveNetwork.xml", nil, nil, nil, nil, invisible)
  luup.create_device ("urn:schemas-micasaverde-com:device:SceneController:1", '',
                      "_SceneController", "D_SceneController1.xml", nil, nil, nil, nil, invisible, 1)
end

do  -- CALLBACK HANDLERS
  -- Register lu_* style (ie. luup system, not luup user) callbacks with HTTP server
  local extendedList = {}
  for name, proc in pairs (requests) do 
    extendedList[name]        = proc
    extendedList["lu_"..name] = proc                      -- add compatibility with old-style call names
  end
  server.add_callback_handlers (extendedList)       -- tell the HTTP server to use these callbacks
end

do -- STARTUP   
  local init = arg[1] or "user_data.json"       -- optional parameter: Lua or JSON startup file
  _log ("loading configuration ".. init)
  if init == "reset" then luup.reload () end    -- factory reset
  local f = io.open (init, 'r')
  if f then 
    local code = f:read "*a"
    f:close ()
    if code then
      local ok = true
      local json_code = code: match "^%s*{"    -- what sort of code is this?
      if json_code then 
        ok = load_user_data (code)
        code = userdata.attributes ["StartupCode"] or ''  -- substitute the Startup Lua
      end
      compile_and_run_startup (code)  -- either the given file or the code embedded in user_data
    else
      _log "no init data"
    end
  else
    _log "init file not found"
  end
  _log "startup completed"
end

do -- SERVER
  local s = server.start "3480"               -- start the port 3480 Web server
  if not s then error "openLuup - no server socket" end
end

-- start the heartbeat
do
  timers.call_delay(openLuupPulse, 6 * 60)     -- it's alive! it's alive!!
end

local status = scheduler.start ()           -- this is the main scheduling loop!

_log "saving user_data"
save_user_data ()

local fmt = "exiting with code %s - after %0.1f hours"
_log (fmt:format (tostring (status), (os.time() - timers.loadtime) / 60 / 60))

os.exit (status)

-----------


