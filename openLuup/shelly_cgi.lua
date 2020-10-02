#!/usr/bin/env wsapi.cgi

module(..., package.seeall)

local wsapi = require "openLuup.wsapi" 

ABOUT = {
  NAME          = "shelly_cgi",
  VERSION       = "2020.10.02",
  DESCRIPTION   = "Shelly-like API for relays and scenes",
  AUTHOR        = "@akbooer",
  COPYRIGHT     = "(c) 2020 AKBooer",
  DOCUMENTATION = "",
  LICENSE       = [[
  Copyright 2013-2020 AK Booer

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
]]
}

-- shelly_cgi.lua
-- see: https://shelly-api-docs.shelly.cloud/#shelly-family-overview
-- see: http://keplerproject.github.io/wsapi/libraries.html

local json = require "openLuup.json"
local luup = require "openLuup.luup"

local SID = {
    hag     = "urn:micasaverde-com:serviceId:HomeAutomationGateway1",   -- run scene
    switch  = "urn:upnp-org:serviceId:SwitchPower1",                          
    toggle  = "urn:micasaverde-com:serviceId:HaDevice1",
  }
  
-- perform generic luup action
local function call_action (info, ...)
  -- returns: error (number), error_msg (string), job (number), arguments (table)
  info.status, info.message, info.job = luup.call_action(...)
end

-- easy HTTP request to run a scene
local function scene (info) 
  if luup.scenes[info.id] then
    call_action(info, SID.hag, "RunScene", {SceneNum = info.id}, 0)
  end
end

-- easy HTTP request to switch a switch
local turn = {
    on      = function (info) call_action (info, SID.switch, "SetTarget", {newTargetValue = '1'}, info.id) end,
    off     = function (info) call_action (info, SID.switch, "SetTarget", {newTargetValue = '0'}, info.id) end,
    toggle  = function (info) call_action (info, SID.toggle, "ToggleState", {}, info.id) end,
  }
  
local function relay (info)
  local op = info.parameters.turn
  local fct = turn[op]
  local id = luup.devices[info.id]
  if fct and id then fct(info) end
end

local function unknown (info)
  info.status = -1
  info.message = "invalid action request"
end

local dispatch = {
    relay = relay,
    scene = scene,
  }
  
function run(wsapi_env)
  
  local req = wsapi.request.new(wsapi_env)
  local res = wsapi.response.new ()
  res:content_type "text/plain" 
  
  local command = req.script_name
  local action, path = command: match "/(%w+)/?(.*)"
  local id = tonumber(path: match "^%d+")
  local info = {command = command, id = id, parameters = req.GET}
  local fct = dispatch[action] or unknown
  
  unknown(info)   -- set default error message (to be over-written)
  fct(info)       -- input and output parameters in info
  
  local reply, err = json.encode (info) 
  res: write (reply or err)
  res:content_type "application/json"
  
  return res:finish()
end

-----
