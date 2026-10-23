--- Rough AI usage counters (characters sent/received, per model) kept in the
--- plugin settings. Character counts are exact; token and cost figures are
--- estimates derived at display time (1 token ~ 4 characters).
local koutil = require("util")

local M = {}

M.CHARS_PER_TOKEN = 4

local KEYS = { "usage_input_chars", "usage_output_chars", "usage_requests", "usage_by_model" }

--- Add one completed request to the counters.
--- @param settings table LuaSettings
--- @param model string|nil model id the request was sent to
--- @param message_history table[] messages sent (string contents are counted)
--- @param response string answer text
function M.record(settings, model, message_history, response)
    local input_chars = 0
    for msg_idx = 1, #message_history do
        local content = message_history[msg_idx].content
        if type(content) == "string" then
            input_chars = input_chars + #content
        end
    end
    local output_chars = type(response) == "string" and #response or 0

    settings:saveSetting("usage_input_chars", (settings:readSetting("usage_input_chars") or 0) + input_chars)
    settings:saveSetting("usage_output_chars", (settings:readSetting("usage_output_chars") or 0) + output_chars)
    settings:saveSetting("usage_requests", (settings:readSetting("usage_requests") or 0) + 1)

    if not model or model == "" then model = "unknown" end
    local by_model = settings:readSetting("usage_by_model") or {}
    local m = by_model[model] or { input_chars = 0, output_chars = 0, requests = 0 }
    m.input_chars = (m.input_chars or 0) + input_chars
    m.output_chars = (m.output_chars or 0) + output_chars
    m.requests = (m.requests or 0) + 1
    by_model[model] = m
    settings:saveSetting("usage_by_model", by_model)
end

function M.reset(settings)
    for key_idx = 1, #KEYS do
        settings:delSetting(KEYS[key_idx])
    end
end

local function toTokens(chars)
    return math.floor((chars or 0) / M.CHARS_PER_TOKEN)
end

--- Per-model price entry, else the general fallback price, else nil.
local function pricesFor(prices, model)
    if type(prices) ~= "table" then return nil end
    local model_prices = koutil.tableGetValue(prices, "models", model)
    if type(model_prices) == "table" and (model_prices.input or model_prices.output) then
        return model_prices
    end
    if prices.input or prices.output then
        return prices
    end
    return nil
end

--- Summarize the counters with estimated tokens and costs.
--- @param settings table LuaSettings
--- @param prices table|nil features.usage_prices: { input, output, currency, models = { [id] = { input, output } } }, per 1M tokens
--- @return table { requests, input_chars, output_chars, input_tokens, output_tokens,
---   models = { { model, requests, input_tokens, output_tokens, cost|nil } }, total_cost|nil, unpriced, currency }
function M.summarize(settings, prices)
    local input_chars = settings:readSetting("usage_input_chars") or 0
    local output_chars = settings:readSetting("usage_output_chars") or 0
    local summary = {
        requests = settings:readSetting("usage_requests") or 0,
        input_chars = input_chars,
        output_chars = output_chars,
        input_tokens = toTokens(input_chars),
        output_tokens = toTokens(output_chars),
        models = {},
        unpriced = false,
        currency = (type(prices) == "table" and prices.currency) or "USD",
    }

    local by_model = settings:readSetting("usage_by_model") or {}
    local names = {}
    for model in pairs(by_model) do table.insert(names, model) end
    table.sort(names)

    local total_cost = 0
    for name_idx = 1, #names do
        local model = names[name_idx]
        local m = by_model[model]
        local entry = {
            model = model,
            requests = m.requests or 0,
            input_tokens = toTokens(m.input_chars),
            output_tokens = toTokens(m.output_chars),
        }
        local p = pricesFor(prices, model)
        if p then
            entry.cost = entry.input_tokens / 1000000 * (p.input or 0)
                + entry.output_tokens / 1000000 * (p.output or 0)
            total_cost = total_cost + entry.cost
        else
            summary.unpriced = true
        end
        table.insert(summary.models, entry)
    end
    if type(prices) == "table" then
        summary.total_cost = total_cost
    end
    return summary
end

return M
