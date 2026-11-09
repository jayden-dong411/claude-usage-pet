#!/bin/zsh
# Builds GPT龙娘, Grok娘 and DeepSeek娘 and zips each with an install guide into ../dist.
# The GPT龙娘 sprite sheet has no open license, so the packages use the v3 look (EXCLUDE_DRAGON=1).
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:-$(cat "$(dirname "$0")/../VERSION")}"
OUT="$(cd .. && pwd)/dist"
mkdir -p "$OUT"
pack() {   # dir app-name zip-name host-app data-note
  local dir="$1" app="$2" zip="$3" host="$4" note="$5"
  (cd "$dir" && EXCLUDE_DRAGON=1 ./build.sh >/dev/null)
  local stage="$(mktemp -d)/$app"
  mkdir -p "$stage"
  cp -R "$dir/build/$app.app" "$stage/"
  cat > "$stage/安装说明.txt" <<TXT
$app —— 安装说明

需要：macOS 14 或更新版本；Intel 和 Apple 芯片的 Mac 都可以。
它只在 $host 在前台时出现，点她看额度和最近的任务，右键有更多功能。

1. 把「$app.app」拖进「应用程序」文件夹。
2. 第一次打开：这个应用没有经过苹果公证，直接双击会被系统拦下。
   打开「系统设置 → 隐私与安全性」，往下翻到"已阻止 $app"，点「仍要打开」；
   或者在「终端」里执行：xattr -dr com.apple.quarantine "/Applications/$app.app"

数据来源：$note
和 Claude大小姐等其他桌宠一起运行时，菜单栏图标、专注番茄钟和提醒会自动合并成一份。

形象：ai-chan-sheets（github.com/lmy414/ai-chan-sheets）的设定图表情，CC BY-NC-SA 4.0，仅限非商业使用。
TXT
  rm -f "$OUT/$zip"
  ditto -c -k --sequesterRsrc --keepParent "$stage" "$OUT/$zip"
  echo "✓ $OUT/$zip（$(du -h "$OUT/$zip" | cut -f1)）"
}
pack ChatGPTPet "GPT龙娘" "GPTDragonPet-v$VERSION-macOS.zip" "ChatGPT" "读取本机 Codex 的登录（~/.codex/auth.json，只读）向 ChatGPT 账号查实时额度；任务列表来自 ~/.codex。"
pack GrokPet "Grok娘" "GrokPet-v$VERSION-macOS.zip" "Grok Bot" "Grok Bot 桌面版缓存在本机的每周额度和机器人列表。"
pack DeepSeekPet "DeepSeek娘" "DeepSeekPet-v$VERSION-macOS.zip" "DeepSeek Harness" "DeepSeek Harness 记在本机的账户余额（~/.dsh），不读密钥、不联网。"
