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
    ["property-change"] = function (tbl)
      if tbl.property and observers[tbl.property] then
        observers[tbl.property](tbl)
      end
    end
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
local function send_with_callback(callback, command, ...)
  if not fd then
    return false
  end

  local message = { command = command}
  if ... then
    message.args = ...
  end
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
  local buf = ffi.new("char[4096]")
  local pollfds = ffi.new("pollfd[1]")
  pollfds[0].fd = fd
  pollfds[0].events = POLLIN
  ffi.C.poll(pollfds, 1, 50)
  if pollfds[0].revents == 0 then
    return nil
  end
  repeat
    local ret = ffi.C.read(fd, buf, 4096)
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
  send("observe-property", { property = name } )
end

----------------------------------------------------------
-- UI handlers
----------------------------------------------------------

-- Update the seekbar
local function ui_seek(message)
  if message.data then
    local pos = 100 * message.data.position/message.data.duration
    layout.seek_slider.progress = string.format("%2.0f", pos)
    local d_min = math.floor(message.data.duration/60)
    local d_s = math.floor(message.data.duration) % 60
    local p_min = math.floor(message.data.position/60)
    local p_s = math.floor(message.data.position) % 60
    layout.seek_slider.text = string.format("%d:%02d / %d:%02d", d_min, d_s, p_min, p_s)
  end
end

-- Update the volume bar
local function ui_update_volume(message)
  if message.value then
    layout.volume_slider.progress = string.format("%2.0f", message.value)
  end
end

-- Update mute status
local function ui_update_mute(message)
  if message.value == 0 then
    layout.volume_slider.color = "green"
  else
    layout.volume_slider.color = "red"
  end
end

-- Set the title
local function ui_set_title(message)
  if message["now-playing"] then
    layout.media_title.text = message["now-playing"]
  end
  server.update( {"id = media-title", weight = "wrap" } )
end

-- Update the stop after buttons
local function ui_update_stop_after_current_track(message)
  if message.value and message.value ~= 0 then
    layout.stop_after_current_track.checked = true
  else
    layout.stop_after_current_track.checked = false
  end
  server.update()
end

local function ui_update_stop_after_current_album(message)
  if message.value and message.value ~= 0 then
      layout.stop_after_current_album.checked = true
  else
      layout.stop_after_current_album.checked = false
  end
  server.update()
end

local repeats  = {"Off", "One", "All"}
local function ui_update_repeats(message)
  log.warn("repeat: " .. message.value)
  local repeat_children = {}
  for k, v in ipairs(repeats) do
    local bool = (message.value == string.lower(v))
    local item =     {
      type = "item",
      checked = bool,
      text = v,
    }
    table.insert(repeat_children, item)
  end
  server.update( {id = "repeat_list", children = repeat_children} )
end

local function ui_update_cover_art(message)
    if not message["blob"] and not message["filename"] then
      return
    end
    tmpf = fs.temp()
    if message["blob"] then
      log.info("writing cover from blob")
      fs.write(tmpf, data.frombase64(message["blob"]))
    end
    if message["filename"] then
      log.warn("copying cover from file")
      fs.copy(message["filename"], tmpf)
    end
    server.update( {id = "cover_art", image=tmpf} )
end

local shuffles = {"Off", "Tracks", "Albums", "Random"}
local function ui_update_shuffles(message)
  log.warn("shuffle: " .. message.value)
  local shuffle_children = {}
  for k, v in ipairs(shuffles) do
    local bool = (message.value == string.lower(v))
    local item =     {
      type = "item",
      checked = bool,
      text = v,
    }
    table.insert(shuffle_children, item)
  end
  server.update( {id = "shuffle_list", children = shuffle_children} )
end

-- Initialize the UI to reflect the current state
local function initialize_ui()
  fmt = "%artist% - '['%album% - #%tracknumber%']' %title%"
  send_with_callback(ui_set_title, "get-now-playing", { format = fmt })

  send_with_callback(ui_update_volume, "get-property", { property = "volume" })
  observe_property("volume", ui_update_volume)

  send_with_callback(ui_update_mute, "get-property", { property = "mute" })
  observe_property("mute", ui_update_mute)

  send_with_callback(ui_seek, "get-playpos")

  -- poll ddb for progress regularly
  local playpos_freq = 100 -- ms
  -- uncomment to poll less frequently -- prevents spamming the debug log
  -- local playpos_freq = 1000 * 100 -- ms
  libs.timer.interval(
    function() send_with_callback(ui_seek, "get-playpos") end,
    playpos_freq
  )
  listeners["seek"] = ui_seek

  send_with_callback(ui_update_repeats, "get-property", {property = "repeat"} )
  send_with_callback(ui_update_shuffles, "get-property", {property = "shuffle"} )
  observe_property("repeat", ui_update_repeats)
  observe_property("shuffle", ui_update_shuffles)

  send_with_callback(ui_update_stop_after_current_track, "get-property", { property = "playlist.stop_after_current" })
  send_with_callback(ui_update_stop_after_current_album, "get-property", { property = "playlist.stop_after_album" })
  observe_property("playlist.stop_after_current", ui_update_stop_after_current_track)
  observe_property("playlist.stop_after_album", ui_update_stop_after_current_album)

  send_with_callback(ui_update_cover_art, "request-cover-art")
  listeners["track-changed"] = function (message)
    send_with_callback(ui_update_cover_art, "request-cover-art")
    send_with_callback(ui_set_title, "get-now-playing", { format = fmt })
  end

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
          log.warn("Error from ddb: " .. msg)
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
    initialize_ui()
  end
end

--@help Set the input IPC server path.
--@param path:string IPC serevr path
actions.update_ipc = function(path)
  settings.input_ipc_server = path
  disconnect()
  connect()
end

--@help Previous track
actions.previous = function()
  send("prev-track")
end

--@help Next track
actions.next = function()
  send("next-track")
end

--@help Previous album
actions.previous_album = function()
  send("prev-album")
end

--@help Next album
actions.next_album = function()
  send("next-album")
end

--@help Toggle play/pause state
actions.play_pause = function()
  send("play-pause")
end

--@help Lower volume
actions.volume_down = function()
  send("adjust-volume", { adjustment = -2} )
end

--@help Mute volume
actions.volume_mute = function()
  send("toggle-mute")
end

--@help Raise volume
actions.volume_up = function()
  send("adjust-volume", { adjustment = 2} )
end

--@help Set volume
actions.volume_set = function(value)
  send("set-volume", { volume = tonumber(value) } )
end

--@help Seek by percent
actions.seek_percent = function(value)
  send("seek", { percent = value} )
end

--@help Toggle Stop after current track
actions.toggle_stop_after_current_track = function()
  send("toggle-stop-after-current-track")
end

--@help Toggle Stop after current album
actions.toggle_stop_after_current_album = function()
  send("toggle-stop-after-current-album")
end

actions.set_repeat = function(index)
  local rep = string.lower(repeats[index+1])
  log.warn("Setting repeat " .. rep)
  send("set-property",
    {
      property = "repeat",
      value = rep
    }
  )
end

actions.set_shuffle = function(index)
  local shuff = string.lower(shuffles[index+1])
  log.warn("Setting shuffle " .. shuff)
  send("set-property",
    {
      property = "shuffle",
      value = shuff
    }
  )
end
