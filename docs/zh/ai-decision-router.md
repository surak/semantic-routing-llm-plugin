---
title: ai-decision-router
keywords:
  - Apache APISIX
  - API 网关
  - Plugin
  - ai-decision-router
  - AI
  - LLM 路由
description: ai-decision-router 插件询问决策模型哪个 LLM 最适合当前请求，并将请求路由到该模型，可与 ai-proxy、ai-proxy-multi 或普通上游配合使用。
---

import Tabs from '@theme/Tabs';
import TabItem from '@theme/TabItem';

## 描述

`ai-decision-router` 插件将每个 LLM 请求路由到最适合它的模型。对于每个请求，插件会把提示词连同候选模型及其路由角色发送给一个类型化的决策模型，并将请求路由到决策模型选中的候选模型。

决策模型可以是任何实现了 Clef 兼容 `/v1/systemone` API 的服务：它接收一个 `state`（提示词）和若干类型化的 `questions`，并返回决策结果及每个选项的概率。插件会发送一个 `choice` 类型的问题，其选项就是各个候选模型。

该插件可以与 [`ai-proxy`](./ai-proxy.md) 插件、[`ai-proxy-multi`](./ai-proxy-multi.md) 插件或普通上游一起使用：

- 与 `ai-proxy` 一起使用时，插件会改写请求体中的 `model` 字段。
- 与 `ai-proxy-multi` 一起使用时，插件会用所选候选模型对应的实例替换负载均衡器选出的实例。
- 与普通上游一起使用时，插件会改写转发的请求体中的 `model` 字段。

路由是建议性的。当决策模型失败、超时、返回未知选项，或置信度低于 `min_confidence` 时，插件会将请求路由到 `fallback` 候选模型，而不是拒绝请求。

插件以协议感知的方式读取提示词，因此支持 `ai-proxy` 支持的所有对话协议，例如 OpenAI Chat Completions、OpenAI Responses 和 Anthropic Messages。插件在 `access` 阶段运行，优先级为 `1039`，位于 `ai-proxy-multi` 和 `ai-proxy` 之后、`ai-cache` 和 `ai-rate-limiting` 之前，因此这些插件看到的是路由后的模型。

与 `ai-proxy-multi` 的 `semantic` 算法（选择示例提示词与请求最相似的实例）相比，该插件不需要示例或嵌入模型：路由策略就是每个候选模型的纯文本路由角色。

## 属性

| 名称 | 类型 | 必选项 | 默认值 | 有效值 | 描述 |
|------|------|--------|--------|--------|------|
| decision | object | 是 | | | 决策模型配置。 |
| decision.endpoint | string | 是 | | 以 `http://` 或 `https://` 开头的 URL | 决策 API 的 URL，例如 `https://example.com/v1/systemone`。 |
| decision.model | string | 是 | | | 决策模型名称。 |
| decision.auth.header | object | 否 | | | 发送给决策模型的请求头，例如 `Authorization`。这些值在存入 etcd 之前会使用 AES 加密。 |
| decision.instructions | string | 否 | 通用路由指令 | | 路由问题的指令。 |
| decision.timeout | integer | 否 | `5000` | >= 1 | 决策请求的超时时间，单位为毫秒。 |
| decision.ssl_verify | boolean | 否 | `true` | | 为 `true` 时，校验决策端点的 TLS 证书。 |
| candidates | array[object] | 是 | | 2 到 64 项 | 可供选择的模型。 |
| candidates.name | string | 是 | | `^[A-Za-z0-9_.:-]+$`，唯一 | 提供给决策模型的选项 ID。 |
| candidates.description | string | 是 | | | 候选模型的路由角色：它应该接收哪些请求。 |
| candidates.model | string | 否 | `name` | | 写入请求体 `model` 字段的值。 |
| candidates.instance | string | 否 | `name` | | 要使用的 `ai-proxy-multi` 实例名称。 |
| fallback | string | 否 | 第一个候选模型 | 某个候选模型的 `name` | 没有可用决策时使用的候选模型。 |
| min_confidence | number | 否 | `0` | [0, 1] | 置信度低于该值的决策将使用 `fallback`。 |
| context | string | 否 | `last_user` | `last_user`、`conversation` | 发送给决策模型的文本。`last_user` 发送最后一条用户消息；`conversation` 以 `role: text` 的形式发送全部消息。 |
| max_chars | integer | 否 | `8000` | >= 1 | 只保留该文本的最后 `max_chars` 个字符。 |
| trigger_models | array[string] | 否 | | | 设置后，只路由 `model` 在该列表中或未指定 `model` 的请求，其他请求原样透传。未设置或为空时，路由所有请求。 |
| rewrite_model | boolean | 否 | `true` | | 为 `true` 时，改写请求体中的 `model` 字段。当 `ai-proxy-multi` 的实例设置了 `options.model` 时，请设为 `false`。 |
| response_headers | boolean | 否 | `true` | | 为 `true` 时，添加 `X-AI-Routed-Model`、`X-AI-Routing-Confidence` 和 `X-AI-Routing-Fallback` 响应头。 |
| fail_mode | string | 否 | `skip` | `skip`、`warn`、`error` | 当请求不是插件可以读取的 JSON 请求时的行为。`skip`：原样透传；`warn`：透传并记录警告日志；`error`：拒绝请求。 |

