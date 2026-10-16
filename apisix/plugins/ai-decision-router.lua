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

--- ai-decision-router: route each LLM request to the best-suited model, as
-- chosen by a typed decision model (Clef-compatible /v1/systemone API).
--
-- Runs in the access phase at priority 1039, right after ai-proxy-multi (1041)
-- and ai-proxy (1040) have parsed the request:
--
--   1. extract the prompt text through ai-protocols (any supported protocol)
--   2. ask the decision model one "choice" question whose options are the
--      configured candidates and their routing descriptions
--   3. take the winner, or the fallback on error / low confidence, and
--        * rewrite the body's "model" field to the candidate's model, and
--        * if ai-proxy-multi is on the route, switch its picked instance to
--          the candidate's instance
--   4. expose the decision via ctx vars and optional response headers
--
-- Routing is advisory: a failing decision model never fails the request, it
-- degrades to the fallback candidate.
local core         = require("apisix.core")
local http         = require("resty.http")
local ai_protocols = require("apisix.plugins.ai-protocols")
local binding      = require("apisix.plugins.ai-protocols.binding")
local ngx          = ngx
local ipairs       = ipairs
local pairs        = pairs
local type         = type
local tostring     = tostring
local tonumber     = tonumber
local concat       = table.concat
local sub          = string.sub

local plugin_name = "ai-decision-router"

local DEFAULT_INSTRUCTIONS = "Choose the model best suited to answer this request, "
    .. "using the routing roles below. Prefer the specialist matching the main "
    .. "deliverable; use a generalist only when no specialist fits. Routine tasks "
    .. "do not need the largest model. Option names and order are not quality rankings."

-- id of the single question sent to the decision model
local QUESTION = "route"


