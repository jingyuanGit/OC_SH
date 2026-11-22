#!/bin/bash
# install-daemon.sh — 把 ocmaindisplay 从「登录时运行」升级为「开机早期运行」的系统级守护进程。
#
# 为什么需要:
#   登录代理(LaunchAgent)要等你登录后才跑。如果机器停在登录界面，
#   那段时间菜单栏/登录窗口可能还在戴尔上。系统级守护进程(LaunchDaemon)
#   不依赖任何用户登录，开机更早就执行，把这个窗口期消掉。
#
# 用法(需要 sudo):
#   sudo bash "/Volumes/NO NAME/EFI/OC/install-daemon.sh"
#
# 卸载:
#   sudo launchctl bootout system/com.local.ocmaindisplay
#   sudo rm /Library/LaunchDaemons/com.local.ocmaindisplay.plist

set -euo pipefail

TARGET_USER="chenjingyuan"
BIN_SRC="/Volumes/NO NAME/EFI/OC/displaysrc/ocmaindisplay"
BIN_DST="/Users/${TARGET_USER}/bin/ocmaindisplay"
PLIST="/Library/LaunchDaemons/com.local.ocmaindisplay.plist"
LABEL="com.local.ocmaindisplay"

if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 请用 sudo 运行, 例如:" >&2
    echo "  sudo bash \"$0\"" >&2
    exit 1
fi

echo "==> 1/6 检查源文件"
if [ ! -f "$BIN_SRC" ]; then
    echo "错误: 找不到 $BIN_SRC" >&2
    echo "      (EFI 分区是否已挂载?)" >&2
    exit 1
fi

echo "==> 2/6 安装可执行文件到 $BIN_DST"
sudo -u "$TARGET_USER" mkdir -p "/Users/${TARGET_USER}/bin"
cp "$BIN_SRC" "$BIN_DST"
chmod 755 "$BIN_DST"
chown "${TARGET_USER}:staff" "$BIN_DST"

echo "==> 3/6 代码签名 (launchd 要求)"
codesign --force --sign - "$BIN_DST"
codesign -dv "$BIN_DST" 2>&1 | grep -i signature || true

echo "==> 4/6 写入守护进程配置"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BIN_DST}</string>
        <string>--vendor</string>
        <string>0x1E6D</string>
        <string>--product</string>
        <string>0x5BC0</string>
        <string>--retries</string>
        <string>18</string>
        <string>--delay</string>
        <string>5</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>/Users/${TARGET_USER}/Library/Logs/ocmaindisplay-daemon.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/${TARGET_USER}/Library/Logs/ocmaindisplay-daemon.log</string>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLISTEOF

chown root:wheel "$PLIST"
chmod 644 "$PLIST"
plutil -lint "$PLIST"

echo "==> 5/6 卸载旧的登录代理 (避免两者重复运行)"
if [ -f "/Users/${TARGET_USER}/Library/LaunchAgents/${LABEL}.plist" ]; then
    launchctl bootout "gui/$(id -u "$TARGET_USER")/${LABEL}" 2>/dev/null || true
    mv "/Users/${TARGET_USER}/Library/LaunchAgents/${LABEL}.plist" \
       "/Users/${TARGET_USER}/Library/LaunchAgents/${LABEL}.plist.disabled"
    echo "    旧代理已重命名为 .disabled (保留以便回滚)"
fi

echo "==> 6/6 加载守护进程"
launchctl bootout "system/${LABEL}" 2>/dev/null || true
launchctl bootstrap system "$PLIST"
launchctl enable "system/${LABEL}" 2>/dev/null || true

echo
echo "完成。守护进程状态:"
launchctl print "system/${LABEL}" 2>/dev/null | grep -E "^\s*(state|program|path) " | head -5 || true
echo
echo "日志: /Users/${TARGET_USER}/Library/Logs/ocmaindisplay-daemon.log"
echo
echo "现在可以立即测试:"
echo "  sudo launchctl kickstart -k system/${LABEL}"
echo
echo "下次重启后, 用这条命令确认它开机跑过:"
echo "  tail -5 /Users/${TARGET_USER}/Library/Logs/ocmaindisplay-daemon.log"
