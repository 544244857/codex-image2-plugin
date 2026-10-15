# Codex image2 插件

通过独立图片中转站为 Codex Desktop 提供文生图能力，并可在开发任务中按开关主动补齐缺失的位图素材。

## 功能

- 用户明确要求时生成图片，并在交付前检查实际输出。
- 可选地为网页、移动端、桌面端、游戏和其他软件项目生成缺失的位图素材。
- 自动素材生成默认关闭：`AUTO_GENERATE_ASSETS=false`。
- 支持 `images`、`images-stream`、`responses` 和 `chat` 四种中转接口模式。
- 保存到当前项目内的 `imagegen-output`，避免把生成文件写到项目外。
- 配置窗口会遮蔽 API key，保留未知配置项，并可测试 `/models`。

## 重要限制

- 当前版本是**文生图**：不支持上传原图、参考图或蒙版，也不能直接编辑已有图片。
- 图片中转站、模型名和 API key 由每位用户自行提供；仓库不包含任何可用凭据。
- 配置窗口是 Windows 独立窗口，不是 Codex 原生设置页面。原生设置页扩展尚未在本插件中实现。
- `Probe` 和 `auto` 可能发出多次真实请求；确认接口后建议固定 `-Mode`。
- 离线测试不代表你的中转站或模型一定可用，也不代替一次真实出图测试。

## 安装

环境要求：Windows、Codex CLI、Windows PowerShell 5.1 或 PowerShell 7，以及 `curl.exe`。

1. 下载本仓库 Release 中的 `image2-codex-*.zip`，解压到一个长期保留的目录。
2. 在解压目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-Codex.ps1
```

3. 重启 Codex 或新建对话。

安装脚本会注册本地 marketplace，并启用 `image2@image2-local`。解压目录需要保留，因为 marketplace 使用本地路径。

## 配置

运行：

```powershell
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\plugins\image2\scripts\Configure.ps1
```

也可以复制 `plugins/image2/image2.env.example` 到 `%USERPROFILE%\.codex\image2.env` 后手动填写。

配置示例：

```dotenv
BASE_URL=https://your-image-relay.example.com/v1
API_KEY=your-image-relay-api-key
MODEL=gpt-image-1
MODE=images
AUTO_GENERATE_ASSETS=false
```

不要把完成后的 `image2.env` 提交到 GitHub。插件使用的是图片中转站配置，不会读取或替换 Codex 的聊天 `model_provider`。

## 使用

直接在 Codex 中提出图片需求即可。开发任务中，只有明确打开 `AUTO_GENERATE_ASSETS=true` 后，插件才会主动处理真正缺失的位图素材；图标、简单图形和已有资源应优先使用项目现有方案。

命令行示例：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\plugins\image2\scripts\imagegen.ps1 `
  -Prompt "一个简洁的蓝色闪电图标，白色背景" `
  -Size 1024x1024 `
  -Mode images
```

不产生网络请求的检查：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\plugins\image2\scripts\imagegen.ps1 `
  -Prompt "test" -DryRun
```

## 视觉验收与重试规则

技能要求打开实际生成文件，检查主体、外观、动作、构图、文字和明显缺陷。首次生成后最多追加五次生成请求；失败且没有文件的请求也计入次数。此前生成的文件不会被覆盖。

## 开发与测试

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Configure.ps1
```

测试使用本地 mock HTTP 服务，不调用付费图片接口。发布包由仓库外的构建脚本生成，发布前会检查 ZIP 清单、文件哈希和明显凭据路径。

## 隐私与安全

- 不要提交 `%USERPROFILE%\.codex\image2.env`、API key、原始响应或生成图片。
- 不要复用聊天模型的 key 或 base URL。
- 图片会发送到你配置的中转站；请自行确认该服务的隐私政策和数据保留规则。

## 许可证

本项目采用 [MIT License](LICENSE)。
