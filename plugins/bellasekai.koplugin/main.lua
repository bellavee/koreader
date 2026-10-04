--[[--
Mirrors a bellasekai book collection onto the device.

The server lists the books of the collection assigned to this device, each with a
`version` that changes whenever the generated EPUB would change (new chapter, new
translation, edited metadata). Sync downloads what is missing or outdated and removes
what left the collection.

Files are named `bellasekai-<bookId>.epub`. The name never changes, so the reading
position in the sidecar survives a refresh, and the Progress sync plugin can match the
document by file name: the server computes the same `md5(filename)` digest.

Progress itself is left to the Progress sync (kosync) plugin; "Apply to Progress sync"
points it at the same server and account.

@module koplugin.Bellasekai
--]]

local BookList = require("ui/widget/booklist")
local DataStorage = require("datastorage")
local Device = require("device")
local DocSettings = require("docsettings")
local FileManager = require("apps/filemanager/filemanager")
local InfoMessage = require("ui/widget/infomessage")
local JSON = require("json")
local LuaSettings = require("luasettings")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local PathChooser = require("ui/widget/pathchooser")
local PluginLoader = require("pluginloader")
local ReadHistory = require("readhistory")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local md5 = require("ffi/sha2").md5
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

-- Matches CHECKSUM_METHOD.FILENAME in kosync.koplugin.
local KOSYNC_CHECKSUM_FILENAME = 1

local Bellasekai = WidgetContainer:extend{
    name = "bellasekai",
    is_doc_only = false,
    settings_file = DataStorage:getSettingsDir() .. "/bellasekai.lua",
}

function Bellasekai:init()
    self.settings = LuaSettings:open(self.settings_file)
    self.ui.menu:registerToMainMenu(self)
end

function Bellasekai:onFlushSettings()
    self.settings:flush()
end

function Bellasekai:getServer()
    local server = self.settings:readSetting("server")
    return server and server:gsub("/+$", "")
end

function Bellasekai:getDownloadDir()
    return self.settings:readSetting("download_dir")
        or (G_reader_settings:readSetting("home_dir") or Device.home_dir or DataStorage:getDataDir()) .. "/Bellasekai"
end

function Bellasekai:isConfigured()
    return self:getServer() and self.settings:readSetting("username") and self.settings:readSetting("userkey")
end

function Bellasekai:addToMainMenu(menu_items)
    menu_items.bellasekai = {
        text = _("Bellasekai"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Sync library"),
                enabled_func = function() return self:isConfigured() and true or false end,
                callback = function() self:startSync() end,
            },
            {
                text = _("Server and account"),
                keep_menu_open = true,
                callback = function() self:showAccountDialog() end,
            },
            {
                text_func = function()
                    return T(_("Download folder: %1"), self:getDownloadDir())
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:chooseDownloadDir(touchmenu_instance)
                end,
            },
            {
                text = _("Delete books removed from the collection"),
                checked_func = function() return self.settings:nilOrTrue("delete_removed") end,
                callback = function()
                    self.settings:flipNilOrTrue("delete_removed")
                end,
            },
            {
                text = _("Apply to Progress sync"),
                enabled_func = function() return self:isConfigured() and true or false end,
                keep_menu_open = true,
                callback = function() self:applyToKosync() end,
                separator = true,
            },
        },
    }
end

