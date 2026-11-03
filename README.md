# instabox-keeper

用 GitHub Actions 给免费的 InstaBox 机器做「跑 7 小时 50 分钟 → 停 10 分钟 → 自动继续」的循环。

跑在 GitHub 的服务器上，所以：不需要你的电脑开机，不需要公网入口，也不需要那台云主机自己活着。
runner 只做一件事——出站访问 `api.instabox.sh`。

## 它每次被叫醒时做什么

调度是每 10 分钟一次，每次只判断一件事：

| 机器的状态 | 动作 |
|---|---|
| `running` 且已连续跑满 470 分钟 | 停 → 保持 10 分钟 → 起（同一个 job 内完成，间隔精确） |
| `running` 但还没到 470 分钟 | 什么都不做 |
| `suspended` / `stopped` 且冷却已过 | 直接拉起（这是平台到点回收后的兜底） |
| 冷却中 | 等待，什么都不做 |

连续运行时间优先取 API 返回的 `startedAt`，取不到才退回仓库里的 `state.json`。

## 部署

### 1. 建仓库

**建议用 public 仓库**，原因见下面「费用」。把本目录整个推上去即可：

```bash
cd instabox-keeper
git init -b main
git add -A
git commit -m "init"
gh repo create instabox-keeper --public --source=. --push
```

### 2. 加两个配置

```bash
# 必填：InstaBox 后台的 API key
gh secret set INSTABOX_API_KEY

# 可选：机器 ID（不设就用 workflow 里的默认值）
gh variable set INSTABOX_MACHINE_ID
```

### 3. 手动跑一次验证

```bash
gh workflow run instabox-keeper.yml
gh run watch
```

日志里应该出现 `已连续运行 N 分钟`。第一次跑如果机器正开着且没到点，会显示
`还没到 470 分钟，继续跑` —— 这是正常的。

## 费用

GitHub Actions 对 **public 仓库不限分钟数**，对 private 仓库每月 2000 分钟（免费额度）。

这个 workflow 每 10 分钟跑一次 = 每天 144 次。按每次最少 1 分钟计费：

| 仓库类型 | 每天 | 每月 | 结论 |
|---|---|---|---|
| public | 144 分钟（不计量） | 0 | 随便用 |
| private | 144 分钟 | ≈4300 分钟 | **超免费额度** |

要用 private 仓库的话，把 cron 从 `*/10` 改成 `*/30`（降 3 倍到 ≈1440 分钟/月），
代价是停机时间会变成 10–40 分钟不等，且更容易撞上平台 480 分钟上限（见下）。

## 必须知道的几个坑

**GitHub 的 cron 不准。** 高峰期会延迟几分钟到十几分钟，最小粒度 5 分钟。
所以「跑满 470 分钟」实际可能落在 470–490 分钟之间。

**这正好卡在平台上限旁边。** 免费计划的 `maxRunMinutes` 是 480 分钟，撞上它之后
平台自己会暂停，并且冷却期会从 10 分钟升级到 60–135 分钟。470 这个值就是留了 10 分钟
余量给 cron 的延迟，但仍然不是绝对安全 —— 如果你发现每次都要等一个多小时才恢复，
就把 `RUN_MINUTES` 调小到 `430` 左右（workflow 里的 env）。

**长时间没有活动，定时任务会被停用。** GitHub 在仓库 60 天无提交后会暂停 scheduled
workflow。这个设计里 `state.json` 会被自动提交，正好能续命；但如果你长期没到点触发、
一次都没提交过，记得回来点一下 `gh workflow run` 或随便提交个东西。

**停 10 分钟是物理停机。** 那 10 分钟里机器上的服务和 `instabox.tech` 的公网映射都是断的。

## 本地测试

不联网、不用真 API key，用假 API 跑完整流程：

```bash
# 需要 bash（Git Bash 即可）和 python3
PY_BIN=$(command -v python3) bash test/run_test.sh
```

覆盖 4 个场景：到点循环、未到点不动、平台停掉后拉起、冷却期内等待。

## 文件

```
keeper.sh                          # 全部逻辑
.github/workflows/instabox-keeper.yml
test/mock_instabox.py              # 假 API
test/run_test.sh                   # 10 条断言
```
