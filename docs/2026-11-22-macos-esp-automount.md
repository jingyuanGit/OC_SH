# 2026-11-22 macOS 开机自动挂载 ESP（mount-esp.sh）

- **状态**：脚本入库，**尚未在真机安装**（安装要 sudo，本次没执行；步骤见 §5）
- **目标**：macOS 下不用每次手动 `sudo diskutil mount disk0s1` 就能用到 ESP 上的东西
- **产物**：[mount-esp.sh](../mount-esp.sh)

---

## 1. 为什么需要

macOS 默认不挂载 ESP。本机 OC 在 `disk0s1`（FAT32，卷名 `NO NAME`，300 MiB），
凡是需要读 ESP 的动作都得先手动挂载：

- `install-daemon.sh` 要从 `/Volumes/NO NAME/EFI/OC/displaysrc/ocmaindisplay` 拷二进制；
- 核对 ESP 上的 `config.plist` 是否与仓库一致（README §6 的部署后检查）；
- 从 macOS 侧取 `opencore-*.txt` 启动日志（docs/2026-11-22-opencore-1.0.8-debug-boot-log.md §6）。

## 2. 为什么是 LaunchDaemon + diskutil，而不是别的方案

| 方案 | 结论 |
|---|---|
| **LaunchDaemon 跑 `diskutil mount`**（采用） | 开机早期、不依赖登录、不需要给用户加 sudo 规则；`diskutil` 走 DiskArbitration，Finder 能看见、`diskutil unmount` 能卸载 |
| `/etc/fstab` 写死挂载项 | ESP 是 DiskArbitration **故意不自动挂载**的类型，fstab 对它不可靠；而且改 fstab 出问题时更难排查 |
| LaunchAgent + `sudoers` NOPASSWD 规则 | 要新增一条永久提权规则（`diskutil` 参数还得锁死），等价于给自己开后门；能用一个 root 守护进程解决就别动 sudoers |
| 把 ESP 上需要的东西拷到本地 | 只解决单个用途（如 ocmaindisplay），看日志、核对配置仍然要挂载 |

## 3. 脚本做了什么

```
bash mount-esp.sh status      # 只读：候选 ESP、选中哪个、挂载点、守护进程状态
bash mount-esp.sh detect      # 只打印设备号，如 disk0s1
sudo bash mount-esp.sh mount  # 立刻挂载（幂等）
sudo bash mount-esp.sh install    # 装 LaunchDaemon：开机自动挂载
sudo bash mount-esp.sh stop       # 停守护进程 + 卸载（大版本更新前用）
sudo bash mount-esp.sh uninstall  # 彻底移除（保留配置）
```

安装后落盘：

| 路径 | 说明 |
|---|---|
| `/Library/PrivilegedHelperTools/mount-esp.sh` | 脚本本体，root:wheel 755 |
| `/Library/LaunchDaemons/com.local.mountesp.plist` | `RunAtLoad`，root 身份跑 `mount-esp.sh daemon` |
| `/Library/Application Support/mount-esp/mount-esp.conf` | 配置（`ESP_DISK` / `MOUNT_POINT` / `STABLE_LINK` / `NO_INDEX_MARKERS` / `BOOT_TIMEOUT`） |
| `/var/log/mount-esp.log` | launchd 重定向的 stdout/stderr，另有 `logger` 副本（`log show --predicate 'process == "mount-esp"'`） |
| `/Volumes/ESP -> /Volumes/NO NAME` | 稳定软链，省得脚本里写带空格的卷名 |

几个设计决定：

1. **脚本放 `/Library/PrivilegedHelperTools`，不放 `/usr/local/sbin`。** 本机 `/usr/local/sbin` 是 admin 组可写；把 root 脚本放在普通用户可写的目录里，等于给这个用户一条无条件提权路径——和 README §8 对「提升脚本不能落在 agent 可写目录」的顾虑是同一件事。
2. **探测不写死 `disk0s1`。** 顺序：配置里钉的 `ESP_DISK` → 只有一个 EFI 分区就用它 → 多个时优先「与 macOS 根卷同一块物理盘」且含 `EFI/OC/config.plist` 的那个，仍不能确认就逐个挂载看标记。**`status`/`stop`/`detect` 走只读模式，不会为了判断而挂任何分区。**
3. **`boot` 阶段等磁盘仲裁。** `RunAtLoad` 很早，`diskutil` 可能还没有 DA 可用；守护进程最多等 `BOOT_TIMEOUT=120` 秒（3 秒一档，成功即退出，不是常驻进程）。
4. **幂等。** 已挂载就直接返回挂载点；`install` 可重复执行（先 `bootout` 再 `bootstrap`）。
5. **不碰 ESP 上的 `EFI\Microsoft` / `EFI\Apple` / `EFI\BOOT`。** 只挂载，只读业务内容，不写。

## 4. 防「macOS 污染」

ESP 只剩约 170 MB，而 Spotlight 与 fseventsd 会往上写 `.Spotlight-V100` / `.fseventsd`（README §9 记的就是这个坑）。挂载成功后脚本会放两个纯标记文件：

- `.metadata_never_index` —— 告诉 Spotlight 别索引这块盘
- `.fseventsd/no_log` —— 告诉 fseventsd 别记录事件

