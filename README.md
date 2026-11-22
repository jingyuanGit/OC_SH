# OC_SH — OpenCore EFI 版本库（ESP 部署说明）

> 给未来的 agent：**先读这一节，再读 [changelog.md](changelog.md) 看最近改了什么，最后才去翻 git 历史。**

## 30 秒速查

| 想干什么 | 怎么做 |
|---|---|
| 看当前 ESP 挂在哪个盘符 | `mountvol`，找 `The EFI System Partition is mounted at X:\` |
| 把仓库内容推到 ESP | 在**提升权限**的 PowerShell 里 `robocopy <仓库> <ESP>\EFI\OC /E /XD .git docs backup esp /XF README.md changelog.md`，再 `robocopy <仓库>\esp <ESP>\EFI /E`（放 BOOTx64.efi） |
| 看最近改了什么 | [changelog.md](changelog.md)（只保留最近 30 天，更早的看 git log） |
| 从 ESP 拉回仓库 | 同上，源和目标反过来 |
| 普通 shell 怎么提升 | `Start-Process powershell -Verb RunAs -ArgumentList ...`（会弹一次 UAC） |

**核心事实：这个机器上，任何非提升权限的进程都读写不了 ESP。** 不是权限表坏了，不是缺盘符，也不是沙箱配置问题——`Access denied` 是 Windows 对 ESP 的保护。别在这上面浪费时间排查。

---

## 1. 这个仓库是什么

- **来源**：本机 ESP（EFI System Partition）上的 OpenCore 目录 `EFI\OC` 的完整副本。
- **用途**：在 NTFS 上编辑 + 版本化（git 可回滚），改完再部署回 ESP。ESP 上的 FAT32 不适合承载工作区和 `.git`（无 ACL、时间戳 2 秒精度、空间只有 ~167 MB 可用）。
- **远端**：`origin` → `https://github.com/jingyuanGit/OC_SH`，分支 `main`。
- **内容规模**：约 138 个文件 / 37 MB。`Kexts` 17 个、`ACPI` 6 个 SSDT、`Drivers` 5 个 efi、`Resources`（字体/图标/标签）、`OpenCore.efi`、`config.plist`。

## 2. ESP 的坐标

- 文件系统：**FAT32**，容量 299 MB（可用 ~167 MB）。
- 卷 GUID：`\\?\Volume{bb28c96d-77d4-4fc1-aadf-df3941948350}\`
- 挂载点：`D:\`（**这是后分配的盘符，会漂移，不要硬编码**）
- 目标目录：`<ESP>\EFI\OC`

同一 ESP 上还有 `EFI\Microsoft`（Windows 启动）、`EFI\Apple`（macOS 启动）、`EFI\BOOT`。**这些都是能开机的关键，一律不要删除或覆盖。**

## 3. 为什么必须提升权限（实测结论）

本机实测，供参考、不必重做：

| 操作 | 普通权限 | 提升权限 |
|---|---|---|
| `Copy-Item` 文件到 `D:\EFI\OC` | `Access denied` | 成功，且回读内容一致 |
| `Get-ChildItem D:\EFI` | `Access denied` | 成功 |
| DSH `danger-full-access` 模式写 ESP | 仍然 `Access denied` | — |

最后一行很重要：**把 DSH 沙箱开到最大也没用**，因为拦住你的是 Windows 的 ESP ACL，不是 harness 的沙箱。

顺带的结论（同样是实测）：
- 资源管理器弹「你当前无权访问该文件夹 / 单击继续」后点「继续」，在 FAT32 的 ESP 上**修不好**——它想写 ACL，FAT32 存不了。
- 读 `E:\OC_SH` 这类 NTFS 路径通常没问题；**写**受 DSH 会话工作区边界限制，只有会话工作区内的路径可写。

## 4. 部署（push：仓库 → ESP）

### 4.1 先提交，再部署

```powershell
cd E:\OC_SH
git status
git add -A
git commit -m "deploy: <改了什么>"
```

有 commit 才有回滚点。**不要跳过这一步直接覆盖 ESP。**

### 4.2 定位 ESP 并复制

在**提升权限**的 PowerShell 里执行：

```powershell
# 1) 找到 ESP 当前盘符；没挂载就挂到 D:
$list = mountvol | Out-String
$m = [regex]::Match($list, 'The EFI System Partition is mounted at ([A-Z]):')
if ($m.Success) { $letter = $m.Groups[1].Value }
else { cmd /c 'mountvol D: /S' | Out-Null; $letter = 'D' }
$esp = "${letter}:\EFI\OC"
Write-Host "ESP -> $esp"

