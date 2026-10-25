--- Chapter summaries: data side (segmentation, text extraction, sidecar cache,
--- prompt assembly). Chapters come from the TOC; summaries are generated in
--- order so each prompt carries the summaries of all previous chapters, and are
--- cached in the book's sidecar. Reading-time features only expose summaries of
--- finished chapters, so spoiler-safety is structural.
--- EPUB-like (rolling) documents only: extraction relies on TOC xpointers.
--- UI flows live in dialogs/chapters.lua.
local koutil = require("util")
local logger = require("logger")
local TextUtils = require("utils/text")
local Prompts = require("core/prompts")
local _ = require("core/gettext")

local M = {}

M.SIDECAR_KEY = "assistant_chapter_summaries"

--- Chapter features need TOC xpointers, only available for rolling documents.
function M.isSupported(ui)
    return ui ~= nil and ui.rolling ~= nil and ui.document ~= nil
end

--- Build the chapter list from the TOC, using a single depth level: the depth
--- with the most entries, so books split into a few big "Parts" fall through to
--- their chapters. A synthetic "(Beginning)" chapter covers front matter when the
--- first entry does not start at page 1. Deterministic, so cached indices stay
--- valid across sessions.
--- @return table|nil chapters { title, start_xp, start_page }, string|nil error
function M.getChapters(ui)
    local toc = ui.toc and ui.toc.toc
    if type(toc) ~= "table" or #toc == 0 then
        return nil, _("This book has no table of contents; chapter summaries are unavailable.")
    end

    local depth_counts = {}
    local max_depth = 1
    for toc_idx = 1, #toc do
        local d = toc[toc_idx].depth or 1
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
    for toc_idx = 1, #toc do
        local item = toc[toc_idx]
        if (item.depth or 1) == depth and item.xpointer then
            table.insert(chapters, {
                title = item.title or _("Untitled chapter"),
                start_xp = item.xpointer,
                start_page = item.page or 1,
                depth = depth,
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
function M.getChapterIndexByPage(chapters, page)
    local idx = 0
    for chapter_idx = 1, #chapters do
        local start_page = chapters[chapter_idx].start_page
        if start_page and start_page <= page then
            idx = chapter_idx
        else
            break
        end
    end
    return idx
end

--- Number of chapters the reader has fully finished.
function M.getFinishedChapterCount(ui, chapters)
    local current_page = ui:getCurrentPage()
    if current_page >= ui.document:getPageCount() then
        return #chapters -- on the last page the whole book counts as finished
    end
    return math.max(0, M.getChapterIndexByPage(chapters, current_page) - 1)
end

--- Text of chapter `idx`. With `up_to_xp`, extraction stops there (text up to
--- the reading position) instead of at the chapter end.
--- @return string|nil
function M.getChapterText(ui, chapters, idx, up_to_xp)
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
        -- resolve document start/end, restoring the reading position afterwards
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
        logger.warn("assistant chapters: text extraction failed for chapter", idx, text)
        return nil
    end
    return text
end

--- Keep the head of a chapter text within max_len bytes, marking the cut.
function M.truncateChapterText(text, max_len)
    if #text <= max_len then return text end
    return TextUtils.truncateToHeadUtf8Safe(text, max_len) .. "\n[... chapter text truncated ...]"
end

function M.loadCache(ui)
    return ui.doc_settings:readSetting(M.SIDECAR_KEY)
end

function M.saveCache(ui, cache)
    ui.doc_settings:saveSetting(M.SIDECAR_KEY, cache)
    ui.doc_settings:flush()
end

function M.deleteCache(ui)
    ui.doc_settings:delSetting(M.SIDECAR_KEY)
    ui.doc_settings:flush()
end

--- Cached entry for chapter `idx`, or nil.
function M.getEntry(cache, idx)
    return koutil.tableGetValue(cache, "chapters", idx)
end

function M.countCachedSummaries(cache)
    local n = 0
    local entries = koutil.tableGetValue(cache, "chapters")
    if type(entries) == "table" then
        for chapter_idx, entry in pairs(entries) do
            if type(entry) == "table" and entry.summary then n = n + 1 end
        end
    end
    return n
end

--- How many of chapters 1 .. upto still need a summary (empty chapters count as done).
function M.countMissing(cache, chapters, upto)
    local valid = type(cache) == "table" and cache.chapter_count == #chapters
    local missing = 0
    for chapter_idx = 1, upto do
        local entry = valid and M.getEntry(cache, chapter_idx)
        if not (entry and (entry.summary or entry.empty)) then
            missing = missing + 1
        end
    end
    return missing
end

function M.buildTocOutline(chapters)
    local lines = {}
    for chapter_idx = 1, #chapters do
        lines[chapter_idx] = string.format("%d. %s", chapter_idx, chapters[chapter_idx].title)
    end
    return table.concat(lines, "\n")
end

--- Concatenated summaries of chapters 1 .. upto (inclusive), for prompt context.
function M.buildSummariesBlock(cache, upto)
    local parts = {}
    for chapter_idx = 1, upto do
        local entry = M.getEntry(cache, chapter_idx)
        if entry and entry.summary then
            table.insert(parts, string.format("### %d. %s\n\n%s", chapter_idx, entry.title or "?", entry.summary))
        end
    end
    return table.concat(parts, "\n\n")
end

--- Highest chapter index the reader may ask about: the current chapter (read
--- up to the position), or every chapter once the book is finished.
--- @return number last index, boolean book_finished
function M.getAvailableChapterCount(ui, chapters)
    if ui:getCurrentPage() >= ui.document:getPageCount() then
        return #chapters, true
    end
    return math.max(1, M.getChapterIndexByPage(chapters, ui:getCurrentPage())), false
end

--- Sections ("parts") from TOC entries shallower than the chapter level. A
--- section spans from the first chapter starting at or after its heading up to
--- the chapter before the next section.
--- @return table[] list of { title, first, last }
function M.getSections(ui, chapters)
    local toc = ui.toc and ui.toc.toc
    local chapter_depth = chapters[#chapters] and chapters[#chapters].depth
    if type(toc) ~= "table" or not chapter_depth or chapter_depth <= 1 then return {} end
    local sections = {}
    for toc_idx = 1, #toc do
        local item = toc[toc_idx]
        if (item.depth or 1) < chapter_depth and item.page then
            local first
            for chapter_idx = 1, #chapters do
                if chapters[chapter_idx].start_page >= item.page then
                    first = chapter_idx
                    break
                end
            end
            if first then
                local prev = sections[#sections]
                if prev and prev.first == first then
                    table.remove(sections) -- nested headings on the same page: keep the innermost
                    prev = sections[#sections]
                end
                if prev then prev.last = math.max(prev.first, first - 1) end
                table.insert(sections, { title = item.title or "?", first = first, last = #chapters })
            end
        end
    end
    return sections
end

--- Context for chapters first .. last within `budget` bytes: full texts from
--- the last chapter backwards while they fit (the last one is tail-truncated if
--- it alone is too long); earlier chapters fall back to cached summaries.
--- getText(idx) is called lazily, newest first, and not for summarized chapters.
--- @param chapters table[]
--- @param cache table|nil summary cache
--- @param first number
--- @param last number
--- @param budget number maximum bytes of full text
--- @param getText function(idx) -> string|nil
--- @return string context, table info { full_from, missing_summaries }
function M.buildRangeContext(chapters, cache, first, last, budget, getText)
    local texts = {}
    local used = 0
    local full_from = last + 1
    for idx = last, first, -1 do
        local text = getText(idx) or ""
        if koutil.trim(text) == "" then
            texts[idx] = ""
            full_from = idx
        elseif used + #text <= budget then
            texts[idx] = text
            used = used + #text
            full_from = idx
        else
            if idx == last then
                texts[idx] = "[...]\n" .. TextUtils.truncateToTailUtf8Safe(text, budget)
                full_from = idx
            end
            break
        end
    end

    local parts = {}
    local missing = 0
    if full_from > first then
        local summaries = {}
        for idx = first, full_from - 1 do
            local entry = M.getEntry(cache, idx)
            local title = chapters[idx] and chapters[idx].title or "?"
            if entry and entry.summary then
                table.insert(summaries, string.format("### %d. %s\n\n%s", idx, title, entry.summary))
            elseif not (entry and entry.empty) then
                missing = missing + 1
                table.insert(summaries, string.format("### %d. %s\n\n(no summary available)", idx, title))
            end
        end
        table.insert(parts, "[SUMMARIES OF EARLIER CHAPTERS]\n" .. table.concat(summaries, "\n\n")
            .. "\n[END SUMMARIES OF EARLIER CHAPTERS]")
    end
    if full_from <= last then
        local full = {}
        for idx = full_from, last do
            if texts[idx] ~= "" then
                table.insert(full, string.format("[CHAPTER %d: %s]\n%s", idx, chapters[idx].title, texts[idx]))
            end
        end
        table.insert(parts, "[FULL TEXT]\n" .. table.concat(full, "\n\n") .. "\n[END FULL TEXT]")
    end
    return table.concat(parts, "\n\n"), { full_from = full_from, missing_summaries = missing }
end

--- Prompt pair for a chapter feature: features.<config_key> in configuration.lua
--- beats the built-in assistant_prompts.<prompts_key>.
--- @return string system_prompt, string user_prompt
function M.getPrompts(config, config_key, prompts_key)
    local file_config = config:getFeature(config_key) or {}
    local system_prompt = koutil.tableGetValue(file_config, "system_prompt")
        or koutil.tableGetValue(Prompts.assistant_prompts, prompts_key, "system_prompt")
    local user_prompt = koutil.tableGetValue(file_config, "user_prompt")
        or koutil.tableGetValue(Prompts.assistant_prompts, prompts_key, "user_prompt")
    return system_prompt, user_prompt
end

--- Built-in chapter prompts merged with features.chapter_prompts, visible ones
--- only, sorted by order.
--- @param user_prompts table|nil features.chapter_prompts
--- @return table[] list of { id, text, user_prompt, order }
function M.getChapterPrompts(user_prompts)
    local merged = {}
    for id, prompt in pairs(Prompts.chapter_prompts) do
        merged[id] = koutil.tableDeepCopy(prompt)
    end
    if type(user_prompts) == "table" then
        for id, prompt in pairs(user_prompts) do
            if type(prompt) == "table" then
                merged[id] = merged[id] or {}
                for k, v in pairs(prompt) do merged[id][k] = v end
            end
        end
    end
    local list = {}
    for id, prompt in pairs(merged) do
        if prompt.visible ~= false and type(prompt.text) == "string" and type(prompt.user_prompt) == "string" then
            prompt.id = id
            table.insert(list, prompt)
        end
    end
    table.sort(list, function(a, b)
        local oa, ob = a.order or 1000, b.order or 1000
        if oa == ob then return a.id < b.id end
        return oa < ob
    end)
    return list
end

--- Expand {placeholders} in a prompt template; unknown ones are left as is.
--- @param template string
--- @param vars table placeholder name -> value
--- @return string
function M.expandPrompt(template, vars)
    return (template:gsub("{([%w_]+)}", function(key)
        local v = vars[key]
        if v == nil then return nil end
        return tostring(v)
    end))
end

return M
