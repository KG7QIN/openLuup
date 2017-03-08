local ABOUT = {
  NAME          = "openLuup.wsapi",
  VERSION       = "2017.01.12",
  DESCRIPTION   = "a WSAPI application connector for the openLuup port 3480 server",
  AUTHOR        = "@akbooer",
  COPYRIGHT     = "(c) 2013-2017 AKBooer",
  DOCUMENTATION = "https://github.com/akbooer/openLuup/tree/master/Documentation",
  LICENSE       = [[
  Copyright 2013-2017 AK Booer

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

-- This module implements a WSAPI application connector for the openLuup port 3480 server.
--
-- see: http://keplerproject.github.io/wsapi/
-- and: http://keplerproject.github.io/wsapi/license.html
-- and: https://github.com/keplerproject/wsapi
-- and: http://keplerproject.github.io/wsapi/manual.html

-- The use of WSAPI concepts for handling openLuup CGI requests was itself inspired by @vosmont,
-- see: http://forum.micasaverde.com/index.php/topic,36189.0.html
-- 2016.02.18

-- 2016.02.26  add self parameter to input.read(), seems to be called from wsapi.request with colon syntax
--             ...also util.lua shows that the same is true for the error.write(...) function.
-- 2016.05.30  look in specified places for some missing CGI files 
-- 2016.07.05  use "require" for WSAPI files with a .lua extension (enables easy debugging)
-- 2016.07.06  add 'method' to WSAPI server call for REQUEST_METHOD metavariable
-- 2016.07.14  change cgi() parameter to request object
-- 2016.07.15  three-parameters WSAPI return: status, headers, iterator
-- 2016.10.17  use CGI aliases from external servertables module

-- 2017.01.12  remove leading colon from REMOTE_PORT metavariable value

--[[

Writing WSAPI connectors

A WSAPI connector builds the environment from information passed by the web server and calls a WSAPI application,
sending the response back to the web server. The first thing a connector needs is a way to specify which application to run,
and this is highly connector specific. Most connectors receive the application entry point as a parameter 
(but WSAPI provides special applications called generic launchers as a convenience).

The environment is a Lua table containing the CGI metavariables (at minimum the RFC3875 ones) plus any server-specific 
metainformation. It also contains an input field, a stream for the request's data, and an error field, a stream for the 
server's error log. The input field answers to the read([n]) method, where n is the number of bytes you want to read 
(or nil if you want the whole input). The error field answers to the write(...) method.

The environment should return the empty string instead of nil for undefined metavariables, and the PATH_INFO variable should
return "/" even if the path is empty. Behavior among the connectors should be uniform: SCRIPT_NAME should hold the URI up
to the part where you identify which application you are serving, if applicable (again, this is highly connector specific),
while PATH_INFO should hold the rest of the URL.

After building the environment the connector calls the application passing the environment to it, and collecting three
return values: the HTTP status code, a table with headers, and the output iterator. The connector sends the status and 
headers right away to the server, as WSAPI does not guarantee any buffering itself. After that it begins calling the
iterator and sending output to the server until it returns nil.

The connectors are careful to treat errors gracefully: if they occur before sending the status and headers they return an 
"Error 500" page instead, if they occur while iterating over the response they append the error message to the response.

--]]

local loader  = require "openLuup.loader"       -- to create new environment in which to execute CGI script 
local logs    = require "openLuup.logs"         -- used for wsapi_env.error:write()
local tables  = require "openLuup.servertables" -- used for CGI aliases

--  local log
local function _log (msg, name) logs.send (msg, name or ABOUT.NAME) end

logs.banner (ABOUT)   -- for version control

-- utilities

local cache = {}       -- cache for compiled CGIs

-- return a dummy WSAPI app with error code and message
local function dummy_app (status, message)
  local function iterator ()     -- one-shot iterator, returns message, then nil
    local x = message
    message = nil 
    return x
  end
  local function run ()   -- dummy app entry point
    return 
        status, 
        { ["Content-Type"] = "text/plain" },
        iterator
  end
  _log (message)
  return run    -- return the entry point
end

-- build makes an application function for the connector
local function build (script)
  local file = script
  -- CGI aliases: any matching full CGI path is redirected
  local alternative = tables.cgi_alias[file]     -- 2016.05.30 and 2016.10.17
  if alternative then
    _log (table.concat {"using ", alternative, " for ", file})
    file = alternative
  end
  
  local f = io.open (file) 
  if not f then 
    return dummy_app (404, "file not found: " .. (file or '?')) 
  end
  local line = f: read "*l"
  
  -- looking for first line of "#!/usr/bin/env wsapi.cgi" for WSAPI application
  local code
  if not line:match "^%s*#!/usr/bin/env%s+wsapi.cgi%s*$" then 
    return dummy_app (501, "file is not a WSAPI application: " .. (script or '?')) 
  end
  
  -- if it has a .lua extension, then we can use 'require' and this means that
  -- it can be easily debugged because the file is recognised by the IDE
  
  local lua_env
  local lua_file = file: match "(.*)%.lua$"
  if lua_file then
    _log "using REQUIRE to load .lua CGI"
    f: close ()                               -- don't need it open
    lua_file = lua_file: gsub ('/','.')       -- replace path separators with periods, for require path
    lua_env = require (lua_file)
    if type(lua_env) ~= "table" then
      _log ("error - require failed: " .. lua_file)
      lua_env = nil
    end
    
  else
    -- do it the hard way...
    code = f:read "*a"
    f: close ()
      
    -- compile and load
    local a, error_msg = loadstring (code, script)    -- load it
    if not a or error_msg then
      return dummy_app (500, error_msg)               -- 'internal server error'
    end
    lua_env = loader.new_environment (script)         -- use new environment
    setfenv (a, lua_env)                              -- Lua 5.1 specific function environment handling
    a, error_msg = pcall(a)                           -- instantiate it
    if not a then
      return dummy_app (500, error_msg)               -- 'internal server error'
    end
  end
  
  -- find application entry point
  local runner = (lua_env or {}).run
  if (not runner) or (type (runner) ~= "function") then
    return dummy_app (500, "can't find WSAPI application entry point")         -- 'internal server error'
  end

  return runner   -- success! return the entry point to the WSAPI application
end


--[[
  see: http://www.ietf.org/rfc/rfc3875

  meta-variable-name = "AUTH_TYPE" | "CONTENT_LENGTH" |
                       "CONTENT_TYPE" | "GATEWAY_INTERFACE" |
                       "PATH_INFO" | "PATH_TRANSLATED" |
                       "QUERY_STRING" | "REMOTE_ADDR" |
                       "REMOTE_HOST" | "REMOTE_IDENT" |
                       "REMOTE_USER" | "REQUEST_METHOD" |
                       "SCRIPT_NAME" | "SERVER_NAME" |
                       "SERVER_PORT" | "SERVER_PROTOCOL" |
                       "SERVER_SOFTWARE" | scheme |
                       protocol-var-name | extension-var-name

also: http://www.cgi101.com/book/ch3/text.html

DOCUMENT_ROOT 	The root directory of your server
HTTP_COOKIE 	  The visitor's cookie, if one is set
HTTP_HOST 	    The hostname of the page being attempted
HTTP_REFERER 	  The URL of the page that called your program
HTTP_USER_AGENT The browser type of the visitor
HTTPS 	        "on" if the program is being called through a secure server
PATH 	          The system path your server is running under
QUERY_STRING 	  The query string (see GET, below)
REMOTE_ADDR 	  The IP address of the visitor
REMOTE_HOST 	  The hostname of the visitor (if your server has reverse-name-lookups on; else this is the IP address again)
REMOTE_PORT 	  The port the visitor is connected to on the web server
REMOTE_USER 	  The visitor's username (for .htaccess-protected pages)
REQUEST_METHOD 	GET or POST
REQUEST_URI 	  The interpreted pathname of the requested document or CGI (relative to the document root)
SCRIPT_FILENAME The full pathname of the current CGI
SCRIPT_NAME 	  The interpreted pathname of the current CGI (relative to the document root)
SERVER_ADMIN 	  The email address for your server's webmaster
SERVER_NAME 	  Your server's fully qualified domain name (e.g. www.cgi101.com)
SERVER_PORT 	  The port number your server is listening on
SERVER_SOFTWARE The server software you're using (e.g. Apache 1.3)


--]]
-- cgi is called by the server when it receives a GET or POST CGI request
-- request object parameter:
-- { {url.parse structure} , {headers}, post_content_string, method_string, http_version_string }

local function cgi (request)
  
  local URL = request.URL
  local headers = request.headers
  local post_content = request.post_content
  
  local meta = {
    __index = function () return '' end;  -- return the empty string instead of nil for undefined metavariables
  }
  
  local ptr = 1
  local input = {
    read =  
      function (self, n) 
        n = tonumber (n) or #post_content
        local start, finish = ptr, ptr + n - 1
        ptr = ptr + n
        return post_content:sub (start, finish)
      end
  }
  
  local error = {
    write = function (self, ...) 
      local msg = {URL.path or '?', ':', ...}
      for i, m in ipairs(msg) do msg[i] = tostring(m) end             -- ensure everything is a string
      _log (table.concat (msg, ' '), "openLuup.wsapi.cgi") 
    end;
  }
  
  local env = {   -- the WSAPI standard (and CGI) is upper case for these metavariables
    
    TEST = {headers = headers},     -- so that test CGIs (or unit tests) can examine all the headers
    
    ["CONTENT_LENGTH"]  = #post_content,
    ["CONTENT_TYPE"]    = headers["Content-Type"] or '',
    ["HTTP_USER_AGENT"] = headers["User-Agent"],
    ["HTTP_COOKIE"]     = headers["Cookie"],
    ["REMOTE_HOST"]     = headers ["Host"],
    ["REMOTE_PORT"]     = (headers ["Host"] or ''): match ":(%d+)$",
    ["REQUEST_METHOD"]  = request.method,
    ["SCRIPT_NAME"]     = URL.path,
    ["SERVER_PROTOCOL"] = request.http_version,
    ["PATH_INFO"]       = '/',
    ["QUERY_STRING"]    = URL.query,
  
    -- methods
    input = input,
    error = error,
  }
  
  local wsapi_env = setmetatable (env, meta)
   
  -- execute the CGI
  local script = URL.path or ''  
  
  script = script: match "^/?(.-)/?$"      -- ignore leading and trailing '/'
  
  cache[script] = cache[script] or build (script) 
  
  -- guaranteed to be something executable here, even it it's a dummy with error message
  -- three return values: the HTTP status code, a table with headers, and the output iterator.
  
  return cache[script] (wsapi_env)
end

return {
    ABOUT = ABOUT,
    TEST  = {build = build},        -- access to 'build' for testing
     
    cgi   = cgi,                    -- called by the server to process a CGI request
  }
  
-----
