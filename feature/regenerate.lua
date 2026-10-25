--- Regenerate: re-ask the last question of a conversation with the provider/
--- model active now and replace its answer. On failure the previous answer is
--- put back, so the conversation is never left without one.
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Trapper = require("ui/trapper")
local _ = require("core/gettext")
local Conversation = require("core/conversation")
local ASUtils = require("utils/base")
local NetUtils = require("utils/net")

local M = {}

--- @param assistant table plugin object (querier, config)
--- @param message_history table[] the conversation, changed in place
--- @param title string|nil request title when the question carries no prompt_title
--- @param on_done function(to_end: boolean) called after the new answer is appended;
---   to_end is true when earlier answers sit above it
function M.run(assistant, message_history, title, on_done)
    local removed = message_history and Conversation.take_last_answer(message_history)
    if not removed then
        UIManager:show(InfoMessage:new{ text = _("There is no answer to regenerate."), timeout = 3 })
        return
    end
    local question = message_history[#message_history]
    local suggestions
    for i = #removed, 1, -1 do
        if removed[i].role == "assistant" then
            suggestions = ASUtils.get_attr(removed[i], "show_suggestions")
            break
        end
    end
    local has_earlier_answer = false
    for i = 1, #message_history - 1 do
        local msg = message_history[i]
        if msg.role == "assistant" and type(msg.content) == "string" then
            has_earlier_answer = true
            break
        end
    end

    NetUtils.runWhenOnlineFast(function()
        Trapper:wrap(function()
            local querier = assistant.querier
            local provider = assistant.config:getActiveProviderId()
            local ok, err = false, _("No active provider configured. Please add one in Settings.")
            if provider then
                ok, err = querier:load_model(provider)
            end
            if ok then
                local answer
                answer, err = querier:query(message_history, ASUtils.get_attr(question, "prompt_title") or title, {
                    use_websearch = ASUtils.get_attr(question, "use_websearch"),
                })
                if not err then
                    Conversation.append_answer(message_history, answer, suggestions)
                    on_done(has_earlier_answer)
                    return
                end
            end
            Conversation.restore_answer(message_history, removed)
            querier:showError(err, message_history)
        end)
    end)
end

return M
