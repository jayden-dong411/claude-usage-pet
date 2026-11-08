#!/bin/zsh
# Downloads the animated GPT龙娘 sprite sheet (github.com/tqlearning/ai-girl-chatgpt-pets) into the
# git-ignored Assets/gpt-dragon. Its art has no open license: use it on your own Mac only.
set -euo pipefail
cd "$(dirname "$0")"
BASE="https://raw.githubusercontent.com/tqlearning/ai-girl-chatgpt-pets/main/assets/gpt-dragon"
mkdir -p Assets/gpt-dragon
for f in spritesheet.png pet.json; do
  curl -fL --retry 2 -o "Assets/gpt-dragon/$f" "$BASE/$f" || { echo "下载 $f 失败，请到仓库里找龙娘素材的实际路径后手动放到 Assets/gpt-dragon/"; exit 1; }
done
printf '形象：GPT龙娘（github.com/tqlearning/ai-girl-chatgpt-pets）\n角色设定：ZipZipPipe\n美术资源未开放授权，仅限本机个人使用。\n' > Assets/gpt-dragon/ATTRIBUTION.md
cp Assets/gpt-dragon/ATTRIBUTION.md Assets/gpt-dragon/RIGHTS.md
echo "✓ 已下载，重新运行 ./build.sh 即可带上龙娘动画"