插件还会将 `$ai_routed_model` 变量设置为所选模型，并更新 `$request_llm_model`，因此日志插件、`ai-rate-limiting` 和指标看到的都是路由后的模型。

### 响应头

| 响应头 | 描述 |
|--------|------|
| `X-AI-Routed-Model` | 请求被路由到的模型。 |
| `X-AI-Routing-Confidence` | 决策模型对其选择的置信度。 |
| `X-AI-Routing-Fallback` | 使用 `fallback` 的原因：`decision error: ...`、`low confidence ...`、`unknown choice ...` 或 `no prompt text`。 |

## 示例

以下示例使用由同一网关提供的 OpenAI 兼容模型，该网关同时托管了一个决策模型。请将端点、模型名称和密钥替换为你自己的值。

:::note

你可以使用以下命令从 `config.yaml` 中获取 `admin_key` 并保存到环境变量中：

```bash
admin_key=$(yq '.deployment.admin.admin_key[0].key' conf/config.yaml | sed 's/"//g')
```

:::

你可以选择将 API 信息保存到环境变量中：

```shell
# 替换为你的数据
export LLM_ENDPOINT=https://llm.example.com/v1/chat/completions
export DECISION_ENDPOINT=https://llm.example.com/v1/systemone
export API_KEY=your-api-key
```

### 将请求路由到最合适的模型

以下示例演示如何将请求模型为 `auto` 的请求路由到四个模型中最合适的一个。指定了模型名称的请求将原样透传。

<Tabs
groupId="api"
defaultValue="admin-api"
values={[
{label: 'Admin API', value: 'admin-api'},
{label: 'ADC', value: 'adc'}
]}>

<TabItem value="admin-api">

创建一个配置了 `ai-decision-router` 和 [`ai-proxy`](./ai-proxy.md) 插件的路由：

```shell
curl "http://127.0.0.1:9180/apisix/admin/routes" -X PUT \
  -H "X-API-KEY: ${admin_key}" \
  -d '{
    "id": "ai-decision-router-route",
    "uri": "/anything",
    "methods": ["POST"],
    "plugins": {
      "ai-decision-router": {
        "decision": {
          "endpoint": "'"$DECISION_ENDPOINT"'",
          "model": "alias-clef",
          "auth": {
            "header": {
              "Authorization": "Bearer '"$API_KEY"'"
            }
          }
        },
        "trigger_models": ["auto"],
        "fallback": "general",
        "min_confidence": 0.3,
        "candidates": [
          { "name": "fast", "description": "Routine factual questions, short summaries, and simple scripts." },
          { "name": "code", "description": "Debugging existing code and reviewing patches." },
          { "name": "reasoning", "description": "Rigorous mathematical proofs and deep multi-step reasoning." },
          { "name": "general", "description": "Broad synthesis with no dominant specialist." }
        ]
      },
      "ai-proxy": {
        "provider": "openai-compatible",
        "auth": {
          "header": {
            "Authorization": "Bearer '"$API_KEY"'"
          }
        },
        "override": {
          "endpoint": "'"$LLM_ENDPOINT"'"
        }
      }
    }
  }'
```

</TabItem>

<TabItem value="adc">

创建一个配置了 `ai-decision-router` 和 [`ai-proxy`](./ai-proxy.md) 插件的路由：

