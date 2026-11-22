#!/bin/bash
#
# mount-esp.sh — 在 macOS 上挂载 OpenCore 所在的 ESP（EFI 系统分区），并支持开机自动挂载
#
# 为什么需要：macOS 默认不挂载 ESP。本机 OC 在 disk0s1（FAT32，卷名 "NO NAME"），
#   每次要用 ESP 上的东西（displaysrc/ocmaindisplay、核对 config.plist……）都得先
#   sudo diskutil mount。挂错分区不会开机失败（ESP 只被 OC 在引导时读），但会白折腾。
#
# 用法（无参数 = status）：
#   bash mount-esp.sh status          探测 + 挂载状态 + 守护进程状态（不需要 root）
#   bash mount-esp.sh detect          只打印选中的 ESP 设备号，如 disk0s1（不需要 root；多 ESP 时给的是优先猜测）
#   sudo bash mount-esp.sh mount      立刻挂载（幂等，已挂载则直接返回挂载点）
#   sudo bash mount-esp.sh install    安装 LaunchDaemon：开机自动挂载
#   sudo bash mount-esp.sh stop       停用守护进程并卸载 ESP（macOS 大版本更新前先跑这个）
#   sudo bash mount-esp.sh uninstall  彻底移除（保留配置文件，方便重装）
#   sudo bash mount-esp.sh plist       打印 LaunchDaemon 配置，调试用
#
# install 之后落盘的东西：
#   /Library/PrivilegedHelperTools/mount-esp.sh          脚本本体（root:wheel 755）
#   /Library/LaunchDaemons/com.local.mountesp.plist      守护进程
#   /Library/Application Support/mount-esp/mount-esp.conf  配置（root:wheel 644）
#   /var/log/mount-esp.log                               日志（launchd 重定向）
#   /Volumes/ESP -> 实际挂载点                            稳定软链，卷名带空格时好用
#
# 为什么脚本装到 /Library/PrivilegedHelperTools 而不是 /usr/local/sbin：
#   本机 /usr/local/sbin 是 admin 组可写（Homebrew 风格）。以 root 身份跑的脚本放在
#   普通用户可写的目录里，等于给这个用户一条「无条件提权」的路径 —— README §8 里
#   对「提升脚本必须落在仓库外且非用户可写」的顾虑同理。/Library/PrivilegedHelperTools
#   只有 root 可写，是放 root helper 的正确位置。
#
# 手动回滚（不用脚本也行）：
#   sudo launchctl bootout system/com.local.mountesp
#   sudo rm -f /Library/LaunchDaemons/com.local.mountesp.plist /Library/PrivilegedHelperTools/mount-esp.sh
#   sudo rm -f /Volumes/ESP
#   sudo diskutil unmount disk0s1
#
# 兼容性：/bin/bash 3.2（macOS 自带），不用 mapfile/关联数组；plutil 读 plist，
#   不解析本地化文本（本机 locale=zh_CN，"Mounted:" 之类字样不可依赖）。
# 写作约定：变量后面紧跟中文/全角标点时一律写 ${var}。bash 3.2 会把全角字符的首字节
#   当成变量名的一部分，报 "unbound variable"（实测踩过：$dev（ → dev?: unbound）。

set -euo pipefail

readonly LABEL="com.local.mountesp"
readonly HELPER="/Library/PrivilegedHelperTools/mount-esp.sh"
readonly PLIST="/Library/LaunchDaemons/${LABEL}.plist"
readonly CONF_DIR="/Library/Application Support/mount-esp"
readonly CONF="${CONF_DIR}/mount-esp.conf"
readonly LOG="/var/log/mount-esp.log"
readonly OC_MARKER="EFI/OC/config.plist"   # 判断「这是 OC 的 ESP」的标记文件

# 配置默认值（可被 mount-esp.conf 覆盖）
ESP_DISK=""              # 例 disk0s1；留空 = 自动探测
MOUNT_POINT=""           # 留空 = /Volumes/<卷名>
STABLE_LINK="/Volumes/ESP"
NO_INDEX_MARKERS=1       # 1 = 往 ESP 放 .metadata_never_index / .fseventsd/no_log
BOOT_TIMEOUT=120         # 开机等磁盘仲裁就绪的最长秒数

