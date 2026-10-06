--[[--
Study tools of the Bindery plugin:

  * Recap      — "Chuyện tới đâu rồi": an AI summary of a Bindery story up to the current
                 position, built from its Story Memory plus the last few chapters, so it
                 costs the same at chapter 90 as at chapter 9 and never spoils what is next.
  * Vocabulary — Lens/Annotate results saved to a notebook on the server, reviewed here
                 or on the website with spaced repetition (one shared schedule).
  * Highlights — highlights and notes of Bindery books are sent on every library sync and
                 shown on the web reader. One way: the website never edits the sidecar.

Mixed into the plugin class by main.lua; every function takes the plugin instance.

@module koplugin.Bellasekai.study
--]]

local DocSettings = require("docsettings")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local md5 = require("ffi/sha2").md5
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local Study = {}

local BOOK_FILE = "^bellasekai%-[%w]+%.epub$" -- documents are "bellasekai-doc-…", not matched
local REVIEW_BATCH = 30

local GRADES = {
    { key = "again", label = "Quên" },
    { key = "hard", label = "Khó" },
    { key = "good", label = "Nhớ" },
    { key = "easy", label = "Dễ" },
}

local function failure(code, body)
    if type(body) == "table" and body.message then return body.message end
    if code == 401 then return _("Wrong username or password.") end
    return tostring(body or code)
end

local function isBinderyBook(file)
    if not file then return nil end
    local _dir, name = util.splitFilePathName(file)
    return name and name:match(BOOK_FILE) and name or nil
end

--- Digest and xpointer of the Bindery story open in this reader, or nil.
function Study:currentBinderyPosition()
    local ui = self.ui
    if not (ui and ui.document and ui.rolling) then return nil end
    local name = isBinderyBook(ui.document.file)
    if not name then return nil end
    return { document = md5(name), position = ui.rolling:getLastProgress() }
end

-- ── Recap ────────────────────────────────────────────────────────────────

function Study:showRecap()
    if not self:isConfigured() then
        UIManager:show(InfoMessage:new{ text = _("Set up the server and account first."), timeout = 3 })
        return
    end
    local where = self:currentBinderyPosition()
    if not where then
        UIManager:show(InfoMessage:new{ text = "Mở một truyện Bindery rồi chọn lại.", timeout = 3 })
        return
    end
    NetworkMgr:runWhenOnline(function()
        local waiting = InfoMessage:new{ text = "Đang tóm tắt…" }
        UIManager:show(waiting)
        UIManager:forceRePaint()
        local code, body = self:postJson("/api/koreader/recap", {
            document = where.document,
            position = where.position,
            target = self:assistLanguage().key,
        }, 120)
        UIManager:close(waiting)
        if code ~= 200 or type(body) ~= "table" or not body.text then
            UIManager:show(InfoMessage:new{ text = T("Không tóm tắt được: %1", failure(code, body)) })
            return
        end
        local footer = {}
        if (body.memoryTo or 0) > 0 then
            table.insert(footer, T("Story Memory tới chương %1", body.memoryTo))
        else
            table.insert(footer, "Chưa có Story Memory, chỉ tóm từ vài chương gần đây")
        end
        if body.model then table.insert(footer, body.model) end
        UIManager:show(TextViewer:new{
            title = T("Chuyện tới đâu rồi · chương %1", body.chapter or "?"),
            text = body.text .. "\n\n— " .. table.concat(footer, " · "),
            justified = false,
        })
    end)
end

-- ── Vocabulary ───────────────────────────────────────────────────────────

--- Saves a Lens/Annotate result to the vocabulary notebook.
function Study:saveVocab(selection, meaning, target)
    local code, body = self:postJson("/api/koreader/vocab", {
        text = selection.text,
        context = selection.context,
        meaning = meaning,
        document = self:currentDocumentDigest(),
        target = target,
    }, 20)
    if code == 200 and type(body) == "table" then
        UIManager:show(InfoMessage:new{
            text = body.created and "Đã lưu vào sổ từ vựng." or "Đã có trong sổ, đã cập nhật nghĩa.",
            timeout = 2,
        })
    else
        UIManager:show(InfoMessage:new{ text = T("Không lưu được: %1", failure(code, body)) })
    end