```yaml title="adc.yaml"
services:
  - name: ai-decision-router-service
    routes:
      - name: ai-decision-router-route
        uris:
          - /anything
        methods:
          - POST
        plugins:
          ai-decision-router:
            decision:
              endpoint: "${DECISION_ENDPOINT}"
              model: alias-clef
              auth:
                header:
                  Authorization: "Bearer ${API_KEY}"
            trigger_models:
              - auto
            fallback: general
            min_confidence: 0.3
            candidates:
              - name: fast
                description: Routine factual questions, short summaries, and simple scripts.
              - name: code
                description: Debugging existing code and reviewing patches.
              - name: reasoning
                description: Rigorous mathematical proofs and deep multi-step reasoning.
              - name: general
                description: Broad synthesis with no dominant specialist.
          ai-proxy:
            provider: openai-compatible
            auth:
              header:
                Authorization: "Bearer ${API_KEY}"
            override:
              endpoint: "${LLM_ENDPOINT}"
```

将配置同步到网关：

```shell
adc sync -f adc.yaml
```

</TabItem>

</Tabs>

向路由发送请求：

```shell
curl -i "http://127.0.0.1:9080/anything" -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "model": "auto",
    "messages": [
      { "role": "user", "content": "Prove that there are infinitely many primes." }
    ]
  }'
```

你应该收到来自 `reasoning` 模型的 `HTTP/1.1 200 OK` 响应，并带有类似以下的响应头：

```text
X-AI-Routed-Model: reasoning
X-AI-Routing-Confidence: 0.9326
```

发送一个指定了模型名称的请求：

```shell
curl -i "http://127.0.0.1:9080/anything" -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "model": "fast",
    "messages": [
      { "role": "user", "content": "Prove that there are infinitely many primes." }
    ]
  }'
```

你应该收到来自 `fast` 模型的 `HTTP/1.1 200 OK` 响应，且不带路由相关的响应头。

### 选择 ai-proxy-multi 的实例

以下示例演示如何将插件与 [`ai-proxy-multi`](./ai-proxy-multi.md) 一起使用，其中每个实例设置了自己的模型。请将实例命名为与候选模型相同的名称，或设置 `candidates.instance`。

```shell
curl "http://127.0.0.1:9180/apisix/admin/routes" -X PUT \
  -H "X-API-KEY: ${admin_key}" \
  -d '{
    "id": "ai-decision-router-multi-route",
    "uri": "/anything",
    "methods": ["POST"],
    "plugins": {
      "ai-decision-router": {
        "decision": {
          "endpoint": "'"$DECISION_ENDPOINT"'",
          "model": "alias-clef",
          "auth": { "header": { "Authorization": "Bearer '"$API_KEY"'" } }
        },
        "rewrite_model": false,
        "fallback": "general",
        "candidates": [
          { "name": "code", "description": "Programming, debugging, and code review." },
          { "name": "general", "description": "Everything else: chat, writing, and summaries." }
        ]
      },
      "ai-proxy-multi": {
        "instances": [
          {
            "name": "code",
            "provider": "openai-compatible",
            "weight": 1,
            "auth": { "header": { "Authorization": "Bearer '"$API_KEY"'" } },
            "options": { "model": "coder-model" },
            "override": { "endpoint": "'"$LLM_ENDPOINT"'" }
          },
          {
            "name": "general",
            "provider": "openai-compatible",
            "weight": 1,
            "auth": { "header": { "Authorization": "Bearer '"$API_KEY"'" } },
            "options": { "model": "general-model" },
            "override": { "endpoint": "'"$LLM_ENDPOINT"'" }
          }
        ]
      }
    }
  }'
```

与代码相关的请求会发送到 `code` 实例，其他请求会发送到 `general` 实例。如果所选实例返回的状态码在 `ai-proxy-multi` 的 `fallback_strategy` 覆盖范围内，`ai-proxy-multi` 会使用自己的负载均衡器重试其他实例。

### 在决策不确定时回退

按照第一个示例配置 `min_confidence` 后，置信度较低的决策会将请求路由到 `fallback`。响应中会带有回退原因：

```text
X-AI-Routed-Model: general
X-AI-Routing-Confidence: 0.21
X-AI-Routing-Fallback: low confidence 0.21
```

当决策模型无法访问、超时或返回错误时，请求同样会发送到 `fallback`，并且插件会记录一条警告日志：

```text
X-AI-Routed-Model: general
X-AI-Routing-Fallback: decision error: request failed: timeout
```
