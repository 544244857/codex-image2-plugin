# 配置参考

配置文件位置：`%USERPROFILE%\.codex\image2.env`。

| 字段 | 必需 | 说明 |
| --- | --- | --- |
| `BASE_URL` | 是 | 图片中转站的 API 根地址，通常以 `/v1` 结尾 |
| `API_KEY` | 是 | 图片中转站密钥 |
| `MODEL` | 是 | 中转站支持的图片模型名 |
| `MODE` | 否 | `auto`、`images`、`images-stream`、`responses` 或 `chat` |
| `CHAT_MODEL` | 否 | `chat` 模式使用的模型 |
| `RESPONSES_MODEL` | 否 | `responses` 模式使用的模型 |
| `OUT_DIR` | 否 | 项目内输出目录 |
| `AUTO_GENERATE_ASSETS` | 否 | 开发时自动补缺失素材，默认 `false` |

配置窗口写入上述文件，但不会修改 Codex 聊天模型配置，也不会读取 `auth.json` 或 `config.toml` 中的凭据。
