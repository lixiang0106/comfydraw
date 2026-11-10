# ComfyDraw

A small native macOS front end for [ComfyUI](https://github.com/Comfy-Org/ComfyUI): write a prompt, get a picture, keep a local history. No browser tab, no node graph.

一个轻量的 macOS 原生 ComfyUI 前端：输入提示词、生成图片、自动保存历史。不用打开浏览器，也不用连线。

> ComfyDraw is an independent third-party project. It is **not** affiliated with, endorsed by, or supported by ComfyUI or Comfy Org.
>
> ComfyDraw 是独立第三方项目，与 ComfyUI 官方无隶属关系。

**[下载 macOS 版（Apple Silicon）](https://github.com/lixiang0106/comfydraw/releases/latest)** · [Download for macOS](https://github.com/lixiang0106/comfydraw/releases/latest) · [从源码构建](#option-b--build-from-source)

---

## Features

- **Text to image** — prompt, size, steps, seed, batch.
- **Image to image** — pick a reference picture and redraw it with a strength slider.
- **Document to prompt** — extract text from PDF/Word and ask a local OpenAI-compatible model for an image prompt.
- **Local history** — every result is archived on disk with its parameters.
- **No browser, no extra window** — ComfyDraw starts a local ComfyUI engine in the background and stops it when you quit and nothing is running.
- **Local only** — requests go to `127.0.0.1`; redirects are refused and no telemetry is sent.

## Requirements

- macOS 14 or later, Apple Silicon recommended.
- **ComfyUI** — either [Comfy Desktop](https://www.comfy.org/download) or a manual install with a `.venv` inside the ComfyUI folder.
- **ComfyUI-GGUF** custom node (only if you use `.gguf` models).
- **Qwen Image models** (the built-in workflow targets this family):

  | Role | File |
  | --- | --- |
  | Diffusion model | `qwen-image-2.1-UC-Q6_K.gguf` |
  | Text encoder | `qwen3vl_8b_bf16.safetensors` |
  | VAE | `qwen_image_2.1_vae_bf16.safetensors` |

  Other Qwen Image variants usually work; drop them into your ComfyUI model folders and pick them in the app.

Document analysis is optional and needs an OpenAI-compatible endpoint (for example a local oMLX server) plus its API key.

## Install

### Option A — prebuilt app

1. Download the latest release, unzip, and drag `ComfyDraw.app` into `Applications`.
2. The build is ad-hoc signed, so the first launch needs **right-click → Open** (or `System Settings → Privacy & Security → Open Anyway`).
3. Launch it. ComfyDraw looks for `127.0.0.1:8188`; if nothing is listening it tries to start a local ComfyUI it can find.

### Option B — build from source

```bash
git clone https://github.com/<your-name>/comfydraw.git
cd comfydraw
./build.sh          # produces ComfyDraw.app
open ComfyDraw.app
```

`build.sh` needs the Swift toolchain (`xcode-select --install` is enough; Xcode is not required).

## First run

Open **设置 (Settings)** in the app:

- **绘图引擎** — shows which ComfyUI install was detected. If detection misses it, press 选择… and point at the folder that contains `main.py`. Turn auto-start off if you prefer to launch ComfyUI yourself.
- **后端地址** — defaults to `http://127.0.0.1:8188`. Only loopback addresses are accepted.
- **文档分析** — optional base URL and API key for a local text model. The key is stored in the app's preferences, unencrypted.

Model dropdowns are filled from your ComfyUI instance, so whatever you have installed shows up automatically.

## How it works

```
ComfyDraw.app
 ├── SwiftUI interface
 ├── POST /prompt        → submit a Qwen Image workflow
 ├── GET  /history/{id}  → poll result, download PNG via /view
 └── local archive       → ~/Library/Application Support/ComfyDraw
```

If port 8188 is free, ComfyDraw launches the detected ComfyUI `main.py` with `--listen 127.0.0.1`, reusing your existing models and input/output folders. It never touches a ComfyUI it did not start, and it never sends a global `/interrupt`.

## Known limitations

- The built-in workflow is **Qwen Image specific**. Other architectures (SDXL, FLUX, …) are not supported yet; the app warns when the selected models look incompatible.
- `cfg` is fixed at `1.0`, so the negative prompt currently has **no effect**.
- No live sampling progress — the app shows queued / running / saving instead of a percentage.
- Cancel only removes a queued job. A job that is already running keeps going.
- PDF text extraction covers the first 12 pages; analysis uses at most the first 6000 characters. No OCR for scanned files.
- Image-to-image is a *reference redraw*, not instruction-based editing.
- Ad-hoc signed: no notarization, so Gatekeeper requires the right-click → Open step.

## Privacy

ComfyDraw talks only to loopback addresses, refuses HTTP redirects, and sends no analytics. Prompts, reference images and document excerpts stay on your machine — but if you point the backend address at another host, that host receives them. Your ComfyUI installation and any custom nodes you installed may have their own network behaviour, which this app does not control.

## License

[MIT](LICENSE)

---

## 中文说明

**ComfyDraw** 是一个 macOS 原生小工具，用来给本机 ComfyUI 套一层简单界面。打开就能写提示词出图，支持参考图重绘、文档转提示词、本地历史记录，不需要开浏览器，也不用面对节点图。

### 使用前提

- macOS 14 及以上，建议 Apple Silicon。
- 本机已装 ComfyUI（Comfy Desktop 或手动安装，目录里带 `.venv`）。
- 使用 GGUF 模型时需要 ComfyUI-GGUF 插件。
- 内置工作流面向 **Qwen Image**：扩散模型、文本编码器、VAE 各一个，装好后在界面里选择即可。

### 安装

下载 Release 里的 `ComfyDraw.app`，拖进「应用程序」。因为是本地签名，第一次打开要**右键 → 打开**。也可以自己编译：`./build.sh`。

### 第一次使用

打开软件左边的「设置」：

- 会自动检测 Comfy Desktop 安装的实例；没检测到就手动选 ComfyUI 目录（包含 `main.py` 那一层）。
- 后端地址默认 `http://127.0.0.1:8188`，只接受本机地址。
- 不用文档功能的话，文档分析那一段可以全部留空。

如果 8188 端口空闲，软件会自动在后台启动检测到的 ComfyUI，复用你已有的模型和输入输出目录；退出时若没有任务在跑，会一并关掉它自己启动的引擎。

### 已知限制

- 只支持 Qwen Image 系列工作流，其他模型架构暂不支持（选错会提示）。
- `cfg` 固定为 1，反向提示词目前不起作用。
- 没有实时采样进度，只有「排队 / 生成中 / 保存中」。
- 取消只对排队中的任务有效，已经在跑的任务会继续。
- PDF 只读前 12 页，分析最多用前 6000 字，扫描件不做 OCR。
- 图生图是「参考图重绘」，不是指令式修图。

### 隐私

只访问本机回环地址，不发送统计信息。提示词、参考图和文档节选都留在本机；但如果你把后端地址改成别的机器，内容就会发到那台机器。