end

--- Grades not sent yet (session finished offline, or the request failed).
function Study:flushReviews()
    local pending = self.settings:readSetting("pending_reviews") or {}
    if #pending == 0 then return 0 end
    local code = self:postJson("/api/koreader/vocab/review", { reviews = pending }, 20)
    if code ~= 200 then return #pending end
    self.settings:saveSetting("pending_reviews", {})
    self.settings:flush()
    return 0
end

function Study:vocabDueText()
    local due = self.settings:readSetting("vocab_due")
    if due == nil then return "Thẻ lưu từ Lens / Annotate" end
    if due == 0 then return "Không có thẻ đến hạn" end
    return T("%1 thẻ đến hạn", due)
end

function Study:refreshVocabDue()
    local code, body = self:request("/api/koreader/vocab?limit=1")
    if code == 200 and type(body) == "table" and body.due then
        self.settings:saveSetting("vocab_due", body.due)
    end
end

function Study:startVocabReview()
    if not self:isConfigured() then
        UIManager:show(InfoMessage:new{ text = _("Set up the server and account first."), timeout = 3 })
        return
    end
    NetworkMgr:runWhenOnline(function()
        self:flushReviews()
        local code, body = self:request("/api/koreader/vocab?limit=" .. REVIEW_BATCH)
        if code ~= 200 or type(body) ~= "table" or type(body.items) ~= "table" then
            UIManager:show(InfoMessage:new{ text = T("Không lấy được sổ từ vựng: %1", failure(code, body)) })
            return
        end
        self.settings:saveSetting("vocab_due", body.due or #body.items)
        if #body.items == 0 then
            UIManager:show(InfoMessage:new{ text = "Không có thẻ nào đến hạn. Lưu thêm từ trong khung Lens / Annotate.", timeout = 3 })
            return
        end
        self.review_session = { queue = body.items, results = {}, seen = 0 }
        self:showReviewCard(false)
    end)
end

local function frontText(card)
    local parts = { card.text }
    if card.context and card.context ~= "" and card.context ~= card.text then
        table.insert(parts, card.context)
    end
    return table.concat(parts, "\n\n")
end

--- One card: front first, "Xem nghĩa" turns it over and shows the four grades.
function Study:showReviewCard(revealed)
    local session = self.review_session
    if not session then return end
    local card = session.queue[1]
    if not card then return self:finishReview() end

    local viewer
    local function go(fn)
        return function()
            UIManager:close(viewer)
            fn()
        end
    end
    local stop = { text = "Dừng", callback = go(function() self:finishReview() end) }
    local buttons
    local text = frontText(card)
    if revealed then
        text = text .. "\n\n────────\n\n" .. (card.meaning or "")
        local row = {}
        for _i, grade in ipairs(GRADES) do
            table.insert(row, {
                text = grade.label,
                callback = go(function() self:gradeCard(grade.key) end),
            })
        end
        buttons = { row, { stop } }
    else
        buttons = {{ stop, { text = "Xem nghĩa", callback = go(function() self:showReviewCard(true) end) } }}
    end
    if card.source and card.source ~= "" then
        text = text .. "\n\n— " .. card.source
    end
    viewer = TextViewer:new{
        title = T("Ôn từ · còn %1", #session.queue),
        text = text,
        justified = false,
        buttons_table = buttons,
        -- The X in the title bar ends the session too, so the grades are not lost.
        close_callback = function() self:finishReview() end,
    }
    UIManager:show(viewer)
end

function Study:gradeCard(grade)
    local session = self.review_session
    local card = table.remove(session.queue, 1)
    table.insert(session.results, { id = card.id, grade = grade })
    session.seen = session.seen + 1
    -- Forgotten cards come back once more at the end of the session, as in Anki.
    if grade == "again" and not card.retried then
        card.retried = true
        table.insert(session.queue, card)
    end
    self:showReviewCard(false)
end

function Study:finishReview()
    local session = self.review_session
    if not session then return end
    self.review_session = nil
    if #session.results == 0 then return end
    local pending = self.settings:readSetting("pending_reviews") or {}
    for _i, result in ipairs(session.results) do table.insert(pending, result) end
    self.settings:saveSetting("pending_reviews", pending)
    self.settings:flush()
    local left = NetworkMgr:isOnline() and self:flushReviews() or #pending
    if NetworkMgr:isOnline() then self:refreshVocabDue() end
    UIManager:show(InfoMessage:new{
        text = left == 0 and T("Đã ôn %1 thẻ.", session.seen)
            or T("Đã ôn %1 thẻ. Kết quả sẽ gửi ở lần sync sau.", session.seen),
        timeout = 3,
    })
end

-- ── Highlights ───────────────────────────────────────────────────────────

local function highlightsOf(annotations)
    local list = {}
    for _i, item in ipairs(annotations or {}) do
        -- Page bookmarks have no drawer; only text highlights go to the website.
        if item.drawer and type(item.pos0) == "string" and item.text and item.text ~= "" then
            table.insert(list, {
                key = md5(item.pos0 .. "|" .. tostring(item.pos1)),
                text = item.text,
                note = item.note,
                pos0 = item.pos0,
                color = item.color,
                drawer = item.drawer,
                datetime = item.datetime,
            })
        end
    end
    return list
end

--- What changed since the last send, as a signature per book.
local function signature(list)
    local parts = {}
    for _i, item in ipairs(list) do
        table.insert(parts, table.concat({ item.key, item.text, item.note or "", item.color or "" }, "\31"))
    end
    return md5(table.concat(parts, "\30"))
end

--- Highlights of the Bindery books on the device whose list changed since the last send.
function Study:changedHighlights(state)
    local reader = require("apps/reader/readerui").instance
    local open_file = reader and reader.document and reader.document.file
    local sent = self.settings:readSetting("highlight_sigs") or {}
    local books = {}
    for _id, known in pairs(state or {}) do
        local file = known.file
        local name = isBinderyBook(file)
        if name and lfs.attributes(file, "mode") == "file" then
            local annotations
            if file == open_file and reader.annotation then
                annotations = reader.annotation.annotations
            elseif DocSettings:hasSidecarFile(file) then
                local ok, doc_settings = pcall(DocSettings.open, DocSettings, file)
                annotations = ok and doc_settings:readSetting("annotations") or nil
            end
            local list = highlightsOf(annotations)
            local digest = md5(name)
            local sig = signature(list)
            -- Never highlighted and never sent: nothing to tell the server.
            if sent[digest] ~= sig and not (#list == 0 and sent[digest] == nil) then
                table.insert(books, { document = digest, highlights = list, sig = sig })
            end
        end
    end
    return books
end

--- Sends changed highlights; returns books sent and books left for the next sync.
function Study:flushHighlights(state)
    local books = self:changedHighlights(state)
    if #books == 0 then return 0, 0 end
    local payload = {}
    for i, book in ipairs(books) do
        payload[i] = { document = book.document, highlights = book.highlights }
    end
    local code, body = self:postJson("/api/koreader/highlights", { books = payload }, 60)
    if code ~= 200 or type(body) ~= "table" or type(body.results) ~= "table" then
        logger.warn("Bellasekai: highlights not sent:", failure(code, body))
        return 0, #books
    end
    local sent_sigs = self.settings:readSetting("highlight_sigs") or {}
    local sent, left = 0, 0
    for i, book in ipairs(books) do
        local result = body.results[i]
        if result and result.ok then
            sent_sigs[book.document] = book.sig
            sent = sent + 1
        elseif result and not result.retry then
            -- Not a book of this device any more: stop trying.
            sent_sigs[book.document] = book.sig
            logger.warn("Bellasekai: highlights dropped:", result.message)
        else
            left = left + 1
        end
    end
    self.settings:saveSetting("highlight_sigs", sent_sigs)
    self.settings:flush()
    return sent, left
end

return Study
