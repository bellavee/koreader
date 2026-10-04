--[[--
Full-screen passcode screen modelled on the stock Kobo one: a serif prompt that turns into
PIN dots and a backspace key once typing starts, a thin rule, a compact 3×3 grid of
digits with a hairline under each key, 0 alone on the last row, and a "forgot your PIN"
line at the bottom.

Everything is painted by hand in `paintTo` and taps are hit-tested against the keys, so
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
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local Screen = Device.screen

local FONT_DIRS = { "/mnt/onboard/fonts/", "./fonts/" }

--- First installed font file among `names`, else a KOReader UI font (both cover Vietnamese).
local function face(names, size, fallback)
    for _i, dir in ipairs(FONT_DIRS) do
        for _j, name in ipairs(names) do
            local path = dir .. name
            if lfs.attributes(path, "mode") == "file" then
                local f = Font:getFace(path, size)
                if f then return f end
            end
        end
    end
    return Font:getFace(fallback or "cfont", size)
end

local function serif(size) return face({ "Georgia-vie.ttf" }, size, "cfont") end
local function sans(size) return face({ "BeVietnamPro-Regular.ttf" }, size, "cfont") end

--- Straight line made of small squares (Blitbuffer has no line primitive).
local function drawLine(bb, x0, y0, x1, y1, thickness, color)
    local dx, dy = x1 - x0, y1 - y0
    local steps = math.max(math.abs(dx), math.abs(dy), 1)
    for i = 0, steps do
        local px = math.floor(x0 + dx * i / steps - thickness / 2 + 0.5)
        local py = math.floor(y0 + dy * i / steps - thickness / 2 + 0.5)
        bb:paintRect(px, py, thickness, thickness, color)
    end
end

--- The ⌫ key: a tag shape pointing left with an × inside.
local function drawBackspace(bb, cx, cy, size, color)
    local w, h = size, math.floor(size * 0.66)
    local t = math.max(1, Screen:scaleBySize(1.5))
    local left, right = cx - math.floor(w / 2), cx + math.floor(w / 2)
    local top, bottom = cy - math.floor(h / 2), cy + math.floor(h / 2)
    local tip = left + math.floor(h / 2)
    drawLine(bb, left, cy, tip, top, t, color)
    drawLine(bb, left, cy, tip, bottom, t, color)
    drawLine(bb, tip, top, right, top, t, color)
    drawLine(bb, tip, bottom, right, bottom, t, color)
    drawLine(bb, right, top, right, bottom, t, color)
    local xc, xr = math.floor((tip + right) / 2), math.floor(h * 0.2)
    drawLine(bb, xc - xr, cy - xr, xc + xr, cy + xr, t, color)
    drawLine(bb, xc - xr, cy + xr, xc + xr, cy - xr, t, color)
end

local LockScreen = InputContainer:extend{
    name = "passcode_lockscreen",
    covers_fullscreen = true,
    -- Set by the caller:
    title = "Vui lòng nhập mã PIN 4 số.",
    length = 4,
    on_complete = nil, -- function(pin) -> true to close, or a string error to show
    on_cancel = nil,   -- when set, the bottom-left key reads "Huỷ" and calls it
    on_forgot = nil,   -- when set, a "Quên mã PIN?" line at the bottom calls it
}

function LockScreen:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.input = ""
    self.message = nil
    self.pressed = nil
    self.keys = {}
end

function LockScreen:onShow()
    UIManager:setDirty(self, "full")
    return true
end

local function paintCentered(bb, widget, cx, cy)
    local size = widget:getSize()
    widget:paintTo(bb, math.floor(cx - size.w / 2), math.floor(cy - size.h / 2))
    widget:free()
end

function LockScreen:paintTo(bb, x, y)
    local w, h = self.dimen.w, self.dimen.h
    self.dimen.x, self.dimen.y = x, y
    local black, white = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
    local rule = Blitbuffer.COLOR_GRAY
    local line = math.max(1, Screen:scaleBySize(0.75))

    local short = math.min(w, h)
    local cell_w = math.floor(short * 0.16)
    local gap = math.floor(short * 0.018)
    local cell_h = math.floor(h * 0.068)
    local grid_w = 3 * cell_w + 2 * gap
    local header_h = math.floor(cell_h * 1.45)
    local group_h = header_h + 4 * cell_h
    local gx = x + math.floor((w - grid_w) / 2)
    local gy = y + math.floor(h * 0.47 - group_h / 2)
    local cx = x + math.floor(w / 2)

    bb:paintRect(x, y, w, h, white)
    self.keys = {}

    -- Header: the prompt (or the error) until typing starts, then dots + backspace.
    local header_cy = gy + math.floor(header_h / 2)
    if #self.input == 0 then
        paintCentered(bb, TextBoxWidget:new{
            text = self.message or self.title,
            face = serif(19),
            width = grid_w,
            alignment = "center",
            fgcolor = black,
        }, cx, header_cy)
    else
        local dot_r = math.max(3, math.floor(cell_h * 0.07))
        local dot_gap = math.floor(dot_r * 4.2)
        local dots_cx = gx + math.floor((2 * cell_w + gap) / 2)
        local first = dots_cx - math.floor((self.length - 1) * dot_gap / 2)
        for i = 1, self.length do
            local dx = first + (i - 1) * dot_gap
            if i <= #self.input then
                bb:paintCircle(dx, header_cy, dot_r, black)
            else
                bb:paintCircle(dx, header_cy, dot_r, black, math.max(1, Screen:scaleBySize(1)))
            end
        end
        local bx = gx + 2 * (cell_w + gap)
        if self.pressed == "⌫" then
            bb:paintRect(bx, gy, cell_w, header_h, Blitbuffer.COLOR_LIGHT_GRAY)
        end
        drawBackspace(bb, bx + math.floor(cell_w / 2), header_cy, math.floor(cell_h * 0.42), black)
        table.insert(self.keys, { label = "⌫", x = bx, y = gy, w = cell_w, h = header_h })
    end
    bb:paintRect(gx, gy + header_h - line, grid_w, line, rule)

    -- Digits: three rows with a hairline under each key, then 0 alone (and Huỷ).
    local labels = { "1", "2", "3", "4", "5", "6", "7", "8", "9", self.on_cancel and "Huỷ" or "", "0", "" }
    for i, label in ipairs(labels) do
        local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
        local kx = gx + col * (cell_w + gap)
        local ky = gy + header_h + row * cell_h
        if label ~= "" then
            local pressed = self.pressed == label
            if pressed then
                bb:paintRect(kx, ky, cell_w, cell_h, black)
            end
            paintCentered(bb, TextWidget:new{
                text = label,
                face = label == "Huỷ" and serif(16) or sans(26),
                fgcolor = pressed and white or black,
            }, kx + math.floor(cell_w / 2), ky + math.floor(cell_h / 2))
            table.insert(self.keys, { label = label, x = kx, y = ky, w = cell_w, h = cell_h })
        end
        if row < 3 then
            bb:paintRect(kx, ky + cell_h - line, cell_w, line, rule)
        end
    end

    if self.on_forgot then
        local fy = y + math.floor(h * 0.9)
        local forgot = TextWidget:new{ text = "Quên mã PIN?", face = serif(15), fgcolor = black }
        local fs = forgot:getSize()
        local fx = cx - math.floor(fs.w / 2)
        forgot:paintTo(bb, fx, fy)
        forgot:free()
        bb:paintRect(fx, fy + fs.h, fs.w, line, black)
        table.insert(self.keys, { label = "forgot", x = fx, y = fy - fs.h, w = fs.w, h = fs.h * 3 })
    end
end

function LockScreen:keyAt(pos)
    for _i, key in ipairs(self.keys) do
        if pos.x >= key.x and pos.x < key.x + key.w and pos.y >= key.y and pos.y < key.y + key.h then
            return key.label
        end
    end
end

function LockScreen:press(label)
    if label == "forgot" then
        if self.on_forgot then self.on_forgot() end
        return
    elseif label == "⌫" then
        self.input = self.input:sub(1, -2)
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
                self.message = type(result) == "string" and result or "Sai mã PIN. Vui lòng thử lại."
                UIManager:setDirty(self, "ui")
            end
        end)
    end
end

--- Swallow every gesture and key press; only taps on keys do anything.
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