# 1 = 允许「挂载候选分区以确认是不是 OC 的 ESP」；status/stop/detect 走只读模式(0)
ALLOW_PROBE=1

# 由 do_mount 回填（bash 3.2 没有 local -n，用全局变量传值）
MOUNTED_DEV=""
MOUNTED_MP=""

# ---------------------------------------------------------------- 输出

# 注意：日志走 stdout，警告/错误走 stderr —— detect/status 的 stdout 要保持机读干净
log()  { _emit 1 "$*"; }
warn() { _emit 2 "警告: $*"; }
die()  { _emit 2 "错误: $*"; exit 1; }

_emit() {
    local fd="$1"; shift
    local msg
    msg="[$(date '+%F %T')] $*"
    if [ "$fd" = "2" ]; then
        printf '%s\n' "$msg" >&2
    else
        printf '%s\n' "$msg"
    fi
    # 同时在统一日志里留一份：log show --predicate 'process == "mount-esp"'
    if command -v logger >/dev/null 2>&1; then
        logger -t mount-esp -p user.notice "$*" 2>/dev/null || true
    fi
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "这个动作要 root。用：sudo bash $0 $1"
    fi
}

load_conf() {
    if [ -r "$CONF" ]; then
        # shellcheck disable=SC1090
        . "$CONF"
    fi
}

# ---------------------------------------------------------------- 探测

# plist_val <device> <key> —— 用 plist 读字段，绕开本地化文本
plist_val() {
    diskutil info -plist "$1" 2>/dev/null | plutil -extract "$2" raw -o - - 2>/dev/null || true
}

# mount_point_of <device> —— 已挂载则输出挂载点，否则输出空串
mount_point_of() {
    plist_val "$1" MountPoint
}

