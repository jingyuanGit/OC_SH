# 变更索引（changelog）

> 给 agent 的读取顺序：**本文件 → 它指向的 `docs/` 文档 → 最后才是 git 历史。**
> 本文件只做索引：一句话一条，不展开细节，细节都在文档里。

## 维护规则

1. **只保留最近 30 天**的条目。每次新增条目时，把下面的「窗口起始」更新为 今天 − 30 天，并删掉日期早于它的行（渐进式披露：旧的沉到 git 里）。
2. 更早的改动不再留索引，直接查历史：`git log --since=YYYY-MM-DD --oneline --stat`。
3. 每条包含：日期、一句话改动、`docs/` 文档链接（没有文档就写 `—`）、commit 短哈希。
4. 新文档放 `docs/`，文件名 `YYYY-MM-DD-<slug>.md`；写完**必须**回到本文件加一行。
5. 条目按日期倒序（最新在最上面）。

**窗口起始：2026-10-23**（今天 2026-11-22 往前 30 天；此前的改动只看 git）

## 索引

| 日期 | 改动 | 文档 | commit |
|---|---|---|---|
| 2026-11-22 | 部署 1.0.8 DEBUG 到 ESP（D:），6 个关键文件哈希全对；补齐 ESP 侧备份（含来源不明的旧 `bootx64.efi` 3 MB） | 同上 §5.1 | —（仅部署动作，无代码提交） |
| 2026-11-22 | 升级 OpenCore 到 1.0.8 DEBUG，config 迁移到新 schema，打开落盘日志与 `-v`；旧构建备份进 `backup/` | [docs/2026-11-22-opencore-1.0.8-debug-boot-log.md](docs/2026-11-22-opencore-1.0.8-debug-boot-log.md) | `90f4bd7` |
| 2026-11-22 | 新增 `.gitattributes`：统一 LF、把 `.efi/.aml/.kext/.hex` 标为二进制，避免行尾转换破坏签名 | — | `ecba842` |
| 2026-11-22 | 打开 OpenCore 调试输出：`Target=67`、`DisplayLevel=0x80000042`、`AppleDebug`/`ApplePanic`，`boot-args` 加 `-v keepsyms=1 debug=0x100` | 同上（§2 是最终状态） | `07ab0ef` |
| 2026-11-22 | 初始化仓库：116 个文件 / 36.7 MB，含 `.gitignore`（排除 `._*`、`*.bak-*`、`oldConfig.plist`、`esp_test.txt`） | — | `3565232` |

> 窗口起始之前的改动：`git log --until=2026-10-23 --oneline --stat`
