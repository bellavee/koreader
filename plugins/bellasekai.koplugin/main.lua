--[[--
Bindery: mirrors a bellasekai book collection onto the device.

Shown to the user as "Bindery" (the name of the books section on the site); the plugin
id, settings file and EPUB file names keep "bellasekai" so existing installs and the
server-side progress matching keep working.

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
local ButtonDialog = require("ui/widget/buttondialog")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local DocSettings = require("docsettings")
local Event = require("ui/event")
local FileManager = require("apps/filemanager/filemanager")
local InfoMessage = require("ui/widget/infomessage")
local JSON = require("json")
local LuaSettings = require("luasettings")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local PathChooser = require("ui/widget/pathchooser")
local PluginLoader = require("pluginloader")
local ReadCollection = require("readcollection")
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

local BRAND = "Bindery"

-- Material Design glyphs from the Nerd Font symbols, used by the fallback dialogs when
-- ZenOS is not installed.
local ICONS = {
    settings = "\u{F0493}",
    sync     = "\u{F04E6}",
    account  = "\u{F0013}",
    folder   = "\u{F0256}",
    delete   = "\u{F0156}",
    connect  = "\u{F0337}",
    unread   = "\u{F00BA}",
    reading  = "\u{F14F7}",
    finished = "\u{F012C}",
    on_hold  = "\u{F03E4}",
    check    = "\u{2713}",
}


local Bellasekai = WidgetContainer:extend{
    name = "bellasekai",
    is_doc_only = false,
    settings_file = DataStorage:getSettingsDir() .. "/bellasekai.lua",
}

function Bellasekai:init()
    -- One settings object for every instance: the file manager and the reader each get
    -- their own plugin instance, and separate copies would flush stale data over a sync
    -- made from the other one.
    if not Bellasekai.shared_settings then
        Bellasekai.shared_settings = LuaSettings:open(self.settings_file)
    end
    self.settings = Bellasekai.shared_settings
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
end

--- "Bindery" as a dispatcher action: a ZenOS Navbar tab (Add > Action), a gesture or a
-- Controls button can open the book list with it.
function Bellasekai:onDispatcherRegisterActions()
    Dispatcher:registerAction("bindery_show_library", {
        category = "none",
        event = "BinderyShowLibrary",
        title = BRAND,
        general = true,
    })
end

function Bellasekai:onBinderyShowLibrary()
    self:showLibraryDialog()
    return true
end

--- "Synced 23:05 04/10" (plus failures), or why there is nothing to show yet.
function Bellasekai:syncedText()
    local last = self.settings:readSetting("last_sync")
    if not last then
        return _("Never synced")
    end
    local text = T(_("Synced %1"), os.date("%H:%M %d/%m", last.time))
    if (last.failed or 0) > 0 then
        text = text .. " · " .. T(_("%1 failed"), last.failed)
    end
    return text
end

--- Books of the collection that are on the device, alphabetically.
function Bellasekai:localBooks()
    local books = {}
    for id, known in pairs(self.settings:readSetting("books") or {}) do
        if known.file and lfs.attributes(known.file, "mode") == "file" then
            table.insert(books, { id = id, file = known.file, title = known.title or id })
        end
    end
    table.sort(books, function(a, b) return a.title < b.title end)
    return books
end

local BOOK_STATUS = {
    new       = { glyph = ICONS.unread,   label = _("Unread") },
    reading   = { glyph = ICONS.reading,  label = _("Reading") },
    complete  = { glyph = ICONS.finished, label = _("Finished") },
    abandoned = { glyph = ICONS.on_hold,  label = _("On hold") },
}

--- Read status of a book, as an icon and a "Reading · 42%" line.
function Bellasekai:bookStatus(book)
    local info = BookList.getBookInfo(book.file)
    local status = info.been_opened and info.status or "new"
    local entry = BOOK_STATUS[status] or BOOK_STATUS.new
    local detail = entry.label
    if status ~= "complete" and info.percent_finished then
        detail = detail .. " · " .. math.floor(info.percent_finished * 100) .. "%"
    end
    return entry, detail
end

function Bellasekai:openBook(file)
    require("apps/reader/readerui"):showReader(file)
end

--- KOReader's gear for the Settings button. List rows stay text-only: SVG icons drawn
-- as list images in the ZenOS picker came out as solid black shapes on the device.
local SETTINGS_ICON = "resources/icons/mdlight/appbar.settings.svg"

--- ZenOS' full-screen list: title bar with a back arrow and an action button, rows
-- with an icon and a detail line. nil without ZenOS, and callers fall back to dialogs.
local function zenPicker()
    local ok, picker = pcall(require, "common/ui/zen_menu_picker")
    return ok and type(picker) == "function" and picker or nil
end

--- What the Home widget opens: the books in the download folder, with Settings behind
-- the gear in the title bar.
function Bellasekai:showLibraryDialog()
    local picker = zenPicker()
    if not picker then
        return self:showLibraryButtons()
    end
    local configured = self:isConfigured()
    local items = {{
        text = self:syncedText(),
        secondary_text = configured and _("Tap to sync now") or _("Set up the account in Settings"),
        sync = true,
    }}
    for _i, book in ipairs(self:localBooks()) do
        local entry, detail = self:bookStatus(book)
        table.insert(items, {
            text = book.title,
            secondary_text = detail,
            file = book.file,
        })
    end
    if #items == 1 then
        table.insert(items, {
            text = configured and _("No books yet") or _("Not set up"),
            secondary_text = _("Tap the gear to open Settings and sync"),
            keep_open = true,
        })
    end
    picker{
        title = BRAND,
        items = items,
        title_action_icon = SETTINGS_ICON,
        title_action_callback = function() self:showSettingsDialog() end,
        on_select = function(item)
            if item.sync then
                self:runSettingsEntry(self:settingsEntries()[1])
            elseif item.file then
                self:openBook(item.file)
            end
        end,
    }
end

--- Settings rows, shared by the ZenOS page and the fallback dialog.
function Bellasekai:settingsEntries()
    local configured = self:isConfigured() and true or false
    local last = self.settings:readSetting("last_sync")
    local server = self:getServer()
    return {
        {
            glyph = ICONS.sync,
            text = _("Sync library"),
            detail = last and T(_("Last sync %1"), os.date("%H:%M %d/%m", last.time)) or _("Never synced"),
            enabled = configured,
            action = function() self:startSync() end,
        },
        {
            glyph = ICONS.account,
            text = _("Server and account"),
            detail = configured
                and (self.settings:readSetting("username") .. " · " .. server:gsub("^https?://", ""))
                or _("Not set up"),
            action = function() self:showAccountDialog() end,
        },
        {
            glyph = ICONS.folder,
            text = _("Download folder"),
            detail = self:getDownloadDir(),
            action = function()
                self:chooseDownloadDir(nil, function() self:showSettingsDialog() end)
            end,
        },
        {
            glyph = ICONS.delete,
            text = _("Delete books removed from the collection"),
            detail = self.settings:nilOrTrue("delete_removed") and _("On") or _("Off"),
            action = function()
                self.settings:flipNilOrTrue("delete_removed")
                self.settings:flush()
                self:showSettingsDialog()
            end,
        },
        {
            glyph = ICONS.connect,
            text = _("Apply to Progress sync"),
            detail = configured and (server .. "/api/kosync") or _("Set up the account first"),
            enabled = configured,
            action = function() self:applyToKosync() end,
        },
    }
end

function Bellasekai:runSettingsEntry(entry)
    if entry.enabled == false then
        UIManager:show(InfoMessage:new{ text = _("Set up the server and account first."), timeout = 3 })
        return
    end
    entry.action()
end

function Bellasekai:showSettingsDialog()
    local entries = self:settingsEntries()
    local picker = zenPicker()
    if not picker then
        return self:showSettingsButtons(entries)
    end
    local items = {}
    for _i, entry in ipairs(entries) do
        table.insert(items, {
            text = entry.text,
            secondary_text = entry.detail,
            entry = entry,
        })
    end
    picker{
        title = T(_("%1 · Settings"), BRAND),
        items = items,
        on_select = function(item) self:runSettingsEntry(item.entry) end,
        -- Back (no item) returns to the book list; picking a row runs it instead.
        on_close = function(item)
            if not item then self:showLibraryDialog() end
        end,
    }
end

--- Fallback without ZenOS: the same content as plain dialogs with inline glyphs.
function Bellasekai:showLibraryButtons()
    local dialog
    local buttons = {{{
        text = ICONS.sync .. "  " .. self:syncedText(),
        align = "left",
        callback = function()
            UIManager:close(dialog)
            self:runSettingsEntry(self:settingsEntries()[1])
        end,
    }}}
    local books = self:localBooks()
    for _i, book in ipairs(books) do
        local entry, detail = self:bookStatus(book)
        table.insert(buttons, {{
            text = entry.glyph .. "  " .. book.title .. "  ·  " .. detail,
            align = "left",
            callback = function()
                UIManager:close(dialog)
                self:openBook(book.file)
            end,
        }})
    end
    if #books == 0 then
        table.insert(buttons, {{
            text = ICONS.unread .. "  " .. _("No books yet"),
            align = "left",
            enabled = false,
        }})
    end
    table.insert(buttons, {{
        text = ICONS.settings .. "  " .. _("Settings"),
        align = "left",
        callback = function()
            UIManager:close(dialog)
            self:showSettingsDialog()
        end,
    }})
    dialog = ButtonDialog:new{
        title = BRAND,
        title_align = "left",
        buttons = buttons,
        rows_per_page = #buttons > 10 and 10 or nil,
    }
    UIManager:show(dialog)
end

function Bellasekai:showSettingsButtons(entries)
    local dialog
    local buttons = {}
    for _i, entry in ipairs(entries) do
        table.insert(buttons, {{
            text = entry.glyph .. "  " .. entry.text .. "  ·  " .. entry.detail,
            align = "left",
            callback = function()
                UIManager:close(dialog)
                self:runSettingsEntry(entry)
            end,
        }})
    end
    dialog = ButtonDialog:new{
        title = T(_("%1 · Settings"), BRAND),
        title_align = "left",
        buttons = buttons,
    }
    UIManager:show(dialog)
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
        or (G_reader_settings:readSetting("home_dir") or Device.home_dir or DataStorage:getDataDir()) .. "/" .. BRAND
end

function Bellasekai:isConfigured()
    return self:getServer() and self.settings:readSetting("username") and self.settings:readSetting("userkey")
end

--- Tools > Bindery (and a ZenOS "Plugin Menu" tab, which reuses this entry) opens the
-- same book list as the action; every setting lives behind its gear.
function Bellasekai:addToMainMenu(menu_items)
    menu_items.bellasekai = {
        text = BRAND,
        sorting_hint = "tools",
        callback = function() self:showLibraryDialog() end,
    }
end

function Bellasekai:showAccountDialog()
    local dialog
    dialog = MultiInputDialog:new{
        title = T(_("%1 server"), BRAND),
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

function Bellasekai:chooseDownloadDir(touchmenu_instance, on_done)
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
            if on_done then on_done() end
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
            ["Accept"] = filepath and "*/*" or "application/json",
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
            UIManager:show(InfoMessage:new{ text = T(_("Logged in to %1."), BRAND), timeout = 3 })
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
    -- Push on close/suspend and pull on open; without it nothing reaches the server
    -- unless positions are pushed by hand.
    settings.auto_sync = true
    settings_obj:saveSetting("settings", settings)
    settings_obj:flush()
    UIManager:show(InfoMessage:new{
        text = T(_("Progress sync now uses %1, matching documents by file name, with automatic sync on: positions are pushed when a book is closed or the device sleeps, and pulled when a book is opened."),
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

--- Forgets what is cached about a file's metadata and cover, like KOReader's and ZenOS'
-- metadata editors do. A refreshed EPUB has no embedded cover, so the cover shown is drawn
-- from the cached title; without this a renamed book keeps its old title on the cover.
local function forgetCachedInfo(file)
    BookList.resetBookInfoCache(file)
    local ok, BookInfoManager = pcall(require, "bookinfomanager")
    if ok and type(BookInfoManager) == "table" and BookInfoManager.deleteBookInfo then
        pcall(BookInfoManager.deleteBookInfo, BookInfoManager, file)
    end
    UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", file))
end

--- ZenOS keeps rendered covers in memory by path; drop them once after a sync changed files.
local function clearCoverCaches()
    for _i, name in ipairs({ "common/cover_render_cache", "common/cover_decode_cache" }) do
        local ok, cache = pcall(require, name)
        if ok and type(cache) == "table" and type(cache.clear) == "function" then
            pcall(cache.clear, cache)
        end
    end
    UIManager:broadcastEvent(Event:new("BookMetadataChanged"))
end

--- Moves a book with everything KOReader keeps about it, as the file manager does.
local function moveBook(file, dest)
    if not os.rename(file, dest) then return false end
    forgetCachedInfo(file)
    DocSettings.updateLocation(file, dest)
    ReadHistory:updateItem(file, dest)
    ReadCollection:updateItem(file, dest)
    return true
end

local function removeBook(file)
    if not os.remove(file) then return false end
    forgetCachedInfo(file)
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
    local stats = { added = 0, updated = 0, removed = 0, moved = 0, busy = 0, failed = {} }
    local wanted = {}
    local old_dirs = {}

    for i, book in ipairs(library.books) do
        wanted[book.id] = true
        -- Documents (PDF, sheet music…) go to a subfolder per category; books stay at the top.
        local book_dir = book.folder and (dir .. "/" .. book.folder) or dir
        if book_dir ~= dir then util.makePath(book_dir) end
        local path = book_dir .. "/" .. book.filename
        local known = state[book.id]
        -- Download folder changed (e.g. the Bellasekai -> Bindery rename): move the book
        -- instead of downloading it again, so its reading position comes along.
        if known and known.file and known.file ~= path and known.file ~= open_file
                and lfs.attributes(known.file, "mode") == "file"
                and lfs.attributes(path, "mode") == nil then
            local old_dir = util.splitFilePathName(known.file)
            if moveBook(known.file, path) then
                old_dirs[old_dir] = true
                known.file = path
                stats.moved = stats.moved + 1
            end
        end
        local exists = lfs.attributes(path, "mode") == "file"
        if not exists or not known or known.version ~= book.version or known.file ~= path then
            if path == open_file then
                stats.busy = stats.busy + 1
            else
                if not Trapper:info(T(_("Downloading %1/%2\n%3"), i, #library.books, book.title)) then
                    break
                end
                local part = path .. ".part"
                local dl_code, err, headers = self:request(book.download or ("/api/koreader/books/" .. book.id), part)
                if dl_code == 200 and lfs.attributes(part, "size") and lfs.attributes(part, "size") > 0
                        and os.rename(part, path) then
                    forgetCachedInfo(path)
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
                    local removed_dir = util.splitFilePathName(known.file)
                    if lfs.attributes(known.file, "mode") ~= "file" or removeBook(known.file) then
                        if removed_dir ~= dir .. "/" then old_dirs[removed_dir] = true end
                        state[id] = nil
                        stats.removed = stats.removed + 1
                    end
                end
            end
        end
    end

    for old_dir in pairs(old_dirs) do
        lfs.rmdir(old_dir) -- only succeeds once nothing is left in it
    end

    if stats.added + stats.updated + stats.removed + stats.moved > 0 then
        clearCoverCaches()
    end

    self.settings:saveSetting("books", state)
    self.settings:saveSetting("last_sync", {
        time = os.time(),
        collection = library.collection and library.collection.name,
        failed = #stats.failed,
    })
    self.settings:flush()
    Trapper:clear()

    if FileManager.instance then
        FileManager.instance:onRefresh()
    end

    local lines = {
        library.collection and T(_("Collection: %1 · %2 items"), library.collection.name, #library.books)
            or T(_("%1 items"), #library.books),
        T(_("New: %1 · Updated: %2 · Removed: %3"), stats.added, stats.updated, stats.removed),
    }
    if stats.moved > 0 then
        table.insert(lines, T(_("Moved %1 to %2"), stats.moved, dir))
    end
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
