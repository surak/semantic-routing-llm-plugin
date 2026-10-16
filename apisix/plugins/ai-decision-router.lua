--
-- Copyright 2026 Alexandre Strube
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
-- ai-decision-router: route each LLM request to the best-suited model,
-- as chosen by a typed decision model (Clef-compatible /v1/systemone API).
--
-- Flow (access phase, priority 1039 -- right after ai-proxy-multi (1041)
-- and ai-proxy (1040) have parsed the request):
--
--   1. read the client's JSON body (OpenAI chat, Responses or Anthropic shape)
--   2. extract the prompt text (last user message or whole conversation)
--   3. ask the decision model one "choice" question whose options are the
--      configured candidates and their routing descriptions
--   4. take the winner (or the fallback on error / low confidence) and
--        * rewrite the body's "model" field to the candidate's model, and
--        * if ai-proxy-multi is on the route, switch its picked instance to
--          the candidate's instance
--   5. expose the decision via ctx vars and optional response headers
--
-- The plugin never fails a request because the decision model is down: any
-- error degrades to the fallback candidate.
--
local core     = require("apisix.core")
local http     = require("resty.http")
local ngx      = ngx
local ipairs   = ipairs
local pairs    = pairs
local type     = type
local tostring = tostring
local tonumber = tonumber
local concat   = table.concat
local sub      = string.sub

local plugin_name = "ai-decision-router"

local DEFAULT_INSTRUCTIONS =
    "Choose the model best suited to answer this request, using the routing " ..
    "roles below. Prefer the specialist matching the main deliverable; use a " ..
    "generalist only when no specialist fits. Routine tasks do not need the " ..
    "largest model. Option names and order are not quality rankings."

local schema = {
    type = "object",
    properties = {
        decision = {
            type = "object",
            properties = {
                endpoint = {
                    type = "string",
                    default = "https://api.blablador.fz-juelich.de/v1/systemone",
                },
                model = { type = "string", default = "alias-clef" },
                auth = {
                    type = "object",
                    properties = {
                        header = {
                            type = "object",
                            additionalProperties = { type = "string" },
                        },
                    },
                },
                instructions = { type = "string", minLength = 1 },
                timeout = { type = "integer", minimum = 1, default = 5000 },
                ssl_verify = { type = "boolean", default = true },
            },
            default = {},
        },
        candidates = {
            type = "array",
            minItems = 2,
            maxItems = 64,
            items = {
                type = "object",
                properties = {
                    -- option id shown to the decision model; letters, digits, _ - .
                    name = { type = "string", pattern = "^[A-Za-z0-9_.:-]+$" },
                    -- routing role: what this model is good for
                    description = { type = "string", minLength = 1 },
                    -- value written into the request body's "model" (default: name)
                    model = { type = "string" },
                    -- ai-proxy-multi instance to use (default: name)
                    instance = { type = "string" },
                },
                required = { "name", "description" },
            },
        },
        fallback = { type = "string" },
        min_confidence = { type = "number", minimum = 0, maximum = 1, default = 0 },
        context = {
            type = "string",
            enum = { "last_user", "conversation" },
            default = "last_user",
        },
        max_chars = { type = "integer", minimum = 1, default = 8000 },
        -- route only when the client asked for one of these models
        -- (or sent no model). Empty / unset: always route.
        trigger_models = { type = "array", items = { type = "string" } },
        rewrite_model = { type = "boolean", default = true },
        response_headers = { type = "boolean", default = true },
    },
    required = { "candidates" },
    encrypt_fields = { "decision.auth.header" },
}


local _M = {
    version = 0.1,
    priority = 1039,
    name = plugin_name,
    schema = schema,
}


local function find_candidate(conf, name)
    for _, c in ipairs(conf.candidates) do
        if c.name == name then
            return c
        end
    end
end


function _M.check_schema(conf)
    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return false, err
    end
    local seen = {}
    for _, c in ipairs(conf.candidates) do
        if seen[c.name] then
            return false, "duplicate candidate name: " .. c.name
        end
        seen[c.name] = true
    end
    if conf.fallback and not seen[conf.fallback] then
        return false, "fallback names unknown candidate: " .. conf.fallback
    end
    return true
end


