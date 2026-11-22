#!/bin/bash
# fix-darkwake.sh — 关掉 macOS 的 CoreSmartPowerNap 定期维护唤醒
#
# 背景:
#   你的机器每约 60 分钟被唤醒一次, 日志显示原因是:
#     DarkWake from Normal Sleep [CDN] : due to RTC XDCI/Maintenance
#   每次入睡时 powerd 都会预约下一次唤醒:
#     Wake Requests [*process=powerd request=CSPNEvaluation deltaSecs=3613 ...]
#   CSPNEvaluation = CoreSmartPowerNap 评估, 由 powerd 的 Feature Flag 控制。
#   注意: 常规的 `pmset -a powernap 0` 对它无效 —— 你的 powernap 已经是 0 了,
#   但唤醒照旧。必须用 Feature Flag 从根上关掉。
#
# 用法(需要 sudo 密码):
#   sudo bash "/Volumes/NO NAME/EFI/OC/fix-darkwake.sh"
#
# 回滚:
#   sudo rm /Library/Preferences/FeatureFlags/Domain/powerd.plist
#   sudo pmset -a powernap 0 womp 0 networkoversleep 0
#   (darkwake=0 的回滚见 EFI/OC/config.plist 注释 / 备份文件)

set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 请用 sudo 运行:" >&2
    echo "  sudo bash \"$0\"" >&2
    exit 1
fi

echo "=============================================="
echo " 1. 关闭 CoreSmartPowerNap (Feature Flag)"
echo "=============================================="
mkdir -p /Library/Preferences/FeatureFlags/Domain/
defaults write /Library/Preferences/FeatureFlags/Domain/powerd.plist \
    CoreSmartPowerNap -dict Enabled -bool NO
echo "写入结果:"
defaults read /Library/Preferences/FeatureFlags/Domain/powerd.plist

echo
echo "=============================================="
echo " 2. 应用本机支持的电源设置"
echo "=============================================="
# 本机不支持 standby / autopoweroff / tcpkeepalive, 所以按能力过滤,
# 只应用 `pmset -g cap` 里真实存在的项, 避免报错和无效设置。
CAPS=$(pmset -g cap 2>/dev/null | tail -n +2 | tr -d ' ' | tr '\n' ' ')
echo "本机支持: $CAPS"
echo

apply() {
    local key="$1" val="$2"
    if echo "$CAPS" | grep -qw "$key"; then
        if pmset -a "$key" "$val" 2>/dev/null; then
            echo "  ✅ $key = $val"
        else
            echo "  ⚠️  $key 设置失败(已跳过)"
        fi
    else
        echo "  ➖ $key 本机不支持, 跳过"
    fi
}

apply powernap 0
apply womp 0
apply networkoversleep 0
apply displaysleep 30
apply disksleep 10
# 系统睡眠定时器: 1 分钟太激进, 改成 30 分钟(不影响本次修复, 但更合理)
apply sleep 30

echo
echo "=============================================="
echo " 3. 确认结果"
echo "=============================================="
pmset -g custom
echo
echo "--- 调度唤醒事件(应为空) ---"
pmset -g sched

echo
echo "=============================================="
echo " 完成"
echo "=============================================="
echo
echo "⚠️  还需要重启一次才生效, 因为:"
echo "     - Feature Flag 在 powerd 启动时读取"
echo "     - darkwake=0 (已写入 EFI config.plist 的 boot-args) 需要重新引导"
echo
echo "重启后这样验证(不需要 sudo):"
echo "    pmset -g log | grep -E 'DarkWake|Wake from' | tail -20"
echo "如果修复生效, 睡一晚后应该看不到新的 'RTC XDCI/Maintenance' 记录。"
