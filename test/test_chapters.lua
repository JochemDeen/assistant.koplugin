-- test_chapters.lua
-- Owns the data side of the chapter companion (feature/chapters):
--   * getChapters: TOC depth choice and the synthetic "(Beginning)" chapter
--   * getChapterIndexByPage / countMissing / buildSummariesBlock
--   * getChapterPrompts: built-in chapter prompts merged with user overrides
--   * expandPrompt: underscore placeholders, unknown ones left untouched
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
}

return helper.runTests("chapters", tests)
