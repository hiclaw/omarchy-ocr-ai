#!/usr/bin/env bash
#
# claw.ocr-ai — 选定屏幕区域，识别其中的文字。
#
# 用法:
#   capture-ocr.sh [LANGS]
#
# 退出码（调用方靠它区分「没事」「没字」「出事」三种结局）:
#   0  成功：stdout 是识别出的文本。
#      也是「用户取消选区」——此时 0 退出且没有任何输出。
#   3  框了区域，但图里没有可识别的文字。不是错误，但也不该完全无声。
#   1  真失败（缺少依赖、截图或识别报错）：原因写到 stderr，必须让用户看见。
#
# 环境:
#   OCR_LANGS   tesseract 语言包，默认 eng（LANGS 参数优先）
#
# 这是一个纯粹的「屏幕区域 → 文本」函数：不写剪贴板、不弹通知、
# 不产生任何全局副作用。对上层的展示与后续处理一律交给调用方决定。
#
# 被 TERM/INT/HUP 打断是常态：调用方收面板、重启 shell 都会这样收进程。
# 所以这两个后台进程必须由本脚本自己拿着 pid 并在所有退出路径上收掉——
# 留下任何一个都是灾难：hyprpicker 会把画面冻住，slurp 会握走输入却
# 什么都不显示，之后每次框选都再也出不来。

set -uo pipefail

langs="${1:-${OCR_LANGS:-eng}}"
freeze_pid=""
slurp_pid=""
sel_file=""
tmp=""

cleanup() {
  [ -n "$slurp_pid" ] && kill "$slurp_pid" 2>/dev/null
  [ -n "$freeze_pid" ] && kill "$freeze_pid" 2>/dev/null
  [ -n "$sel_file" ] && rm -f "$sel_file"
  [ -n "$tmp" ] && rm -f "$tmp"
  return 0
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# 缺依赖时不能只是安静地什么都没发生，那样用户完全无从判断：
# 报错到 stderr、以 1 退出，由调用方把原因显示出来。
for cmd in hyprpicker slurp grim tesseract; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "缺少依赖：$cmd（OCR 需要 hyprpicker、slurp、grim、tesseract）" >&2
    exit 1
  }
done

# 冻结屏幕：选区过程中画面静止，且随后 grim 截取的是这帧冻结画面，
# 不会把浮层收起、动画收敛这类过程画面截进去（与 omarchy capture text 一致）。
hyprpicker -r -z >/dev/null 2>&1 &
freeze_pid=$!
sleep 0.1

# slurp 放到后台跑、自己留着 pid：Esc 取消只是它非零退出，
# 而脚本被信号打断时我们还得能主动把它收掉（见文件头）。
sel_file="$(mktemp "${TMPDIR:-/tmp}/claw-ocr-ai-sel-XXXXXX")" \
  || { echo "无法创建临时文件（TMPDIR=${TMPDIR:-/tmp}）" >&2; exit 1; }

slurp >"$sel_file" 2>/dev/null &
slurp_pid=$!
wait "$slurp_pid" || { slurp_pid=""; exit 0; }   # Esc 取消：安静收场
slurp_pid=""

selection="$(cat "$sel_file")"
[ -n "$selection" ] || exit 0

# 截图落盘再交给 tesseract：管道里拿不到各自的退出码，一旦失败就分不清
# 是截图坏了还是识别坏了，只能默默什么都没发生。
tmp="$(mktemp "${TMPDIR:-/tmp}/claw-ocr-ai-XXXXXX.png")" \
  || { echo "无法创建临时文件（TMPDIR=${TMPDIR:-/tmp}）" >&2; exit 1; }

grim -g "$selection" "$tmp" 2>/dev/null \
  || { echo "截图失败：grim 无法捕获所选区域" >&2; exit 1; }

raw="$(tesseract "$tmp" stdout --oem 1 --psm 6 -l "$langs" --dpi 300 \
        -c preserve_interword_spaces=1 2>/dev/null)" \
  || { echo "识别失败：tesseract 无法处理该图像" >&2; exit 1; }

# 去掉每行行尾空白与开头的空行；整段都是空白视为没识别到内容。
text="$(printf '%s' "$raw" | sed -e 's/[[:space:]]*$//' -e '/./,$!d')"
[ -n "${text//[[:space:]]/}" ] || exit 3

printf '%s' "$text"
