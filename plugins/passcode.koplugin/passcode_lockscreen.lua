--[[--
Full-screen passcode screen: clock, a row of PIN dots and a round keypad, in the spirit
of the stock Kobo lock screen.

Everything is painted by hand in `paintTo` and taps are hit-tested against the keypad, so
the widget can swallow every gesture and key press: nothing below it (the book, the file
manager, ZenOS gestures) reacts while it is shown. `covers_fullscreen` also stops
UIManager from repainting what is underneath, so the page never shows through.

@module koplugin.passcode.lockscreen
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local Screen = Device.screen

local WEEKDAYS = { "Chủ Nhật", "Thứ Hai", "Thứ Ba", "Thứ Tư", "Thứ Năm", "Thứ Sáu", "Thứ Bảy" }

-- Be Vietnam Pro when the user installed it into the Kobo fonts folder, else KOReader's
-- UI font (Noto Sans) — both carry full Vietnamese diacritics.
local FONT_DIRS = { "/mnt/onboard/fonts/", "./fonts/" }
local function face(weight, size)
    for _i, dir in ipairs(FONT_DIRS) do
        local path = dir .. "BeVietnamPro-" .. weight .. ".ttf"
        if lfs.attributes(path, "mode") == "file" then
            local f = Font:getFace(path, size)
            if f then return f end
        end
    end
    return Font:getFace(weight == "Regular" and "cfont" or "tfont", size)
end

local LockScreen = InputContainer:extend{
    name = "passcode_lockscreen",
    covers_fullscreen = true,
    -- Set by the caller:
    title = "Nhập mã PIN",
    length = 4,
    on_complete = nil, -- function(pin) -> true to close, or a string error to show
    on_cancel = nil,   -- when set, the bottom-left key reads "Huỷ" and calls it
    show_clock = true,
}

function LockScreen:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.input = ""
    self.message = nil
    self.pressed = nil
    self.keys = {}
    -- Refresh the clock once a minute while visible.
    self.tick = function()
        UIManager:setDirty(self, "ui", self.clock_dimen)
        UIManager:scheduleIn(60 - tonumber(os.date("%S")), self.tick)
    end
    if self.show_clock then
        UIManager:scheduleIn(60 - tonumber(os.date("%S")), self.tick)
    end
end

function LockScreen:onCloseWidget()
    UIManager:unschedule(self.tick)
end

function LockScreen:onShow()
    UIManager:setDirty(self, "full")
    return true
end

local function centered(bb, widget, cx, y)
    local size = widget:getSize()
    widget:paintTo(bb, math.floor(cx - size.w / 2), y)
    local h = size.h
    widget:free()
    return h
end

function LockScreen:layout(w, h)
    local short = math.min(w, h)
    local L = { w = w, h = h }
    L.key_d = math.floor(short * 0.165)                 -- keypad button diameter
    L.key_gap_x = math.floor(short * 0.085)
    L.key_gap_y = math.floor(short * 0.045)
    local pad_w = 3 * L.key_d + 2 * L.key_gap_x
    local pad_h = 4 * L.key_d + 3 * L.key_gap_y
    L.pad_x = math.floor((w - pad_w) / 2)
    L.pad_y = h - pad_h - math.floor(h * 0.07)
    L.dot_r = math.floor(short * 0.016)
    L.dot_gap = math.floor(short * 0.06)
    L.dots_y = L.pad_y - math.floor(h * 0.11)
    L.title_y = L.dots_y - math.floor(h * 0.075)
    L.message_y = L.dots_y + L.dot_r + math.floor(h * 0.025)
    L.clock_y = math.floor(h * 0.07)
    return L
end

function LockScreen:paintTo(bb, x, y)
    local w, h = self.dimen.w, self.dimen.h
    self.dimen.x, self.dimen.y = x, y
    local L = self:layout(w, h)
    self.L = L
    local cx = x + math.floor(w / 2)
    local black, white = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
    local grey = Blitbuffer.COLOR_DARK_GRAY

    bb:paintRect(x, y, w, h, white)

    if self.show_clock then
        local clock_top = y + L.clock_y
        local th = centered(bb, TextWidget:new{
            text = os.date("%H:%M"),
            face = face("Regular", 64),
            fgcolor = black,
        }, cx, clock_top)
        local t = os.date("*t")
        local dh = centered(bb, TextWidget:new{
            text = string.format("%s, %d tháng %d", WEEKDAYS[t.wday], t.day, t.month),
            face = face("Regular", 18),
            fgcolor = grey,
        }, cx, clock_top + th + Screen:scaleBySize(4))
        self.clock_dimen = Geom:new{ x = x, y = clock_top, w = w, h = th + dh + Screen:scaleBySize(8) }
    end

    centered(bb, TextWidget:new{
        text = self.title,
        face = face("Medium", 20),
        fgcolor = black,
    }, cx, y + L.title_y)

    -- PIN dots: outlined when empty, filled when typed.
    local row_w = (self.length - 1) * L.dot_gap
    for i = 1, self.length do
        local dx = cx - math.floor(row_w / 2) + (i - 1) * L.dot_gap
        if i <= #self.input then
            bb:paintCircle(dx, y + L.dots_y, L.dot_r, black)
        else
            bb:paintCircle(dx, y + L.dots_y, L.dot_r, black, Screen:scaleBySize(1.5))
        end
    end

    if self.message then
        centered(bb, TextWidget:new{
            text = self.message,
            face = face("Regular", 16),
            fgcolor = grey,
        }, cx, y + L.message_y)
    end

    -- Keypad: 1-9, then [Huỷ|blank] 0 [Xoá].
    self.keys = {}
    local labels = { "1", "2", "3", "4", "5", "6", "7", "8", "9",
        self.on_cancel and "Huỷ" or "", "0", "Xoá" }
    local r = math.floor(L.key_d / 2)
    for i, label in ipairs(labels) do
        local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
        local kx = x + L.pad_x + col * (L.key_d + L.key_gap_x)
        local ky = y + L.pad_y + row * (L.key_d + L.key_gap_y)
        if label ~= "" then
            local is_digit = label:match("^%d$") ~= nil
            local pressed = self.pressed == label
            if is_digit then
                if pressed then
                    bb:paintCircle(kx + r, ky + r, r, black)
                else
                    bb:paintCircle(kx + r, ky + r, r, grey, Screen:scaleBySize(1))
                end
            elseif pressed then
                bb:paintRoundedRect(kx, ky + math.floor(r / 2), L.key_d, r, Blitbuffer.COLOR_LIGHT_GRAY, math.floor(r / 2))
            end
            local text = TextWidget:new{
                text = label,
                face = is_digit and face("Regular", 30) or face("Regular", 16),
                fgcolor = (pressed and is_digit) and white or black,
            }
            local ts = text:getSize()
            text:paintTo(bb, kx + r - math.floor(ts.w / 2), ky + r - math.floor(ts.h / 2))
            text:free()
            table.insert(self.keys, { label = label, x = kx, y = ky, d = L.key_d })
        end
    end
end

function LockScreen:keyAt(pos)
    for _i, key in ipairs(self.keys) do
        if pos.x >= key.x and pos.x < key.x + key.d and pos.y >= key.y and pos.y < key.y + key.d then
            return key.label
        end
    end
end

function LockScreen:press(label)
    if label == "Xoá" then
        self.input = self.input:sub(1, -2)
        self.message = nil
    elseif label == "Huỷ" then
        UIManager:close(self)
        if self.on_cancel then self.on_cancel() end
        return
    elseif #self.input < self.length then
        self.input = self.input .. label
        self.message = nil
    end
    UIManager:setDirty(self, "ui")

    if #self.input == self.length and self.on_complete then
        local pin = self.input
        -- Let the last dot paint before checking.
        UIManager:scheduleIn(0.2, function()
            local result = self.on_complete(pin)
            if result == true then
                UIManager:close(self, "full")
            else
                self.input = ""
                self.message = type(result) == "string" and result or "Sai mã PIN"
                UIManager:setDirty(self, "ui")
            end
        end)
    end
end

--- Swallow every gesture and key press; only keypad taps do anything.
function LockScreen:handleEvent(event)
    local handler = event.handler
    if handler == "onGesture" then
        local ges = event.args[1]
        if ges and ges.ges == "tap" and ges.pos and not self.busy then
            local label = self:keyAt(ges.pos)
            if label then
                self.busy = true
                self.pressed = label
                UIManager:setDirty(self, "fast")
                UIManager:scheduleIn(0.12, function()
                    self.pressed = nil
                    self.busy = false
                    self:press(label)
                end)
            end
        end
        return true
    end
    if handler == "onKeyPress" or handler == "onKeyRepeat" or handler == "onKeyRelease" then
        return true
    end
    return InputContainer.handleEvent(self, event)
end

return LockScreen
