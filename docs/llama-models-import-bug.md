# llama-models 0.3.0 import bug: `No module named 'llama_models.cli.model'`

## 问题现象

```bash
$ uv run llama-model download --source meta --model-id Llama3.1-8B
llama download: error: Download failed: No module named 'llama_models.cli.model'
```

## 根因

`llama-models` **0.3.0** 中 `download.py` 的 import 路径写错了。

**出错位置**：`.venv/lib/python3.12/site-packages/llama_models/cli/download.py` 第 464 行

```python
# 错误写法（包内源码）
from .model.safety_models import (
    prompt_guard_download_info_map,
    prompt_guard_model_sku_map,
)
```

`from .model.safety_models` 解析为 `llama_models.cli.model.safety_models`，但 `cli/` 下**没有 `model/` 子目录**。

**实际目录结构**：

```
cli/
├── __init__.py
├── download.py        # 出问题的文件
├── safety_models.py   # <-- 目标模块在这里（cli/ 的直接子级）
├── list.py
├── describe.py
├── llama.py
├── ...
```

`safety_models.py` 就在 `cli/` 目录下，根本不在什么 `cli/model/` 里。

## 修复方式

将 import 路径从 `.model.safety_models` 改为 `.safety_models`：

```python
# 正确写法
from .safety_models import (
    prompt_guard_download_info_map,
    prompt_guard_model_sku_map,
)
```

## 临时 patch

如果等不了上游修，直接改已安装的包文件：

```bash
sed -i 's/from \.model\.safety_models/from .safety_models/' \
  .venv/lib/python3.12/site-packages/llama_models/cli/download.py
```

## Llama 模型下载说明

修完上述 bug 后，下载 Llama 模型还需要授权：

### 方式一：Meta 官方源（需要签名 URL）

```bash
uv run llama-model download --source meta --model-id Llama3.1-8B --meta-url "<从邮件获取的签名URL>"
```

1. 访问 https://www.llama.com/llama-downloads/
2. 接受许可条款
3. 会收到一封邮件，内含签名 URL

### 方式二：HuggingFace（需要 token）

```bash
uv run llama-model download --source huggingface --model-id Llama3.1-8B --hf-token "<your_hf_token>"
```

需要先申请对应模型的访问权限并获取 HF token。

---

# SOCKS 代理导致下载失败: `socksio` package is not installed

## 问题现象

```bash
$ uv run llama-model download --source meta --model-id Llama3.1-8B --meta-url "..."

Failed: /home/jiao/.llama/checkpoints/Llama3.1-8B/checklist.chk       ━━ 0.0% ...
Failed: /home/jiao/.llama/checkpoints/Llama3.1-8B/tokenizer.model     ━━ 0.0% ...
Failed: /home/jiao/.llama/checkpoints/Llama3.1-8B/params.json         ━━ 0.0% ...
Failed: /home/jiao/.llama/checkpoints/Llama3.1-8B/consolidated.00.pth ━━ 0.0% ...

Some downloads failed:
- checklist.chk: ... Using SOCKS proxy, but the 'socksio' package is not installed.
  Make sure to install httpx using `pip install httpx`.
```

所有文件都报同一个错误：`Using SOCKS proxy, but the 'socksio' package is not installed.`

## 根因

系统设置了 `all_proxy=socks5://127.0.0.2:7897` 环境变量，`httpx` 会自动读取并通过 SOCKS5 代理发起请求。但 httpx 的 SOCKS 支持是**可选依赖**，需要额外安装 `socksio` 包。

## 修复方式

```bash
uv add socksio
```

或者直接 `pip install socksio`。

## 排查过程

```bash
# 检查当前环境的代理设置
$ env | grep -i proxy
all_proxy=socks5://127.0.0.2:7897
http_proxy=http://127.0.0.1:7897
https_proxy=http://127.0.0.1:7897
```

其中 `all_proxy` 设置了 SOCKS5 代理，httpx 会优先使用它。

## 绕过方式（不装 socksio）

如果不想装 `socksio`，可以在运行命令时临时取消 `all_proxy`：

```bash
env -u all_proxy uv run llama-model download --source meta --model-id Llama3.1-8B --meta-url "..."
```

因为 `http_proxy` / `https_proxy` 已经设了 HTTP 代理，httpx 可以走 HTTP 代理而不需要 SOCKS。