# 2) 部署 EFI\OC（docs/backup/esp 只是仓库内的资料与暂存，不进 ESP）
robocopy 'E:\OC_SH' $esp /E /XD .git docs backup esp /XF README.md changelog.md /R:1 /W:1 /NFL /NDL
if ($LASTEXITCODE -ge 8) { throw "robocopy failed: $LASTEXITCODE" }

# 3) 部署 EFI\BOOT（BOOTx64.efi；第一次用 1.0.8 时必须做，否则加载器和 OpenCore 版本不配套）
robocopy 'E:\OC_SH\esp' "${letter}:\EFI" /E /R:1 /W:1 /NFL /NDL
if ($LASTEXITCODE -ge 8) { throw "robocopy failed: $LASTEXITCODE" }
Write-Host "deploy OK"
```

要点：

- `/XD .git docs backup esp`：**必须**。`.git` 写进 FAT32 的 ESP 没意义，还会快速吃掉剩余空间；`docs`/`backup` 是仓库资料，`esp` 是给 `EFI\BOOT` 用的暂存区，都不该落到 `EFI\OC` 里。
- `/XF README.md changelog.md`：这两份是给仓库看的，不需要部署进 ESP。
- **不要用 `/MIR`**：它会删掉 ESP 上仓库里没有的东西，误删就开不了机。需要清理就单独、逐个确认地删。
- `/R:1 /W:1`：失败别重试 100 万次（robocopy 默认 1,000,000 次重试）。
- robocopy 退出码 `< 8` 都算正常（3 = 有复制 + 有额外项）。

### 4.3 从普通（非提升）shell 触发

agent 自己一般跑在非提升环境，用这个把活交给提升进程，**会弹一次 UAC**：

```powershell
$script = 'C:\path\to\deploy-esp.ps1'   # 里面有 4.2 的内容
$p = Start-Process powershell -Verb RunAs -PassThru `
       -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$script
$null = $p.WaitForExit(180000)
"exit=$($p.ExitCode)"
```

注意：`Start-Process -Verb RunAs` 不要加 `-RedirectStandardOutput/Input`（在受限令牌下会因命名管道失败而报 `Access is denied`）。要拿结果就让提升进程自己写一个日志文件到可写目录。

## 5. 拉取（pull：ESP → 仓库）

首次同步、或怀疑 ESP 被人（OC 引导、另一台机器、macOS 侧）改过时：

```powershell
robocopy $esp 'E:\OC_SH' /E /XD .git docs backup esp /XF README.md changelog.md /R:1 /W:1
```

拉完立刻 `git status` 看差异，再决定要不要 commit。

## 6. 部署前后检查清单

部署**前**：

- [ ] `git status` 干净、已 commit
- [ ] `git diff --stat HEAD~1` 只包含你想改的文件
- [ ] 改过 `config.plist` → 用 `ocvalidate` 校验（OpenCore 包里的 `Utilities/ocvalidate/`）
- [ ] 确认没有把 `._*`、`*.bak-*`、`oldConfig.plist` 之类的垃圾提交进来（见 `.gitignore`）

部署**后**：

