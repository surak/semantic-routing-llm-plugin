#
# Copyright 2026 Alexandre Strube
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
use t::APISIX 'no_plan';

log_level("info");
repeat_each(1);
no_long_string();
no_root_location();
no_shuffle();


add_block_preprocessor(sub {
    my ($block) = @_;

    if (!defined $block->request) {
        $block->set_value("request", "GET /t");
    }

    # 6724: mock decision model (/v1/systemone). The answer depends on the
    # prompt ("state") it receives:
    #   "decision-error"   -> HTTP 500
    #   "decision-timeout" -> sleeps past the plugin timeout
    #   "unsure"           -> picks "math" with confidence 0.2
    #   "unknown-choice"   -> picks a candidate that does not exist
    #   "python" / "bug"   -> "code" (0.9);  "prove" -> "math" (0.85)
    #   otherwise          -> "general" (0.7)
    # 6725: mock LLM, echoes the model and path it was called with.
    my $http_config = $block->http_config // <<_EOC_;
        server {
            listen 6724;
            default_type 'application/json';

            location /v1/systemone {
                content_by_lua_block {
                    local core = require("apisix.core")
                    ngx.req.read_body()
                    local raw = ngx.req.get_body_data() or "{}"
                    core.log.warn("decision mock: auth=", ngx.var.http_authorization,
                                  " body=", raw)
                    local req = core.json.decode(raw)
                    local state = req.state or ""
                    if core.string.find(state, "decision-error") then
                        ngx.status = 500
                        ngx.say([[{"error":"boom"}]])
                        return
                    end
                    if core.string.find(state, "decision-timeout") then
                        ngx.sleep(0.5)
                    end
                    local choice, confidence = "general", 0.7
                    if core.string.find(state, "unsure") then
                        choice, confidence = "math", 0.2
                    elseif core.string.find(state, "unknown-choice") then
                        choice, confidence = "nope", 0.99
                    elseif core.string.find(state, "python")
                           or core.string.find(state, "bug") then
                        choice, confidence = "code", 0.9
                    elseif core.string.find(state, "prove") then
                        choice, confidence = "math", 0.85
                    end
                    ngx.say(core.json.encode({
                        model = req.model,
                        answers = { route = { choice = choice, confidence = confidence } },
                    }))
                }
            }
        }

        server {
            listen 6725;
            default_type 'application/json';

            location / {
                content_by_lua_block {
                    local core = require("apisix.core")
                    ngx.req.read_body()
                    local req = core.json.decode(ngx.req.get_body_data() or "{}") or {}
                    ngx.say(core.json.encode({
                        id = "mock",
                        object = "chat.completion",
                        model = req.model,
                        choices = { {
                            index = 0,
                            finish_reason = "stop",
                            message = {
                                role = "assistant",
                                content = "model=" .. tostring(req.model)
                                          .. " path=" .. ngx.var.uri,
                            },
                        } },
                        usage = { prompt_tokens = 1, completion_tokens = 1,
                                  total_tokens = 2 },
                    }))
                }
            }
        }
_EOC_

    $block->set_value("http_config", $http_config);
});

run_tests();

__DATA__

=== TEST 1: schema - valid configuration
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.ai-decision-router")
            local ok, err = plugin.check_schema({
                decision = {
                    endpoint = "http://127.0.0.1:6724/v1/systemone",
                    model = "alias-clef",
                },
                candidates = {
                    { name = "code", description = "Programming." },
                    { name = "general", description = "Everything else." },
                },
                fallback = "general",
            })
            ngx.say(ok and "passed" or err)
        }
    }
--- response_body
passed



=== TEST 2: schema - decision endpoint and model are required
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.ai-decision-router")
            local candidates = {
                { name = "a", description = "A." },
                { name = "b", description = "B." },
            }
            local _, err = plugin.check_schema({ candidates = candidates })
            ngx.say(err)
            _, err = plugin.check_schema({
                decision = { endpoint = "http://127.0.0.1:6724/v1/systemone" },
                candidates = candidates,
            })
            ngx.say(err)
            _, err = plugin.check_schema({
                decision = { endpoint = "ftp://example.com", model = "m" },
                candidates = candidates,
            })
            ngx.say(err)
        }
    }
