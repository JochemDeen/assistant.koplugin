-- test_usage.lua
-- Owns the usage estimate (core/usage) and the side features that feed it:
--   * record/summarize: per-model counters, token estimate, per-model and
--     fallback prices, unpriced models
--   * page_terms.parseTermList: the term list parser behind People & Terms
--   * gemini: top-level thinking_level maps into thinkingConfig
local helper = require("test.helper")
local assert = helper.assert
local Usage = require("core/usage")

local function test(name, fn)
    return { name = name, fn = fn }
end

local function fakeSettings()
    local data = {}
    return {
        readSetting = function(self, key, default)
            if data[key] == nil then return default end
            return data[key]
        end,
        saveSetting = function(self, key, value) data[key] = value end,
        delSetting = function(self, key) data[key] = nil end,
    }
end

local tests = {
    test("record: counts string contents per model", function()
        local settings = fakeSettings()
        Usage.record(settings, "model-a", {
            { role = "system", content = string.rep("s", 40) },
            { role = "user", content = string.rep("u", 360) },
            { role = "user", parts = {} }, -- tool payload without string content
        }, string.rep("a", 80))
        Usage.record(settings, "model-b", { { role = "user", content = "1234" } }, "abcd")
        local summary = Usage.summarize(settings, nil)
        assert.equal(2, summary.requests)
        assert.equal(404, summary.input_chars)
        assert.equal(101, summary.input_tokens)
        assert.equal(2, #summary.models)
        assert.equal("model-a", summary.models[1].model)
        assert.equal(100, summary.models[1].input_tokens)
        assert.equal(20, summary.models[1].output_tokens)
        assert.equal(nil, summary.total_cost)
    end),

    test("summarize: per-model price beats the fallback; unpriced models are flagged", function()
        local settings = fakeSettings()
        Usage.record(settings, "priced", { { content = string.rep("x", 4000000) } }, string.rep("y", 4000000))
        Usage.record(settings, "fallback", { { content = string.rep("x", 4000000) } }, "")
        local summary = Usage.summarize(settings, {
            input = 1, output = 0, currency = "EUR",
            models = { priced = { input = 2, output = 10 } },
        })
        assert.equal("EUR", summary.currency)
        assert.equal(12, summary.models[2].cost) -- "priced" sorts after "fallback"
        assert.equal(1, summary.models[1].cost)
        assert.equal(13, summary.total_cost)
        assert.isFalse(summary.unpriced)

        local only_models = Usage.summarize(settings, { models = { priced = { input = 2, output = 10 } } })
        assert.isTrue(only_models.unpriced)
        assert.equal(12, only_models.total_cost)
    end),

    test("reset: clears every counter", function()
        local settings = fakeSettings()
        Usage.record(settings, "m", { { content = "abcd" } }, "abcd")
        Usage.reset(settings)
        local summary = Usage.summarize(settings, nil)
        assert.equal(0, summary.requests)
        assert.equal(0, #summary.models)
    end),

    test("parseTermList: strips numbering, bullets and emphasis; dedupes; drops junk", function()
        local PageTerms = require("feature/page_terms")
        local terms = PageTerms.parseTermList(table.concat({
            "1. **Frodo**",
            "- Mordor",
            "• frodo",
            "Here are the terms:",
            "\"The Shire\"",
            "",
        }, "\n"))
        assert.equal(3, #terms)
        assert.equal("Frodo", terms[1])
        assert.equal("Mordor", terms[2])
        assert.equal("The Shire", terms[3])
        assert.equal(2, #PageTerms.parseTermList("a\nb\nc", 2))
    end),

    test("gemini: top-level thinking_level maps into thinkingConfig", function()
        local GeminiHandler = require("api_handlers.gemini")
        local handler = GeminiHandler:new{
            model = "test-model", api_key = "sk-test",
            base_url = "https://generativelanguage.googleapis.com/v1beta/models",
            additional_parameters = { thinking_level = "low", maxOutputTokens = 512 },
        }
        local body = handler:buildRequestBody({ { role = "user", content = "hi" } })
        assert.equal("low", body.generationConfig.thinkingConfig.thinkingLevel)
        assert.equal(512, body.generationConfig.maxOutputTokens)
    end),
}

return helper.runTests("usage", tests)
