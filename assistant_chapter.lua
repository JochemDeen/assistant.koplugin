--- Chapter summaries: pre-generated, cached per-chapter summaries (map-reduce style).
--- Chapters are segmented via the TOC; summaries are generated sequentially so each
--- chapter prompt includes the summaries of all previous chapters, and stored in the
--- book's sidecar (doc_settings). Reading-time features only ever expose summaries
--- of chapters the user has finished, so spoiler-safety is structural.
--- EPUB (rolling/crengine) documents only: chapter text extraction relies on TOC xpointers.

local logger = require("logger")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local util = require("util")
local T = require("ffi/util").template
local _ = require("assistant_gettext")
local ChatGPTViewer = require("assistant_viewer")
local assistant_prompts = require("assistant_prompts").assistant_prompts
local normalizeMarkdownHeadings = require("assistant_utils").normalizeMarkdownHeadings

local SIDECAR_KEY = "assistant_chapter_summaries"

local AssistantChapter = {}

--- Chapter features need TOC xpointers, only available for rolling (EPUB-like) documents.
function AssistantChapter.isSupported(ui)
    return ui ~= nil and ui.rolling ~= nil and ui.document ~= nil
end

local function getBookInfo(ui)
    local props = ui.document:getProps() or {}
    return props.title or _("Unknown Title"), props.authors or _("Unknown Author")
end

--- Build the chapter list from the TOC, using a single depth level.
--- Picks the shallowest depth with at least 4 entries, so books split into a few
--- big "Parts" fall through to their chapters; if no depth has that many entries
--- (tiny TOC), the depth with the most entries wins. A synthetic "(Beginning)"
--- chapter is added when the first TOC entry does not start at page 1, to cover
--- front matter and unlisted prologues. The rule is deterministic so cached
--- indices stay valid across sessions.
--- @return table|nil chapters, string|nil error
function AssistantChapter.getChapters(ui)
    local toc = ui.toc and ui.toc.toc
    if not toc or #toc == 0 then
        return nil, _("This book has no table of contents; chapter summaries are unavailable.")
    end

    local depth_counts = {}
    local max_depth = 1
    for _, item in ipairs(toc) do
        local d = item.depth or 1
        depth_counts[d] = (depth_counts[d] or 0) + 1
        if d > max_depth then max_depth = d end
    end
    local depth
    local best = 0
    for d = 1, max_depth do
        if (depth_counts[d] or 0) > best then
            best = depth_counts[d]
            depth = d
        end
    end

    local chapters = {}
    for _, item in ipairs(toc) do
        if (item.depth or 1) == depth and item.xpointer then
            table.insert(chapters, {
                title = item.title or _("Untitled chapter"),
                start_xp = item.xpointer,
                start_page = item.page or 1,
            })
        end
    end
    if #chapters == 0 then
        return nil, _("Could not determine chapter boundaries from the table of contents.")
    end

    if chapters[1].start_page > 1 then
        -- start_xp = nil means "start of document", resolved at extraction time
        table.insert(chapters, 1, {
            title = _("(Beginning)"),
            start_xp = nil,
            start_page = 1,
        })
    end
    return chapters
end

--- Index of the chapter containing the given page; 0 if before the first chapter.
function AssistantChapter.getChapterIndexByPage(chapters, page)
    local idx = 0
    for i, chapter in ipairs(chapters) do
        if chapter.start_page and chapter.start_page <= page then
            idx = i
        else
            break
        end
    end
    return idx
end

--- Number of chapters the reader has fully finished.
local function getFinishedChapterCount(ui, chapters)
    local current_page = ui:getCurrentPage()
    if current_page >= ui.document:getPageCount() then
        return #chapters -- on the last page: the whole book counts as finished
    end
    local idx = AssistantChapter.getChapterIndexByPage(chapters, current_page)
    return math.max(0, idx - 1)
end

