# 安装 quota-pulse 状态栏到 Claude Code(给 Claude Code 执行的引导)

> 你(Claude Code)正在帮用户安装 **quota-pulse 的 Claude Code 状态栏**:一个直连 sub2api、
> 在状态栏显示某个账号 5h/7d 用量的小脚本。请**按下面步骤逐步执行**,每一步做完向用户确认。
> 全程只读 sub2api、只写用户本机的两个文件(脚本 + 配置 + settings.json 的 statusLine 段)。
> **绝不要把用户的 api_key 回显到对话里、也不要写进 settings.json**——它只进 600 权限的 env 文件。

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

## 步骤 3 — 收集配置(base_url + api_key)

向用户询问两项(**api_key 让用户直接粘贴,你不要复述、不要写进对话可见处**):

1. sub2api 后台地址,例如 `https://sub2api.example.com`
2. sub2api 管理端 API Key(用于 `x-api-key` 头)

## 步骤 4 — 帮用户选账号 id

用刚拿到的凭据列出账号,展示 `id / name / platform` 让用户挑一个(把 `$BASE`/`$KEY` 换成实际值,
**不要把带 key 的完整命令留在对话里**,跑完即可):

```bash
curl -fsS -H "x-api-key: $KEY" "$BASE/api/v1/admin/accounts?page_size=200" \
  | jq -r '.data.items[] | "\(.id)\t\(.name)\t\(.platform)\t\(.status)"'
```

把结果做成表格给用户,让其选定一个 `id`。

## 步骤 5 — 写配置文件(600 权限)

创建 `~/.config/quota-pulse/statusline.env`,权限 600。用 heredoc 写入(把三个值替换为实际值):

```bash
mkdir -p ~/.config/quota-pulse
umask 177   # 保证新文件 600
cat > ~/.config/quota-pulse/statusline.env <<'EOF'
QP_BASE_URL="<用户的 base_url>"
QP_API_KEY="<用户的 api_key>"
QP_ACCOUNT_ID="<用户选的账号 id>"
# 可选:QP_WINDOWS / QP_TTL / QP_SOURCE / QP_PREFIX,详见仓库 statusline.env.example
EOF
chmod 600 ~/.config/quota-pulse/statusline.env
```

写完 `ls -l ~/.config/quota-pulse/statusline.env` 确认是 `-rw-------`。

## 步骤 6 — 先跑一次验证能取到数

```bash
~/.claude/quota-pulse/statusline.sh
```

应输出类似 `5h 42% · 7d 68%`(带颜色)。若显示 `qp: 未配置` / `qp: --` / `qp: ⚠ error`,
回头核对 base_url、api_key、account_id;`qp: 缺少 jq` 则回步骤 1。也可以喂假数据验证格式:

```bash
QP_BASE_URL=x QP_API_KEY=x QP_ACCOUNT_ID=1 \
  QP_FIXTURE='{"five_hour":{"utilization":42},"seven_day":{"utilization":88}}' \
  ~/.claude/quota-pulse/statusline.sh
```

## 步骤 7 — 接进 Claude Code 的 statusLine

把 `statusLine` 段**合并**进 `~/.claude/settings.json`(**保留已有其它键**,只加/改 statusLine)。
注意 `command` 必须是**绝对路径**(Claude Code 不做 `~` 展开),用 `$HOME` 展开后的真实路径:

期望的合并结果(示意):

```json
{
  "statusLine": {
    "type": "command",
    "command": "/Users/<you>/.claude/quota-pulse/statusline.sh",
    "padding": 0
  }
}
```

实现时优先用 jq 原地合并、保留原文件其它字段:

```bash
SL="$HOME/.claude/quota-pulse/statusline.sh"
F="$HOME/.claude/settings.json"
[ -f "$F" ] || echo '{}' > "$F"
tmp=$(mktemp)
jq --arg cmd "$SL" '.statusLine = {type:"command", command:$cmd, padding:0}' "$F" > "$tmp" && mv "$tmp" "$F"
```

## 步骤 8 — 收尾提示

告诉用户:

- 状态栏会在**每条回复后**刷新(300ms 去抖);脚本内置 30s 缓存,所以不会每次都真打接口。
- 想让空闲时也定时刷新,可在 `statusLine` 里加 `"refreshInterval": 5000`(毫秒)。
- 想改展示窗口/颜色/前缀,编辑 `~/.config/quota-pulse/statusline.env`(可选项见仓库
  `integrations/claude-code/statusline.env.example`)。
- 卸载:从 `settings.json` 删掉 `statusLine` 段即可;脚本和 env 文件可一并删除。

装完在这里概述一下你改动了哪些文件,让用户心里有数。