-- Text of one message's content: a plain string, or the text parts of a
-- content-block array (OpenAI multimodal / Anthropic / Responses).
local function content_text(content)
    if type(content) == "string" then
        return content
    end
    if type(content) ~= "table" then
        return nil
    end
    local parts = {}
    for _, p in ipairs(content) do
        if type(p) == "string" then
            parts[#parts + 1] = p
        elseif type(p) == "table" and type(p.text) == "string" then
            parts[#parts + 1] = p.text
        end
    end
    if #parts == 0 then
        return nil
    end
    return concat(parts, " ")
end


-- Normalize the request into a list of {role, text}.
local function get_messages(body)
    local out = {}
    local list = body.messages
    if list == nil then
        -- OpenAI Responses API: input is a string or a list of items
        if type(body.input) == "string" then
            return { { role = "user", text = body.input } }
        end
        list = body.input
    end
    if type(list) ~= "table" then
        return out
    end
    if type(body.system) == "string" then  -- Anthropic top-level system prompt
        out[#out + 1] = { role = "system", text = body.system }
    end
    for _, m in ipairs(list) do
        if type(m) == "table" then
            local text = content_text(m.content)
            if text and text ~= "" then
                out[#out + 1] = { role = m.role or "user", text = text }
            end
        end
    end
    return out
end


local function build_state(conf, body)
    local msgs = get_messages(body)
    local state
    if conf.context == "conversation" then
        local lines = {}
        for _, m in ipairs(msgs) do
            lines[#lines + 1] = m.role .. ": " .. m.text
        end
        state = concat(lines, "\n\n")
    else
        for i = #msgs, 1, -1 do
            if msgs[i].role == "user" then
                state = msgs[i].text
                break
            end
        end
    end
    if not state or state == "" then
        return nil
    end
    if #state > conf.max_chars then
        -- keep the tail: the most recent text matters most for routing
        state = sub(state, -conf.max_chars)
    end
    return state
end


-- Ask the decision model. Returns winner name, confidence, probabilities.
local function decide(conf, state)
    local d = conf.decision
    local criteria = {}
    for _, c in ipairs(conf.candidates) do
        criteria[c.name] = c.description
    end
    local payload = {
        model = d.model,
        state = state,
        questions = {
            route = {
                type = "choice",
                instructions = d.instructions or DEFAULT_INSTRUCTIONS,
                criteria = criteria,
            },
        },
    }

    local headers = {
        ["Content-Type"] = "application/json",
        ["Accept"] = "application/json",
    }
    if d.auth and d.auth.header then
        for k, v in pairs(d.auth.header) do
            headers[k] = v
        end
    end

    local httpc = http.new()
    httpc:set_timeout(d.timeout)
    local res, err = httpc:request_uri(d.endpoint, {
        method = "POST",
        body = core.json.encode(payload),
        headers = headers,
        ssl_verify = d.ssl_verify,
    })
    if not res then
        return nil, "request failed: " .. tostring(err)
    end
    if res.status ~= 200 then
        return nil, "status " .. res.status .. ": " .. sub(res.body or "", 1, 256)
    end
    local resp, derr = core.json.decode(res.body)
    if type(resp) ~= "table" then
        return nil, "invalid JSON: " .. tostring(derr)
    end
    local answer = resp.answers and resp.answers.route
    if type(answer) ~= "table" or type(answer.choice) ~= "string" then
        return nil, "no answer for question 'route'"
    end
    local confidence = tonumber(answer.confidence)
    if not confidence and type(answer.probabilities) == "table" then
        confidence = tonumber(answer.probabilities[answer.choice])
    end
    return answer.choice, confidence, answer.probabilities
end


-- The ai-proxy-multi conf active on this request, if any.
local function ai_proxy_multi_conf(ctx)
    local plugins = ctx.plugins
    if not plugins then
        return nil
    end
    for i = 1, #plugins, 2 do
        if plugins[i].name == "ai-proxy-multi" then
            return plugins[i + 1]
        end
    end
end


local function apply(conf, ctx, body, cand)
    if conf.rewrite_model then
        local model = cand.model or cand.name
        body.model = model
        ctx.var.request_llm_model = model
        -- keep the raw body in sync for non-AI upstreams
        ngx.req.set_body_data(core.json.encode(body))
    end

    local multi = ai_proxy_multi_conf(ctx)
    if multi and multi.instances then
        local want = cand.instance or cand.name
        for _, ins in ipairs(multi.instances) do
            if ins.name == want then
                ctx.picked_ai_instance_name = ins.name
                ctx.picked_ai_instance = ins
                ctx.balancer_ip = ins.name
                return
            end
        end
        core.log.warn(plugin_name, ": ai-proxy-multi has no instance '", want,
                      "', keeping ", ctx.picked_ai_instance_name)
    end
end


function _M.access(conf, ctx)
    local body = core.request.get_json_request_body_table()
    if type(body) ~= "table" then
        return  -- not JSON: nothing to route; downstream plugins report errors
    end

    if conf.trigger_models and #conf.trigger_models > 0 and body.model ~= nil then
        local hit = false
        for _, m in ipairs(conf.trigger_models) do
            if body.model == m then
                hit = true
                break
            end
        end
        if not hit then
            ctx.ai_decision_router = { skipped = "client chose model" }
            return
        end
    end

    local fallback = find_candidate(conf, conf.fallback) or conf.candidates[1]
    local state = build_state(conf, body)
    local cand, confidence, reason

    if not state then
        reason = "no prompt text"
    else
        local start = ngx.now()
        local choice, conf_or_err = decide(conf, state)
        ctx.ai_decision_router_latency = (ngx.now() - start) * 1000
        if not choice then
            reason = "decision error: " .. conf_or_err
            core.log.warn(plugin_name, ": ", reason, ", using fallback ", fallback.name)
        else
            confidence = conf_or_err
            cand = find_candidate(conf, choice)
            if not cand then
                reason = "unknown choice " .. choice
            elseif confidence and confidence < conf.min_confidence then
                reason = "low confidence " .. confidence
                cand = nil
            end
        end
    end

    cand = cand or fallback
    ctx.ai_decision_router = {
        choice = cand.name,
        confidence = confidence,
        fallback_reason = reason,
    }
    ctx.var.ai_routed_model = cand.model or cand.name
    core.log.info(plugin_name, ": routed to ", cand.name,
                  " (confidence ", tostring(confidence), ", ", reason or "decided", ")")

    apply(conf, ctx, body, cand)
end


function _M.header_filter(conf, ctx)
    local r = ctx.ai_decision_router
    if not conf.response_headers or not r or not r.choice then
        return
    end
    core.response.set_header("X-AI-Routed-Model", ctx.var.ai_routed_model)
    if r.confidence then
        core.response.set_header("X-AI-Routing-Confidence", tostring(r.confidence))
    end
    if r.fallback_reason then
        core.response.set_header("X-AI-Routing-Fallback", r.fallback_reason)
    end
end


return _M
