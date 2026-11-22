# 备份：升级到 OpenCore 1.0.8 DEBUG 之前的状态

- 日期：2026-11-22（部署前快照 13:10 抓取）
- 原因：macOS 更新卡在进度条，需要换成 DEBUG 构建并打开落盘日志。本目录是**替换前原样拷出**的文件。
- 触发文档：[../../docs/2026-11-22-opencore-1.0.8-debug-boot-log.md](../../docs/2026-11-22-opencore-1.0.8-debug-boot-log.md)

## 仓库侧（替换前的构建）

| 文件 | 大小 | 说明 |
|---|---|---|
| `OpenCore.efi` | 630,784 B | 旧构建（RELEASE，具体版本号未确认） |
| `Drivers/OpenRuntime.efi` | 24,576 B | 同一旧版本 |
| `Drivers/OpenCanopy.efi` | 114,688 B | 同一旧版本 |
| `Drivers/ResetNvramEntry.efi` | 45,056 B | 同一旧版本 |
| `config.plist` | 26,390 B | 迁移到 1.0.8 schema **之前**的版本（已含 `-v`、`Target=67`） |

## ESP 侧（部署前快照）

| 文件 | 大小 | 说明 |
|---|---|---|
| `esp-BOOTx64.efi` | 3,086,728 B | ESP 上原来的 `EFI\Boot\bootx64.efi`（2026-07-26）。**来源不明**：PE32+ 但搜不到 `OpenCore`/`Clover`/`rEFInd` 标识，不是官方 ~53 KB 那套启动器 |
| `esp-config.plist` | 26,365 B | ESP 上原来的 `EFI\OC\config.plist`，**不含** `-v`（部署前 ESP 落后于仓库一个提交） |
| `esp-manifest-before.txt` | 32 KB | ESP `EFI\` 全量清单（381 个文件，含大小与时间戳），回滚核对用 |

## 回滚

完全回滚（回到旧构建）：

1. 把本目录的 `OpenCore.efi`、`Drivers\*.efi` 覆盖回仓库根目录对应路径；
2. 把 `config.plist` 覆盖回仓库根目录（它是旧 schema，必须配旧构建）；
3. 按 README §4.2 部署到 ESP；
4. `BOOTx64.efi` 也要一起换回——用 `esp-BOOTx64.efi` 覆盖 ESP 的 `EFI\Boot\bootx64.efi`；
5. **不要**只覆盖 `OpenCore.efi` 而留下 1.0.8 的驱动/启动器——版本必须成套。

只关日志、保留 1.0.8 的最小回滚见文档 §8。