--- Extract the text of chapter `idx`. When `up_to_xp` is given, extraction stops
--- there (used for "text up to my reading position") instead of the chapter end.
--- Note: for the last chapter the end boundary is the top of the last rendered
--- page, so up to one screenful of the very end of the book may be missed.
function AssistantChapter.getChapterText(ui, chapters, idx, up_to_xp)
    local chapter = chapters[idx]
    if not chapter then return nil end
    local document = ui.document

    local start_xp = chapter.start_xp
    local end_xp = up_to_xp
    if not end_xp then
        local next_chapter = chapters[idx + 1]
        if next_chapter then
            end_xp = next_chapter.start_xp
        end
    end

    if not start_xp or not end_xp then
        -- resolve document start/end boundaries, restoring the reading position afterwards
        local current_xp = document:getXPointer()
        if not start_xp then
            document:gotoPos(0)
            start_xp = document:getXPointer()
        end
        if not end_xp then
            document:gotoPos(document.info.doc_height)
            end_xp = document:getXPointer()
        end
        document:gotoXPointer(current_xp)
    end

    local ok, text = pcall(document.getTextFromXPointers, document, start_xp, end_xp)
    if not ok or type(text) ~= "string" then
        logger.warn("assistant chapter: text extraction failed for chapter", idx, text)
        return nil
    end
    return text
end

local function truncateHead(text, max_len)
    if #text <= max_len then return text end
    text = text:sub(1, max_len)
    text = text:gsub("[\194-\244][\128-\191]*$", "") -- drop a trailing incomplete UTF-8 char
    text = util.fixUtf8(text, "_")
    return text .. "\n[... chapter text truncated ...]"
end

function AssistantChapter.loadCache(ui)
    return ui.doc_settings:readSetting(SIDECAR_KEY)
end

function AssistantChapter.saveCache(ui, cache)
    ui.doc_settings:saveSetting(SIDECAR_KEY, cache)
    ui.doc_settings:flush()
end

function AssistantChapter.deleteCache(ui)
    ui.doc_settings:delSetting(SIDECAR_KEY)
    ui.doc_settings:flush()
end

local function countCachedSummaries(cache)
    local n = 0
    if cache and cache.chapters then
        for _, entry in pairs(cache.chapters) do
            if entry.summary then n = n + 1 end
        end
    end
    return n
end

local function buildTocOutline(chapters)
    local lines = {}
    for i, chapter in ipairs(chapters) do
        lines[i] = string.format("%d. %s", i, chapter.title)
    end
    return table.concat(lines, "\n")
end

--- Concatenated summaries of chapters 1 .. upto (inclusive), for prompt context.
local function buildSummariesBlock(cache, upto)
    local parts = {}
    for i = 1, upto do
        local entry = cache and cache.chapters and cache.chapters[i]
        if entry and entry.summary then
            table.insert(parts, string.format("### %d. %s\n\n%s", i, entry.title or "?", entry.summary))
        end
    end
    return table.concat(parts, "\n\n")
end

--- Prompt lookup with the same override convention as the other features:
--- configuration.lua `features.<config_key>` beats the built-in prompt.
local function getPrompts(CONFIGURATION, config_key, prompts_key)
    local file_config = util.tableGetValue(CONFIGURATION, "features", config_key) or {}
    local system_prompt = util.tableGetValue(file_config, "system_prompt")
        or util.tableGetValue(assistant_prompts, prompts_key, "system_prompt")
    local user_prompt = util.tableGetValue(file_config, "user_prompt")
        or util.tableGetValue(assistant_prompts, prompts_key, "user_prompt")
    return system_prompt, user_prompt
end

local function getResponseLanguage(assistant)
    return assistant.settings:readSetting("response_language") or assistant.ui_language
end

--- Shared viewer with follow-up question support (mirrors assistant_featuredialog).
local function showResultViewer(assistant, viewer_title, text, message_history)
    local Querier = assistant.querier
    local viewer
    viewer = ChatGPTViewer:new{
        assistant = assistant,
        ui = assistant.ui,
        title = viewer_title,
        text = text,
        disable_add_note = true,
        message_history = message_history,
        onAskQuestion = message_history and function(v, user_question)
            local question = type(user_question) == "string" and user_question
                or (user_question.user_prompt or user_question.text)
            table.insert(message_history, {
                role = "user",
                content = question,
            })
            v:trimMessageHistory()
            NetworkMgr:runWhenOnline(function()
                Trapper:wrap(function()
                    local answer, err = Querier:query(message_history)
                    if err then
                        Querier:showError(err)
                        return
                    end
                    table.insert(message_history, { role = "assistant", content = answer })
                    local normalized_answer = normalizeMarkdownHeadings(answer, 3, 6) or answer
                    local shown_question = type(user_question) == "string" and user_question
                        or (user_question.text or question)
                    v:update(v.text .. "\n\n### ⮞ User: \n" .. shown_question
                        .. "\n\n### ⮞ Assistant:\n" .. normalized_answer)
                    if v.scroll_text_w then
                        v.scroll_text_w:resetScroll()
                    end
                end)
            end)
        end or nil,
        default_hold_callback = function()
            viewer:HoldClose()
        end,
    }
    UIManager:show(viewer)
