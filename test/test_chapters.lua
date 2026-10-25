-- test_chapters.lua
-- Owns the data side of the chapter companion (feature/chapters):
--   * getChapters: TOC depth choice and the synthetic "(Beginning)" chapter
--   * getChapterIndexByPage / countMissing / buildSummariesBlock
--   * getChapterPrompts: built-in chapter prompts merged with user overrides
--   * expandPrompt: underscore placeholders, unknown ones left untouched
--   * buildRangeContext: full text newest first within the budget, summaries
--     for the rest, lazy text extraction
--   * getSections / getAvailableChapterCount: Ask About scopes
local helper = require("test.helper")
local assert = helper.assert
local Chapters = require("feature/chapters")

local function test(name, fn)
    return { name = name, fn = fn }
end

local function uiWithToc(toc)
    return { toc = { toc = toc } }
end

local function fakeConfig(features)
    return {
        getFeature = function(self, key, default)
            local v = features[key]
            if v == nil then return default end
            return v
        end,
    }
end

local tests = {
    test("getChapters: picks the depth with the most entries", function()
        local chapters = Chapters.getChapters(uiWithToc({
            { depth = 1, title = "Part One", xpointer = "p1", page = 1 },
            { depth = 2, title = "Ch 1", xpointer = "c1", page = 1 },
            { depth = 2, title = "Ch 2", xpointer = "c2", page = 10 },
            { depth = 1, title = "Part Two", xpointer = "p2", page = 20 },
            { depth = 2, title = "Ch 3", xpointer = "c3", page = 20 },
        }))
        assert.equal(3, #chapters)
        assert.equal("Ch 1", chapters[1].title)
        assert.equal("c3", chapters[3].start_xp)
    end),

    test("getChapters: adds (Beginning) when the first chapter starts after page 1", function()
        local chapters = Chapters.getChapters(uiWithToc({
            { depth = 1, title = "One", xpointer = "c1", page = 5 },
            { depth = 1, title = "Two", xpointer = "c2", page = 9 },
        }))
        assert.equal(3, #chapters)
        assert.equal(nil, chapters[1].start_xp)
        assert.equal(1, chapters[1].start_page)
        assert.equal("One", chapters[2].title)
    end),

    test("getChapters: no TOC returns an error", function()
        local chapters, err = Chapters.getChapters(uiWithToc({}))
        assert.equal(nil, chapters)
        assert.notNil(err)
    end),

    test("getChapterIndexByPage: 0 before the first chapter, else the containing one", function()
        local chapters = {
            { start_page = 3 }, { start_page = 10 }, { start_page = 20 },
        }
        assert.equal(0, Chapters.getChapterIndexByPage(chapters, 1))
        assert.equal(1, Chapters.getChapterIndexByPage(chapters, 9))
        assert.equal(2, Chapters.getChapterIndexByPage(chapters, 10))
        assert.equal(3, Chapters.getChapterIndexByPage(chapters, 99))
    end),

    test("countMissing: empty chapters count as done, a stale cache counts nothing", function()
        local chapters = { {}, {}, {} }
        local cache = { chapter_count = 3, chapters = {
            [1] = { summary = "s1" }, [2] = { empty = true },
        } }
        assert.equal(1, Chapters.countMissing(cache, chapters, 3))
        assert.equal(0, Chapters.countMissing(cache, chapters, 2))
        cache.chapter_count = 4
        assert.equal(3, Chapters.countMissing(cache, chapters, 3))
    end),

    test("buildSummariesBlock: only chapters up to the limit, skipping gaps", function()
        local cache = { chapters = {
            [1] = { title = "One", summary = "first" },
            [3] = { title = "Three", summary = "third" },
            [4] = { title = "Four", summary = "fourth" },
        } }
        local block = Chapters.buildSummariesBlock(cache, 3)
        assert.matches(block, "### 1%. One\n\nfirst")
        assert.matches(block, "### 3%. Three\n\nthird")
        assert.notMatches(block, "fourth")
        assert.equal("", Chapters.buildSummariesBlock(nil, 3))
    end),

    test("getChapterPrompts: built-ins sorted by order, mind map and quiz included", function()
        local list = Chapters.getChapterPrompts(nil)
        assert.isTrue(#list >= 5)
        for i = 2, #list do
            assert.isTrue((list[i - 1].order or 1000) <= (list[i].order or 1000))
        end
        local ids = {}
        for prompt_idx = 1, #list do ids[list[prompt_idx].id] = true end
        assert.isTrue(ids.quiz)
        assert.isTrue(ids.mind_map)
    end),

    test("getChapterPrompts: user entries hide, override and add", function()
        local list = Chapters.getChapterPrompts({
            quiz = { visible = false },
            critique = { text = "Review" },
            plot_holes = { text = "Plot Holes", order = 1, user_prompt = "Find plot holes in {scope}." },
            broken = { text = "No prompt" },
        })
        local by_id = {}
        for prompt_idx = 1, #list do by_id[list[prompt_idx].id] = list[prompt_idx] end
        assert.equal(nil, by_id.quiz)
        assert.equal(nil, by_id.broken)
        assert.equal("Review", by_id.critique.text)
        assert.notNil(by_id.critique.user_prompt)
        assert.equal("plot_holes", list[1].id)
        -- the built-in table itself stays untouched
        assert.equal(nil, require("core/prompts").chapter_prompts.quiz.visible)
    end),

    test("expandPrompt: underscore placeholders expand, unknown ones stay", function()
        local out = Chapters.expandPrompt("{scope} of {chapter_title} in {language}: {other}",
            { scope = "this chapter", chapter_title = "The Storm", language = "Dutch" })
        assert.equal("this chapter of The Storm in Dutch: {other}", out)
    end),

    test("getPrompts: configuration overrides beat the built-in prompt", function()
        local system, user = Chapters.getPrompts(fakeConfig({
            chapter_question_config = { user_prompt = "custom {user_input}" },
        }), "chapter_question_config", "chapter_question")
        assert.equal("custom {user_input}", user)
        assert.matches(system, "reading companion")
    end),

    test("buildRangeContext: everything fits as full text", function()
        local chapters = { { title = "A" }, { title = "B" } }
        local context, info = Chapters.buildRangeContext(chapters, nil, 1, 2, 1000,
            function(idx) return "text" .. idx end)
        assert.matches(context, "%[CHAPTER 1: A%]\ntext1")
        assert.matches(context, "%[CHAPTER 2: B%]\ntext2")
        assert.notMatches(context, "SUMMARIES")
        assert.equal(1, info.full_from)
        assert.equal(0, info.missing_summaries)
    end),

    test("buildRangeContext: older chapters fall back to summaries, lazily", function()
        local chapters = { { title = "A" }, { title = "B" }, { title = "C" }, { title = "D" } }
        local cache = { chapters = { [1] = { summary = "sum A" }, [3] = { empty = true } } }
        local asked = {}
        local context, info = Chapters.buildRangeContext(chapters, cache, 1, 4, 25, function(idx)
            table.insert(asked, idx)
            return string.rep(tostring(idx), 10)
        end)
        -- 4 (10 bytes) and 3 (10 bytes) fit, 2 does not: 1 is never extracted
        assert.equal(3, #asked)
        assert.equal(3, info.full_from)
        assert.matches(context, "### 1%. A\n\nsum A")
        assert.matches(context, "### 2%. B\n\n%(no summary available%)")
        assert.equal(1, info.missing_summaries)
        assert.matches(context, "%[CHAPTER 4: D%]")
        assert.notMatches(context, "%[CHAPTER 2")
    end),

    test("buildRangeContext: an oversized last chapter keeps its tail", function()
        local chapters = { { title = "A" } }
        local context, info = Chapters.buildRangeContext(chapters, nil, 1, 1, 5,
            function() return "0123456789" end)
        assert.matches(context, "%[%.%.%.%]\n56789")
        assert.equal(1, info.full_from)
    end),

    test("getSections: parts span their chapters", function()
        local ui = uiWithToc({
            { depth = 1, title = "Part One", xpointer = "p1", page = 1 },
            { depth = 2, title = "Ch 1", xpointer = "c1", page = 1 },
            { depth = 2, title = "Ch 2", xpointer = "c2", page = 10 },
            { depth = 1, title = "Part Two", xpointer = "p2", page = 19 },
            { depth = 2, title = "Ch 3", xpointer = "c3", page = 20 },
            { depth = 2, title = "Ch 4", xpointer = "c4", page = 30 },
            { depth = 2, title = "Ch 5", xpointer = "c5", page = 40 },
        })
        local chapters = Chapters.getChapters(ui)
        local sections = Chapters.getSections(ui, chapters)
        assert.equal(2, #sections)
        assert.equal("Part One", sections[1].title)
        assert.equal(1, sections[1].first)
        assert.equal(2, sections[1].last)
        assert.equal(3, sections[2].first)
        assert.equal(5, sections[2].last)
        -- a flat TOC has no sections
        assert.equal(0, #Chapters.getSections(uiWithToc({
            { depth = 1, title = "One", xpointer = "c1", page = 1 },
        }), { { title = "One", start_page = 1, depth = 1 } }))
    end),

    test("getAvailableChapterCount: the current chapter, or all once finished", function()
        local chapters = { { start_page = 1 }, { start_page = 10 }, { start_page = 20 } }
        local ui = { document = { getPageCount = function() return 30 end } }
        ui.getCurrentPage = function() return 12 end
        local n, finished = Chapters.getAvailableChapterCount(ui, chapters)
        assert.equal(2, n)
        assert.isFalse(finished)
        ui.getCurrentPage = function() return 30 end
        n, finished = Chapters.getAvailableChapterCount(ui, chapters)
        assert.equal(3, n)
        assert.isTrue(finished)
    end),
}

return helper.runTests("chapters", tests)
