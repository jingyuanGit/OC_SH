# 备份：升级到 OpenCore 1.0.8 DEBUG 之前的核心文件

- 日期：2026-11-22
- 原因：macOS 更新卡在进度条，需要换成 DEBUG 构建并打开落盘日志。本目录是**替换前原样拷出**的文件。
- 触发文档：[../../docs/2026-11-22-opencore-1.0.8-debug-boot-log.md](../../docs/2026-11-22-opencore-1.0.8-debug-boot-log.md)

## 内容

| 文件 | 大小 | 说明 |
|---|---|---|
| `OpenCore.efi` | 630,784 B | 旧构建（RELEASE，具体版本号未确认） |
| `Drivers/OpenRuntime.efi` | 24,576 B | 同一旧版本 |
| `Drivers/OpenCanopy.efi` | 114,688 B | 同一旧版本 |
| `Drivers/ResetNvramEntry.efi` | 45,056 B | 同一旧版本 |
| `config.plist` | 26,390 B | 迁移到 1.0.8 schema **之前**的版本（已含 `-v`、`Target=67`） |

## 缺口

ESP 上 `EFI\BOOT\BOOTx64.efi`（旧构建的启动加载器）**没有**备份到本目录——它不在本仓库的部署范围内，且替换前没有从 ESP 取回。

回滚前建议先把它拷进来（`D:` 换成实际 ESP 盘符）：

```powershell
# 提升权限的 PowerShell
Copy-Item 'D:\EFI\BOOT\BOOTx64.efi' 'E:\OC_SH\backup\2026-11-22-oc-before-1.0.8-debug\BOOTx64.efi'
```

## 回滚

1. 把本目录的 `OpenCore.efi`、`Drivers\*.efi` 覆盖回仓库根目录对应路径；
2. 把 `config.plist` 覆盖回仓库根目录（它是旧 schema，配旧构建）；
3. 按 README 4.2 部署到 ESP；`BOOTx64.efi` 若也换过，一并换回；
4. **不要**只覆盖 `OpenCore.efi` 而留下 1.0.8 的驱动——版本必须成套。
