--- Chapter companion UI: generating chapter summaries, the per-chapter summary
--- viewer (with chapter navigation), Book Structure So Far, Ask About Current
--- Chapter, and the finished-chapter notification. Data side: feature/chapters.lua.
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local Trapper = require("ui/trapper")
local koutil = require("util")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("core/gettext")
local Chapters = require("feature/chapters")
local Prompts = require("core/prompts")
local Conversation = require("core/conversation")
local ResultViewer = require("dialogs/viewer")
local ASUtils = require("utils/base")
local DocUtils = require("utils/doc")
local NetUtils = require("utils/net")

local M = {}

-- LLM-facing descriptions of what a conversation is about, for {scope}.
local SCOPE_CHAPTER = "this chapter"
local SCOPE_CURRENT_CHAPTER = "the current chapter up to my reading position"
local SCOPE_BOOK_SO_FAR = "the book so far (the chapters I have finished)"
local SCOPE_BOOK = "the book so far, up to my reading position"

local function getBookInfo(ui)
    local meta = DocUtils.getBookMeta(ui)
    return meta.title or _("Unknown Title"), meta.authors or _("Unknown Author")
end

local function getLanguage(assistant)
    return assistant.settings:readSetting("response_language") or assistant.ui_language
end

local function getMaxTextLength(assistant)
    return assistant.config:getFeature("max_text_length_for_analysis", 100000)
end

--- Load the active provider into the querier; shows the error and returns false on failure.
local function loadActiveModel(assistant)
    local provider = assistant.config:getActiveProviderId()
    if not provider then
        UIManager:show(InfoMessage:new{ icon = "notice-warning",
            text = _("No active provider configured. Please add one in Settings.") })
        return false
    end
    local ok, err = assistant.querier:load_model(provider)
    if not ok then
        UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
        return false
    end
    return true
end

--- System prompt for an interactive chapter conversation: response language and,
--- when Show Follow-up Questions is on, the suggested-questions instruction.
local function conversationSystemPrompt(assistant, system_prompt, suggestions)
    if suggestions then
        system_prompt = system_prompt .. Prompts.assistant_prompts.suggestions_prompt
    end
    return Prompts.withResponseLanguage(system_prompt, getLanguage(assistant))
end

local function suggestionsEnabled(assistant)
    return Prompts.isSuggestionsEnabled(assistant.settings, nil)
end

--- Result viewer for a chapter conversation, with follow-ups and the chapter prompts.
--- @param assistant table
--- @param opts table { title, message_history, vars (placeholders incl. scope),
---   lazy_context (function|nil -> string appended once to message_history[2] before the first follow-up),
---   buttons_table (table|nil extra button rows above the default ones),
---   onRegenerate (function|nil viewer callback replacing the default Regenerate) }
--- @return table viewer
local function showConversation(assistant, opts)
    local history = opts.message_history
    local suggestions = suggestionsEnabled(assistant)
    local render_opts = { settings = assistant.settings }
    local context_added = opts.lazy_context == nil

    local function renderAll()
        return Conversation.Renderer.render(history, render_opts)
    end

    local viewer
    viewer = ResultViewer:new{
        assistant = assistant,
        ui = assistant.ui,
        title = opts.title,
        text = renderAll(),
        is_show_addnote = false,
        buttons_table = opts.buttons_table,
        add_default_buttons = opts.buttons_table ~= nil,
        followup_prompts = Chapters.getChapterPrompts(assistant.config:getFeature("chapter_prompts")),
        message_history = history,
        onRegenerate = opts.onRegenerate,
        onSubmit = function(v, input, use_websearch)
            if not context_added then
                local extra = opts.lazy_context()
                if extra and extra ~= "" then
                    history[2].content = history[2].content .. extra
                end
                context_added = true
            end

            local msg, query_title
            if type(input) == "string" then
                msg = { role = "user", content = input }
                query_title = opts.title
            else
                local user_input = koutil.trim(input.user_input or "")
                local content = Chapters.expandPrompt(input.user_prompt, opts.vars)
                if user_input ~= "" then
                    content = content .. "\n\n" .. user_input
                end
                msg = { role = "user", content = content }
                ASUtils.set_attr(msg, "prompt_title", input.text)
                ASUtils.set_attr(msg, "user_input", user_input)
                query_title = input.text
                use_websearch = false
            end
            ASUtils.set_attr(msg, "show_suggestions", suggestions)
            ASUtils.set_attr(msg, "use_websearch", use_websearch or false)
            table.insert(history, msg)

            NetUtils.runWhenOnlineFast(function()
                Trapper:wrap(function()
                    local answer, err = assistant.querier:query(history, query_title, {
                        use_websearch = use_websearch and Prompts.isWebSearchEnabled(assistant.settings)
                            and assistant.settings:readSetting("use_websearch", "none") or "none",
                    })
                    if err then
                        table.remove(history) -- drop the unanswered turn so it can be asked again
                        assistant.querier:showError(err, history)
                        return
                    end
                    Conversation.append_answer(history, answer, suggestions)
                    v:update(v.text .. Conversation.Renderer.render_increment(history, render_opts))
                    if v.scroll_text_w then
                        v.scroll_text_w:resetScroll()
                    end
                end)
            end)
        end,
        rebuild_text = renderAll,
        default_hold_callback = function()
            viewer:HoldClose()
        end,
    }
    UIManager:show(viewer)
    return viewer
