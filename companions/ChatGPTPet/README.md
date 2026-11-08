# GPT龙娘 · ChatGPT / Codex 用量桌宠（macOS）

和 Claude大小姐同一套功能，换成 ChatGPT 桌面版（Codex）的数据。

- **只在 ChatGPT 在前台时出现**（`com.openai.codex` / `com.openai.chat`）
- **额度**：直接向 ChatGPT 账号查实时的 5 小时 / 每周额度（读取本机 Codex 的登录 `~/.codex/auth.json`，只读）；查不到时退回 `~/.codex/sessions` 日志里最近一次的 `rate_limits`
- **任务**：最近 6 小时的 Codex 线程，点击用 `codex://threads/<id>` 在 ChatGPT 里打开
- **形象**：v3 表情（ai-chan-sheets 的 GPT娘设定图，CC BY-NC-SA 4.0，已包含）；可选 GPT龙娘动画（见下）
- 每日 Token 热力图、用量统计、设置；菜单栏、番茄钟和提醒与其他桌宠共用（`../../Sources/PetHub.swift`）

```bash
./build.sh                       # 生成 build/GPT龙娘.app
./fetch-dragon.sh && ./build.sh  # 可选：下载龙娘动画后再构建
```

GPT龙娘动画素材来自 [tqlearning/ai-girl-chatgpt-pets](https://github.com/tqlearning/ai-girl-chatgpt-pets)，该仓库的美术资源没有开放授权，所以不包含在本仓库和安装包里；`fetch-dragon.sh` 会把它下载到被忽略的 `Assets/gpt-dragon/`，只在你自己的电脑上使用。