# efi_candidates —— 列出所有 Content=EFI 的分区（文本先粗筛，plist 再确认）
efi_candidates() {
    local dev
    for dev in $(diskutil list 2>/dev/null | awk '
            /^[[:space:]]*[0-9]+:[[:space:]]+EFI[[:space:]]/ {
                if ($NF ~ /^disk[0-9]+s[0-9]+$/) print $NF
            }' || true); do
        if [ "$(plist_val "$dev" Content)" = "EFI" ]; then
            printf '%s\n' "$dev"
        fi
    done
}

has_oc_marker() {
    [ -n "${1:-}" ] && { [ -f "$1/$OC_MARKER" ] || [ -f "$1/EFI/OC/OpenCore.efi" ]; }
}

# macos_whole_disk —— macOS 根卷所在的物理盘（如 disk0），用于给候选排序
macos_whole_disk() {
    local apfs physical
    apfs=$(diskutil info -plist / 2>/dev/null | plutil -extract ParentWholeDisk raw -o - - 2>/dev/null || true)
    if [ -n "$apfs" ]; then
        physical=$(diskutil info -plist "$apfs" 2>/dev/null \
                   | plutil -extract APFSPhysicalStores.0.APFSPhysicalStore raw -o - - 2>/dev/null || true)
        if [ -n "$physical" ]; then
            printf '%s\n' "$(printf '%s' "$physical" | sed -E 's/s[0-9]+$//')"
            return 0
        fi
        printf '%s\n' "$apfs"
    fi
}

# resolve_esp —— 决定用哪个分区，stdout 输出设备号
resolve_esp() {
    local dev

    if [ -n "$ESP_DISK" ]; then
        if [ "$(plist_val "$ESP_DISK" Content)" = "EFI" ]; then
            printf '%s\n' "$ESP_DISK"
            return 0
        fi
        warn "配置里的 ESP_DISK=$ESP_DISK 不是 EFI 分区（或已不存在），改用自动探测"
    fi

    local cands="" n=0
    for dev in $(efi_candidates); do
        cands="$cands $dev"
        n=$((n + 1))
    done
    cands=${cands# }

    if [ "$n" -eq 0 ]; then
        warn "没有找到任何 EFI 分区"
        return 1
    fi
    if [ "$n" -eq 1 ]; then
        printf '%s\n' "$cands"
        return 0
    fi

    # 多个 ESP：1) 已挂载且带 OC 标记的直接用；2) 按「与 macOS 同盘」优先逐个探测
    local mp
    for dev in $cands; do
        mp=$(mount_point_of "$dev")
        if [ -n "$mp" ] && has_oc_marker "$mp"; then
            printf '%s\n' "$dev"
            return 0
        fi
    done

    local macdisk ordered="" rest=""
    macdisk=$(macos_whole_disk || true)
    if [ -n "$macdisk" ]; then
        for dev in $cands; do
            if [ "$(plist_val "$dev" ParentWholeDisk)" = "$macdisk" ]; then
                ordered="$ordered $dev"
            fi
        done
    fi
    for dev in $cands; do
        case " $ordered " in
            *" $dev "*) ;;
            *) rest="$rest $dev" ;;
        esac
    done
    ordered=$(printf '%s %s' "${ordered# }" "${rest# }" | sed 's/^ *//;s/ *$//')

    local was_mounted
    if [ "$ALLOW_PROBE" = "1" ]; then
        for dev in $ordered; do
            mp=$(mount_point_of "$dev")
            was_mounted=0
            if [ -z "$mp" ]; then
                was_mounted=1
                diskutil mount "$dev" >/dev/null 2>&1 || continue
                mp=$(mount_point_of "$dev")
                [ -n "$mp" ] || continue
            fi
            if has_oc_marker "$mp"; then
                printf '%s\n' "$dev"
                return 0
            fi
            if [ "$was_mounted" -eq 1 ]; then
                diskutil unmount "$dev" >/dev/null 2>&1 || true
            fi
        done
        local fallback
        fallback=$(printf '%s' "$ordered" | awk '{print $1}')
        warn "所有 EFI 分区都没有 ${OC_MARKER}，回退到 ${fallback}（可在 ${CONF} 里用 ESP_DISK 指定）"
        printf '%s\n' "$fallback"
        return 0
    fi

    # 只读模式：不挂载任何分区，按优先级给第一个（可能不是 OC 的 ESP）
    local guess
    guess=$(printf '%s' "$ordered" | awk '{print $1}')
    warn "有多个 EFI 分区且都没挂载，只读模式只能按优先顺序猜 ${guess}（mount 时会逐个挂载确认；也可在 ${CONF} 里钉 ESP_DISK）"
    printf '%s\n' "$guess"
}

# ---------------------------------------------------------------- 挂载

# 防 Spotlight / fseventsd 往只有 ~170 MB 的 ESP 里写索引（README §9 的「macOS 污染」）
drop_no_index_markers() {
    local mp="$1"
    [ "$NO_INDEX_MARKERS" = "1" ] || return 0
    if [ ! -w "$mp" ]; then
        warn "ESP 是只读挂载，跳过索引标记"
        return 0
    fi
    if [ ! -e "$mp/.metadata_never_index" ]; then
        : > "$mp/.metadata_never_index" 2>/dev/null || warn "写 .metadata_never_index 失败（Spotlight 可能会索引这块盘）"
    fi
    if mkdir -p "$mp/.fseventsd" 2>/dev/null; then
        if [ ! -e "$mp/.fseventsd/no_log" ]; then
            : > "$mp/.fseventsd/no_log" 2>/dev/null || warn "写 .fseventsd/no_log 失败"
        fi
    fi
}

