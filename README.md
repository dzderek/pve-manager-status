### shell脚本：
codex重构
- 一键给PVE添加CPU频率和各种温度显示，NVME硬盘，机械硬盘，固态硬盘信息

### V20260918 支持pve9.2.20版本
# PVE 9.2 硬件状态显示

为 Proxmox VE 9.2 节点的 **Summary（概要）** 页面增加硬件状态信息：

- CPU 温度
- CPU 实时频率、当前最低/最高频率、调速器
- NVMe 温度、健康度、0E（介质错误数）、通电时长、通电次数、累计读写量和 SMART 状态

## 工作方式

脚本不会在 PVE 网页每次刷新时直接运行 sensors 或 smartctl。

它会创建一个 systemd 定时任务，每 60 秒采集一次硬件状态并保存到：

~~~text
/run/pve-hwstatus.json
~~~

随后，PVE Summary 页面正常轮询节点状态时只读取这个 JSON 缓存。因此即使某块 NVMe 的 SMART 查询较慢，也不会阻塞或拖慢网页管理界面。

脚本会修改以下 PVE 文件：

~~~text
/usr/share/perl5/PVE/API2/Nodes.pm
/usr/share/pve-manager/js/pvemanagerlib.js
~~~

首次安装前的原文件会备份至：

~~~text
/root/pve-hwstatus-backup/
~~~

## 要求

- Proxmox VE 9.2
- 使用 root 用户执行
- PVE 主机能访问 APT 软件源（首次安装依赖时需要）

脚本会按需安装：

~~~text
lm-sensors
smartmontools
python3
~~~

## 安装

将脚本上传到 PVE 主机，例如上传到 /root：

~~~bash
scp showtempcpufreq.sh root@PVE_IP:/root/
~~~

登录 PVE 后执行：

~~~bash
cd /root
chmod +x showtempcpufreq.sh
./showtempcpufreq.sh install
~~~

完成后，浏览器使用 Ctrl+Shift+R 或 Shift+F5 硬刷新，再打开节点的 Summary 页面。

如果 CPU 温度为空，请先检测传感器：

~~~bash
sensors-detect
sensors
~~~

## 验证与排错

查看缓存内容：

~~~bash
./showtempcpufreq.sh status
~~~

查看定时采集服务：

~~~bash
systemctl status pve-hwstatus-cache.timer
systemctl status pve-hwstatus-cache.service
~~~

手动立刻采集一次：

~~~bash
systemctl start pve-hwstatus-cache.service
~~~

查看最近的采集日志：

~~~bash
journalctl -u pve-hwstatus-cache.service -n 50 --no-pager
~~~

## 升级 PVE 后

pve-manager 升级可能覆盖被修改的 API 和前端文件。升级后重新执行：

~~~bash
cd /root
./showtempcpufreq.sh install
~~~

若升级前已经运行旧版脚本，或需要更新此脚本到新版本，先执行还原再安装：

~~~bash
./showtempcpufreq.sh restore
./showtempcpufreq.sh install
~~~

## 卸载

执行：

~~~bash
cd /root
./showtempcpufreq.sh restore
~~~

该操作会移除 PVE API/UI 补丁、systemd 定时任务、采集器和运行时缓存；依赖软件包以及 /root/pve-hwstatus-backup/ 中的备份会保留。

## 注意事项

- 每台 PVE 节点都需要分别安装。
- NVMe 统计依赖设备及驱动提供的 SMART 数据；不支持的字段会显示为 - 或 SMART unavailable。
- 此项目通过修改 PVE 的已安装文件实现 UI 扩展，不属于 Proxmox 官方功能；升级 PVE 后请检查页面并按需重新应用补丁。
- 本脚本不采集 CPU 功耗，不安装 linux-cpupower，也不修改 msr 模块或 SUID 权限。