end

--- Summarize chapter `idx` into cache.chapters[idx] (one non-streaming query
--- with the TOC and the previous chapters' summaries as context). A chapter
--- without text is stored as empty. The caller saves the cache.
--- @return boolean summarized, string|nil error, table|nil message_history (on error)
local function summarizeChapter(assistant, chapters, cache, idx)
    local ui = assistant.ui
    local chapter = chapters[idx]
    local chapter_text = Chapters.getChapterText(ui, chapters, idx)
    if not chapter_text or koutil.trim(chapter_text) == "" then
        logger.warn("assistant chapters: no text for chapter", idx, chapter.title)
        cache.chapters[idx] = { title = chapter.title, empty = true }
        return false
    end

    local title, author = getBookInfo(ui)
    local system_prompt, user_prompt_template = Chapters.getPrompts(assistant.config, "chapter_summary_config", "chapter_summary")
    local user_content = Chapters.expandPrompt(user_prompt_template, {
        title = title,
        author = author,
        chapter_title = chapter.title,
        chapter_number = idx,
        chapter_count = #chapters,
        language = getLanguage(assistant),
    })
    user_content = user_content .. "\n\n[TABLE OF CONTENTS]\n" .. Chapters.buildTocOutline(chapters) .. "\n[END TABLE OF CONTENTS]"
    local previous_summaries = Chapters.buildSummariesBlock(cache, idx - 1)
    if previous_summaries ~= "" then
        user_content = user_content .. "\n\n[SUMMARIES OF PREVIOUS CHAPTERS]\n"
            .. previous_summaries .. "\n[END SUMMARIES OF PREVIOUS CHAPTERS]"
    end
    user_content = user_content .. "\n\n[CHAPTER TEXT BEGIN]\n"
        .. Chapters.truncateChapterText(chapter_text, getMaxTextLength(assistant)) .. "\n[CHAPTER TEXT END]"

    local message_history = {
        { role = "system", content = system_prompt },
        { role = "user", content = user_content },
    }
    assistant.querier.user_interrupted = false
    -- One loading message per chapter is the progress UI: no stream dialog, no web search.
    local answer, err = assistant.querier:query(message_history,
        T(_("Summarizing chapter %1 of %2: %3"), idx, #chapters, chapter.title),
        { use_stream_mode = false, use_websearch = "none" })
    if err then
        return false, err, message_history
    end
    cache.chapters[idx] = { title = chapter.title, summary = answer, generated_at = os.time() }
    return true
end

--- Generate summaries for chapters 1 .. upto (default: the whole book), in order.
--- Resumable: cached chapters are skipped and the cache is saved after each
--- chapter. Must run inside Trapper:wrap with network available.
function M.generateAllSummaries(assistant, upto)
    local ui = assistant.ui
    if not loadActiveModel(assistant) then return end

    local chapters, cherr = Chapters.getChapters(ui)
    if not chapters then
        UIManager:show(InfoMessage:new{ icon = "notice-warning", text = cherr })
        return
    end
    local last = math.min(upto or #chapters, #chapters)

    local cache = Chapters.loadCache(ui)
    if type(cache) ~= "table" or cache.chapter_count ~= #chapters then
        -- no cache yet, or the TOC segmentation changed: start fresh
        cache = { version = 1, chapter_count = #chapters, chapters = {} }
    end

    local generated = 0
    for chapter_idx = 1, last do
        local entry = cache.chapters[chapter_idx]
        if not (entry and entry.summary) then
            local ok, qerr, message_history = summarizeChapter(assistant, chapters, cache, chapter_idx)
            if qerr then
                Chapters.saveCache(ui, cache)
                if not assistant.querier.user_interrupted then
                    assistant.querier:showError(qerr, message_history)
                end
                UIManager:show(InfoMessage:new{
                    text = T(_("Stopped: %1 of %2 chapter summaries saved.\nRun \"Generate Summaries\" again to continue."),
                        Chapters.countCachedSummaries(cache), #chapters),
                })
                return
            end
            if ok then generated = generated + 1 end
            Chapters.saveCache(ui, cache)
        end
    end
    Chapters.saveCache(ui, cache)
    if generated == 0 then
        UIManager:show(InfoMessage:new{ text = _("These chapter summaries were already generated.") })
    elseif last < #chapters then
        UIManager:show(InfoMessage:new{
            text = T(_("Chapter summaries ready for the first %1 of %2 chapters."), last, #chapters),
        })
    else
        UIManager:show(InfoMessage:new{
            text = T(_("Chapter summaries ready for all %1 chapters."), #chapters),
        })
    end
end

--- Confirm the number of API requests, then generate.
--- scope "read": chapters up to and including the current one; otherwise the whole book.
function M.confirmAndGenerate(assistant, scope)
    if not assistant:isConfigured() then return end
    local ui = assistant.ui
    local chapters, err = Chapters.getChapters(ui)
    if not chapters then
        UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
        return
    end

    local upto = #chapters
    local scope_text = _("The whole book is processed, including parts you have not read yet.")
    if scope == "read" then
        upto = Chapters.getChapterIndexByPage(chapters, ui:getCurrentPage())
        if upto == 0 then
            UIManager:show(InfoMessage:new{ text = _("You are before the first chapter; nothing to summarize yet.") })
            return
        end
        scope_text = T(_("Only chapters 1-%1 (up to your reading position) are processed."), upto)
    end

    local todo = Chapters.countMissing(Chapters.loadCache(ui), chapters, upto)
    if todo <= 0 then
        UIManager:show(InfoMessage:new{ text = _("These chapter summaries were already generated.") })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("Generate AI summaries for %1 chapters (%1 API requests)?\n\n%2 Summaries are stored with the book and only shown to you after you finish each chapter.\n\nYou can dismiss the progress message to stop; completed chapters are kept."),
            todo, scope_text),
        ok_text = _("Generate"),
        ok_callback = function()
            NetUtils.runWhenOnlineFast(function()
                Trapper:wrap(function()
                    M.generateAllSummaries(assistant, upto)
                end)
            end)
        end,
    })
end

--- Nearest chapter index from `idx` in direction `step` (within 1 .. finished) that has a summary.
local function findSummaryIndex(cache, idx, step, finished)
    local target = idx + step
    while target >= 1 and target <= finished do
        local entry = Chapters.getEntry(cache, target)
        if entry and entry.summary then return target end
        target = target + step
    end
    return nil
end

--- Show the cached summary of one finished chapter, with chapter navigation
--- and follow-ups (the chapter text joins the context on the first follow-up).
function M.showChapterSummary(assistant, chapter_idx)
    local ui = assistant.ui
    local cache = Chapters.loadCache(ui)
    local entry = Chapters.getEntry(cache, chapter_idx)
    if not entry or not entry.summary then
        UIManager:show(InfoMessage:new{ text = _("No summary was generated for this chapter yet.") })
        return
    end
    local chapters = Chapters.getChapters(ui)
    local finished = chapters and Chapters.getFinishedChapterCount(ui, chapters) or chapter_idx
    finished = math.max(finished, chapter_idx)

    local title, author = getBookInfo(ui)
    local chapter_title = entry.title or "?"
    local suggestions = suggestionsEnabled(assistant)
    local context_msg = {
        role = "user",
        content = string.format(
            "I'm reading '%s' by %s and just finished chapter %d, \"%s\". You summarized it as follows; I may ask follow-up questions about it. Never reveal anything from later chapters.",
            title, author, chapter_idx, chapter_title),
    }
    ASUtils.set_attr(context_msg, "is_context", true)
    local summary_msg = { role = "assistant", content = entry.summary }
    ASUtils.set_attr(summary_msg, "show_suggestions", false)
    local message_history = {
        { role = "system", content = conversationSystemPrompt(assistant, Prompts.assistant_prompts.default.system_prompt, suggestions) },
        context_msg,
        summary_msg,
    }

    local viewer
    local function goTo(target)
        UIManager:close(viewer)
        M.showChapterSummary(assistant, target)
    end
    local prev_idx = findSummaryIndex(cache, chapter_idx, -1, finished)
    local next_idx = findSummaryIndex(cache, chapter_idx, 1, finished)
    local nav_row = {
        {
            text = "◁ " .. _("Previous"),
            enabled = prev_idx ~= nil,
            callback = function() goTo(prev_idx) end,
        },
        {
            text = _("Chapter List"),
            callback = function()
                UIManager:close(viewer)
                M.showSummaryPicker(assistant)
            end,
        },
        {
            text = _("Next") .. " ▷",
            enabled = next_idx ~= nil,
            callback = function() goTo(next_idx) end,
        },
    }

    viewer = showConversation(assistant, {
        title = T(_("Summary: %1"), chapter_title),
        message_history = message_history,
        vars = { scope = SCOPE_CHAPTER, title = title, author = author,
            language = getLanguage(assistant), chapter_title = chapter_title },
        lazy_context = function()
            local parts = {}
            if chapters then
                local previous = Chapters.buildSummariesBlock(cache, chapter_idx - 1)
                if previous ~= "" then
                    table.insert(parts, "\n\n[SUMMARIES OF EARLIER CHAPTERS]\n" .. previous .. "\n[END SUMMARIES OF EARLIER CHAPTERS]")
                end
                local text = Chapters.getChapterText(ui, chapters, chapter_idx)
                if text and koutil.trim(text) ~= "" then
                    table.insert(parts, "\n\n[CHAPTER TEXT BEGIN]\n"
                        .. Chapters.truncateChapterText(text, getMaxTextLength(assistant)) .. "\n[CHAPTER TEXT END]")
                end
            end
            return table.concat(parts)
        end,
        buttons_table = { nav_row },
        -- Without follow-ups the answer is the stored summary: regenerate that
        -- chapter's summary with the current model and keep the new one.
        onRegenerate = function(v)
            if #message_history > 3 then
                v:regenerateLastAnswer()
                return
            end
            NetUtils.runWhenOnlineFast(function()
                Trapper:wrap(function()
                    if not loadActiveModel(assistant) then return end
                    local fresh = Chapters.loadCache(ui)
                    if not chapters or type(fresh) ~= "table" or fresh.chapter_count ~= #chapters then
                        UIManager:show(InfoMessage:new{ icon = "notice-warning",
                            text = _("The chapter list of this book changed. Generate the summaries again.") })
                        return
                    end
                    local ok, err, failed_history = summarizeChapter(assistant, chapters, fresh, chapter_idx)
                    if err then
                        assistant.querier:showError(err, failed_history)
                        return
                    end
                    if not ok then return end
                    fresh.overview = nil -- built from the old summary
                    Chapters.saveCache(ui, fresh)
                    UIManager:close(v)
                    M.showChapterSummary(assistant, chapter_idx)
                end)
            end)
        end,
    })
end

--- Picker listing the summaries of finished chapters (bindable to a gesture).
function M.showSummaryPicker(assistant)
    local ui = assistant.ui
    if not Chapters.isSupported(ui) then
        UIManager:show(InfoMessage:new{ text = _("Chapter summaries are only available for EPUB-like documents.") })
        return
    end
    local chapters, err = Chapters.getChapters(ui)
    if not chapters then
        UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
        return
    end
    local cache = Chapters.loadCache(ui)
    if Chapters.countCachedSummaries(cache) == 0 then
        UIManager:show(InfoMessage:new{ text = _("No chapter summaries yet. Generate them from the AI Assistant menu.") })
        return
    end
    local finished = Chapters.getFinishedChapterCount(ui, chapters)
    if finished == 0 then
        UIManager:show(InfoMessage:new{ text = _("Finish a chapter first: summaries are only shown for chapters you have completed.") })
        return
    end

    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local buttons = {}
    for chapter_idx = 1, finished do
        local entry = Chapters.getEntry(cache, chapter_idx)
        table.insert(buttons, {{
            text = string.format("%d. %s", chapter_idx, (entry and entry.title) or chapters[chapter_idx].title),
            enabled = entry ~= nil and entry.summary ~= nil,
            callback = function()
                UIManager:close(dialog)
                M.showChapterSummary(assistant, chapter_idx)
            end,
        }})
    end
    dialog = ButtonDialog:new{
        title = _("Finished Chapters"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

--- Book Structure So Far: one reduce query over the finished chapters' summaries,
--- cached in the sidecar until another chapter is finished; `force` regenerates.
function M.showStructureOverview(assistant, force)
    if not assistant:isConfigured() then return end
    local ui = assistant.ui
    local chapters, err = Chapters.getChapters(ui)
    if not chapters then
        UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
        return
    end
    local cache = Chapters.loadCache(ui)
    local finished = Chapters.getFinishedChapterCount(ui, chapters)
    local summaries = Chapters.buildSummariesBlock(cache, finished)
    if summaries == "" then
        UIManager:show(InfoMessage:new{
            text = _("No summaries of finished chapters available yet. Generate chapter summaries first."),
        })
        return
    end
    local title, author = getBookInfo(ui)
    local system_prompt, user_prompt_template = Chapters.getPrompts(assistant.config, "chapter_overview_config", "chapter_overview")

    local function viewOverview(overview)
        local suggestions = suggestionsEnabled(assistant)
        local context_msg = {
            role = "user",
            content = string.format(
                "I'm reading '%s' by %s. You wrote the structure overview below of the %d chapters I have finished, based on my chapter summaries. I may ask follow-up questions. Never reveal anything beyond these chapters.",
                title, author, overview.finished_count),
        }
        ASUtils.set_attr(context_msg, "is_context", true)
        local overview_msg = {
            role = "assistant",
            content = T(_("_Based on %1 finished chapters, generated %2. Hold the menu entry to regenerate._"),
                overview.finished_count, os.date("%Y-%m-%d %H:%M", overview.generated_at))
                .. "\n\n" .. overview.text,
        }
        ASUtils.set_attr(overview_msg, "show_suggestions", false)
        showConversation(assistant, {
            title = _("Book Structure So Far"),
            message_history = {
                { role = "system", content = conversationSystemPrompt(assistant, Prompts.assistant_prompts.default.system_prompt, suggestions) },
                context_msg,
                overview_msg,
            },
            vars = { scope = SCOPE_BOOK_SO_FAR, title = title, author = author, language = getLanguage(assistant) },
            lazy_context = function()
                return "\n\n[CHAPTER SUMMARIES BEGIN]\n" .. summaries .. "\n[CHAPTER SUMMARIES END]"
            end,
            onRegenerate = function(v)
                if #v.message_history > 3 then
                    v:regenerateLastAnswer()
                    return
                end
                UIManager:close(v)
                M.showStructureOverview(assistant, true)
            end,
        })
    end

    local cached_overview = cache.overview
    if not force and type(cached_overview) == "table" and cached_overview.text
            and cached_overview.finished_count == finished then
        viewOverview(cached_overview)
        return
    end

    NetUtils.runWhenOnlineFast(function()
        Trapper:wrap(function()
            if not loadActiveModel(assistant) then return end
            local user_content = Chapters.expandPrompt(user_prompt_template, {
                title = title,
                author = author,
                language = getLanguage(assistant),
            })
            user_content = user_content .. "\n\n[CHAPTER SUMMARIES BEGIN]\n" .. summaries .. "\n[CHAPTER SUMMARIES END]"
            local message_history = {
                { role = "system", content = system_prompt },
                { role = "user", content = user_content },
            }
            local answer, qerr = assistant.querier:query(message_history, _("Book Structure So Far"),
                { use_websearch = "none" })
            if qerr then
                assistant.querier:showError(qerr, message_history)
                return
            end
            local overview = {
                text = answer,
                finished_count = finished,
                generated_at = os.time(),
            }
            cache.overview = overview
            Chapters.saveCache(ui, cache)
            viewOverview(overview)
        end)
    end)
end

--- Ask-about scope: { kind = "chapter" | "book" | "range", first, last, section (title|nil) }.
local function scopeLabel(scope, chapters)
    if scope.kind == "chapter" then
        return T(_("Current Chapter: %1"), chapters[scope.last].title)
    elseif scope.kind == "book" then
        return _("Book So Far")
    elseif scope.section then
        return T("%1 (%2-%3)", scope.section, scope.first, scope.last)
    elseif scope.first == scope.last then
        return T(_("Chapter %1: %2"), scope.first, chapters[scope.first].title)
    end
    return T(_("Chapters %1-%2"), scope.first, scope.last)
end

--- LLM-facing description of a scope, for {scope}.
local function scopeForPrompt(scope)
    if scope.kind == "chapter" then
        return SCOPE_CURRENT_CHAPTER
    elseif scope.kind == "book" then
        return SCOPE_BOOK
    elseif scope.section then
        return string.format("the section \"%s\" (chapters %d to %d)", scope.section, scope.first, scope.last)
    elseif scope.first == scope.last then
        return string.format("chapter %d", scope.first)
    end
    return string.format("chapters %d to %d", scope.first, scope.last)
end

--- Two-step chapter range picker (from, then to), limited to 1 .. available.
local function pickChapterRange(chapters, available, on_pick)
    local ButtonDialog = require("ui/widget/buttondialog")
    local function chapterList(from, title, on_select)
        local dialog
        local buttons = {}
        for chapter_idx = from, available do
            table.insert(buttons, {{
                text = string.format("%d. %s", chapter_idx, chapters[chapter_idx].title),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    on_select(chapter_idx)
                end,
            }})
        end
        dialog = ButtonDialog:new{ title = title, buttons = buttons }
        UIManager:show(dialog)
    end
    chapterList(1, _("From Chapter"), function(first)
        chapterList(first, _("To Chapter"), function(last)
            on_pick({ kind = "range", first = first, last = last })
        end)
    end)
end

--- Scope picker: current chapter, book so far, the book's sections, or a chapter range.
local function pickScope(ui, chapters, current, available, on_pick)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local function choose(scope)
        UIManager:close(dialog)
        on_pick(scope)
    end
    local buttons = {
        {{ text = T(_("Current Chapter: %1"), chapters[current].title), align = "left",
            callback = function() choose({ kind = "chapter", first = current, last = current }) end }},
        {{ text = _("Book So Far"), align = "left",
            callback = function() choose({ kind = "book", first = 1, last = available }) end }},
    }
    local sections = Chapters.getSections(ui, chapters)
    for section_idx = 1, #sections do
        local section = sections[section_idx]
        if section.first <= available then
            local last = math.min(section.last, available)
            table.insert(buttons, {{
                text = T("%1 (%2-%3)", section.title, section.first, last),
                align = "left",
                callback = function()
                    choose({ kind = "range", first = section.first, last = last, section = section.title })
                end,
            }})
        end
    end
    table.insert(buttons, {{ text = _("Choose Chapters..."), align = "left",
        callback = function()
            UIManager:close(dialog)
            pickChapterRange(chapters, available, on_pick)
        end }})
    dialog = ButtonDialog:new{ title = _("Ask About"), buttons = buttons }
    UIManager:show(dialog)
end

--- Ask about the current chapter, the book so far or a range of chapters,
--- typed or via a chapter prompt button. Never beyond the reading position
--- (the whole book once it is finished).
--- @param scope table|nil defaults to the current chapter
--- @param typed string|nil question text carried over from a scope change
function M.askAbout(assistant, scope, typed)
    if not assistant:isConfigured() then return end
    local ui = assistant.ui
    if not Chapters.isSupported(ui) then
        UIManager:show(InfoMessage:new{ text = _("Chapter questions are only available for EPUB-like documents.") })
        return
    end
    local chapters, err = Chapters.getChapters(ui)
    if not chapters then
        UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
        return
    end
    local available = Chapters.getAvailableChapterCount(ui, chapters)
    local current = math.max(1, Chapters.getChapterIndexByPage(chapters, ui:getCurrentPage()))
    scope = scope or { kind = "chapter", first = current, last = current }

    local input_dialog
    local function submit(request)
        UIManager:close(input_dialog)
        NetUtils.runWhenOnlineFast(function()
            Trapper:wrap(function()
                M.queryAbout(assistant, chapters, scope, request)
            end)
        end)
    end

    local button_rows = {
        {{
            text = T(_("Scope: %1"), scopeLabel(scope, chapters)),
            callback = function()
                local text = input_dialog:getInputText()
                UIManager:close(input_dialog)
                pickScope(ui, chapters, current, available, function(new_scope)
                    M.askAbout(assistant, new_scope, text)
                end)
            end,
        }},
        {
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
                    local question = koutil.trim(input_dialog:getInputText() or "")
                    if question == "" then
                        UIManager:show(InfoMessage:new{ text = _("Enter a question or tap one of the buttons."), timeout = 3 })
                        return
                    end
                    submit({ question = question })
                end,
            },
        },
    }
    local prompts = Chapters.getChapterPrompts(assistant.config:getFeature("chapter_prompts"))
    for i = 1, #prompts, 3 do
        local row = {}
        for j = i, math.min(i + 2, #prompts) do
            local prompt = prompts[j]
            table.insert(row, {
                text = prompt.text,
                callback = function()
                    submit({ prompt = prompt, question = koutil.trim(input_dialog:getInputText() or "") })
                end,
            })
        end
        table.insert(button_rows, row)
    end

    input_dialog = InputDialog:new{
        title = _("Ask About"),
        input = typed or "",
        input_hint = _("Type a question, or tap a button below"),
        buttons = button_rows,
    }
    UIManager:show(input_dialog)
end

--- Run an ask-about request and show the conversation.
--- Chapter scope: summaries of finished chapters + the current chapter up to
--- the position. Book/range scope: full chapter texts newest first within
--- max_text_length_for_analysis, summaries for the earlier ones.
--- @param request table { question = string, prompt = table|nil chapter prompt }
function M.queryAbout(assistant, chapters, scope, request)
    local ui = assistant.ui
    if not loadActiveModel(assistant) then return end

    local title, author = getBookInfo(ui)
    local language = getLanguage(assistant)
    local current = math.max(1, Chapters.getChapterIndexByPage(chapters, ui:getCurrentPage()))
    local position_xp = ui.document:getXPointer()
    local _available, finished = Chapters.getAvailableChapterCount(ui, chapters)
    local vars = { scope = scopeForPrompt(scope), title = title, author = author,
        language = language, chapter_title = chapters[current].title }

    local request_text = request.question or ""
    if request.prompt then
        request_text = Chapters.expandPrompt(request.prompt.user_prompt, vars)
            .. (request.question ~= "" and ("\n\n" .. request.question) or "")
    end

    local cache = Chapters.loadCache(ui)
    local max_len = getMaxTextLength(assistant)
    local system_prompt, user_content
    if scope.kind == "chapter" then
        local user_prompt_template
        system_prompt, user_prompt_template = Chapters.getPrompts(assistant.config, "chapter_question_config", "chapter_question")
        user_content = Chapters.expandPrompt(user_prompt_template, {
            title = title,
            author = author,
            chapter_title = chapters[current].title,
            user_input = request_text,
            language = language,
        })
        local previous_summaries = Chapters.buildSummariesBlock(cache, current - 1)
        if previous_summaries ~= "" then
            user_content = user_content .. "\n\n[SUMMARIES OF FINISHED CHAPTERS]\n"
                .. previous_summaries .. "\n[END SUMMARIES OF FINISHED CHAPTERS]"
        end
        -- the current chapter up to the top of the current page
        local chapter_text = Chapters.getChapterText(ui, chapters, current, position_xp)
        if chapter_text and koutil.trim(chapter_text) ~= "" then
            user_content = user_content .. "\n\n[CURRENT CHAPTER TEXT, UP TO MY POSITION]\n"
                .. Chapters.truncateChapterText(chapter_text, max_len) .. "\n[END CURRENT CHAPTER TEXT]"
        end
    else
        local user_prompt_template
        system_prompt, user_prompt_template = Chapters.getPrompts(assistant.config, "book_question_config", "book_question")
        user_content = Chapters.expandPrompt(user_prompt_template, {
            title = title,
            author = author,
            chapter_title = chapters[current].title,
            scope = vars.scope,
            user_input = request_text,
            language = language,
        })
        local context, info = Chapters.buildRangeContext(chapters, cache, scope.first, scope.last, max_len,
            function(idx)
                -- the chapter being read only counts up to the position
                if idx == current and not finished then
                    return Chapters.getChapterText(ui, chapters, idx, position_xp)
                end
                return Chapters.getChapterText(ui, chapters, idx)
            end)
        user_content = user_content .. "\n\n" .. context
        if info.missing_summaries > 0 then
            UIManager:show(InfoMessage:new{
                text = T(_("%1 earlier chapters did not fit as full text and have no summary yet; the answer will not cover them. Generate chapter summaries to include them."),
                    info.missing_summaries),
                timeout = 5,
            })
        end
    end

    local label = scopeLabel(scope, chapters)
    local suggestions = suggestionsEnabled(assistant)
    local request_msg = { role = "user", content = user_content }
    ASUtils.set_attr(request_msg, "prompt_title", request.prompt and request.prompt.text or label)
    ASUtils.set_attr(request_msg, "user_input", request.question or "")
    ASUtils.set_attr(request_msg, "show_suggestions", suggestions)
    ASUtils.set_attr(request_msg, "use_websearch", false)
    local message_history = {
        { role = "system", content = conversationSystemPrompt(assistant, system_prompt, suggestions) },
        request_msg,
    }
    local query_title = request.prompt and request.prompt.text or label
    local answer, qerr = assistant.querier:query(message_history, query_title, { use_websearch = "none" })
    if qerr then
        assistant.querier:showError(qerr, message_history)
        return
    end
    Conversation.append_answer(message_history, answer, suggestions)
    showConversation(assistant, {
        title = label,
        message_history = message_history,
        vars = vars,
    })
end

--- Called from Assistant:onPageUpdate on sequential forward page turns: when the
--- turn crosses into the next chapter and the finished chapter has a cached
--- summary, offer to show it.
function M.onPageTurn(assistant, prev_page, new_page)
    local ui = assistant.ui
    if not Chapters.isSupported(ui) then return end
    local cache = Chapters.loadCache(ui)
    if type(cache) ~= "table" or not cache.chapters then return end
    local chapters = Chapters.getChapters(ui)
    if not chapters then return end

    local prev_idx = Chapters.getChapterIndexByPage(chapters, prev_page)
    local new_idx = Chapters.getChapterIndexByPage(chapters, new_page)
    if prev_idx < 1 or new_idx ~= prev_idx + 1 then return end

    local entry = Chapters.getEntry(cache, prev_idx)
    if not entry or not entry.summary then return end
    if assistant._last_chapter_notified == prev_idx then return end
    assistant._last_chapter_notified = prev_idx

    UIManager:show(ConfirmBox:new{
        text = T(_("You finished \"%1\".\n\nView the AI chapter summary?"), entry.title or "?"),
        ok_text = _("View"),
        ok_callback = function()
            M.showChapterSummary(assistant, prev_idx)
        end,
        cancel_text = _("Not Now"),
    })
end

--- Sub-menu for the AI Assistant main menu.
function M.genMenuItems(assistant)
    local ui = assistant.ui
    local function supported() return Chapters.isSupported(ui) end
    return {
        {
            text = _("Ask About Chapter or Book"),
            enabled_func = supported,
            callback = function()
                M.askAbout(assistant)
            end,
            hold_callback = function()
                UIManager:show(InfoMessage:new{
                    text = _("Ask a question, or tap a ready-made request (critique, quiz, mind map, ...), about the current chapter, the book so far, a part of the book or chosen chapters. Uses the full text where it fits and chapter summaries for the rest. Never goes beyond your reading position."),
                })
            end,
        },
        {
            text = _("View Chapter Summaries"),
            enabled_func = supported,
            callback = function()
                M.showSummaryPicker(assistant)
            end,
            hold_callback = function()
                UIManager:show(InfoMessage:new{
                    text = _("Summaries of the chapters you have finished, with buttons to move between chapters. Chapters you have not reached yet are never shown, to avoid spoilers."),
                })
            end,
        },
        {
            text = _("Book Structure So Far"),
            enabled_func = supported,
            callback = function()
                M.showStructureOverview(assistant)
            end,
            hold_callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("How the finished chapters fit into the book's overall structure, synthesized from the stored chapter summaries.\n\nThe result is stored with the book and only regenerated after you finish another chapter. Regenerate it now (one API request)?"),
                    ok_text = _("Regenerate"),
                    ok_callback = function()
                        M.showStructureOverview(assistant, true)
                    end,
                })
            end,
            separator = true,
        },
        {
            text = _("Generate Summaries: Read Chapters"),
            enabled_func = supported,
            callback = function()
                M.confirmAndGenerate(assistant, "read")
            end,
            hold_callback = function()
                UIManager:show(InfoMessage:new{
                    text = _("Summarizes only the chapters up to your reading position (one API request per chapter). Run it again later to cover newly read chapters; already summarized chapters are never redone."),
                })
            end,
        },
        {
            text_func = function()
                local label = _("Generate Summaries: Whole Book")
                if not supported() then return label end
                local chapters = Chapters.getChapters(ui)
                local cache = Chapters.loadCache(ui)
                local cached = (type(cache) == "table" and chapters and cache.chapter_count == #chapters)
                    and Chapters.countCachedSummaries(cache) or 0
                if chapters and cached > 0 and cached < #chapters then
                    return T("%1 (%2/%3)", label, cached, #chapters)
                end
                return label
            end,
            enabled_func = supported,
            callback = function()
                M.confirmAndGenerate(assistant)
            end,
            hold_callback = function()
                UIManager:show(InfoMessage:new{
                    text = _("Summarizes every chapter of the book (one API request per chapter), including unread ones; summaries stay hidden until you finish each chapter. Interrupted runs continue where they stopped."),
                })
            end,
        },
        {
            text = _("Notify When Finishing a Chapter"),
            enabled_func = supported,
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
            text = _("Delete Chapter Summaries"),
            enabled_func = function()
                return supported() and Chapters.loadCache(ui) ~= nil
            end,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("Delete all stored chapter summaries for this book?"),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        Chapters.deleteCache(ui)
                    end,
                })
            end,
        },
    }
end

return M
