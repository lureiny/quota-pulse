# 安装 quota-pulse 状态栏到 Claude Code(给 Claude Code 执行的引导)

> 你(Claude Code)正在帮用户安装 **quota-pulse 的 Claude Code 状态栏**:一个直连 sub2api、
> 在状态栏显示某个账号 5h/7d 用量的小脚本。请**按下面步骤逐步执行**,每一步做完向用户确认。
> 全程只读 sub2api;你会写用户本机的两个文件(脚本、settings.json 的 statusLine 段),
> 而**配置文件里的 api_key 由用户自己填,不经过你**——见下面的硬性安全规则。

## ⛔ 硬性安全规则(最高优先级,任何情况下不得违反)

1. **你(以及任何 AI agent:Claude Code / Codex / Cursor 等)绝不能接触 sub2api 的 admin api_key。**
   不索要、不接收、不复述、不写入任何文件、不把 key 明文放进你要执行的命令、不让 key 明文进入你的输出或对话。
   (步骤 6 的验证命令只在子 shell 里 source 配置、且只打印 HTTP 码,key 不外露,属允许。)
2. **不要**让用户把 key 粘贴进对话;**也不要**让用户用 `!` 前缀去运行「含 key」或「需要当场输入 key」的命令
   —— 这两种方式都会把内容送进模型上下文 / 日志。
3. api_key **只能由用户本人**,在一个**你读不到的独立终端**(本机 shell / SSH,不是 Claude Code 的对话或 `!`)里,
   亲手写进配置文件 `~/.config/quota-pulse/statusline.env`。
4. 你负责准备好**除 key 以外的一切**(base_url、account_id、文件骨架、命令模板),把「填 key」这一步交给用户在自己终端完成。
5. base_url 和 account_id **不是**密钥,可以正常经过你。**唯独 api_key 不行。**
6. 若用户不慎把 key 暴露给了你或对话:提醒他该 key 应视为已泄露、去 sub2api 后台**轮换**,再在独立终端重填。

源仓库:`https://github.com/lureiny/quota-pulse`(公开)。脚本原始地址:
`https://raw.githubusercontent.com/lureiny/quota-pulse/main/integrations/claude-code/statusline.sh`

---

## 步骤 1 — 检查依赖

运行 `command -v bash curl jq`。三者缺一都要先让用户装:

- **jq**:macOS `brew install jq`;Debian/Ubuntu `sudo apt install jq`;Windows(Git Bash)从 https://jqlang.github.io/jq/ 下载。
- **curl** 现代系统一般自带;**bash** macOS/Linux 自带,Windows 需 Git Bash 或 WSL。

依赖不全就停下,告诉用户装好再继续。

## 步骤 2 — 下载脚本

把脚本放到 `~/.claude/quota-pulse/statusline.sh` 并加可执行位:

```bash
mkdir -p ~/.claude/quota-pulse
curl -fsSL "https://raw.githubusercontent.com/lureiny/quota-pulse/main/integrations/claude-code/statusline.sh" \
  -o ~/.claude/quota-pulse/statusline.sh
chmod +x ~/.claude/quota-pulse/statusline.sh
```

## 步骤 3 — 只收集 base_url(**不要问 key**)

向用户询问 sub2api 后台地址,例如 `https://sub2api.example.com`。
**不要**向用户索取 api_key(见硬性规则第 1、2 条)。

## 步骤 4 — 让用户自己列账号、选 id

列账号需要 admin key,所以这一步**由用户在自己的独立终端跑,你不要代跑**(你不该持有 key)。
把下面命令的 `你的base_url` 换成步骤 3 的地址后交给用户,让他在**自己的终端**里执行(key 用 `read -rs` 隐式输入、不回显、不留痕);跑完让他只把选中的 **`id`** 告诉你(id 不是密钥):

```bash
read -rs -p 'admin key: ' K && echo && \
printf 'x-api-key: %s\n' "$K" | \
curl -fsS -H @- "https://你的base_url/api/v1/admin/accounts?page_size=200" \
  | jq -r '.data.items[] | "\(.id)\t\(.name)\t\(.platform)\t\(.status)"'; unset K
```

用户回你一个 `id` 即可。

## 步骤 5 — 写配置文件(**key 由用户在独立终端填**)

配置文件 `~/.config/quota-pulse/statusline.env` 需要三项:base_url、account_id(你已知)+ api_key(你不该碰)。
把下面这条**完整命令**里的 `实际base_url`、`实际account_id` 替换成真实值后交给用户,
让他在**自己的独立终端**里运行(**不是**粘进对话、**不是** `!` 前缀);api_key 由 `read -rs` 当场隐式输入:

