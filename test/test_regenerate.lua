-- test_regenerate.lua
-- Owns feature/regenerate (the result viewer's Regenerate):
--   * the last answer is replaced, re-asked with the question's prompt title
--     and web-search choice, and the start/end scroll hint is right
--   * a failed request puts the previous answer back
--   * nothing to regenerate leaves the history untouched
-- The online guard is replaced for the duration of each test.
local helper = require("test.helper")
local assert = helper.assert
local ASUtils = require("utils/base")
local NetUtils = require("utils/net")
local Regenerate = require("feature/regenerate")

local function test(name, fn)
    return { name = name, fn = fn }
end

local function withOnline(fn)
    local saved = NetUtils.runWhenOnlineFast
    NetUtils.runWhenOnlineFast = function(cb) cb() end
    local ok, err = pcall(fn)
    NetUtils.runWhenOnlineFast = saved
    if not ok then error(err, 0) end
end

local function fakeAssistant(result)
    local a = { queries = {}, errors = {} }
    a.config = { getActiveProviderId = function() return "p" end }
    a.querier = {
        load_model = function() return true end,
        query = function(self, history, title, opts)
            table.insert(a.queries, { size = #history, title = title, opts = opts })
            if result == "fail" then return nil, "boom" end
            return "NEW"
        end,
        showError = function(self, err) table.insert(a.errors, err) end,
    }
    return a
end

local tests = {
    test("replaces the first answer, keeping prompt title and web-search choice", function()
        withOnline(function()
            local question = { role = "user", content = "question" }
            ASUtils.set_attr(question, "use_websearch", true)
            ASUtils.set_attr(question, "prompt_title", "Explain")
            local history = { { role = "system", content = "s" }, question, { role = "assistant", content = "OLD" } }
            local assistant = fakeAssistant()
            local to_end
            Regenerate.run(assistant, history, "Viewer", function(e) to_end = e end)
            assert.equal(3, #history)
            assert.equal("NEW", history[3].content)
            assert.equal(2, assistant.queries[1].size)
            assert.equal("Explain", assistant.queries[1].title)
            assert.equal(true, assistant.queries[1].opts.use_websearch)
            assert.isFalse(to_end)
        end)
    end),

    test("a follow-up answer is regenerated in place and shown at the end", function()
        withOnline(function()
            local history = { { role = "system", content = "s" },
                { role = "user", content = "q1" }, { role = "assistant", content = "A1" },
                { role = "user", content = "q2" }, { role = "assistant", content = "A2" } }
            local assistant = fakeAssistant()
            local to_end
            Regenerate.run(assistant, history, "Viewer", function(e) to_end = e end)
            assert.equal("A1", history[3].content)
            assert.equal("NEW", history[5].content)
            assert.equal("Viewer", assistant.queries[1].title)
            assert.isTrue(to_end)
        end)
    end),

    test("a failed request restores the previous answer", function()
        withOnline(function()
            local history = { { role = "system", content = "s" },
                { role = "user", content = "q" }, { role = "assistant", content = "OLD" } }
            local assistant = fakeAssistant("fail")
            Regenerate.run(assistant, history, "Viewer", function() error("must not finish") end)
            assert.equal(3, #history)
            assert.equal("OLD", history[3].content)
            assert.equal("boom", assistant.errors[1])
        end)
    end),

    test("nothing to regenerate: no query, history untouched", function()
        withOnline(function()
            local history = { { role = "system", content = "s" }, { role = "user", content = "q" } }
            local assistant = fakeAssistant()
            Regenerate.run(assistant, history, "Viewer", function() error("must not finish") end)
            assert.equal(2, #history)
            assert.equal(0, #assistant.queries)
        end)
    end),
}

return helper.runTests("regenerate", tests)