end

--- Generate summaries for chapters 1 .. upto (default: the whole book), in order.
--- Resumable: chapters already in the cache are skipped, and the cache is saved
--- after each chapter, so a cancelled or failed run continues where it left off.
--- Must be called inside Trapper:wrap with network available.
function AssistantChapter.generateAllSummaries(assistant, upto)
    local ui = assistant.ui
    local ok, err = assistant.querier:load_model(assistant:getModelProvider())
    if not ok then
        UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
        return
    end

    local chapters, cherr = AssistantChapter.getChapters(ui)
    if not chapters then
        UIManager:show(InfoMessage:new{ icon = "notice-warning", text = cherr })
        return
    end
    local last = math.min(upto or #chapters, #chapters)

    local cache = AssistantChapter.loadCache(ui)
    if not cache or cache.chapter_count ~= #chapters then
        -- no cache yet, or the TOC segmentation changed: start fresh
        cache = { version = 1, chapter_count = #chapters, chapters = {} }
    end

    local title, author = getBookInfo(ui)
    local language = getResponseLanguage(assistant)
    local max_len = util.tableGetValue(assistant.CONFIGURATION, "features", "max_text_length_for_analysis") or 100000
    local toc_outline = buildTocOutline(chapters)
    local system_prompt, user_prompt_template = getPrompts(assistant.CONFIGURATION, "chapter_summary_config", "chapter_summary")

    local generated = 0
    for i = 1, last do
        local entry = cache.chapters[i]
        if not (entry and entry.summary) then
            local chapter_text = AssistantChapter.getChapterText(ui, chapters, i)
            if not chapter_text or #util.trim(chapter_text) == 0 then
                logger.warn("assistant chapter: no text for chapter", i, chapters[i].title)
                cache.chapters[i] = { title = chapters[i].title, empty = true }
            else
                local user_content = user_prompt_template:gsub("{([%w_]+)}", {
                    title = title,
                    author = author,
                    chapter_title = chapters[i].title,
                    chapter_number = tostring(i),
                    chapter_count = tostring(#chapters),
                    language = language,
                })
                user_content = user_content .. "\n\n[TABLE OF CONTENTS]\n" .. toc_outline .. "\n[END TABLE OF CONTENTS]"
                local previous_summaries = buildSummariesBlock(cache, i - 1)
                if previous_summaries ~= "" then
                    user_content = user_content .. "\n\n[SUMMARIES OF PREVIOUS CHAPTERS]\n"
                        .. previous_summaries .. "\n[END SUMMARIES OF PREVIOUS CHAPTERS]"
                end
                user_content = user_content .. "\n\n[CHAPTER TEXT BEGIN]\n"
                    .. truncateHead(chapter_text, max_len) .. "\n[CHAPTER TEXT END]"

                local message_history = {
                    { role = "system", content = system_prompt },
                    { role = "user", content = user_content },
                }
                assistant.querier.user_interrupted = false -- clear stale flag from earlier runs
                local answer, qerr = assistant.querier:query(message_history,
                    T(_("Summarizing chapter %1 of %2…\n%3"), i, #chapters, chapters[i].title),
                    true) -- disable streaming: one InfoMessage per chapter is the progress UI
                if qerr then
                    AssistantChapter.saveCache(ui, cache)
                    if not assistant.querier.user_interrupted then
                        assistant.querier:showError(qerr)
                    end
                    UIManager:show(InfoMessage:new{
                        text = T(_("Stopped: %1 of %2 chapter summaries saved.\nRun \"Generate chapter summaries\" again to continue."),
                            countCachedSummaries(cache), #chapters),
                    })
                    return
                end
                cache.chapters[i] = { title = chapters[i].title, summary = answer, generated_at = os.time() }
                generated = generated + 1
                AssistantChapter.saveCache(ui, cache)
            end
        end
    end
    AssistantChapter.saveCache(ui, cache)
    if generated > 0 then
        if last < #chapters then
            UIManager:show(InfoMessage:new{
                text = T(_("Chapter summaries ready for the first %1 of %2 chapters."), last, #chapters),
            })
        else
            UIManager:show(InfoMessage:new{
                text = T(_("Chapter summaries ready for all %1 chapters."), #chapters),
            })
        end
    else
        UIManager:show(InfoMessage:new{ text = _("These chapter summaries were already generated.") })
    end
end

--- Count how many of chapters 1 .. upto still need a summary.
local function countMissing(cache, chapters, upto)
    local missing = 0
    for i = 1, upto do
        local entry = cache and cache.chapter_count == #chapters and cache.chapters and cache.chapters[i]
        if not (entry and (entry.summary or entry.empty)) then
            missing = missing + 1
        end
    end
    return missing
end

--- Confirm the number of API requests, then generate.
--- scope "read": chapters up to and including the current one; anything else: whole book.
function AssistantChapter.confirmAndGenerate(assistant, scope)
    if not assistant:isConfigured() then return end
    local ui = assistant.ui
    local chapters, err = AssistantChapter.getChapters(ui)
    if not chapters then
        UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
        return
    end

    local upto = #chapters
    local scope_text = _("The whole book is processed, including parts you have not read yet.")
    if scope == "read" then
        upto = AssistantChapter.getChapterIndexByPage(chapters, ui:getCurrentPage())
        if upto == 0 then
            UIManager:show(InfoMessage:new{ text = _("You are before the first chapter; nothing to summarize yet.") })
            return
        end
        scope_text = T(_("Only chapters 1-%1 (up to your reading position) are processed."), upto)
    end

    local cache = AssistantChapter.loadCache(ui)
    local todo = countMissing(cache, chapters, upto)
    if todo <= 0 then
        UIManager:show(InfoMessage:new{ text = _("These chapter summaries were already generated.") })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("Generate AI summaries for %1 chapters (%1 API requests)?\n\n%2 Summaries are stored with the book and only shown to you after you finish each chapter.\n\nYou can dismiss the progress message to stop; completed chapters are kept."),
            todo, scope_text),
        ok_text = _("Generate"),
        ok_callback = function()
            NetworkMgr:runWhenOnline(function()
                Trapper:wrap(function()
                    AssistantChapter.generateAllSummaries(assistant, upto)
                end)
            end)
        end,
    })
end

--- Show the cached summary of one chapter in a viewer that supports follow-ups.
function AssistantChapter.showChapterSummary(assistant, chapter_idx)
    local cache = AssistantChapter.loadCache(assistant.ui)
    local entry = cache and cache.chapters and cache.chapters[chapter_idx]
    if not entry or not entry.summary then
        UIManager:show(InfoMessage:new{ text = _("No summary was generated for this chapter yet.") })
        return
    end
    local title, author = getBookInfo(assistant.ui)
    local system_prompt = getPrompts(assistant.CONFIGURATION, "chapter_summary_config", "chapter_summary")
    local message_history = {
        { role = "system", content = system_prompt },
        {
            role = "user",
            content = string.format(
                "I'm reading '%s' by %s. Here is the summary of the chapter \"%s\":\n\n%s\n\nI may ask follow-up questions about this chapter. Never reveal anything from later chapters.",
                title, author, entry.title or "?", entry.summary),
        },
        { role = "assistant", content = entry.summary },
    }
    showResultViewer(assistant, T(_("Summary: %1"), entry.title or "?"),
        normalizeMarkdownHeadings(entry.summary, 2, 6) or entry.summary, message_history)
end

--- Picker listing the summaries of finished chapters (bindable to a gesture).
function AssistantChapter.showSummaryPicker(assistant)
    local ui = assistant.ui
    if not AssistantChapter.isSupported(ui) then
        UIManager:show(InfoMessage:new{ text = _("Chapter summaries are only available for EPUB-like documents.") })
        return
    end
    local chapters, err = AssistantChapter.getChapters(ui)
    if not chapters then
        UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
        return
    end
    local cache = AssistantChapter.loadCache(ui)
    if countCachedSummaries(cache) == 0 then
        UIManager:show(InfoMessage:new{ text = _("No chapter summaries yet. Generate them from the AI Assistant menu.") })
        return
    end
    local finished = getFinishedChapterCount(ui, chapters)
    if finished == 0 then
        UIManager:show(InfoMessage:new{ text = _("Finish a chapter first: summaries are only shown for chapters you have completed.") })
        return
    end

    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local buttons = {}
    for i = 1, finished do
        local entry = cache.chapters and cache.chapters[i]
        table.insert(buttons, {{
            text = string.format("%d. %s", i, (entry and entry.title) or chapters[i].title),
            enabled = entry ~= nil and entry.summary ~= nil,
            callback = function()
                UIManager:close(dialog)
                AssistantChapter.showChapterSummary(assistant, i)
            end,
        }})
    end
    dialog = ButtonDialog:new{
        title = _("Finished chapters"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

--- "Book structure so far": one reduce query over the finished chapters' summaries.
--- The result is cached in the sidecar and reused until another chapter is
--- finished (or the summaries are regenerated); `force` skips the cache.
function AssistantChapter.showStructureOverview(assistant, force)
    if not assistant:isConfigured() then return end
    local ui = assistant.ui
    local chapters, err = AssistantChapter.getChapters(ui)
    if not chapters then
        UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
        return
    end
    local cache = AssistantChapter.loadCache(ui)
    local finished = getFinishedChapterCount(ui, chapters)
    local summaries = buildSummariesBlock(cache, finished)
    if summaries == "" then
        UIManager:show(InfoMessage:new{
            text = _("No summaries of finished chapters available yet. Generate chapter summaries first."),
        })
        return
    end

    local function viewOverview(overview)
        local title, author = getBookInfo(ui)
        local system_prompt = getPrompts(assistant.CONFIGURATION, "chapter_overview_config", "chapter_overview")
        -- rebuilt small history for follow-up questions; never persisted to the sidecar
        local message_history = {
            { role = "system", content = system_prompt },
            {
                role = "user",
                content = string.format(
                    "I'm reading '%s' by %s. Here is a structure overview of the book so far, based on my chapter summaries:\n\n%s\n\nI may ask follow-up questions. Never reveal anything beyond these chapters.",
                    title, author, overview.text),
            },
            { role = "assistant", content = overview.text },
        }
        local header = T(_("_Based on %1 finished chapters — generated %2. Hold the menu entry to regenerate._"),
            overview.finished_count, os.date("%Y-%m-%d %H:%M", overview.generated_at))
        showResultViewer(assistant, _("Book structure so far"),
            header .. "\n\n" .. (normalizeMarkdownHeadings(overview.text, 2, 6) or overview.text),
            message_history)
    end

    -- serve from cache while no new chapter has been finished
    local cached_overview = cache.overview
    if not force and cached_overview and cached_overview.text
            and cached_overview.finished_count == finished then
        viewOverview(cached_overview)
        return
    end

    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            local ok, lerr = assistant.querier:load_model(assistant:getModelProvider())
            if not ok then
                UIManager:show(InfoMessage:new{ icon = "notice-warning", text = lerr })
                return
            end
            local title, author = getBookInfo(ui)
            local system_prompt, user_prompt_template = getPrompts(assistant.CONFIGURATION, "chapter_overview_config", "chapter_overview")
            local user_content = user_prompt_template:gsub("{([%w_]+)}", {
                title = title,
                author = author,
                language = getResponseLanguage(assistant),
            })
            user_content = user_content .. "\n\n[CHAPTER SUMMARIES BEGIN]\n" .. summaries .. "\n[CHAPTER SUMMARIES END]"
            local message_history = {
                { role = "system", content = system_prompt },
                { role = "user", content = user_content },
            }
            local answer, qerr = assistant.querier:query(message_history, _("Building book structure…"))
            if qerr then
                assistant.querier:showError(qerr)
                return
            end
            local overview = {
                text = answer,
                finished_count = finished,
                generated_at = os.time(),
            }
            cache.overview = overview
            AssistantChapter.saveCache(ui, cache)
            viewOverview(overview)
        end)
    end)
end

--- Ask a question about the current chapter: context = summaries of finished
--- chapters + the current chapter's text up to the reading position.
function AssistantChapter.askAboutChapter(assistant)
    if not assistant:isConfigured() then return end
    local ui = assistant.ui
    if not AssistantChapter.isSupported(ui) then
        UIManager:show(InfoMessage:new{ text = _("Chapter questions are only available for EPUB-like documents.") })
        return
    end
    local chapters, err = AssistantChapter.getChapters(ui)
    if not chapters then
        UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
        return
    end
    local current_page = ui:getCurrentPage()
    local idx = AssistantChapter.getChapterIndexByPage(chapters, current_page)
    if idx == 0 then idx = 1 end
    local chapter_title = chapters[idx].title

    local input_dialog
    input_dialog = InputDialog:new{
        title = T(_("Ask about: %1"), chapter_title),
        input_hint = _("Type your question about this chapter…"),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(input_dialog)
                end,
            },
            {
                text = _("Ask"),
                is_enter_default = true,
                callback = function()
                    local question = input_dialog:getInputText()
                    if not question or util.trim(question) == "" then return end
                    UIManager:close(input_dialog)
                    NetworkMgr:runWhenOnline(function()
                        Trapper:wrap(function()
                            AssistantChapter._queryAboutChapter(assistant, chapters, idx, question)
                        end)
                    end)
                end,
            },
        }},
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function AssistantChapter._queryAboutChapter(assistant, chapters, idx, question)
    local ui = assistant.ui
    local ok, err = assistant.querier:load_model(assistant:getModelProvider())
    if not ok then
        UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
        return
    end

    local title, author = getBookInfo(ui)
    local language = getResponseLanguage(assistant)
    local max_len = util.tableGetValue(assistant.CONFIGURATION, "features", "max_text_length_for_analysis") or 100000
    local system_prompt, user_prompt_template = getPrompts(assistant.CONFIGURATION, "chapter_question_config", "chapter_question")

    local user_content = user_prompt_template:gsub("{([%w_]+)}", {
        title = title,
        author = author,
        chapter_title = chapters[idx].title,
        user_input = question,
        language = language,
    })

    local cache = AssistantChapter.loadCache(ui)
    local previous_summaries = buildSummariesBlock(cache, idx - 1)
    if previous_summaries ~= "" then
        user_content = user_content .. "\n\n[SUMMARIES OF FINISHED CHAPTERS]\n"
            .. previous_summaries .. "\n[END SUMMARIES OF FINISHED CHAPTERS]"
    end

    -- text of the current chapter up to the top of the current page
    local chapter_text = AssistantChapter.getChapterText(ui, chapters, idx, ui.document:getXPointer())
    if chapter_text and #util.trim(chapter_text) > 0 then
        user_content = user_content .. "\n\n[CURRENT CHAPTER TEXT, UP TO MY POSITION]\n"
            .. truncateHead(chapter_text, max_len) .. "\n[END CURRENT CHAPTER TEXT]"
    end

    local message_history = {
        { role = "system", content = system_prompt },
        { role = "user", content = user_content },
    }
    local answer, qerr = assistant.querier:query(message_history, T(_("Asking about: %1"), chapters[idx].title))
    if qerr then
        assistant.querier:showError(qerr)
        return
    end
    table.insert(message_history, { role = "assistant", content = answer })
    local result_text = "### ⮞ User: \n" .. question .. "\n\n### ⮞ Assistant:\n"
        .. (normalizeMarkdownHeadings(answer, 3, 6) or answer)
    showResultViewer(assistant, T(_("Chapter: %1"), chapters[idx].title), result_text, message_history)
end

--- Called from Assistant:onPageUpdate on sequential forward page turns.
--- When the turn crosses into the next chapter and a summary of the finished
--- chapter is cached, offer to show it.
function AssistantChapter.onPageTurn(assistant, prev_page, new_page)
    local ui = assistant.ui
    if not AssistantChapter.isSupported(ui) then return end
    local cache = AssistantChapter.loadCache(ui)
    if not cache or not cache.chapters then return end
    local chapters = AssistantChapter.getChapters(ui)
    if not chapters then return end

    local prev_idx = AssistantChapter.getChapterIndexByPage(chapters, prev_page)
    local new_idx = AssistantChapter.getChapterIndexByPage(chapters, new_page)
    if prev_idx < 1 or new_idx ~= prev_idx + 1 then return end

    local entry = cache.chapters[prev_idx]
    if not entry or not entry.summary then return end
    if assistant._last_chapter_notified == prev_idx then return end
    assistant._last_chapter_notified = prev_idx

    UIManager:show(ConfirmBox:new{
        text = T(_("You finished \"%1\".\n\nView the AI chapter summary?"), entry.title or "?"),
        ok_text = _("View"),
        ok_callback = function()
            AssistantChapter.showChapterSummary(assistant, prev_idx)
        end,
        cancel_text = _("Not now"),
    })
end

--- Sub-menu for the AI Assistant main menu.
function AssistantChapter.genMenuItems(assistant)
    local ui = assistant.ui
    return {
        {
            text = _("Generate summaries: read chapters"),
            enabled_func = function() return AssistantChapter.isSupported(ui) end,
            callback = function()
                AssistantChapter.confirmAndGenerate(assistant, "read")
            end,
            hold_callback = function()
                UIManager:show(InfoMessage:new{
                    text = _("Summarizes only the chapters up to your reading position (one API request per chapter). Run it again later to cover newly read chapters; already summarized chapters are never redone."),
                })
            end,
        },
        {
            text_func = function()
                if not AssistantChapter.isSupported(ui) then
                    return _("Generate summaries: whole book")
                end
                local chapters = AssistantChapter.getChapters(ui)
                local cache = AssistantChapter.loadCache(ui)
                local cached = (cache and chapters and cache.chapter_count == #chapters)
                    and countCachedSummaries(cache) or 0
                if chapters and cached > 0 and cached < #chapters then
                    return T(_("Generate summaries: whole book (%1/%2 done)"), cached, #chapters)
                end
                return _("Generate summaries: whole book")
            end,
            enabled_func = function() return AssistantChapter.isSupported(ui) end,
            callback = function()
                AssistantChapter.confirmAndGenerate(assistant)
            end,
            hold_callback = function()
                UIManager:show(InfoMessage:new{
                    text = _("Summarizes every chapter of the book (one API request per chapter), including unread ones — summaries stay hidden until you finish each chapter. Interrupted runs continue where they stopped."),
                })
            end,
        },
        {
            text = _("View chapter summaries"),
            enabled_func = function() return AssistantChapter.isSupported(ui) end,
            callback = function()
                AssistantChapter.showSummaryPicker(assistant)
            end,
            hold_callback = function()
                UIManager:show(InfoMessage:new{
                    text = _("Summaries of the chapters you have finished. Chapters you have not reached yet are never shown, to avoid spoilers."),
                })
            end,
        },
        {
            text = _("Book structure so far"),
            enabled_func = function() return AssistantChapter.isSupported(ui) end,
            callback = function()
                AssistantChapter.showStructureOverview(assistant)
            end,
            hold_callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("How the finished chapters fit into the book's overall structure, synthesized from the stored chapter summaries.\n\nThe result is stored with the book and only regenerated after you finish another chapter (tap = show, possibly cached). Regenerate it now (one API request)?"),
                    ok_text = _("Regenerate"),
                    ok_callback = function()
                        AssistantChapter.showStructureOverview(assistant, true)
                    end,
                })
            end,
        },
        {
            text = _("Ask about current chapter"),
            enabled_func = function() return AssistantChapter.isSupported(ui) end,
            callback = function()
                AssistantChapter.askAboutChapter(assistant)
            end,
            hold_callback = function()
                UIManager:show(InfoMessage:new{
                    text = _("Ask a question with the current chapter (up to your reading position) and the summaries of finished chapters as context — no spoilers from further ahead."),
                })
            end,
            separator = true,
        },
        {
            text = _("Notify when finishing a chapter"),
            enabled_func = function() return AssistantChapter.isSupported(ui) end,
            checked_func = function()
                return assistant.settings:readSetting("chapter_end_notification", false)
            end,
            callback = function()
                assistant.settings:toggle("chapter_end_notification")
                assistant.updated = true
            end,
            hold_callback = function()
                UIManager:show(InfoMessage:new{
                    text = _("When turning the page into a new chapter, offer to show the summary of the chapter just finished (page-turn mode only)."),
                })
            end,
        },
        {
            text = _("Delete chapter summaries"),
            enabled_func = function()
                return AssistantChapter.isSupported(ui) and AssistantChapter.loadCache(ui) ~= nil
            end,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("Delete all stored chapter summaries for this book?"),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        AssistantChapter.deleteCache(ui)
                    end,
                })
            end,
        },
    }
end

return AssistantChapter