两个都在仓库 `.gitignore` 里已有/已补，pull 回仓库时不会变成待提交垃圾。
要关掉这个行为：配置里 `NO_INDEX_MARKERS=0`。

## 5. 安装与验证（需在 macOS 终端里手敲，因为有 sudo 密码）

```bash
cd /Users/chenjingyuan/projects/OC_SH      # 或 ESP 上的 EFI/OC/

# 1) 先看探测结果对不对（不需要 root）
bash mount-esp.sh status
#    期望：disk0s1 卷名=NO NAME，选择为 disk0s1

# 2) 安装
sudo bash mount-esp.sh install

# 3) 验证：立刻生效
ls -l /Volumes/ESP/EFI/OC/config.plist
df -h "/Volumes/NO NAME"
launchctl print system/com.local.mountesp | head -20
tail -5 /var/log/mount-esp.log

# 4) 验证：开机生效 —— 重启后不要再手动 mount，直接
bash mount-esp.sh status
```

## 6. 回滚

```bash
sudo bash mount-esp.sh uninstall      # 删 plist / helper / 软链，保留配置
sudo rm -rf '/Library/Application Support/mount-esp'
sudo bash mount-esp.sh stop           # 只临时停用 + 卸载（大版本更新前后用这个）
```

完全手动等价操作见脚本头部注释。

## 7. 风险与注意

- **macOS 大版本更新 / 固件更新期间**：系统可能会自己去挂/写 ESP，占用冲突会让更新报「无法挂载 EFI 分区」之类的错。**升级前先 `sudo bash mount-esp.sh stop`**，升级完再 `install`。这条尤其重要——本机当前正因为「macOS 更新卡在进度条」处于调试态（见 docs/2026-11-22-opencore-1.0.8-debug-boot-log.md），排障期间先别装这个守护进程，免得引入第二个变量。
- **双系统安全**：脚本只做 `mount`/`unmount`，不写 `EFI\Microsoft`、`EFI\Apple`、`EFI\BOOT`、`EFI\OC` 里的业务文件（只额外放 §4 的两个标记文件）。
- **两个 macOS 安装**：本机 `disk3` 上还有一份 APFS 容器/卷（`data`）。ESP 只有一个，脚本不会选错，但这也意味着两个 macOS 共用同一份 OC 配置。
- **别把它当部署通道**：往 ESP 写文件仍按 README §4 走 Windows 提权 + robocopy，`/MIR` 依然禁止。

## 8. 本次踩到的坑

1. **bash 3.2 把全角字符吞进变量名。** `$dev（` 在 `/bin/bash` 3.2 下报 `dev?: unbound variable`——全角括号的首字节被当成了名字的一部分。脚本里凡「变量紧跟中文标点」一律写成 `${var}`，已在文件头写明约定。
2. **`diskutil` 的输出会本地化。** 本机 locale 是 `zh_CN`，`mountvol` 那种教训（README 文档 §9.2）同样适用于 `diskutil info` 的文本字段。脚本改用 `diskutil info -plist | plutil -extract` 读 `Content`/`MountPoint`/`VolumeName`，不解析人类可读文本。
3. **`plutil -extract MountPoint` 在未挂载时返回成功但输出为空**，不能靠退出码判断「是否挂载」，要判空。
4. **`launchctl bootout` 的写法。** `bootout system/<路径>` 是错的，要么 `bootout system/<label>`，要么 `bootout system <plist 路径>`；脚本统一用 `system/com.local.mountesp`。
5. **`/usr/local/sbin` 本机是 `drwxrwxr-x admin`**，不是「只有 root 能写」，所以 helper 不装那里。
6. **命令替换会丢全局回填。** 守护进程原先写成 `if out=$(do_mount 2>&1)`，`$( )` 是子 shell，`do_mount` 里给 `MOUNTED_DEV`/`MOUNTED_MP` 的赋值回不到父进程，日志打出 `开机自动挂载完成： -> `（空）。改成 `if do_mount >/dev/null 2>&1; then`，重试期的失败细节交给 `logger` 进统一日志。

## 9. 本次怎么验证的

真机安装要 sudo 密码，本次没执行安装；用一套 stub 的 `diskutil`/`launchctl`/`install` 做了逻辑回归（`/tmp/esptest`，临时目录，未入库）：

- 单 ESP / 多 ESP（内部 `disk0s1` + 外置 `disk5s1`）都能选对；
- 已挂载再 `mount` 是幂等的；
- `status`、`stop` 在多 ESP 且未挂载时**不挂载任何东西**；
- `install` 生成的 plist 通过 `plutil -lint`，`launchctl` 调用序列为 `bootout → enable → bootstrap → print`；
- `daemon` 入口：前两次 `diskutil mount` 失败、第三次成功时能正确回填设备号与挂载点；一直失败则在 `BOOT_TIMEOUT` 后放弃并退出 0（不常驻、不触发 launchd 节流）；
- `stop` / `uninstall` 的清理与「配置保留」符合预期；
- 真机上 `status`/`detect` 只读跑通，ESP 保持未挂载（`Mounted: No`）。

待真机确认的只剩一件事：`RunAtLoad` 时刻 `diskutil mount` 是否一次成功（失败也有 120 秒重试兜底），以及 `/Volumes/ESP` 软链在真实卷名下是否正确。
