#!/bin/zsh
# Builds the app and makes dist/Claude大小姐.zip (app + install guide) to send to a friend.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
STAGE="build/package"
rm -rf "$STAGE" && mkdir -p "$STAGE/Claude大小姐" dist
cp -R "build/Claude大小姐.app" "$STAGE/Claude大小姐/"
cp "Assets/daxiaojie/ATTRIBUTION.txt" "$STAGE/Claude大小姐/素材署名.txt"
cat > "$STAGE/Claude大小姐/安装说明.txt" <<'TXT'
Claude大小姐 桌宠 —— 安装说明

需要：macOS 14 或更新版本；Intel 和 Apple 芯片的 Mac 都可以。
建议先装好 Claude 桌面版并登录，这样桌宠能直接读到你的用量。

1. 把「Claude大小姐.app」拖进「应用程序」文件夹。
2. 第一次打开：这个应用没有经过苹果公证，直接双击会被系统拦下。
   - 先双击一次，看到"无法打开"的提示后点「完成」；
   - 打开「系统设置 → 隐私与安全性」，往下翻到"已阻止 Claude大小姐"，点「仍要打开」，再输入电脑密码确认。
   如果找不到这个按钮，也可以打开「终端」，执行下面这一行后再双击打开：
       xattr -dr com.apple.quarantine "/Applications/Claude大小姐.app"
3. 打开后会弹出钥匙串对话框，问能否访问「Claude Safe Storage」。点「始终允许」并输入电脑密码。
   这是为了读取 Claude 桌面版的登录来显示用量，只读不写，数据只留在你的电脑上。
   不想授权的话点「拒绝」，之后在大小姐的面板里点「登录 claude.ai」单独登录也可以。

用法：
- 大小姐默认只在 Claude 窗口在前台时出现；点她看用量和正在进行的任务，右键有更多功能（用量统计、设置、开机启动等）。
- 用量统计读取的是你自己电脑上 ~/.claude/projects 的 Claude Code 会话记录。

素材署名见「素材署名.txt」（CC BY-NC-SA 4.0，仅限非商业使用）。
TXT
OUT="dist/Claude大小姐.zip"
rm -f "$OUT"
ditto -c -k --sequesterRsrc --keepParent "$STAGE/Claude大小姐" "$OUT"
rm -rf "$STAGE"
echo "✓ 打包完成：$(pwd)/$OUT（$(du -h "$OUT" | cut -f1)）"
