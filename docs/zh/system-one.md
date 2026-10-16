---
title: system_one 算法
---

# ai-proxy-multi 的 `system_one` 算法

本页介绍为 Apache APISIX [`ai-proxy-multi`](https://apisix.apache.org/zh/docs/apisix/plugins/ai-proxy-multi/) 插件提议的 `system_one` 负载均衡算法。它由[功能分支](https://github.com/surak/apisix/tree/feat/ai-proxy-multi-system-one)上的 APISIX 文档生成，因此与拉取请求所添加的内容一致。此处未列出的属性与 `ai-proxy-multi` 相同。

## 属性

| 名称                               | 类型            | 必选项 | 默认值                           | 有效值 | 描述 |
|------------------------------------|----------------|----------|-----------------------------------|--------------|-------------|
| balancer.algorithm                 | string         | 否    | roundrobin                     | [roundrobin, chash, semantic, system_one] | 负载均衡算法。设置为 `roundrobin` 时，使用加权轮询算法。设置为 `chash` 时，使用一致性哈希算法。设置为 `semantic` 时，插件根据请求提示词与各实例 `examples` 之间的语义相似度选择实例，其相关选项配置在 `semantic_opts` 下。注意：`semantic` 不参与健康检查，也不参与 `fallback_strategy` / 重试——被选中实例的上游失败会直接返回给客户端；只有当没有实例达到其阈值或嵌入请求失败时，才会回退（回退到 `semantic_opts.fallback` 实例，若未配置则回退到第一个实例）。设置为 `system_one` 时，插件请 System One 模型根据各实例的 `description` 对实例进行排序，并选择概率最高的可用实例，其相关选项配置在 `system_one_opts` 下。与 `semantic` 不同，`system_one` 会跳过健康检查失败或被限流的实例，并在出现 `fallback_strategy` 错误时按排序重试下一个实例。 |
| instances.description               | string         | 否    |                                   | 1 到 4096 个字符 | 当 `algorithm` 为 `system_one` 时使用。用自然语言描述的实例路由角色，例如 `Debugging existing code and reviewing patches.`。它会作为该实例选项的判断标准发送给 System One 模型。当 `algorithm` 为 `system_one` 时每个实例都必填，包括被 `system_one_opts.fallback` 指定的实例。 |
| system_one_opts                     | object         | 否    |                                   |              | `system_one` 均衡器的选项。当 `balancer.algorithm` 为 `system_one` 时必填。 |
| system_one_opts.endpoint            | string         | 是    |                                   |              | System One API 的完整 URL，例如 `https://api.example.com/v1/systemone`。 |
| system_one_opts.model               | string         | 是    |                                   |              | 对实例进行排序的 System One 模型，例如 `jev`。 |
| system_one_opts.auth                | object         | 否    |                                   |              | System One API 的认证配置。 |
| system_one_opts.auth.header         | object         | 否    |                                   |              | 认证请求头。加密存储。 |
| system_one_opts.auth.query          | object         | 否    |                                   |              | 认证查询参数。加密存储。 |
| system_one_opts.instructions        | string         | 否    |                                   |              | 路由问题的指令。默认使用一条通用指令，要求选择最合适的实例。 |
| system_one_opts.threshold           | number         | 否    | 0                               | 0 到 1       | 实例被选中所需的最小概率。当没有可用实例达到该值时，请求回退到 `fallback` 实例；若未指定，则回退到第一个实例。重试时同样适用：只有当排序中的下一个实例达到阈值时才会重试该实例，否则重试 `fallback` 实例。 |
| system_one_opts.fallback            | string         | 否    |                                   |              | 当 System One 请求失败或没有实例达到阈值时，路由到的实例名称。它本身也是一个参与排名的普通实例，同样需要配置 `description`。未设置时默认回退到第一个实例。 |
| system_one_opts.timeout             | integer        | 否    | 3000                            | 最小值为 1  | System One 请求的超时时间（毫秒）。每个请求都会同步调用 System One API，因此该值限定了当端点变慢或不可用时每个请求增加的延迟上限（随后请求会 fail-open 到回退实例）。 |
| system_one_opts.ssl_verify          | boolean        | 否    | true                            |              | 如果为 true，验证 System One API 的证书。 |
| system_one_opts.debugging           | boolean        | 否    | false                           |              | 若为 true，通过 `X-AI-System-One-Probabilities` 和 `X-AI-System-One-Picked-Instance` 响应头暴露各实例的概率和路由决策，用于调试。 |

## 示例：使用 System One 模型路由

以下示例演示了如何使用 `system_one` 算法，让 System One 模型为每个请求选择实例。System One 模型（例如 [TypeSafe Jev](https://en.wikipedia.org/wiki/Jev_(AI_model)) 或 Cloudflare Clef）是一种判别式模型：它不生成文本，而是针对输入回答类型化的问题，并返回概率分布。插件将请求提示词作为 `state` 发送，并提出一个 `choice` 类型的问题，其选项是各实例的名称，每个选项由实例的 `description` 描述。随后插件将请求转发给概率最高、健康且未被限流的实例。

与 `semantic` 相比，路由策略是每个实例的自然语言描述，而不是一组示例提示词，并且不需要嵌入模型。由于模型会对所有实例进行排序，插件可以跳过不健康或被限流的实例，并在下一个概率最高的实例上重试。

创建如下路由，并相应地更新 LLM 提供商、System One 端点和模型以及 API 密钥。`default` 实例被指定为 `system_one_opts.fallback`，当 System One 请求失败或没有实例达到阈值时兜底：

```shell
curl "http://127.0.0.1:9180/apisix/admin/routes" -X PUT \
  -H "X-API-KEY: ${admin_key}" \
  -d '{
    "id": "ai-proxy-multi-route",
    "uri": "/anything",
    "methods": ["POST"],
    "plugins": {
      "ai-proxy-multi": {
        "balancer": {
          "algorithm": "system_one"
        },
        "system_one_opts": {
          "endpoint": "https://api.example.com/v1/systemone",
          "model": "jev",
          "auth": {
            "header": {
              "Authorization": "Bearer '"$YOUR_SYSTEM_ONE_API_KEY"'"
            }
          },
          "threshold": 0.3,
          "fallback": "default"
        },
        "fallback_strategy": ["http_429", "http_5xx"],
        "instances": [
          {
            "name": "code",
            "provider": "openai",
            "weight": 1,
            "auth": {
              "header": {
                "Authorization": "Bearer '"$YOUR_LLM_API_KEY"'"
              }
            },
            "options": {
              "model": "gpt-4o"
            },
            "description": "Writing, debugging and reviewing code."
          },
          {
            "name": "translate",
            "provider": "openai",
            "weight": 1,
            "auth": {
              "header": {
                "Authorization": "Bearer '"$YOUR_LLM_API_KEY"'"
              }
            },
            "options": {
              "model": "gpt-4o-mini"
            },
            "description": "Translating and summarizing text."
          },
          {
            "name": "default",
            "provider": "openai",
            "weight": 1,
            "auth": {
              "header": {
                "Authorization": "Bearer '"$YOUR_LLM_API_KEY"'"
              }
            },
            "options": {
              "model": "gpt-4o-mini"
            },
            "description": "General questions and conversation with no specialist need."
          }
        ]
      }
    }
  }'
```

发送一个编程类提示词的请求：

```shell
curl "http://127.0.0.1:9080/anything" -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "model": "auto",
    "messages": [
      { "role": "user", "content": "help me debug this python code" }
    ]
  }'
```

请求应被路由到 `code` 实例，并由 `gpt-4o` 处理。如果 `code` 实例返回 `5xx` 或 `429` 状态码，请求会在下一个达到 `threshold` 且概率最高的实例上重试，否则在回退实例 `default` 上重试，而不会再次询问 System One 模型。

插件发送给 System One API 的请求类似如下：

```json
{
  "model": "jev",
  "state": "help me debug this python code",
  "questions": {
    "instance": {
      "type": "choice",
      "instructions": "Choose the option best suited to answer this request. ...",
      "criteria": {
        "code": "Writing, debugging and reviewing code.",
        "translate": "Translating and summarizing text.",
        "default": "General questions and conversation with no specialist need."
      }
    }
  }
}
```

插件根据响应中的 `answers.instance.probabilities` 对实例进行排序。如果响应中没有概率分布，插件会改用 `answers.instance.choice`。

### 调试路由决策

将 `system_one_opts.debugging` 设置为 `true`，插件会报告每个实例的概率以及最终选择的实例：

```text
HTTP/1.1 200 OK
X-AI-System-One-Picked-Instance: code
X-AI-System-One-Probabilities: code:0.9100,default:0.0600,translate:0.0300
```

当 System One 请求失败，或没有可用实例达到阈值时，插件会以 `warn` 级别记录原因，并路由到回退实例：

```text
system_one routing: system one request failed: request: timeout, falling back
```

由于 `debugging` 会向调用方暴露实例名称，生产环境中请保持关闭，改用日志进行排查。