local schema = {
    type = "object",
    properties = {
        decision = {
            type = "object",
            description = "The decision model that picks a candidate.",
            properties = {
                endpoint = {
                    type = "string",
                    pattern = [[^https?://]],
                    description = "URL of the Clef-compatible decision API, "
                                  .. "e.g. https://host/v1/systemone.",
                },
                model = {
                    type = "string",
                    minLength = 1,
                    description = "Name of the decision model.",
                },
                auth = {
                    type = "object",
                    description = "Credentials sent to the decision model.",
                    properties = {
                        header = {
                            type = "object",
                            additionalProperties = { type = "string" },
                            description = "Request headers, e.g. Authorization.",
                        },
                    },
                },
                instructions = {
                    type = "string",
                    minLength = 1,
                    description = "Instructions of the routing question. "
                                  .. "Defaults to a generic routing instruction.",
                },
                timeout = {
                    type = "integer",
                    minimum = 1,
                    default = 5000,
                    description = "Decision request timeout in milliseconds.",
                },
                ssl_verify = {
                    type = "boolean",
                    default = true,
                    description = "Verify the TLS certificate of the decision endpoint.",
                },
            },
            required = { "endpoint", "model" },
        },
        candidates = {
            type = "array",
            minItems = 2,
            maxItems = 64,
            description = "Models to choose between.",
            items = {
                type = "object",
                properties = {
                    name = {
                        type = "string",
                        pattern = [[^[A-Za-z0-9_.:-]+$]],
                        description = "Option id given to the decision model. Unique.",
                    },
                    description = {
                        type = "string",
                        minLength = 1,
                        description = "Routing role: which requests this model should get.",
                    },
                    model = {
                        type = "string",
                        minLength = 1,
                        description = "Value written into the request body's model. "
                                      .. "Defaults to name.",
                    },
                    instance = {
                        type = "string",
                        minLength = 1,
                        description = "ai-proxy-multi instance to use. Defaults to name.",
                    },
                },
                required = { "name", "description" },
            },
        },
        fallback = {
            type = "string",
            description = "Candidate used when no usable decision is available. "
                          .. "Defaults to the first candidate.",
        },
        min_confidence = {
            type = "number",
            minimum = 0,
            maximum = 1,
            default = 0,
            description = "Decisions below this confidence use the fallback.",
        },
        context = {
            type = "string",
            enum = { "last_user", "conversation" },
            default = "last_user",
            description = "Text given to the decision model: the last user message, "
                          .. "or the whole conversation.",
        },
        max_chars = {
            type = "integer",
            minimum = 1,
            default = 8000,
            description = "Keep only the last max_chars characters of that text.",
        },
        trigger_models = {
            type = "array",
            items = { type = "string" },
            description = "Route only requests whose model is in this list or missing. "
                          .. "Unset or empty: route every request.",
        },
        rewrite_model = {
            type = "boolean",
            default = true,
            description = "Rewrite the model field of the request body.",
        },
        response_headers = {
            type = "boolean",
            default = true,
            description = "Add X-AI-Routed-Model, X-AI-Routing-Confidence and "
                          .. "X-AI-Routing-Fallback to the response.",
        },
        fail_mode = binding.schema_property("skip"),
    },
    required = { "decision", "candidates" },
    encrypt_fields = { "decision.auth.header" },
}


local _M = {
    version = 0.1,
    priority = 1039,
    name = plugin_name,
    schema = schema,
}


local function find_candidate(conf, name)
    if not name then
        return nil
    end
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


-- ai-protocols returns content as a string, or unflattened content parts for
-- some multimodal messages; keep only the text.
local function content_text(content)
    if type(content) == "string" then
        return content
    end
    if type(content) ~= "table" then
        return nil
    end
    local parts = {}
    for _, p in ipairs(content) do
        if type(p) == "table" and type(p.text) == "string" then
            parts[#parts + 1] = p.text
        end
    end
    return concat(parts, " ")
end


local function build_state(conf, body, ctx)
    local messages = ai_protocols.get_messages(body, ctx)
    local state
    if conf.context == "conversation" then
        local lines = {}
        for _, m in ipairs(messages) do
            local text = content_text(m.content)
            if text and text ~= "" then
                lines[#lines + 1] = (m.role or "user") .. ": " .. text
            end
        end
        state = concat(lines, "\n\n")
    else
        for i = #messages, 1, -1 do
            if messages[i].role == "user" then
                state = content_text(messages[i].content)
                if state and state ~= "" then
                    break
                end
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


-- Ask the decision model. Returns the chosen name and its confidence, or nil
-- and an error string.
local function decide(conf, state)
    local d = conf.decision
    local criteria = {}
    for _, c in ipairs(conf.candidates) do
        criteria[c.name] = c.description
    end

    local headers = {
        ["Content-Type"] = "application/json",
        ["Accept"] = "application/json",
    }
    if d.auth and d.auth.header then
        for k, v in pairs(d.auth.header) do
            headers[k] = v
        end
    end

    local body, err = core.json.encode({
        model = d.model,
        state = state,
        questions = {
            [QUESTION] = {
                type = "choice",
                instructions = d.instructions or DEFAULT_INSTRUCTIONS,
                criteria = criteria,
            },
        },
    })
    if not body then
        return nil, "failed to encode request: " .. err
    end

    local httpc = http.new()
    httpc:set_timeout(d.timeout)
    local res, req_err = httpc:request_uri(d.endpoint, {
        method = "POST",
        body = body,
        headers = headers,
        ssl_verify = d.ssl_verify,
    })
    if not res then
        return nil, "request failed: " .. tostring(req_err)
    end
    if res.status ~= 200 then
        return nil, "status " .. res.status .. ": " .. sub(res.body or "", 1, 256)
    end

    local resp, decode_err = core.json.decode(res.body)
    if type(resp) ~= "table" then
        return nil, "invalid JSON: " .. tostring(decode_err)
    end
    local answer = type(resp.answers) == "table" and resp.answers[QUESTION]
    if type(answer) ~= "table" or type(answer.choice) ~= "string" then
        return nil, "no answer for question '" .. QUESTION .. "'"
    end

    local confidence = tonumber(answer.confidence)
    if not confidence and type(answer.probabilities) == "table" then
        confidence = tonumber(answer.probabilities[answer.choice])
    end
    return answer.choice, confidence
end


-- The ai-proxy-multi conf active on this request, if any. ctx.plugins is a
-- flat list: plugin, conf, plugin, conf, ...
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
        -- ai-proxy(-multi) read the cached body table; keep the raw body in
        -- sync for plain upstreams
        local raw, err = core.json.encode(body)
        if not raw then
            core.log.error("failed to encode request body: ", err)
        else
            ngx.req.set_body_data(raw)
        end
    end

    local multi = ai_proxy_multi_conf(ctx)
    if not multi or not multi.instances then
        return
    end
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


local function triggered(conf, body)
    if not conf.trigger_models or #conf.trigger_models == 0 or body.model == nil then
        return true
    end
    for _, m in ipairs(conf.trigger_models) do
        if body.model == m then
            return true
        end
    end
    return false
end


function _M.access(conf, ctx)
    local ct = core.request.header(ctx, "Content-Type") or "application/json"
    if not core.string.has_prefix(ct, "application/json") then
        local handled, code, msg = binding.on_unsupported(conf.fail_mode, plugin_name,
                ctx, "unsupported content-type: " .. ct, 400, "unsupported content-type")
        if handled then
            return code, { message = msg }
        end
        return
    end

    local body, err = core.request.get_json_request_body_table()
    if type(body) ~= "table" then
        local reason = type(err) == "table" and err.message or err
        local handled, code, msg = binding.on_unsupported(conf.fail_mode, plugin_name,
                ctx, reason, 400, "invalid request body")
        if handled then
            return code, { message = msg }
        end
        return
    end

    if not triggered(conf, body) then
        return
    end

    local fallback = find_candidate(conf, conf.fallback) or conf.candidates[1]
    local state = build_state(conf, body, ctx)
    local cand, confidence, reason

    if not state then
        reason = "no prompt text"
    else
        local choice, conf_or_err = decide(conf, state)
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
    core.log.info(plugin_name, ": routed to ", cand.name, " (confidence ",
                  tostring(confidence), ", ", reason or "decided", ")")

    apply(conf, ctx, body, cand)
end


function _M.header_filter(conf, ctx)
    local r = ctx.ai_decision_router
    if not conf.response_headers or not r then
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
