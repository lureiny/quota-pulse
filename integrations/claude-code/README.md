# quota-pulse → Claude Code 状态栏(降级版)

把 quota-pulse 桌面版的核心能力——「一眼看某账号还剩多少额度」——降级成一行状态栏,
接进 [Claude Code](https://code.claude.com) 的 `statusLine`。直连 sub2api、只读、不启动任何常驻进程。

```
5h [▰▰▰▰▱▱▱▱▱▱] 42% 3h20m · 7d [▰▰▰▰▰▰▰▰▰▱] 88% 5d5h
```

- 只显示**一个 sub2api 实例的一个账号**的滚动窗口(默认 `five_hour` + `seven_day`)。
- 按 utilization 上色:<70 绿 / 70–89 黄 / ≥90 红。
- 账号异常(banned / 需重新授权 / forbidden / error)优先提示。

> 小时级用量、GitHub 式热力图等留在桌面版,CLI 版**故意不做**——它只回答「现在还剩多少」。

## 一键安装(推荐)

在 Claude Code 里让它读取安装引导并照做:

```
帮我按 https://raw.githubusercontent.com/lureiny/quota-pulse/main/integrations/claude-code/install.md 安装 quota-pulse 状态栏
```

它会检查依赖、下载脚本、问你要 base_url、引导你在**自己的终端**列账号选 id 并亲手填入 admin key
(**key 全程不经过 agent**),最后接进 `settings.json`。

## 手动安装

1. 依赖:`bash`、`curl`、`jq`。
2. 下载脚本:
   ```bash
   mkdir -p ~/.claude/quota-pulse
   curl -fsSL https://raw.githubusercontent.com/lureiny/quota-pulse/main/integrations/claude-code/statusline.sh \
     -o ~/.claude/quota-pulse/statusline.sh && chmod +x ~/.claude/quota-pulse/statusline.sh
   ```
3. 配置:把 [`statusline.env.example`](./statusline.env.example) 复制到 `~/.config/quota-pulse/statusline.env`,
   填 `QP_BASE_URL` / `QP_API_KEY` / `QP_ACCOUNT_ID`,`chmod 600`。
   不知道账号 id(在你自己的终端里跑,key 用 `read -rs` 隐式输入、不留痕):
   ```bash
   read -rs -p 'admin key: ' K && echo && \
   printf 'x-api-key: %s\n' "$K" | \
   curl -fsS -H @- "https://你的base_url/api/v1/admin/accounts?page_size=200" \
     | jq -r '.data.items[] | "\(.id)\t\(.name)\t\(.platform)"'; unset K
   ```
4. 接进 `~/.claude/settings.json`(`command` 用绝对路径):
   ```json
   { "statusLine": { "type": "command", "command": "/home/user/.claude/quota-pulse/statusline.sh", "padding": 0 } }
   ```

## 配置项

全部走环境变量 / `statusline.env`,详见 [`statusline.env.example`](./statusline.env.example)。常用:

| 变量 | 默认 | 说明 |
|---|---|---|
| `QP_BASE_URL` | — | sub2api 后台地址(必填) |
| `QP_API_KEY` | — | 管理端 API Key,`x-api-key` 头(必填) |
| `QP_ACCOUNT_ID` | — | 要展示的账号 id(必填) |
| `QP_WINDOWS` | `five_hour,seven_day` | 展示哪些窗口,逗号分隔、按序 |
| `QP_TTL` | `30` | 缓存秒数(状态栏高频触发,TTL 内不打接口) |
| `QP_SOURCE` | `passive` | `passive`(便宜)/ `active`(自动附带 `force=true` 强制回源) |
| `QP_PREFIX` / `QP_SEP` | — / ` · ` | 行首前缀 / 窗口分隔符 |
| `QP_BAR_WIDTH` | `10` | 进度条格数 |
| `QP_BAR_FILL` / `QP_BAR_EMPTY` | `▰` / `▱` | 已用 / 剩余格字符 |
| `QP_BAR_LEFT` / `QP_BAR_RIGHT` | `[` / `]` | 进度条左右括号 |
| `QP_SHOW_RESET` | `1` | 每格百分比后显示重置倒计时(`0` 隐藏) |
| `QP_COLOR` | `1` | `0` 或 `NO_COLOR=1` 关闭颜色 |

## 数据来源与安全

- 端点:`GET {base}/api/v1/admin/accounts/{id}/usage?source=passive`,鉴权 `x-api-key`,只读。
- `passive` 读 sub2api 侧已缓存的窗口值(来自真实流量的响应头采样),不强制回源上游;
  想要更实时用 `QP_SOURCE=active`(更贵,会触发一次上游查询)。
- api_key 只存在 600 权限的 `statusline.env`,**不进 `settings.json`、不进仓库**。
- 本地响应缓存写在用户私有 cache 目录,文件名按 base/account/source 的匿名指纹隔离并原子替换;
  多个后台存在相同 account id 也不会串缓存。curl 的鉴权 header 从 stdin 读取,key 不进入进程 argv。
- **admin key 绝不经过任何 AI agent**:安装 / 改配置时,key 只由你本人在**独立终端**写进 `statusline.env`;
  别把 key 粘进对话、也别用 `!` 前缀运行需输入 key 的命令(都会进模型上下文 / 日志)。非密钥项
  (窗口 / 颜色 / 进度条等)才可以让 agent 帮改。若 key 曾暴露给 agent,视为泄露、去 sub2api 后台轮换。

## Codex CLI?

Codex CLI 目前**不支持**自定义命令式状态栏(`tui.status_line` 只认固定内置项,
见 openai/codex#17827),所以还无法像 Claude Code 这样直接接入。等它支持,或改用
tmux/zellij 状态栏、starship 提示符来跑本脚本——同一个 `statusline.sh` 可复用。
