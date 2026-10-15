# 发布说明

维护者发布新版本时：

1. 更新 `plugins/image2/plugin.json` 的版本号。
2. 更新 `plugins/image2/README.md` 和根目录 README 的行为说明。
3. 运行配置窗口测试和 PowerShell 解析检查。
4. 用项目中的 `Build-Packages.ps1` 重新生成安装包并检查 `SHA256SUMS.txt`。
5. 确认仓库没有真实 `.env`、密钥、原始响应、测试输出和用户路径。

公开 Release 应同时提供源码 ZIP 和经过构建验证的 `image2-codex-*.zip` 安装包，并在 Release notes 中注明是否做过真实模型调用测试。
