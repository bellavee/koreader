--[[--
Reading tools of the Bindery plugin, added to the highlight menu:

  * Lens     — quick AI translation of the selection.
  * Annotate — translation plus meaning in context, grammar notes and examples.
  * Flag     — report a bad translation (wrong form of address, leftover Chinese, wrong
               meaning, name, other). Wrong forms of address use a template: who calls
               whom, the right word and the wrong one. Flags made offline are queued and
               sent on the next library sync.

Everything goes through the bellasekai server with the device account: the AI keys stay
on the server, and Bindery books get their Story Memory (names, forms of address).

Mixed into the plugin class by main.lua; every function takes the plugin instance.

@module koplugin.Bellasekai.tools
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local JSON = require("json")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local http = require("socket.http")
local logger = require("logger")
local ltn12 = require("ltn12")
local md5 = require("ffi/sha2").md5
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local Tools = {}

local LANGUAGES = {
    { key = "vi", label = "Tiếng Việt" },
    { key = "en", label = "English" },
    { key = "fr", label = "Français" },
}

local ISSUE_KINDS = {
    { key = "address", label = "Xưng hô" },
    { key = "untranslated", label = "Còn Hán tự" },
    { key = "meaning", label = "Sai nghĩa" },
    { key = "name", label = "Tên riêng" },
    { key = "other", label = "Khác" },
}

local MAX_SELECTION = 1000

function Tools:assistLanguage()
    local key = self.settings:readSetting("assist_language") or "vi"
    for _i, lang in ipairs(LANGUAGES) do
        if lang.key == key then return lang end
    end
    return LANGUAGES[1]
end

function Tools:cycleAssistLanguage()
    local current = self:assistLanguage().key
    for i, lang in ipairs(LANGUAGES) do
        if lang.key == current then
            local next_lang = LANGUAGES[i % #LANGUAGES + 1]
            self.settings:saveSetting("assist_language", next_lang.key)
            self.settings:flush()
            return next_lang
        end
    end
end

--- POST a JSON body; returns status code and decoded JSON (or an error text).
function Tools:postJson(path, payload, timeout)
    local body = JSON.encode(payload)
    local chunks = {}
    -- AI answers can take a while before the first byte: wait longer than for metadata.
    socketutil:set_timeout(timeout or 60, (timeout or 60) + 30)
    local request = {
        url = self:getServer() .. path,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#body),
            ["Accept"] = "application/json",
            ["Accept-Encoding"] = "identity",
            ["x-auth-user"] = self.settings:readSetting("username"),
            ["x-auth-key"] = self.settings:readSetting("userkey"),
        },
        source = ltn12.source.string(body),
        sink = socketutil.table_sink(chunks),
    }
    logger.dbg("Bellasekai: POST", request.url)
    local code, headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()
    if headers == nil then
        return nil, status or code or _("network unreachable")
    end
    local text = table.concat(chunks)
    local ok, decoded = pcall(JSON.decode, text)
    if ok and type(decoded) == "table" then return code, decoded end
    return code, text ~= "" and text or status
end

local function responseError(code, body)
    if type(body) == "table" and body.message then return body.message end
    if code == 401 then return _("Wrong username or password.") end
    return tostring(body or code)
end

--- md5 of the open document's file name: how the server recognises Bindery books.
function Tools:currentDocumentDigest()
    local file = self.ui.document and self.ui.document.file
    if not file then return nil end
    local _dir, name = util.splitFilePathName(file)
    return name and md5(name) or nil
end

--- Selected text, a little context around it, and its position, captured before the
-- highlight menu closes (closing clears the selection).
local function captureSelection(highlight)
    local selected = highlight.selected_text
    if not (selected and selected.text and selected.text ~= "") then return nil end
    local text = util.cleanupSelectedText(selected.text)
    local ok, before, after = pcall(highlight.getSelectedWordContext, highlight, 30)
    local context = ok and table.concat({ before or "", text, after or "" }, " ") or text
    return {
        text = text,
        context = context,
        position = type(selected.pos0) == "string" and selected.pos0 or nil,
    }
end

function Tools:addHighlightButtons()
    local highlight = self.ui.highlight
    if not (highlight and highlight.addToHighlightDialog) then return end
    -- "12_…" sorts just before KOReader's own "12_search", at the end of the menu.
    local function button(key, text, handler)
        highlight:addToHighlightDialog(key, function(this)
            return {
                text = text,
                callback = function()
                    local selection = captureSelection(this)
                    this:onClose()
                    if selection then handler(selection) end
                end,
            }
        end)
    end
    button("12_bindery_1_lens", "Lens", function(selection) self:runAssist("lens", selection) end)
    button("12_bindery_2_annotate", "Annotate", function(selection) self:runAssist("annotate", selection) end)
    button("12_bindery_3_flag", "Flag", function(selection) self:showFlagDialog(selection) end)
end

--- The same three actions in the dictionary popup, which is what a long-press on a single
-- word opens (the highlight menu only appears for a multi-word selection).
function Tools:dictActions()
    return {
        { id = "bindery_1_lens", text = "Lens", run = function(selection) self:runAssist("lens", selection) end },
        { id = "bindery_2_annotate", text = "Annotate", run = function(selection) self:runAssist("annotate", selection) end },
        { id = "bindery_3_flag", text = "Flag", run = function(selection) self:showFlagDialog(selection) end },
    }
end

local function selectionFromPopup(popup)
    local selection = popup.highlight and captureSelection(popup.highlight)
    if selection then return selection end
    local word = popup.word or popup.lookupword
    if not word or word == "" then return nil end
    return { text = word, context = word }
end

function Tools:addDictButtons()
    local dictionary = self.ui.dictionary
    if not (dictionary and dictionary.addToDictButtons) then return end
    for _i, action in ipairs(self:dictActions()) do
        dictionary:addToDictButtons({
            id = action.id,
            text = action.text,
            conditional = true,
            row_group = "bindery",
            show_func = function(popup) return not popup.is_wiki end,
            callback = function(popup)
                local selection = selectionFromPopup(popup)
                popup:onClose()
                if selection then action.run(selection) end
            end,
        })
    end
end

--- Older KOReader without addToDictButtons: append the row when the popup builds.
function Tools:onDictButtonsReady(popup, buttons)
    if (self.ui.dictionary and self.ui.dictionary.addToDictButtons) or popup.is_wiki then return end
    local row = {}
    for _i, action in ipairs(self:dictActions()) do
        table.insert(row, {
            id = action.id,
            text = action.text,
            callback = function()
                local selection = selectionFromPopup(popup)
                popup:onClose()
                if selection then action.run(selection) end
            end,
        })
    end
    table.insert(buttons, row)
end

function Tools:runAssist(mode, selection)
    if not self:isConfigured() then
        UIManager:show(InfoMessage:new{ text = _("Set up the server and account first."), timeout = 3 })
        return
    end
    if #selection.text > MAX_SELECTION then
        UIManager:show(InfoMessage:new{ text = T(_("Select at most %1 characters."), MAX_SELECTION), timeout = 3 })
        return
    end
    local title = mode == "lens" and "Lens" or "Annotate"
    local language = self:assistLanguage()
    NetworkMgr:runWhenOnline(function()
        local waiting = InfoMessage:new{ text = title .. "…" }
        UIManager:show(waiting)
        UIManager:forceRePaint()
        local code, body = self:postJson("/api/koreader/assist", {
            mode = mode,
            text = selection.text,
            context = selection.context,
            position = selection.position,
            document = self:currentDocumentDigest(),
            target = language.key,
        })
        UIManager:close(waiting)
        if code ~= 200 or type(body) ~= "table" or not body.text then
            UIManager:show(InfoMessage:new{ text = T(_("%1 failed: %2"), title, responseError(code, body)) })
            return
        end
        UIManager:show(TextViewer:new{
            title = T("%1 · %2", title, language.label),
            text = body.text .. "\n\n— " .. selection.text,
            justified = false,
        })
    end)
end

--- Flags waiting to be sent (made offline, or when sending failed).
function Tools:pendingIssues()
    return self.settings:readSetting("pending_issues") or {}
end

--- Sends queued flags; keeps those that failed for a reason worth retrying.
function Tools:flushIssues()
    local pending = self:pendingIssues()
    if #pending == 0 then return 0, 0 end
    local code, body = self:postJson("/api/koreader/issues", { issues = pending }, 20)
    if code ~= 200 or type(body) ~= "table" or type(body.results) ~= "table" then
        return 0, #pending
    end
    local keep = {}
    local sent = 0
    for i, item in ipairs(pending) do
        local result = body.results[i]
        if result and result.ok then
            sent = sent + 1
        elseif not result or result.retry then
            table.insert(keep, item)
        else
            logger.warn("Bellasekai: dropping flag:", result.message)
        end
    end
    self.settings:saveSetting("pending_issues", keep)
    self.settings:flush()
    return sent, #keep
end

function Tools:queueIssue(issue)
    local pending = self:pendingIssues()
    table.insert(pending, issue)
    self.settings:saveSetting("pending_issues", pending)
    self.settings:flush()
    if NetworkMgr:isOnline() then
        local sent, left = self:flushIssues()
        if sent > 0 and left == 0 then
            UIManager:show(InfoMessage:new{ text = _("Flag sent."), timeout = 2 })
            return
        end
    end
    UIManager:show(InfoMessage:new{ text = _("Flag saved, it will be sent on the next sync."), timeout = 3 })
end

function Tools:showFlagDialog(selection)
    if not self:isConfigured() then
        UIManager:show(InfoMessage:new{ text = _("Set up the server and account first."), timeout = 3 })
        return
    end
    local base = {
        document = self:currentDocumentDigest(),
        position = selection.position,
        excerpt = selection.text:sub(1, MAX_SELECTION),
    }
    local dialog
    local buttons = {}
    for _i, kind in ipairs(ISSUE_KINDS) do
        table.insert(buttons, {{
            text = kind.label,
            align = "left",
            callback = function()
                UIManager:close(dialog)
                if kind.key == "address" then
                    self:showAddressTemplate(base)
                else
                    self:showFlagNote(base, kind)
                end
            end,
        }})
    end
    dialog = ButtonDialog:new{
        title = "Flag · " .. util.cleanupSelectedText(selection.text):sub(1, 80),
        title_align = "left",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

--- The usual case gets a template: "A gọi B là 'chị', không phải 'cô'".
function Tools:showAddressTemplate(base)
    local dialog
    dialog = MultiInputDialog:new{
        title = "Xưng hô",
        fields = {
            { hint = "Người gọi (A)" },
            { hint = "Người được gọi (B)" },
            { hint = "Gọi đúng là (vd: chị)" },
            { hint = "Không phải (vd: cô) — tuỳ chọn" },
        },
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Send"),
                is_enter_default = true,
                callback = function()
                    local f = dialog:getFields()
                    local speaker, addressee, correct = util.trim(f[1]), util.trim(f[2]), util.trim(f[3])
                    if speaker == "" or addressee == "" or correct == "" then
                        UIManager:show(InfoMessage:new{ text = "Cần điền người gọi, người được gọi và cách gọi đúng.", timeout = 3 })
                        return
                    end
                    UIManager:close(dialog)
                    local issue = util.tableDeepCopy(base)
                    issue.kind = "address"
                    issue.details = { speaker = speaker, addressee = addressee, correct = correct, wrong = util.trim(f[4]) }
                    self:queueIssue(issue)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Tools:showFlagNote(base, kind)
    local dialog
    dialog = InputDialog:new{
        title = "Flag · " .. kind.label,
        input_hint = "Ghi chú (tuỳ chọn)",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Send"),
                is_enter_default = true,
                callback = function()
                    local note = util.trim(dialog:getInputText() or "")
                    UIManager:close(dialog)
                    local issue = util.tableDeepCopy(base)
                    issue.kind = kind.key
                    issue.note = note
                    self:queueIssue(issue)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return Tools
