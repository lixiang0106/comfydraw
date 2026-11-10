# ComfyDraw

A small native macOS front end for [ComfyUI](https://github.com/Comfy-Org/ComfyUI): write a prompt, get a picture, keep a local history. No browser tab, no node graph.

一个轻量的 macOS 原生 ComfyUI 前端：输入提示词、生成图片、自动保存历史。不用打开浏览器，也不用连线。

> ComfyDraw is an independent third-party project. It is **not** affiliated with, endorsed by, or supported by ComfyUI or Comfy Org.
>
> ComfyDraw 是独立第三方项目，与 ComfyUI 官方无隶属关系。

> **Source / Release:** This source tree contains unreleased changes after v1.1. The current v1.1 download does not include these updates.
>
> **源码与下载版：**本源码包含 v1.1 之后尚未发布的修改；当前下载版 v1.1 不包含这些更新。

**[下载 macOS 版（Apple Silicon）](https://github.com/lixiang0106/comfydraw/releases/latest)** · [Download for macOS](https://github.com/lixiang0106/comfydraw/releases/latest) · [从源码构建](#option-b--build-from-source)

---

## Features

- **Text to image** — prompt, size, steps, seed, batch.
- **Image to image** — pick a reference picture and redraw it with a strength slider.
- **Document to prompt** — extract text from PDF/Word and ask a local OpenAI-compatible model for an image prompt.
- **Local history** — every result is archived on disk with its parameters.
- **No browser, no extra window** — ComfyDraw can start an existing local ComfyUI engine in the background.
- **Loopback connections** — the app's drawing and document requests accept local HTTP endpoints; redirects are refused and the app sends no telemetry.

## Requirements

- macOS 14 or later and Apple Silicon (arm64). The current build script targets arm64.
- **ComfyUI** — either [Comfy Desktop](https://www.comfy.org/download) or a manual install with a `.venv` inside the ComfyUI folder.
- **ComfyUI-GGUF** custom node: the current built-in workflow always uses its `UnetLoaderGGUF` node and a GGUF diffusion model.
- **Qwen Image models** (the built-in workflow targets this family):

  | Role | File |
  | --- | --- |
  | Diffusion model | `qwen-image-2.1-UC-Q6_K.gguf` |
  | Text encoder | `qwen3vl_8b_bf16.safetensors` |
  | VAE | `qwen_image_2.1_vae_bf16.safetensors` |

  Compatibility depends on the selected GGUF diffusion model, text encoder, VAE, and ComfyUI nodes. Other combinations are not guaranteed to work.

Document analysis is optional and needs a local OpenAI-compatible endpoint (for example oMLX) and its API key. PDF extraction additionally requires `pdftotext` at one of the paths supported by the app. Word and RTF extraction uses macOS `textutil`.

## Install

### Option A — prebuilt app

1. Download the latest release DMG or ZIP and drag the enclosed `ComfyDraw.app` into `Applications`.
2. The build is ad-hoc signed, so the first launch may require **right-click → Open** or `System Settings → Privacy & Security → Open Anyway`.
3. Launch it. ComfyDraw looks for `127.0.0.1:8188`; if nothing is listening it tries to start a local ComfyUI it can find.

### Option B — build from source

```bash
git clone https://github.com/lixiang0106/comfydraw.git
cd comfydraw
./build.sh          # creates ComfyDraw.app if the path does not already exist
open ComfyDraw.app
```

`build.sh` needs the Swift toolchain (`xcode-select --install` is enough; Xcode is not required). It refuses to overwrite an existing output. To build alongside an existing app, supply another `.app` path whose parent directory already exists, for example `./build.sh /tmp/ComfyDraw-test.app`.

## First run

Open **设置 (Settings)** in the app:

- **绘图引擎** — shows which ComfyUI install was detected. If detection misses it, press 选择… and point at the folder that contains `main.py`. Turn auto-start off if you prefer to launch ComfyUI yourself.
- **后端地址** — defaults to `http://127.0.0.1:8188`. Only loopback addresses are accepted.
- **文档分析** — optional loopback base URL and API key for a local text model. A manually entered key is saved in macOS Keychain; leaving it blank uses a saved key or, if none is saved, attempts to read the existing local oMLX configuration. Access may require Keychain authorization. To replace an existing saved key, first back it up securely, then use the explicit delete action before saving the new key.

Model dropdowns are filled from your ComfyUI instance, so whatever you have installed shows up automatically.

## How it works

```
ComfyDraw.app
 ├── SwiftUI interface
 ├── POST /prompt        → submit a Qwen Image workflow
 ├── GET  /history/{id}  → poll result, download PNG via /view
 └── local archive       → ~/Library/Application Support/ComfyDraw
```

In this source version, when auto-start is enabled and the configured local port is free, ComfyDraw can launch a detected ComfyUI `main.py` with `--listen 127.0.0.1`, reusing existing files where detected. The app does not terminate the engine on exit: another client may have submitted work, and a queue check alone cannot rule out a race. You can manage the remaining engine yourself. ComfyDraw never sends a global `/interrupt`.

If the new `ComfyDraw` data directory does not exist but the legacy `Local Image Desk` directory does, this source version continues using the legacy directory in place; it does not move or copy it. If both directories exist, it uses the `ComfyDraw` directory. Avoid running different app versions that write to the same history at the same time: older versions do not participate in this version's history lock.

## Known limitations

- The built-in workflow is **Qwen Image specific**. Other architectures (SDXL, FLUX, …) are not supported yet; the app warns when the selected models look incompatible.
- `cfg` is fixed at `1.0`, so the negative prompt currently has **no effect**.
- No live sampling progress — the app shows queued / running / saving instead of a percentage.
- Cancel only removes a queued job. A job that is already running keeps going.
- PDF text extraction covers the first 12 pages; analysis uses at most the first 6000 characters. No OCR for scanned files.
- Image-to-image is a *reference redraw*, not instruction-based editing.
- Ad-hoc signed and not notarized; Gatekeeper may require additional confirmation on first launch.

## Privacy

The source version accepts loopback HTTP endpoints for drawing and document analysis, refuses HTTP redirects, and sends no analytics. This restricts where this app sends requests, but it does not authenticate the process listening on the local port: that process receives prompts, reference images, document excerpts, and any applicable API key. Local proxy services, your ComfyUI installation, and installed custom nodes may have their own network behaviour that this app does not control. A manually entered key is kept in Keychain; oMLX's own settings file is not changed.

## License

[MIT](LICENSE)

---

## 中文说明

**ComfyDraw** 是一个 macOS 原生小工具，用来给本机 ComfyUI 套一层简单界面。打开就能写提示词出图，支持参考图重绘、文档转提示词、本地历史记录，不需要开浏览器，也不用面对节点图。

### 使用前提

- macOS 14 及以上、Apple Silicon（arm64）。
- 本机已装 ComfyUI（Comfy Desktop 或手动安装，目录里带 `.venv`）。
- 需要 ComfyUI-GGUF 插件：内置工作流始终使用其 GGUF 加载节点。
- 内置工作流面向 **Qwen Image**，需要匹配的 GGUF 扩散模型、文本编码器和 VAE；其他模型组合尚未保证兼容。
- 可选的 PDF 文档提取需要安装 `pdftotext`；Word/RTF 使用 macOS 自带的 `textutil`。

### 安装

下载 Release 的 DMG 或 ZIP，将其中的 `ComfyDraw.app` 拖进「应用程序」。因为是本地签名，第一次打开可能需要**右键 → 打开**，或在「系统设置 → 隐私与安全性」中确认。也可以自己编译：`./build.sh`；构建脚本不会覆盖已有的同名 App。

### 第一次使用

打开软件左边的「设置」：

- 会自动检测 Comfy Desktop 安装的实例；没检测到就手动选 ComfyUI 目录（包含 `main.py` 那一层）。
- 后端地址默认 `http://127.0.0.1:8188`，只接受本机地址。
- 不用文档功能的话，文档分析那一段可以全部留空。需要替换已经保存的 Key 时，请先安全备份旧 Key，再明确执行「删除已保存的 Key」，然后保存新 Key。

在当前源码版本中，开启自动启动后，如果配置的本机端口空闲，软件可在后台启动检测到的 ComfyUI，并尝试复用已有模型和输入输出目录。由于引擎可能被其他客户端共享，退出应用时不会自动关闭引擎；可由用户自行管理后台进程。

如果新的 `ComfyDraw` 数据目录不存在，但旧的 `Local Image Desk` 目录存在，当前源码版本会继续在旧目录原地读写，不会移动或复制旧目录；如果两个目录都存在，则使用 `ComfyDraw` 目录。请避免同时运行写入同一历史目录的不同版本：旧版本不会遵守新版的历史记录锁。

### 已知限制

- 只支持 Qwen Image 系列工作流，其他模型架构暂不支持（选错会提示）。
- `cfg` 固定为 1，反向提示词目前不起作用。
- 没有实时采样进度，只有「排队 / 生成中 / 保存中」。
- 取消只对排队中的任务有效，已经在跑的任务会继续。
- PDF 只读前 12 页，分析最多用前 6000 字，扫描件不做 OCR。
- 图生图是「参考图重绘」，不是指令式修图。

### 隐私

源码版的绘图和文档分析请求只接受本机回环 HTTP 地址，拒绝重定向，不发送遥测数据。但回环地址不能证明监听端口的一定是可信服务；相应本机进程会收到提示词、参考图、文档节选及适用的 API Key。本机转发服务、ComfyUI 和第三方节点自身的网络行为不受本软件控制。手动填写的 Key 存入系统钥匙串；oMLX 自己的设置文件不会被修改。