--- response_body_like
property "decision" is required
property "decision" validation failed: property "model" is required
property "decision" validation failed: property "endpoint" validation failed: failed to match pattern .*



=== TEST 3: schema - candidates must be unique, at least two, fallback must exist
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.ai-decision-router")
            local decision = { endpoint = "http://127.0.0.1:6724/v1/systemone", model = "m" }
            local _, err = plugin.check_schema({
                decision = decision,
                candidates = { { name = "a", description = "A." } },
            })
            ngx.say(err)
            _, err = plugin.check_schema({
                decision = decision,
                candidates = {
                    { name = "a", description = "A." },
                    { name = "a", description = "B." },
                },
            })
            ngx.say(err)
            _, err = plugin.check_schema({
                decision = decision,
                candidates = {
                    { name = "a", description = "A." },
                    { name = "b", description = "B." },
                },
                fallback = "c",
            })
            ngx.say(err)
        }
    }
--- response_body_like
property "candidates" validation failed: expect array to have at least 2 items
duplicate candidate name: a
fallback names unknown candidate: c



=== TEST 4: create a route with ai-decision-router + ai-proxy
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "uri": "/chat",
                    "plugins": {
                        "ai-decision-router": {
                            "decision": {
                                "endpoint": "http://127.0.0.1:6724/v1/systemone",
                                "model": "alias-clef",
                                "timeout": 200,
                                "auth": { "header": { "Authorization": "Bearer decision-key" } }
                            },
                            "candidates": [
                                { "name": "code", "description": "Programming.",
                                  "model": "coder-model" },
                                { "name": "math", "description": "Proofs.",
                                  "model": "math-model" },
                                { "name": "general", "description": "Everything else.",
                                  "model": "general-model" }
                            ],
                            "fallback": "general",
                            "min_confidence": 0.5,
                            "trigger_models": ["auto"]
                        },
                        "ai-proxy": {
                            "provider": "openai-compatible",
                            "auth": { "header": { "Authorization": "Bearer llm-key" } },
                            "override": { "endpoint": "http://127.0.0.1:6725/v1/chat/completions" }
                        }
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 5: the chosen candidate's model is sent to the LLM
--- request
POST /chat
{ "model": "auto", "messages": [ { "role": "system", "content": "be brief" }, { "role": "user", "content": "why does my python script crash?" } ] }
--- more_headers
Content-Type: application/json
--- error_code: 200
--- response_headers
X-AI-Routed-Model: coder-model
X-AI-Routing-Confidence: 0.9
--- response_body_like eval
qr/model=coder-model path=\/v1\/chat\/completions/



=== TEST 6: the decision request is a choice question with the configured auth
--- request
POST /chat
{ "model": "auto", "messages": [ { "role": "user", "content": "please prove this" } ] }
--- more_headers
Content-Type: application/json
--- response_body_like eval
qr/model=math-model/
--- error_log eval
[
    qr/decision mock: auth=Bearer decision-key/,
    qr/"type":"choice"/,
    qr/"model":"alias-clef"/,
    qr/"state":"please prove this"/,
]



=== TEST 7: decision model error falls back
--- request
POST /chat
{ "model": "auto", "messages": [ { "role": "user", "content": "decision-error" } ] }
--- more_headers
Content-Type: application/json
--- error_code: 200
--- response_headers
X-AI-Routed-Model: general-model
--- response_headers_like
X-AI-Routing-Fallback: decision error: status 500.*
--- response_body_like eval
qr/model=general-model/
--- error_log
ai-decision-router: decision error: status 500



=== TEST 8: decision model timeout falls back
--- request
POST /chat
{ "model": "auto", "messages": [ { "role": "user", "content": "decision-timeout" } ] }
--- more_headers
Content-Type: application/json
--- error_code: 200
--- response_headers
X-AI-Routed-Model: general-model
X-AI-Routing-Fallback: decision error: request failed: timeout
--- error_log
decision error: request failed: timeout



=== TEST 9: a decision below min_confidence falls back
--- request
POST /chat
{ "model": "auto", "messages": [ { "role": "user", "content": "unsure" } ] }
--- more_headers
Content-Type: application/json
--- response_headers
X-AI-Routed-Model: general-model
X-AI-Routing-Confidence: 0.2
X-AI-Routing-Fallback: low confidence 0.2



=== TEST 10: a choice that is not a candidate falls back
--- request
POST /chat
{ "model": "auto", "messages": [ { "role": "user", "content": "unknown-choice" } ] }
--- more_headers
Content-Type: application/json
--- response_headers
X-AI-Routed-Model: general-model
X-AI-Routing-Fallback: unknown choice nope



=== TEST 11: a model not listed in trigger_models is passed through
--- request
POST /chat
{ "model": "my-own-model", "messages": [ { "role": "user", "content": "python bug" } ] }
--- more_headers
Content-Type: application/json
--- response_headers
X-AI-Routed-Model:
--- response_body_like eval
qr/model=my-own-model/
--- no_error_log
decision mock



=== TEST 12: a request without a model is routed
--- request
POST /chat
{ "messages": [ { "role": "user", "content": "python bug" } ] }
--- more_headers
Content-Type: application/json
--- response_body_like eval
qr/model=coder-model/



=== TEST 13: an OpenAI Responses request is understood
--- request
POST /chat
{ "model": "auto", "input": "prove the theorem" }
--- more_headers
Content-Type: application/json
--- error_log eval
qr/"state":"prove the theorem"/
--- response_headers
X-AI-Routed-Model: math-model



=== TEST 14: context=conversation sends every message, max_chars keeps the tail
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/2',
                ngx.HTTP_PUT,
                [[{
                    "uri": "/conversation",
                    "plugins": {
                        "ai-decision-router": {
                            "decision": {
                                "endpoint": "http://127.0.0.1:6724/v1/systemone",
                                "model": "alias-clef"
                            },
                            "candidates": [
                                { "name": "code", "description": "Programming." },
                                { "name": "general", "description": "Everything else." }
                            ],
                            "context": "conversation",
                            "max_chars": 40
                        },
                        "ai-proxy": {
                            "provider": "openai-compatible",
                            "auth": { "header": { "Authorization": "Bearer llm-key" } },
                            "override": { "endpoint": "http://127.0.0.1:6725/v1/chat/completions" }
                        }
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 15: verify the conversation state
--- request
POST /conversation
{ "messages": [ { "role": "system", "content": "you are terse" }, { "role": "user", "content": "hello there" }, { "role": "assistant", "content": "hi" }, { "role": "user", "content": "fix this bug" } ] }
--- more_headers
Content-Type: application/json
--- error_log eval
qr/"state":"there\\n\\nassistant: hi\\n\\nuser: fix this bug"/
--- response_body_like eval
qr/model=code /



=== TEST 16: ai-proxy-multi - the chosen instance replaces the balancer's pick
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/3',
                ngx.HTTP_PUT,
                [[{
                    "uri": "/multi",
                    "plugins": {
                        "ai-decision-router": {
                            "decision": {
                                "endpoint": "http://127.0.0.1:6724/v1/systemone",
                                "model": "alias-clef"
                            },
                            "candidates": [
                                { "name": "code", "description": "Programming." },
                                { "name": "math", "description": "Proofs." },
                                { "name": "general", "description": "Everything else." }
                            ],
                            "rewrite_model": false
                        },
                        "ai-proxy-multi": {
                            "instances": [
                                {
                                    "name": "code", "provider": "openai-compatible", "weight": 1,
                                    "auth": { "header": { "Authorization": "Bearer a" } },
                                    "options": { "model": "inst-code" },
                                    "override": { "endpoint": "http://127.0.0.1:6725/code/v1/chat/completions" }
                                },
                                {
                                    "name": "math", "provider": "openai-compatible", "weight": 1,
                                    "auth": { "header": { "Authorization": "Bearer b" } },
                                    "options": { "model": "inst-math" },
                                    "override": { "endpoint": "http://127.0.0.1:6725/math/v1/chat/completions" }
                                },
                                {
                                    "name": "general", "provider": "openai-compatible", "weight": 1,
                                    "auth": { "header": { "Authorization": "Bearer c" } },
                                    "options": { "model": "inst-general" },
                                    "override": { "endpoint": "http://127.0.0.1:6725/general/v1/chat/completions" }
                                }
                            ]
                        }
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 17: verify every request goes to the chosen instance
--- config
    location /t {
        content_by_lua_block {
            local http = require("resty.http")
            local uri = "http://127.0.0.1:" .. ngx.var.server_port .. "/multi"
            for _, prompt in ipairs({ "python bug", "python bug", "python bug", "prove it" }) do
                local httpc = http.new()
                local res = assert(httpc:request_uri(uri, {
                    method = "POST",
                    headers = { ["Content-Type"] = "application/json" },
                    body = [[{"messages":[{"role":"user","content":"]] .. prompt .. [["}]}]],
                }))
                ngx.say(res.body:match("model=[^ ]+ path=/%w+"))
            end
        }
    }
--- response_body
model=inst-code path=/code
model=inst-code path=/code
model=inst-code path=/code
model=inst-math path=/math



=== TEST 18: plain upstream receives the rewritten body; fail_mode=error rejects non-JSON
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/4',
                ngx.HTTP_PUT,
                [[{
                    "uri": "/plain",
                    "plugins": {
                        "ai-decision-router": {
                            "decision": {
                                "endpoint": "http://127.0.0.1:6724/v1/systemone",
                                "model": "alias-clef"
                            },
                            "candidates": [
                                { "name": "code", "description": "Programming.",
                                  "model": "coder-model" },
                                { "name": "general", "description": "Everything else." }
                            ],
                            "fail_mode": "error",
                            "response_headers": false
                        }
                    },
                    "upstream": {
                        "type": "roundrobin",
                        "nodes": { "127.0.0.1:6725": 1 }
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 19: verify the plain upstream got the rewritten model, without routing headers
--- request
POST /plain
{ "model": "auto", "messages": [ { "role": "user", "content": "python bug" } ] }
--- more_headers
Content-Type: application/json
--- response_headers
X-AI-Routed-Model:
--- response_body_like eval
qr/model=coder-model path=\/plain/



=== TEST 20: verify fail_mode=error rejects a non-JSON request
--- request
POST /plain
hello
--- more_headers
Content-Type: text/plain
--- error_code: 400
--- response_body_like eval
qr/unsupported content-type/



=== TEST 21: the decision auth header is encrypted in etcd
--- yaml_config
apisix:
    data_encryption:
        enable_encrypt_fields: true
        keyring:
            - edd1c9f0985e76a2
--- config
    location /t {
        content_by_lua_block {
            local json = require("toolkit.json")
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/5',
                ngx.HTTP_PUT,
                [[{
                    "uri": "/encrypted",
                    "plugins": {
                        "ai-decision-router": {
                            "decision": {
                                "endpoint": "http://127.0.0.1:6724/v1/systemone",
                                "model": "alias-clef",
                                "auth": { "header": { "Authorization": "Bearer decision-key" } }
                            },
                            "candidates": [
                                { "name": "a", "description": "A." },
                                { "name": "b", "description": "B." }
                            ]
                        }
                    },
                    "upstream": {
                        "type": "roundrobin",
                        "nodes": { "127.0.0.1:6725": 1 }
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end
            ngx.sleep(0.5)

            local _, _, res = t('/apisix/admin/routes/5', ngx.HTTP_GET)
            res = json.decode(res)
            local conf = res.value.plugins["ai-decision-router"]
            ngx.say(conf.decision.auth.header.Authorization)

            local etcd = require("apisix.core.etcd")
            local stored = assert(etcd.get('/routes/5'))
            conf = stored.body.node.value.plugins["ai-decision-router"]
            ngx.say(conf.decision.auth.header.Authorization == "Bearer decision-key"
                    and "plaintext" or "encrypted")
        }
    }
--- response_body
Bearer decision-key
encrypted
