### shell脚本：
一键给PVE添加CPU频率和各种温度显示，NVME硬盘，机械硬盘，固态硬盘信息

codex重构ing，仍在实验中

### V20260918 支持pve9.2.20版本
- 每 60 秒独立采集 CPU 温度、实时频率和 NVMe SMART。
- 缓存写入 /run/pve-hwstatus.json。
- PVE Summary 的 5 秒刷新只读取缓存，不再直接执行 smartctl / sensors。
- 不再使用 SUID 权限。
- 支持 install、status、restore。
- PVE 升级覆盖 UI/API 文件后，重新运行一次 install 即可。