function Bellasekai:showAccountDialog()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Bellasekai server"),
        fields = {
            {
                text = self:getServer() or "https://",
                hint = _("Server address"),
            },
            {
                text = self.settings:readSetting("username") or "",
                hint = _("Username"),
            },
            {
                text = "",
                hint = self.settings:readSetting("userkey") and _("Password (leave empty to keep)") or _("Password"),
                text_type = "password",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Save and test"),
                    callback = function()
                        local fields = dialog:getFields()
                        local server = util.trim(fields[1]):gsub("/+$", "")
                        local username = util.trim(fields[2]):lower()
                        if not server:match("^https?://.+") or username == "" then
                            UIManager:show(InfoMessage:new{ text = _("Server address and username are required.") })
                            return
                        end
                        self.settings:saveSetting("server", server)
                        self.settings:saveSetting("username", username)
                        if fields[3] ~= "" then
                            self.settings:saveSetting("userkey", md5(fields[3]))
                        end
                        self.settings:flush()
                        UIManager:close(dialog)
                        self:testLogin()
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Bellasekai:chooseDownloadDir(touchmenu_instance)
    local current = self:getDownloadDir()
    local start = lfs.attributes(current, "mode") == "directory" and current
        or G_reader_settings:readSetting("home_dir") or Device.home_dir or "/"
    UIManager:show(PathChooser:new{
        select_file = false,
        show_files = false,
        path = start,
        onConfirm = function(path)
            self.settings:saveSetting("download_dir", path)
            self.settings:flush()
            if touchmenu_instance and touchmenu_instance.updateItems then touchmenu_instance:updateItems() end
        end,
    })
end

--- Performs an authenticated request against the bellasekai server.
-- @string path Absolute path on the server, e.g. "/api/koreader/library"
-- @string[opt] filepath Stream the body into this file instead of returning it
-- @treturn int|nil HTTP status code, nil on network failure
-- @treturn table|string|nil Decoded JSON, or the error text
-- @treturn table|nil Response headers
function Bellasekai:request(path, filepath)
    local handle
    if filepath then
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        handle = io.open(filepath, "wb")
        if not handle then
            socketutil:reset_timeout()
            return nil, T(_("Cannot write to %1"), filepath)
        end
    else
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    end
    local chunks = {}
    local request = {
        url = self:getServer() .. path,
        method = "GET",
        headers = {
            ["Accept"] = filepath and "application/epub+zip" or "application/json",
            ["Accept-Encoding"] = "identity",
            ["x-auth-user"] = self.settings:readSetting("username"),
            ["x-auth-key"] = self.settings:readSetting("userkey"),
        },
        sink = filepath and socketutil.file_sink(handle) or socketutil.table_sink(chunks),
    }
    logger.dbg("Bellasekai: GET", request.url)
    local code, headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()

    if headers == nil then
        return nil, status or code or _("network unreachable")
    end
    if filepath then
        if code == 200 then return code, nil, headers end
        -- The error body landed in the file; read it back for the message.
        local f = io.open(filepath, "rb")
        if f then
            chunks = { f:read("*a") }
            f:close()
        end
    end
    local body = table.concat(chunks)
    local ok, decoded = pcall(JSON.decode, body)
    if ok and type(decoded) == "table" then
        return code, decoded, headers
    end
    return code, body ~= "" and body or status, headers
end

local function errorText(code, body)
    if type(body) == "table" and body.message then
        return body.message
    end
    if code == 401 then
        return _("Wrong username or password.")
    end
    return tostring(body or code)
end

function Bellasekai:testLogin()
    NetworkMgr:runWhenOnline(function()
        local code, body = self:request("/api/kosync/users/auth")
        if code == 200 then
            UIManager:show(InfoMessage:new{ text = _("Logged in to bellasekai."), timeout = 3 })
        else
            UIManager:show(InfoMessage:new{ text = T(_("Login failed: %1"), errorText(code, body)) })
        end
    end)
end

--- Points the Progress sync (kosync) plugin at this server and account.
-- Edits the live settings table when kosync already loaded it, so a later flush from
-- kosync cannot write the old values back.
function Bellasekai:applyToKosync()
    local kosync_class
    for _, plugin in ipairs(PluginLoader.enabled_plugins or {}) do
        if plugin.name == "kosync" then
            kosync_class = plugin
            break
        end
    end
    local settings_obj = kosync_class and kosync_class.settings_obj
        or LuaSettings:open(DataStorage:getSettingsDir() .. "/kosync.lua")
    local settings = settings_obj:readSetting("settings")
    if not settings then
        settings = kosync_class and util.tableDeepCopy(kosync_class.default_settings) or {}
    end
    settings.custom_server = self:getServer() .. "/api/kosync"
    settings.username = self.settings:readSetting("username")
    settings.userkey = self.settings:readSetting("userkey")
    settings.checksum_method = KOSYNC_CHECKSUM_FILENAME
    settings_obj:saveSetting("settings", settings)
    settings_obj:flush()
    UIManager:show(InfoMessage:new{
        text = T(_("Progress sync now uses %1, matching documents by file name.\n\nEnable automatic sync in Progress sync if you want positions pushed and pulled on their own."),
            settings.custom_server),
    })
end

function Bellasekai:startSync()
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function() self:sync() end)
    end)