```bash
mkdir -p ~/.config/quota-pulse && umask 177 && \
read -rs -p 'admin key: ' K && echo && \
printf 'QP_BASE_URL="%s"\nQP_API_KEY="%s"\nQP_ACCOUNT_ID="%s"\n' \
  "https://实际base_url" "$K" "实际account_id" > ~/.config/quota-pulse/statusline.env && \
chmod 600 ~/.config/quota-pulse/statusline.env && unset K && echo "写好了"
```

**你(agent)不要运行这条命令**——它需要 key。等用户在自己终端跑完、回你「写好了」再继续。
之后你可以 `ls -l ~/.config/quota-pulse/statusline.env` 确认权限是 `-rw-------`(这条不含 key,你可以跑)。
可选项(窗口/缓存/来源/颜色/进度条)见仓库 `integrations/claude-code/statusline.env.example`,那些非密钥项日后可由你帮改。

## 步骤 6 — 验证(以下命令都不暴露 key,你可以跑)

用户填好 key 后验证能取到数。这些命令都**不打印 key**(脚本自己读配置;探测在子 shell 里 source 配置、只回状态码):

```bash
# a) 直连探测:只回 HTTP 状态码,不打印 key
( . ~/.config/quota-pulse/statusline.env
  printf 'x-api-key: %s\n' "$QP_API_KEY" | \
  curl -s -o /dev/null -w 'HTTP %{http_code}\n' --max-time 8 -H @- \
    "${QP_BASE_URL%/}/api/v1/admin/accounts/${QP_ACCOUNT_ID}/usage?source=passive" )

# b) 实跑状态栏脚本
~/.claude/quota-pulse/statusline.sh
```

`HTTP 200` + 脚本输出类似 `5h 42% · 7d 68%`(带颜色/进度条)即成功。
`HTTP 401/403` = key 无效或未填 → 让用户回步骤 5 在**独立终端**重填(别在对话里排查 key)。
`qp: 缺少 jq` 回步骤 1。想只验证渲染格式(不需要真实 key):

```bash
QP_BASE_URL=x QP_API_KEY=x QP_ACCOUNT_ID=1 \
  QP_FIXTURE='{"five_hour":{"utilization":42},"seven_day":{"utilization":88}}' \
  ~/.claude/quota-pulse/statusline.sh
```

## 步骤 7 — 接进 Claude Code 的 statusLine

把 `statusLine` 段**合并**进 `~/.claude/settings.json`(**保留已有其它键**,只加/改 statusLine)。
注意 `command` 必须是**绝对路径**(Claude Code 不做 `~` 展开),用 `$HOME` 展开后的真实路径。
若已存在 `statusLine`,先看清它指向什么、征得用户同意再覆盖。期望结果(示意):

```json
{
  "statusLine": {
    "type": "command",
    "command": "/home/user/.claude/quota-pulse/statusline.sh",
    "padding": 0
  }
}
```

用 jq 原地合并、保留原文件其它字段(此命令不含 key,你可以跑):

```bash
SL="$HOME/.claude/quota-pulse/statusline.sh"
F="$HOME/.claude/settings.json"
[ -f "$F" ] || echo '{}' > "$F"
cp "$F" "$F.qp-bak" 2>/dev/null || true      # 先备份
tmp=$(mktemp)
jq --arg cmd "$SL" '.statusLine = {type:"command", command:$cmd, padding:0}' "$F" > "$tmp" && mv "$tmp" "$F"
```

## 步骤 8 — 收尾提示

告诉用户:

- 状态栏会在**每条回复后**刷新(300ms 去抖);脚本内置 30s 缓存,所以不会每次都真打接口。
- 想让空闲时也定时刷新,可在 `statusLine` 里加 `"refreshInterval": 5000`(毫秒)。
- 想改展示窗口/颜色/进度条/前缀:编辑 `~/.config/quota-pulse/statusline.env`(可选项见仓库
  `integrations/claude-code/statusline.env.example`)。这些**非密钥项**可以让 agent 帮改。
- **但 api_key 永远只由你本人在自己的终端里编辑**,别再让 Claude Code 或任何 agent 代填 / 代改 / 代读 key。
- 卸载:从 `settings.json` 删掉 `statusLine` 段即可(有 `settings.json.qp-bak` 可回滚);脚本和 env 文件可一并删除。

装完在这里概述你改动了哪些文件,让用户心里有数(**不要**在总结里出现 key)。
