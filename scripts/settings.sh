#!/bin/bash
set -euo pipefail

# ====================== 1. 基础固件自定义修改 ======================
# 移除attendedsysupgrade在线升级组件
sed -i "/attendedsysupgrade/d" $(find ./feeds/luci/collections/ -type f -name "Makefile")

# 修改系统默认LuCI主题
sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js")

# 修改后台登录默认管理IP正则（精准匹配，避免误伤）
sed -i "s/\b192\.168\.[0-9]\{1,3\}\.[0-9]\{1,3\}\b/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js")

# 后台页面增加编译日期水印标识
sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" $(find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js")

# ====================== 2. WiFi默认参数批量修改（带容错日志） ======================
WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh")
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"

if [ -n "$WIFI_SH" ] && [ -f "$WIFI_SH" ]; then
	echo "[WIFI自定义] 检测到脚本: $WIFI_SH"
	sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" "$WIFI_SH"
	sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" "$WIFI_SH"
elif [ -f "$WIFI_UC" ]; then
	echo "[WIFI自定义] 使用通用wifi配置文件: $WIFI_UC"
	sed -i "s/\bssid='.*'\b/ssid='$WRT_SSID'/g" "$WIFI_UC"
	sed -i "s/\bkey='.*'\b/key='$WRT_WORD'/g" "$WIFI_UC"
	sed -i "s/\bcountry='.*'\b/country='CN'/g" "$WIFI_UC"
	sed -i "s/\bencryption='.*'\b/encryption='psk2+ccmp'/g" "$WIFI_UC"
else
	echo "[警告] 未找到WiFi配置文件，跳过WiFi自定义操作"
fi

# ====================== 3. 修改系统基础配置：IP、主机名 ======================
CFG_FILE="./package/base-files/files/bin/config_generate"
# 替换默认管理IP
sed -i "s/\b192\.168\.[0-9]\{1,3\}\.[0-9]\{1,3\}\b/$WRT_IP/g" "$CFG_FILE"
# 修改路由器主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" "$CFG_FILE"

# ====================== 4. 写入.config编译配置（先删后写，杜绝重复项） ======================
# 基础LuCI与中文汉化
sed -i "/CONFIG_PACKAGE_luci/d" ./.config
sed -i "/CONFIG_LUCI_LANG_zh_Hans/d" ./.config
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config

# 主题配置（解决argon找不到包报错）
sed -i "/CONFIG_PACKAGE_luci-theme-$WRT_THEME/d" ./.config
sed -i "/CONFIG_PACKAGE_luci-app-$WRT_THEME-config/d" ./.config
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config

# 外部自定义插件批量导入
if [ -n "${WRT_PACKAGE:-}" ]; then
	while IFS= read -r line; do
		# 跳过空行
		[[ -z "$line" ]] && continue
		# 删除旧配置再写入
		sed -i "/$line/d" ./.config
		echo "$line" >> ./.config
	done <<< "$WRT_PACKAGE"
fi

# ====================== 5. 高通qualcommax平台专属适配（IPQ6000/5018/8074） ======================
DTS_PATH="./target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/"
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
	echo "[高通平台] 开始配置NSS网络加速"
	# 关闭官方NSS feeds源
	echo "CONFIG_FEED_nss_packages=n" >> ./.config
	echo "CONFIG_FEED_sqm_scripts_nss=n" >> ./.config
	# NSS固件版本选择
	echo "CONFIG_NSS_FIRMWARE_VERSION_11_4=n" >> ./.config
	if [[ "${WRT_CONFIG,,}" == *"ipq50"* ]]; then
		echo "CONFIG_NSS_FIRMWARE_VERSION_12_2=y" >> ./.config
	else
		echo "CONFIG_NSS_FIRMWARE_VERSION_12_5=y" >> ./.config
	fi
	# 无WiFi机型DTS替换（新增ipq6000适配）
	if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
		find "$DTS_PATH" -type f ! -iname '*nowifi*' -exec sed -i 's/ipq\(6000\|6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g' {} +
		echo "[高通平台] ipq6000/6018/8074 无WiFi设备DTS修改完成"
	fi
	# 开启高通USB串口驱动（4G模块必备）
	echo "CONFIG_PACKAGE_kmod-usb-serial-qualcomm=y" >> ./.config
fi

# ====================== 6. ARM64平台编译器优化（IPQ6000 cortex-a53） ======================
if [[ "${WRT_TARGET:-}" != *"X86"* ]]; then
	sed -i "/CONFIG_TARGET_OPTIONS/d" ./.config
	sed -i "/CONFIG_TARGET_OPTIMIZATION/d" ./.config
	echo "CONFIG_TARGET_OPTIONS=y" >> ./.config
	echo "CONFIG_TARGET_OPTIMIZATION=\"-O2 -pipe -march=armv8-a+crypto+crc -mcpu=cortex-a53+crypto+crc -mtune=cortex-a53\"" >> ./.config
fi

echo "===== 固件自定义预处理脚本执行完成 ====="
