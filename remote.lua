local data = require("data")
local device = require("device")
local ffi = require("ffi")
local fs = libs.fs;
local log = require("log")
local server = require("server")

-----------------------------------------------------------
-- FFI interface
-----------------------------------------------------------

-- POSIX constants
local AF_UNIX = 1
local SOCK_STREAM = 1
local SOCK_NONBLOCK = 2048
local EAGAIN = 11
local POLLIN = 1

ffi.cdef[[
typedef unsigned short int sa_family_t;
typedef unsigned short int nfds_t;
typedef int socklen_t;
typedef int ssize_t;

typedef struct {
  sa_family_t sun_family;
  char        sun_path[108];
} sockaddr_un;

typedef struct {
  int   fd;
  short events;
  short revents;
} pollfd;


int socket(int domain, int type, int protocol);
int connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen);

ssize_t write(int fd, const void *buf, size_t count);
ssize_t read(int fd, void *buf, size_t count);

int poll(pollfd *fds, nfds_t nfds, int timeout);

char *strerror(int errnum);

int close(int fd);
]]

-- Convert errno to a Lua string.
local function strerror()
  return ffi.string(ffi.C.strerror(ffi.errno()))
end

-----------------------------------------------------------
-- IPC interface
-----------------------------------------------------------

local fd = nil

-- Disconnect from ddb, resetting some values.
local function disconnect()
  if fd then
    ffi.C.close(fd)
    fd = nil
  end

  if tid then
    libs.timer.cancel(tid)
    tid = nil
  end

  layout.onoff.icon = "off"
  layout.onoff.color = "red"
end

-- Connect to ddb at the given path.
local function connect(path)
  -- Make sure we start off in a disconnected state.
  disconnect()

  requests = {}
  next_request_id = 1
  listeners = {
  }
  observers = {}

  -- Use the supplied path, or the one from the settings.
  path = path or settings.input_ipc_server

  -- Check that the socket exists.
  if not path or path == "" then
    device.toast("No ddb IPC path configured.")
    return false
  elseif not events.detect() then
    device.toast("No ddb IPC server at '"..path.."'")
    return false
  end

  fd = ffi.C.socket(AF_UNIX, SOCK_STREAM + SOCK_NONBLOCK, 0)
  if fd < 0 then
    device.toast("Failed to set up")
    log.error("Failed to create socket: "..strerror())
    fd = nil
    return false
  end

  local sockaddr = ffi.new("sockaddr_un")
  sockaddr.sun_family = AF_UNIX
  sockaddr.sun_path = path

  if ffi.C.connect(fd, ffi.cast("const struct sockaddr*", sockaddr), ffi.sizeof(sockaddr)) ~= 0 then
    device.toast("Failed to connect to ddb at '"..path.."'")
    log.warn("Failed to connect to '"..path.."': "..strerror())
    disconnect()
    return false
  end

  layout.onoff.icon = "on"
  layout.onoff.color = "green"

  return true
end

-- Send a command to ddb, registering a callback to handle any responses
local function send_with_callback(callback, ...)
  if not fd then
    return false
  end

  local message = { command = { ...} }
  if callback then
    requests[next_request_id] = callback
    message.request_id = next_request_id
    next_request_id = next_request_id + 1
  end
  local json = data.tojson(message) .. "\n"
  local len = #json
  local ret = ffi.C.write(fd, json, len)
  if ret < 0 then
    device.toast("Failed to communicate with ddb")
    log.warn("Failed to send: "..strerror())
    disconnect()
    return false
  end
  return ret == len
end

-- Read any messages from ddb.
local function read()
  if not fd then
    return nil
  end

  local out = ""
  local buf = ffi.new("char[255]")
  local pollfds = ffi.new("pollfd[1]")
  pollfds[0].fd = fd
  pollfds[0].events = POLLIN
  ffi.C.poll(pollfds, 1, 50)
  if pollfds[0].revents == 0 then
    return nil
  end
  repeat
    local ret = ffi.C.read(fd, buf, 255)
    if ret < 0 then
      if ffi.errno() == EAGAIN then
        break
      else
        log.warn("Failed to read: "..strerror())
      end
      disconnect()
      return nil
    elseif ret > 0 then
      out = out .. ffi.string(buf, ret)
    end
  until ret == 0
  if out:len() > 0 then
    return out
  else
    return nil
  end
end

-- Send one or more commands to ddb.
local function send ( ... )
  send_with_callback(nil, ... )
end

-- Observe a property
local function observe_property(name, callback)
  observers[name] = callback
  send("observe_property", 1, name)
end

----------------------------------------------------------
-- UI handlers
----------------------------------------------------------


-- Initialize the UI to reflect the current state
local function initialize_ui()
    return nil
end


-----------------------------------------------------------
-- Remote events
-----------------------------------------------------------

-- Always allow a few actions, without trying to connect.
local allow = {
  onoff = true,
  update_ipc = true
}

-- Try to establish the connection before each action.
events.preaction = function(name)
  if allow[name] then
    return true
  end

  if not fd and not connect() then
    return false
  end

  return true
end

-- Consume any responses from ddb after each action.
local handle_response = function()
  -- Try to get a response from ddb.
  local resp = read()
  if resp ~= nil and resp:len() > 0 then
    -- ddb can send multiple JSON objects on each line.
    for msg in resp:gmatch("[^\r\n]+") do
      if msg:match("^{") then
        local tbl = data.fromjson(msg)
        if tbl.error and tbl.error ~= "success" then
          device.toast("Command failed")
          log.warn("Error from ddb: "..msg)
        end
        -- If the message contains a request ID, it is a response to our command.
        if tbl.request_id and requests[tbl.request_id] then
          requests[tbl.request_id](tbl)
        end
        -- If the message is an event, let the corresponding listener handle it
        if tbl.event and listeners[tbl.event] then
          listeners[tbl.event](tbl)
        end
        -- Flush any other messages/events.
      end
    end
  end
end

-- Set the input field when loading the remote.
events.preload = function()
  layout.input_ipc_server.text = settings.input_ipc_server
end

-- Set the input field when the remote gains focus, and try to connect.
-- Apparently some things happen with the internal state of the remote when it loses focus.
events.focus = function()
  layout.input_ipc_server.text = settings.input_ipc_server
  if connect() then
    initialize_ui()
    tid = libs.timer.interval(handle_response, 50)
  end
end

-- Disconnect from ddb when losing focus.
events.blur = function()
  disconnect()
end

-- Disconnect from ddb when the remote is destroyed.
events.destroy = function()
  disconnect()
end

-- Detect something.
events.detect = function ()
  return fs.exists(settings.input_ipc_server)
end

-----------------------------------------------------------
-- Actions
-----------------------------------------------------------

--@help Pushing the on/off button toggles the connection state.
actions.onoff = function()
  if fd then
    disconnect()
  else
    connect()
  end
end

--@help Set the input IPC server path.
--@param path:string IPC serevr path
actions.update_ipc = function(path)
  settings.input_ipc_server = path
  disconnect()
  connect()
end
