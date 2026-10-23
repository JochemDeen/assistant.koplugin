--- People & terms on the current page: one small AI request lists the people,
--- places and special terms visible on the page; the picked one goes into the
--- Term X-Ray flow (dialogs/dict.lua), whose context is limited to the book text
--- up to the reading position, so the explanation is spoiler-free.
--- EPUB-like (rolling) documents only: page text extraction needs getPageXPointer.
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Trapper = require("ui/trapper")
local koutil = require("util")
local _ = require("core/gettext")
local Prompts = require("core/prompts")
local DocUtils = require("utils/doc")
local NetUtils = require("utils/net")
local TextUtils = require("utils/text")

local M = {}

M.MAX_TERMS = 12

function M.isSupported(ui)
    return ui ~= nil and ui.rolling ~= nil and ui.document ~= nil
end

--- Text of the visible page; falls back to the tail of the text read so far
--- when the page yields too little (e.g. an image-only page).
local function getCurrentPageText(assistant)
    local ui = assistant.ui
    local document = ui.document
    local page = ui:getCurrentPage()

    local text
    local ok, start_xp = pcall(document.getPageXPointer, document, page)
    if ok and start_xp then
        local end_xp
        if page < document:getPageCount() then
            local ok_next, xp = pcall(document.getPageXPointer, document, page + 1)
            if ok_next then end_xp = xp end
        end
        if not end_xp then
            local current_xp = document:getXPointer()
            document:gotoPos(document.info.doc_height)
            end_xp = document:getXPointer()
            document:gotoXPointer(current_xp)
        end
        local ok_text, t = pcall(document.getTextFromXPointers, document, start_xp, end_xp)
        if ok_text and type(t) == "string" then text = t end
    end

    if not text or #koutil.trim(text) < 200 then
        local book_text = DocUtils.extractBookTextForAnalysis(assistant)
        if book_text and #book_text > 0 then
            local tail_len = assistant.config:getFeature("page_terms_context_length", 3000)
            text = (text or "") .. "\n" .. TextUtils.truncateToTailUtf8Safe(book_text, tail_len)
        end
    end
    return text
end

--- Parse the model's list answer into clean, unique term strings. Tolerates
--- numbering, bullets and markdown emphasis despite the prompt.
--- @param answer string
--- @param max_terms number|nil
--- @return string[]
function M.parseTermList(answer, max_terms)
    max_terms = max_terms or M.MAX_TERMS
    local terms, seen = {}, {}
    for line in tostring(answer):gmatch("[^\r\n]+") do
        local term = line
        term = term:gsub("^%s*%d+[%.%)]%s*", "")    -- "1. " / "2) "
        term = term:gsub("%*%*", ""):gsub("__", "") -- markdown bold, before bullet stripping
        -- multi-byte bullets are matched as literal sequences, not in a byte class
        term = term:gsub("^%s*•%s*", ""):gsub("^%s*–%s*", ""):gsub("^%s*‣%s*", "")
        term = term:gsub("^%s*[-*+]+%s*", "")
        term = koutil.trim(term)
        term = term:gsub("^[\"']+", ""):gsub("[\"']+$", "")
        local key = term:lower()
        if #term > 0 and #term <= 60 and not term:find("[:%[%]]") and not seen[key] then
            seen[key] = true
            table.insert(terms, term)
            if #terms >= max_terms then break end
        end
    end
    return terms
end

local function showTermPicker(assistant, terms)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local buttons = {}
    for term_idx = 1, #terms do
        local term = terms[term_idx]
        table.insert(buttons, {{
            text = term,
            callback = function()
                UIManager:close(dialog)
                local showDictionaryDialog = require("dialogs/dict")
                NetUtils.runWhenOnlineFast(function()
                    Trapper:wrap(function()
                        showDictionaryDialog(assistant, term, nil, "term_xray")
                    end)
                end)
            end,
        }})
    end
    dialog = ButtonDialog:new{
        title = _("People & terms on this page\n(tap one for a spoiler-free explanation)"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

--- Entry point: detect people/terms on the current page, then let the reader
--- pick one for a Term X-Ray explanation.
function M.showPageTerms(assistant)
    if not assistant:isConfigured() then return end
    local ui = assistant.ui
    if not M.isSupported(ui) then
        UIManager:show(InfoMessage:new{ text = _("People & terms is only available for EPUB-like documents.") })
        return
    end

    NetUtils.runWhenOnlineFast(function()
        Trapper:wrap(function()
            local provider = assistant.config:getActiveProviderId()
            local ok, err = assistant.querier:load_model(provider)
            if not ok then
                UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
                return
            end

            local page_text = getCurrentPageText(assistant)
            if not page_text or #koutil.trim(page_text) < 50 then
                UIManager:show(InfoMessage:new{ text = _("Not enough text on this page to analyze.") })
                return
            end

            local meta = DocUtils.getBookMeta(ui)
            local file_config = assistant.config:getFeature("page_terms_config") or {}
            local system_prompt = file_config.system_prompt or Prompts.assistant_prompts.page_terms.system_prompt
            local user_prompt = file_config.user_prompt or Prompts.assistant_prompts.page_terms.user_prompt
            local user_content = user_prompt:gsub("{([%w_]+)}", {
                title = meta.title or _("Unknown Title"),
                author = meta.authors or _("Unknown Author"),
                excerpt = page_text,
            })

            local message_history = {
                { role = "system", content = system_prompt },
                { role = "user", content = user_content },
            }
            local answer, qerr = assistant.querier:query(message_history, _("People & Terms on This Page"),
                { use_stream_mode = false, use_websearch = "none" })
            if qerr then
                assistant.querier:showError(qerr, message_history)
                return
            end

            local terms = M.parseTermList(answer)
            if #terms == 0 then
                UIManager:show(InfoMessage:new{ text = _("No people or terms were found on this page.") })
                return
            end
            showTermPicker(assistant, terms)
        end)
    end)
end

return M