write_stable_link() {
    local mp="$1"
    [ -n "$STABLE_LINK" ] || return 0
    case "$STABLE_LINK" in
        /*) ;;
        *) warn "STABLE_LINK 必须是绝对路径，跳过：$STABLE_LINK"; return 0 ;;
    esac
    if [ "$mp" = "$STABLE_LINK" ]; then
        return 0
    fi
    # 目标位置已经有真实目录（不是我们建的软链）就别动
    if [ -L "$STABLE_LINK" ]; then
        ln -sfn "$mp" "$STABLE_LINK" 2>/dev/null || warn "更新软链失败：$STABLE_LINK"
    elif [ -e "$STABLE_LINK" ]; then
        warn "$STABLE_LINK 是已存在的真实路径，跳过软链"
    else
        ln -s "$mp" "$STABLE_LINK" 2>/dev/null || warn "创建软链失败：$STABLE_LINK"
    fi
}

# do_mount —— 挂载并返回 0/1，结果放 MOUNTED_DEV / MOUNTED_MP
do_mount() {
    local dev mp
    dev=$(resolve_esp) || return 1
    MOUNTED_DEV="$dev"
    mp=$(mount_point_of "$dev")

    if [ -n "$mp" ]; then
        log "$dev 已经挂载：$mp"
    else
        log "挂载 $dev ..."
        if [ -n "$MOUNT_POINT" ]; then
            mkdir -p "$MOUNT_POINT" 2>/dev/null || { warn "建挂载点失败：$MOUNT_POINT"; return 1; }
            diskutil mount -mountPoint "$MOUNT_POINT" "$dev" >/dev/null 2>&1 || true
        else
            diskutil mount "$dev" >/dev/null 2>&1 || true
        fi
        mp=$(mount_point_of "$dev")
        if [ -z "$mp" ]; then
            sleep 1
            mp=$(mount_point_of "$dev")
        fi
        if [ -z "$mp" ]; then
            warn "挂载失败：${dev}（手动试：sudo diskutil mount ${dev}）"
            return 1
        fi
        log "挂载成功：$dev -> $mp"
    fi

    MOUNTED_MP="$mp"
    if ! has_oc_marker "$mp"; then
        warn "$mp 里没有 $OC_MARKER —— 可能不是 OpenCore 那个 ESP"
    fi
    write_stable_link "$mp"
    drop_no_index_markers "$mp"
    return 0
}

# ---------------------------------------------------------------- 子命令

cmd_detect() {
    ALLOW_PROBE=0        # detect 承诺不动磁盘
    local dev
    dev=$(resolve_esp) || exit 1
    printf '%s\n' "$dev"
}

cmd_status() {
    load_conf
    ALLOW_PROBE=0        # status 不能挂载任何东西
    local macdisk
    macdisk=$(macos_whole_disk || true)
    printf '== 探测 ==\n'
    printf '  macOS 根卷物理盘: %s\n' "${macdisk:-<未识别>}"
    local dev mp state ncands=0
    for dev in $(efi_candidates); do
        ncands=$((ncands + 1))
        mp=$(mount_point_of "$dev")
        if [ -n "$mp" ]; then
            if has_oc_marker "$mp"; then
                state="已挂载 ${mp}（含 ${OC_MARKER}）"
            else
                state="已挂载 ${mp}（不含 ${OC_MARKER}）"
            fi
        else
            state="未挂载"
        fi
        printf '  %-9s 卷名=%-10s %s\n' "$dev" "$(plist_val "$dev" VolumeName)" "$state"
    done

    printf '\n== 选择 ==\n'
    if dev=$(resolve_esp 2>/dev/null); then
        printf '  将使用: %s\n' "$dev"
        if [ "$ncands" -gt 1 ] && [ -z "$(mount_point_of "$dev")" ]; then
            printf '  注意: 有 %s 个 EFI 分区且都未挂载，只读模式按「与 macOS 同盘优先」推断；\n' "$ncands"
            printf '        mount 时会逐个挂载确认，也可在配置里钉 ESP_DISK\n'
        fi
        mp=$(mount_point_of "$dev")
        printf '  当前挂载点: %s\n' "${mp:-<未挂载>}"
        if [ -n "$mp" ]; then
            printf '  剩余空间: %s\n' "$(df -H "$mp" 2>/dev/null | awk 'NR==2{print $4}')"
        fi
    else
        printf '  未找到可用的 ESP\n'
    fi
    if [ -n "$STABLE_LINK" ]; then
        if [ -L "$STABLE_LINK" ]; then
            printf '  稳定软链: %s -> %s\n' "$STABLE_LINK" "$(readlink "$STABLE_LINK")"
        else
            printf '  稳定软链: %s（未创建）\n' "$STABLE_LINK"
        fi
    fi

    printf '\n== 开机自动挂载 ==\n'
    if [ -f "$PLIST" ]; then
        printf '  plist: %s\n' "$PLIST"
    else
        printf '  plist: 未安装（sudo bash %s install）\n' "$0"
    fi
    if launchctl print "system/$LABEL" >/dev/null 2>&1; then
        printf '  状态: 已加载 (%s)\n' "$LABEL"
    else
        printf '  状态: 未加载\n'
    fi
    if [ -f "$LOG" ]; then
        printf '  最近日志: %s\n' "$LOG"
        tail -n 3 "$LOG" 2>/dev/null | sed 's/^/    /' || true
    fi
}

cmd_mount() {
    require_root mount
    load_conf
    do_mount || die "挂载失败"
    log "完成。挂载点：${MOUNTED_MP}${STABLE_LINK:+（软链 ${STABLE_LINK}）}"
    df -H "$MOUNTED_MP" 2>/dev/null | sed 's/^/    /' || true
}

plist_xml() {
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${HELPER}</string>
		<string>daemon</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
	<key>ProcessType</key>
	<string>Background</string>
	<key>ThrottleInterval</key>
	<integer>10</integer>
	<key>StandardOutPath</key>
	<string>${LOG}</string>
	<key>StandardErrorPath</key>
	<string>${LOG}</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/usr/bin:/bin:/usr/sbin:/sbin</string>
	</dict>
</dict>
</plist>
PLIST
}

default_conf() {
    cat <<'CONF'
# mount-esp.sh 配置（由 install 生成，root:wheel 644）
# 改完下次挂载/开机生效；只写 `KEY="值"` 这一种形式，脚本会直接 source 它。

# ESP 设备号，例如 "disk0s1"。留空 = 自动探测：
#   1) 只有一个 EFI 分区 → 用它
#   2) 多个 → 优先「与 macOS 根卷同一块物理盘」且含 EFI/OC 的那个
ESP_DISK=""

# 挂载点。留空 = /Volumes/<卷名>（本机是 /Volumes/NO NAME）
MOUNT_POINT=""

# 稳定软链，让脚本不用管卷名。留空 = 不建
STABLE_LINK="/Volumes/ESP"

# 1 = 往 ESP 写 .metadata_never_index / .fseventsd/no_log，防止 Spotlight 与
# fseventsd 在只有 ~170 MB 的 ESP 上写索引目录（这两类文件已被 .gitignore 排除）
NO_INDEX_MARKERS=1

# 开机等磁盘仲裁就绪的最长秒数
BOOT_TIMEOUT=120
CONF
}

cmd_install() {
    require_root install

    mkdir -p "$CONF_DIR"
    chown root:wheel "$CONF_DIR" 2>/dev/null || true
    chmod 755 "$CONF_DIR"

    if [ ! -f "$CONF" ]; then
        default_conf > "$CONF"
        chown root:wheel "$CONF"
        chmod 644 "$CONF"
        log "写入默认配置：$CONF"
    else
        log "沿用已有配置：$CONF"
    fi
    load_conf

    # 1) 先挂一次，装完立刻可用
    if do_mount; then
        log "当前挂载点：$MOUNTED_MP"
    else
        warn "现在没挂上；脚本已装好，下次开机还会重试"
    fi

    # 2) 装脚本本体（root 独占目录）
    install -m 755 -o root -g wheel "$SCRIPT_PATH" "$HELPER"
    log "脚本已装到：$HELPER"

    # 3) 装 LaunchDaemon
    plist_xml > "$PLIST"
    chown root:wheel "$PLIST"
    chmod 644 "$PLIST"
    if ! plutil -lint "$PLIST" >/dev/null 2>&1; then
        rm -f "$PLIST"
        die "生成的 plist 没通过 plutil -lint，已删除"
    fi
    launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
    launchctl enable "system/$LABEL" >/dev/null 2>&1 || true
    if ! launchctl bootstrap system "$PLIST" >/dev/null 2>&1; then
        # 部分系统需要权限数据库已刷新；再试一次
        sleep 1
        launchctl bootstrap system "$PLIST" >/dev/null 2>&1 || true
    fi

    if launchctl print "system/$LABEL" >/dev/null 2>&1; then
        log "开机自动挂载已启用：$LABEL"
    else
        warn "守护进程没加载成功，检查：sudo launchctl bootstrap system $PLIST"
        warn "日志：$LOG"
    fi

    printf '\n'
    log "完成。验证：sudo bash $0 status"
}

cmd_stop() {
    require_root stop
    load_conf
    ALLOW_PROBE=0        # 不为了判断而先挂载
    launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
    log "守护进程已停用（plist 保留，用 install 可重新启用）"
    local dev mp
    if dev=$(resolve_esp 2>/dev/null); then
        mp=$(mount_point_of "$dev")
        if [ -n "$mp" ]; then
            if diskutil unmount "$dev" >/dev/null 2>&1; then
                log "已卸载 ${dev}（${mp}）"
            else
                warn "卸载失败：${dev}（可能还有进程占用，如 Finder 里打开了 ESP）"
            fi
        else
            log "$dev 本来就没挂载"
        fi
    fi
    if [ -n "$STABLE_LINK" ] && [ -L "$STABLE_LINK" ]; then
        rm -f "$STABLE_LINK"
        log "已删除软链 $STABLE_LINK"
    fi
}

cmd_uninstall() {
    require_root uninstall
    load_conf
    ALLOW_PROBE=0
    launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
    if rm -f "$PLIST"; then log "已删除 $PLIST"; else warn "删不掉 $PLIST"; fi
    if [ -f "$HELPER" ]; then
        if rm -f "$HELPER"; then log "已删除 $HELPER"; else warn "删不掉 $HELPER"; fi
    fi
    if [ -n "$STABLE_LINK" ] && [ -L "$STABLE_LINK" ]; then
        if rm -f "$STABLE_LINK"; then log "已删除软链 $STABLE_LINK"; else warn "删不掉 $STABLE_LINK"; fi
    fi
    log "配置保留在 ${CONF}（要一起删：sudo rm -rf '${CONF_DIR}'）"
    log "ESP 不会自动卸载（内存盘上的挂载不影响下次开机）；需要卸载：sudo bash $0 stop"
}

cmd_daemon() {
    load_conf
    # 注意：这里不能写成 out=$(do_mount) ——命令替换会开子 shell，MOUNTED_DEV/MOUNTED_MP
    # 回填不到父进程（实测拿到空值）。因此重试期间直接丢弃输出，失败细节靠 logger
    # 进统一日志（log show --predicate 'process == "mount-esp"'）。
    local deadline=$((SECONDS + BOOT_TIMEOUT)) attempt=0
    while :; do
        attempt=$((attempt + 1))
        if do_mount >/dev/null 2>&1; then
            log "开机自动挂载完成：${MOUNTED_DEV} -> ${MOUNTED_MP}（第 ${attempt} 次尝试）"
            return 0
        fi
        if [ "$SECONDS" -ge "$deadline" ]; then
            warn "等磁盘仲裁 ${BOOT_TIMEOUT}s 仍未挂载成功，放弃（本次开机需要手动：sudo bash $0 mount）"
            warn "失败原因：log show --predicate 'process == \"mount-esp\"' --last 5m"
            return 0
        fi
        sleep 3
    done
}

usage() {
    sed -n '/^# 用法/,/^#$/p' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------- 入口

SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" || SCRIPT_PATH="$0"

case "${1:-status}" in
    status)    cmd_status ;;
    detect)    cmd_detect ;;
    mount)     cmd_mount ;;
    install)   cmd_install ;;
    stop)      cmd_stop ;;
    uninstall) cmd_uninstall ;;
    daemon)    cmd_daemon ;;
    plist)     plist_xml ;;
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
esac