end

function Bellasekai:currentDocument()
    local ReaderUI = require("apps/reader/readerui")
    local reader = ReaderUI.instance
    return reader and reader.document and reader.document.file
end

local function removeBook(file)
    if not os.remove(file) then return false end
    BookList.resetBookInfoCache(file)
    DocSettings.updateLocation(file) -- deletes the sidecar
    ReadHistory:fileDeleted(file)
    return true
end

function Bellasekai:sync()
    if not Trapper:info(_("Fetching library…")) then return end
    local code, library = self:request("/api/koreader/library")
    if code ~= 200 or type(library) ~= "table" or type(library.books) ~= "table" then
        Trapper:clear()
        UIManager:show(InfoMessage:new{ text = T(_("Cannot fetch the library: %1"), errorText(code, library)) })
        return
    end

    local dir = self:getDownloadDir()
    if not util.makePath(dir) and lfs.attributes(dir, "mode") ~= "directory" then
        Trapper:clear()
        UIManager:show(InfoMessage:new{ text = T(_("Cannot create folder %1"), dir) })
        return
    end

    local state = self.settings:readSetting("books", {})
    local open_file = self:currentDocument()
    local stats = { added = 0, updated = 0, removed = 0, busy = 0, failed = {} }
    local wanted = {}

    for i, book in ipairs(library.books) do
        wanted[book.id] = true
        local path = dir .. "/" .. book.filename
        local known = state[book.id]
        local exists = lfs.attributes(path, "mode") == "file"
        if not exists or not known or known.version ~= book.version or known.file ~= path then
            if path == open_file then
                stats.busy = stats.busy + 1
            else
                if not Trapper:info(T(_("Downloading %1/%2\n%3"), i, #library.books, book.title)) then
                    break
                end
                local part = path .. ".part"
                local dl_code, err, headers = self:request("/api/koreader/books/" .. book.id, part)
                if dl_code == 200 and lfs.attributes(part, "size") and lfs.attributes(part, "size") > 0
                        and os.rename(part, path) then
                    BookList.resetBookInfoCache(path)
                    state[book.id] = {
                        file = path,
                        title = book.title,
                        version = headers and headers["x-bellasekai-version"] or book.version,
                    }
                    if exists then
                        stats.updated = stats.updated + 1
                    else
                        stats.added = stats.added + 1
                    end
                    self.settings:flush()
                else
                    os.remove(part)
                    table.insert(stats.failed, book.title .. ": " .. errorText(dl_code, err))
                end
            end
        end
    end

    if self.settings:nilOrTrue("delete_removed") then
        for id, known in pairs(state) do
            if not wanted[id] then
                if known.file == open_file then
                    stats.busy = stats.busy + 1
                else
                    if lfs.attributes(known.file, "mode") ~= "file" or removeBook(known.file) then
                        state[id] = nil
                        stats.removed = stats.removed + 1
                    end
                end
            end
        end
    end

    self.settings:saveSetting("books", state)
    self.settings:flush()
    Trapper:clear()

    if FileManager.instance then
        FileManager.instance:onRefresh()
    end

    local lines = {
        T(_("Collection: %1 · %2 books"), library.collection and library.collection.name or "?", #library.books),
        T(_("New: %1 · Updated: %2 · Removed: %3"), stats.added, stats.updated, stats.removed),
    }
    if stats.busy > 0 then
        table.insert(lines, T(_("Skipped %1 (open in the reader, sync again after closing it)"), stats.busy))
    end
    if #stats.failed > 0 then
        table.insert(lines, _("Failed:"))
        for _, line in ipairs(stats.failed) do
            table.insert(lines, line)
        end
    end
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
end

return Bellasekai
