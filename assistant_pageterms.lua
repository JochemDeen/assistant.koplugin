--- People & terms on the current page: one small AI request detects the people,
--- places and special terms visible on the current page; the reader picks one and
--- it is fed into the existing Term X-Ray flow (assistant_dictdialog), whose
--- LexRank context is built from the book text up to the reading position, so the
--- resulting explanation is spoiler-free.
--- EPUB (rolling/crengine) documents only: page text extraction needs getPageXPointer.

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ButtonDialog = require("ui/widget/buttondialog")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local util = require("util")
local T = require("ffi/util").template
local _ = require("assistant_gettext")
local assistant_prompts = require("assistant_prompts").assistant_prompts

local PageTerms = {}

function PageTerms.isSupported(ui)
    return ui ~= nil and ui.rolling ~= nil and ui.document ~= nil
end

--- Text of the currently visible page (falls back to the tail of the text read
--- so far when the page yields too little, e.g. an image-only page).
local function getCurrentPageText(assistant)
    local ui = assistant.ui
    local document = ui.document
    local page = ui:getCurrentPage()

    local text
    local ok, start_xp = pcall(document.getPageXPointer, document, page)
    if ok and start_xp then
        local end_xp
        if page < document:getPageCount() then
            local ok2, xp = pcall(document.getPageXPointer, document, page + 1)
            if ok2 then end_xp = xp end
        end
        if not end_xp then
            -- last page: use the document end
            local current_xp = document:getXPointer()
            document:gotoPos(document.info.doc_height)
            end_xp = document:getXPointer()
            document:gotoXPointer(current_xp)
        end
        local ok3, t = pcall(document.getTextFromXPointers, document, start_xp, end_xp)
        if ok3 and type(t) == "string" then text = t end
    end

    if not text or #util.trim(text) < 200 then
        -- fallback: the most recent text before the reading position
        local extractBookTextForAnalysis = require("assistant_utils").extractBookTextForAnalysis
        local book_text = extractBookTextForAnalysis(assistant.CONFIGURATION, ui)
        if book_text and #book_text > 0 then
            local tail_len = util.tableGetValue(assistant.CONFIGURATION, "features", "page_terms_context_length") or 3000
            local tail = book_text:sub(-tail_len)
            tail = tail:gsub("^[\128-\191]+", "")
            text = (text or "") .. "\n" .. util.fixUtf8(tail, "_")
        end
    end
    return text
end

--- Parse the model's list response into clean term strings.
--- Tolerates numbering, bullets and markdown emphasis despite the prompt.
function PageTerms.parseTermList(answer, max_terms)
    max_terms = max_terms or 12
    local terms, seen = {}, {}
    for line in tostring(answer):gmatch("[^\r\n]+") do
        local term = line
        term = term:gsub("^%s*%d+[%.%)]%s*", "")    -- "1. " / "2) "
        term = term:gsub("%*%*", ""):gsub("__", "") -- markdown bold (before bullet stripping)
        -- multi-byte bullets must be matched as literal sequences, not in a byte class
        term = term:gsub("^%s*•%s*", ""):gsub("^%s*–%s*", ""):gsub("^%s*‣%s*", "")
        term = term:gsub("^%s*[-*+]+%s*", "")       -- ASCII bullets
        term = util.trim(term)
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
    local dialog
    local buttons = {}
    for _, term in ipairs(terms) do
        table.insert(buttons, {{
            text = term,
            callback = function()
                UIManager:close(dialog)
                local showDictionaryDialog = require("assistant_dictdialog")
                NetworkMgr:runWhenOnline(function()
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
function PageTerms.showPageTerms(assistant)
    if not assistant:isConfigured() then return end
    local ui = assistant.ui
    if not PageTerms.isSupported(ui) then
        UIManager:show(InfoMessage:new{ text = _("People & terms is only available for EPUB-like documents.") })
        return
    end

    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            local ok, err = assistant.querier:load_model(assistant:getModelProvider())
            if not ok then
                UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
                return
            end

            local page_text = getCurrentPageText(assistant)
            if not page_text or #util.trim(page_text) < 50 then
                UIManager:show(InfoMessage:new{ text = _("Not enough text on this page to analyze.") })
                return
            end

            local props = ui.document:getProps() or {}
            local file_config = util.tableGetValue(assistant.CONFIGURATION, "features", "page_terms_config") or {}
            local system_prompt = file_config.system_prompt or assistant_prompts.page_terms.system_prompt
            local user_prompt = file_config.user_prompt or assistant_prompts.page_terms.user_prompt
            local user_content = user_prompt:gsub("{([%w_]+)}", {
                title = props.title or _("Unknown Title"),
                author = props.authors or _("Unknown Author"),
                excerpt = page_text,
            })

            local message_history = {
                { role = "system", content = system_prompt },
                { role = "user", content = user_content },
            }
            local answer, qerr = assistant.querier:query(message_history, _("Finding people & terms on this page…"), true)
            if qerr then
                assistant.querier:showError(qerr)
                return
            end

            local terms = PageTerms.parseTermList(answer)
            if #terms == 0 then
                UIManager:show(InfoMessage:new{ text = _("No people or terms were found on this page.") })
                return
            end
            showTermPicker(assistant, terms)
        end)
    end)
end

return PageTerms
