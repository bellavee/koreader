--[[--
Passcode: asks for a 4-digit PIN when KOReader starts and when the device wakes up, like
the stock Kobo passcode, which no longer applies once KOReader is running.

This is a UI lock, not encryption: the files stay readable over USB, and deleting the
"passcode" entry from settings.reader.lua over USB removes the lock if the PIN is lost.

The PIN is stored as a salted SHA-256, never in clear.

@module koplugin.passcode
--]]

local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local LockScreen = require("passcode_lockscreen")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local sha256 = require("ffi/sha2").sha256
local T = require("ffi/util").template

local PIN_LENGTH = 4
local DELAYS = { 0, 5, 15, 60 } -- minutes asleep before the next wake asks for the PIN

local Passcode = WidgetContainer:extend{
    name = "passcode",
    is_doc_only = false,
}

-- Shared by the file manager and reader instances: one lock screen at a time, one
-- "locked at startup" per KOReader session, one suspend timestamp.
local state = {
    screen = nil,
    started = false,
    suspended_at = nil,
}

local function settings()
    return G_reader_settings:readSetting("passcode") or {}
end

local function saveSettings(s)
    G_reader_settings:saveSetting("passcode", s)
    G_reader_settings:flush()
end

local function hashPin(pin, salt)
    return sha256(salt .. ":" .. pin)
end

local function isEnabled()
    local s = settings()
    return s.enabled == true and type(s.hash) == "string" and s.hash ~= ""
end

local function checkPin(pin)
    local s = settings()
    return s.hash ~= nil and hashPin(pin, s.salt or "") == s.hash
end

local function newSalt()
    math.randomseed(os.time() + math.floor(os.clock() * 1e6))
    local t = {}
    for i = 1, 16 do t[i] = string.format("%x", math.random(0, 15)) end
    return table.concat(t)
end

function Passcode:init()
    Dispatcher:registerAction("passcode_lock_now", {
        category = "none",
        event = "PasscodeLockNow",
        title = "Khoá máy bằng mã PIN",
        general = true,
    })
    self.ui.menu:registerToMainMenu(self)

    -- Lock once when KOReader starts, like the stock firmware does at boot.
    if not state.started then
        state.started = true
        if isEnabled() then
            UIManager:nextTick(function() Passcode.lock() end)
        end
    end
end

--- Shows the lock screen until the right PIN is typed. Safe to call repeatedly.
function Passcode.lock()
    if state.screen or not isEnabled() then return end
    state.screen = LockScreen:new{
        title = "Vui lòng nhập mã PIN 4 số.",
        length = PIN_LENGTH,
        on_complete = function(pin)
            if checkPin(pin) then
                state.screen = nil
                return true
            end
            return "Sai mã PIN. Vui lòng thử lại."
        end,
        on_forgot = function()
            UIManager:show(InfoMessage:new{
                text = "Cắm máy vào máy tính, mở .adds/koreader/settings.reader.lua và xoá mục \"passcode\". Mở lại KOReader là hết khoá.",
            })
        end,
    }
    UIManager:show(state.screen)
end

function Passcode:onPasscodeLockNow()
    if isEnabled() then
        Passcode.lock()
    else
        UIManager:show(InfoMessage:new{ text = "Chưa bật khoá mã PIN.", timeout = 2 })
    end
    return true
end

function Passcode:onSuspend()
    state.suspended_at = os.time()
end

function Passcode:onResume()
    if not isEnabled() then return end
    local delay = (settings().delay or 0) * 60
    local slept = state.suspended_at and (os.time() - state.suspended_at) or math.huge
    if slept >= delay then
        -- Shown before the first repaint after wake-up, so the page never flashes through.
        Passcode.lock()
    end
end

--- Asks for a PIN on a cancellable screen; `step(pin)` returns true, or an error string.
local function askPin(title, step, on_cancel)
    UIManager:show(LockScreen:new{
        title = title,
        length = PIN_LENGTH,
        on_complete = step,
        on_cancel = on_cancel or function() end,
    })
end

--- New PIN twice, then `done(pin)`.
local function chooseNewPin(done)
    askPin("Nhập mã PIN mới gồm 4 số.", function(first)
        UIManager:nextTick(function()
            askPin("Nhập lại mã PIN mới.", function(second)
                if second ~= first then return "Hai mã không khớp. Vui lòng thử lại." end
                done(second)
                return true
            end)
        end)
        return true
    end)
end

--- Runs `action` after the current PIN is confirmed.
local function withCurrentPin(action)
    askPin("Vui lòng nhập mã PIN hiện tại.", function(pin)
        if not checkPin(pin) then return "Sai mã PIN. Vui lòng thử lại." end
        UIManager:nextTick(action)
        return true
    end)
end

local function storePin(pin, extra)
    local s = settings()
    s.salt = newSalt()
    s.hash = hashPin(pin, s.salt)
    for k, v in pairs(extra or {}) do s[k] = v end
    saveSettings(s)
end

function Passcode:addToMainMenu(menu_items)
    local delay_items = {}
    for _i, minutes in ipairs(DELAYS) do
        table.insert(delay_items, {
            text = minutes == 0 and "Mỗi lần thức dậy" or T("Ngủ quá %1 phút", minutes),
            checked_func = function() return (settings().delay or 0) == minutes end,
            radio = true,
            callback = function()
                local s = settings()
                s.delay = minutes
                saveSettings(s)
            end,
        })
    end

    menu_items.passcode = {
        text = "Mã PIN",
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = "Khoá bằng mã PIN",
                checked_func = isEnabled,
                callback = function(touchmenu_instance)
                    local refresh = function()
                        if touchmenu_instance and touchmenu_instance.updateItems then touchmenu_instance:updateItems() end
                    end
                    if isEnabled() then
                        withCurrentPin(function()
                            local s = settings()
                            s.enabled = false
                            saveSettings(s)
                            refresh()
                            UIManager:show(InfoMessage:new{ text = "Đã tắt khoá mã PIN.", timeout = 2 })
                        end)
                    else
                        chooseNewPin(function(pin)
                            storePin(pin, { enabled = true })
                            refresh()
                            UIManager:show(InfoMessage:new{ text = "Đã bật khoá mã PIN.", timeout = 2 })
                        end)
                    end
                end,
            },
            {
                text = "Đổi mã PIN",
                enabled_func = isEnabled,
                callback = function()
                    withCurrentPin(function()
                        chooseNewPin(function(pin)
                            storePin(pin)
                            UIManager:show(InfoMessage:new{ text = "Đã đổi mã PIN.", timeout = 2 })
                        end)
                    end)
                end,
            },
            {
                text = "Hỏi mã khi",
                enabled_func = isEnabled,
                sub_item_table = delay_items,
            },
            {
                text = "Khoá ngay",
                enabled_func = isEnabled,
                callback = function() Passcode.lock() end,
            },
        },
    }
end

return Passcode
