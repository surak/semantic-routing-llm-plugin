--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--

-- Client for the System One API, used by the system_one balancer of
-- ai-proxy-multi. A System One model (e.g. TypeSafe Jev, Cloudflare Clef) is a
-- discriminative model: given a `state` and typed questions it returns one
-- probability distribution per question instead of generated text. The balancer
-- asks a single `choice` question whose options are the instance names, with
-- each instance's `description` as the option's criterion, and ranks the
-- instances by the returned probabilities.
--
-- Like the embedding client, the request goes through the shared ai-provider
-- layer, so endpoint parsing, auth and HTTP transport match the chat path, and
-- none of the client's headers are forwarded.
local core = require("apisix.core")
local ipairs = ipairs
local pairs = pairs
local type = type
local tostring = tostring
local require = require
local INF = math.huge

local _M = {}

-- Id of the single question sent to the System One model.
local QUESTION = "instance"
_M.QUESTION = QUESTION

local DEFAULT_INSTRUCTIONS = "Choose the option best suited to answer this "
    .. "request. Prefer the option whose criteria match the main task; options "
    .. "are not ordered by quality."


local function valid_probability(p)
    return type(p) == "number" and p == p and p ~= INF and p ~= -INF
           and p >= 0 and p <= 1
end


function _M.build_request(opts, state, instances)
    local criteria = {}
    for _, inst in ipairs(instances) do
        criteria[inst.name] = inst.description
    end
    return {
        model = opts.model,
        state = state,
        questions = {
            [QUESTION] = {
                type = "choice",
                instructions = opts.instructions or DEFAULT_INSTRUCTIONS,
                criteria = criteria,
            },
        },
    }
end


-- Turn the answer to our question into a ranking: an array of
-- { name = instance name, probability = number }, most probable first. Ties keep
-- the configured instance order. Options the model returns that are not
-- instances are ignored; instances it omits get probability 0.
--
-- The API returns the probability distribution itself; any derived `choice` or
-- `confidence` is computed from it, so the distribution is all we rely on. An
-- answer without one but with a `choice` ranks that choice first.
function _M.rank(answer, instances)
    if type(answer) ~= "table" then
        return nil, "no answer for question '" .. QUESTION .. "'"
    end

    local probs = answer.probabilities
    if probs ~= nil and type(probs) ~= "table" then
        return nil, "invalid probabilities"
    end

    local by_name = {}
    local have_any = false
    if probs then
        for name, p in pairs(probs) do
            if type(name) == "string" then
                if not valid_probability(p) then
                    return nil, "invalid probability for option '" .. name .. "'"
                end
                by_name[name] = p
            end
        end
    end
    for _, inst in ipairs(instances) do
        if by_name[inst.name] then
            have_any = true
        end
    end

    if not have_any then
        local choice = answer.choice
        if type(choice) ~= "string" then
            return nil, "answer has neither probabilities nor a choice"
        end
        local confidence = answer.confidence
        by_name[choice] = valid_probability(confidence) and confidence or 1
    end

    local ranking = {}
    for i, inst in ipairs(instances) do
        ranking[#ranking + 1] = {
            name = inst.name,
            probability = by_name[inst.name] or 0,
            order = i,
        }
    end
    core.table.sort(ranking, function(a, b)
        if a.probability ~= b.probability then
            return a.probability > b.probability
        end
        return a.order < b.order
    end)

    if ranking[1].probability == 0 then
        return nil, "the model chose none of the instances"
    end
    return ranking
end


-- Ask the System One model to rank `instances` for `state`.
-- Returns the ranking (see rank()) or nil + err.
function _M.fetch(opts, state, instances)
    -- The endpoint is the full URL of the System One API (it carries its own
    -- path), so the generic OpenAI-compatible provider is only used for its
    -- transport and auth handling.
    local ai_provider = require("apisix.plugins.ai-providers.openai-compatible")
    local extra_opts = {
        endpoint = opts.endpoint,
        auth = opts.auth,
    }
    local req_conf = {
        ssl_verify = opts.ssl_verify ~= false,
        timeout = opts.timeout or 3000,
        keepalive = true,
    }
    local status, raw_body, err = ai_provider:request(req_conf,
        _M.build_request(opts, state, instances), extra_opts)

    -- Never log or return the upstream body: it is third-party content that may
    -- echo the prompt back or forge log lines.
    if status ~= 200 then
        if err then
            return nil, "system one request failed: " .. err
        end
        return nil, "system one endpoint returned status " .. tostring(status)
    end

    local data, derr = core.json.decode(raw_body)
    if type(data) ~= "table" or type(data.answers) ~= "table" then
        return nil, "invalid system one response: " .. (derr or "unexpected shape")
    end
    return _M.rank(data.answers[QUESTION], instances)
end


return _M
