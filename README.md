# CodexDog 🐶

一只住在 macOS 桌面上的小黑狗。平时躲着，在屏幕右下角晃晃鼠标，鼠标就变成一根淀粉肠，小黑站起来作揖、一蹦一蹦地追过来吃。点它一下，它会帮你清理 [Codex](https://openai.com/codex/) 会话文件里内嵌的历史图片，免得每轮对话都把旧截图重新上传一遍。

> 非 OpenAI 官方项目。

## 功能

- **藏起来 / 叫出来**：小黑平时不占桌面。在屏幕右下角 1.2 秒内左右来回晃 4 次鼠标，光标变成淀粉肠，小黑从屏幕底边钻出来。
- **追淀粉肠**：小黑用站立作揖的动作追着光标跑，追上就吃掉；15 秒没追上会扑上来抢。25 秒没人理就跑回角落躲起来。
- **清理图片**：单击小黑，退出 Codex / ChatGPT，把 `~/.codex/sessions` 和 `~/.codex/archived_sessions` 里内嵌的 base64 图片换成 1×1 透明图，再重新打开。
- 右键菜单：立即清理、躲起来、开机自动启动、重新抠图、退出。

小黑的形象来自真狗的照片和视频，用 macOS 自带的 Vision 抠图（`VNGenerateForegroundInstanceMaskRequest`），第一次启动时生成并缓存到 `~/Library/Application Support/CodexDog/`。

## 安装

需要 macOS 14+ 和 Xcode 命令行工具（`xcode-select --install`）。

```bash
git clone https://github.com/zio005792-blip/CodexDog.git
cd CodexDog
bash install.sh
```

装到 `~/Applications/CodexDog.app` 并自动打开。卸载：右键 → 退出，然后删掉这个 App。

## ⚠️ 清理前请知道

- 清理会**直接改写** `~/.codex` 下的会话文件，**不做备份**，清掉的图片无法恢复，模型之后也看不到这些旧图片。
- 清理前会退出 Codex / ChatGPT，正在跑的任务会被打断。
- 改过的行会在末尾补空格，保持字节数不变：新版 Codex 在 `thread_history_1.sqlite` 里按字节位置索引对话，文件变短会导致聊天记录打不开。因此文件大小不会变小。
- 如果你用过早期版本清理后记录打不开，运行 `python3 repair_history.py`（`--dry` 只检查不修改）。

## 文件

| 文件 | 作用 |
| --- | --- |
| `main.swift` | 桌宠本体（AppKit + Core Animation） |
| `clean_images.py` | 清理 Codex 会话里的图片 |
| `repair_history.py` | 修复旧版清理造成的记录错位 |
| `install.sh` | 编译并安装 |
| `photos/` | 小黑的照片、作揖动作帧和淀粉肠 |

## 小提示

- 为了在后台把系统箭头换成淀粉肠，用了一个私有的 CoreGraphics 开关（`SetsCursorInBackground`）。系统不支持时，箭头会和淀粉肠同时显示，其他功能不受影响。
- 想换成自己家的狗：替换 `photos/` 里的图片，调整 `main.swift` 里 `POSES` 的 `crop` / `erase`，然后右键 → 重新抠图。

## 协议

[MIT](LICENSE)