- [ ] robocopy 退出码 < 8
- [ ] ESP 上 `OpenCore.efi`、`config.plist` 的时间戳已更新
- [ ] ESP 上 `EFI\Microsoft`、`EFI\Apple`、`EFI\BOOT` 仍在（没被 `/MIR` 之类误删）
- [ ] 重启前想清楚怎么回滚：`git revert` 或 `git checkout <commit> -- .` 后重新部署

## 7. 绝对不要做的事

1. **格式化、重建、resize ESP**（`diskpart` 的 `format` / `clean` / `create partition efi`）。ESP 一坏，Windows 和 macOS 都开不了机。
2. **删除 `EFI\Microsoft`、`EFI\Apple`、`EFI\BOOT`**。
3. **用 `/MIR` 部署**。
4. **往 ESP 写 `.git`**。
5. 把 ESP 当日常编辑目录（编辑器自动保存、临时文件、锁文件都会撞上 ACL 和空间问题）。

## 8. 可选：把 UAC 点击也去掉（未默认启用）

建一个以当前用户、`RunLevel Highest` 运行的计划任务，动作是**仓库外**的固定脚本（例如 `C:\HackOS\bin\deploy-esp.cmd`），之后 `schtasks /run /tn ESP-Deploy` 即可免 UAC 触发。

- 任务建立需要一次管理员授权。
- 脚本必须在仓库外：如果提升脚本落在 agent 可写的目录里，等于给 agent 一个「以管理员跑任意代码」的持久后门。

## 9. 已知坑

- **盘符漂移**：`D:` 是后分配的。优先用 `mountvol` 动态解析，或用卷 GUID 路径 `\\?\Volume{bb28c96d-...}\EFI\OC`。
- **macOS 污染**：从 macOS 侧写过 ESP 后会出现 `._*`（AppleDouble）、`.Spotlight-V100`、`.fseventsd`，别提交。
- **Keystore/序列号**：`config.plist` 里有 `PlatformInfo` 的序列号和 SMBIOS 信息。推到公开仓库前想清楚；要公开就先清理或改用私有仓库。
- **仓库体积**：`Kexts\itlwm.kext`(16 MB)、`IntelBluetoothFirmware.kext`(11 MB) 是二进制大件，GitHub 单文件 100 MB 限制没问题，但别再加更大的东西进去。
- **当前处于调试态**（2026-11-22 起）：OpenCore 是 1.0.8 **DEBUG** 构建，`boot-args` 带 `-v keepsyms=1 debug=0x100`，`Misc > Debug > Target=67` 会往 ESP 根目录写 `opencore-*.txt`。开机变慢、每次引导多一个日志文件都是预期行为；定位完按 [docs/2026-11-22-opencore-1.0.8-debug-boot-log.md](docs/2026-11-22-opencore-1.0.8-debug-boot-log.md) §8 回滚。

## 10. 文件布局

```
E:\OC_SH\
├─ README.md          ← 本文件（部署与坑）
├─ changelog.md       ← 最近 30 天改动索引（agent 读完 README 就读它）
├─ docs\              ← 每次操作的详细记录，YYYY-MM-DD-<slug>.md
├─ backup\            ← 替换二进制前的旧构建备份（不进 ESP）
├─ esp\               ← 只放 EFI\BOOT 下的文件（BOOTx64.efi），部署时单独 robocopy
├─ config.plist       ← OC 主配置
├─ OpenCore.efi
├─ ACPI\              ← SSDT-*.aml
├─ Drivers\           ← OpenRuntime / OpenCanopy / ResetNvramEntry / HfsPlus / apfs_aligned
├─ Kexts\             ← 17 个 kext（Lilu / VirtualSMC / NootRX / itlwm / Intel 蓝牙 / 网卡 / USB 映射 …）
├─ Resources\         ← 开机菜单字体、图标、标签
├─ Tools\
└─ displaysrc\        ← 显示相关源码（ocmaindisplay / usbmap）
```
