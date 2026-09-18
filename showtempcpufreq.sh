#!/usr/bin/env bash
# PVE 9.2 cached hardware status patcher.
#
# 功能：
#   1. 在 PVE 节点 Summary 页面显示 CPU 温度、CPU 频率/调速器和 NVMe SMART 状态。
#   2. 用 systemd 每 60 秒采集一次数据，缓存到 /run/pve-hwstatus.json。
#   3. PVE 网页原有的 5 秒状态请求只读取缓存，避免 smartctl 或 sensors 卡住网页。
#
# 安装时会修改（PVE 升级可能覆盖，升级后请重新执行 install）：
#   /usr/share/perl5/PVE/API2/Nodes.pm             # 向节点状态 API 增加 hwstatus 字段
#   /usr/share/pve-manager/js/pvemanagerlib.js     # 在 Summary 页面增加三行显示
#
# 命令：
#   ./showtempcpufreq.sh install    安装或重新应用补丁
#   ./showtempcpufreq.sh status     输出当前缓存 JSON，便于检查采集结果
#   ./showtempcpufreq.sh restore    删除本脚本插入的补丁和 systemd 缓存服务
set -Eeuo pipefail

# 以下路径均为 PVE 主机上的路径，不是运行脚本的当前目录。
NODES_PM=/usr/share/perl5/PVE/API2/Nodes.pm
MANAGER_JS=/usr/share/pve-manager/js/pvemanagerlib.js
COLLECTOR=/usr/local/sbin/pve-hwstatus-cache
SERVICE=/etc/systemd/system/pve-hwstatus-cache.service
TIMER=/etc/systemd/system/pve-hwstatus-cache.timer
CACHE=/run/pve-hwstatus.json
BACKUP_DIR=/root/pve-hwstatus-backup
die(){ echo "Error: $*" >&2; exit 1; }
info(){ echo "==> $*"; }
check_pve(){
  # 修改 PVE 系统文件前，确认当前身份、PVE 命令和两个目标文件都存在。
  [[ $EUID -eq 0 ]] || die 'Run as root.'
  command -v pveversion >/dev/null || die 'Not a Proxmox VE host.'
  [[ -f $NODES_PM && -f $MANAGER_JS ]] || die 'Expected PVE files are missing.'
}
dependencies(){
  # 仅安装缺失的采集依赖；不安装 CPU 功耗工具，也不设置任何 SUID 权限。
  local packages=''
  command -v sensors >/dev/null || packages="$packages lm-sensors"
  command -v smartctl >/dev/null || packages="$packages smartmontools"
  command -v python3 >/dev/null || packages="$packages python3"
  if [[ -n $packages ]]; then
    info "Installing required packages:$packages"
    apt-get update
    # packages is assembled above from fixed package names only.
    apt-get install -y $packages
  fi
}
backup(){
  # 只保留首次安装前的原始版本，防止重复安装时覆盖最初备份。
  install -d -m 700 "$BACKUP_DIR"
  [[ -f $BACKUP_DIR/Nodes.pm.original ]] || cp -p "$NODES_PM" "$BACKUP_DIR/Nodes.pm.original"
  [[ -f $BACKUP_DIR/pvemanagerlib.js.original ]] || cp -p "$MANAGER_JS" "$BACKUP_DIR/pvemanagerlib.js.original"
}
collector(){
# 此函数在 PVE 上生成 Python 采集器和两个 systemd unit 文件。
# 定时器启动后，每分钟以 root 身份执行一次采集器。
cat >"$COLLECTOR" <<'PY'
#!/usr/bin/env python3
import glob,json,os,re,subprocess,tempfile,time
# run：统一执行外部命令，并设置超时；失败时返回空字符串，避免定时任务失败。
def run(a,t):
 try:
  p=subprocess.run(a,text=True,capture_output=True,timeout=t,check=False); return p.stdout
 except (OSError,subprocess.TimeoutExpired): return ''
def temps():
 # sensors -j 以 JSON 输出传感器。仅提取常见 CPU 传感器芯片的 *_input 温度。
 try: x=json.loads(run(['sensors','-j'],8))
 except (TypeError,json.JSONDecodeError): return []
 out=[]
 for chip,groups in x.items():
  if not re.search(r'coretemp|k10temp|zenpower|cpu|peci',chip,re.I): continue
  for group in groups.values():
   if isinstance(group,dict): out += [round(float(v),1) for k,v in group.items() if k.endswith('_input') and isinstance(v,(int,float))]
 return out
def freq():
 # scaling_cur_freq 是内核导出的每个逻辑 CPU 当前频率（单位 kHz）。
 # 同时读取 policy*/scaling_governor，以获得当前调速器。
 x=[]
 governors=set()
 for p in glob.glob('/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq'):
  try:
   with open(p) as f: x.append(int(f.read())/1000)
  except (OSError,ValueError): pass
 for p in glob.glob('/sys/devices/system/cpu/cpufreq/policy*/scaling_governor'):
  try:
   with open(p) as f: governors.add(f.read().strip())
  except OSError: pass
 return {'average_mhz':round(sum(x)/len(x)) if x else None,'minimum_mhz':round(min(x)) if x else None,'maximum_mhz':round(max(x)) if x else None,'governor':' / '.join(sorted(governors)) or None}
def nvme():
 # smartctl -a -j 读取每个 NVMe 控制器的 SMART JSON。
 # 采集温度、健康度、0E（media_errors）、通电时长/次数及累计 R/W。
 out=[]
 for dev in sorted(glob.glob('/dev/nvme[0-9]*')):
  if not re.fullmatch(r'/dev/nvme[0-9]+',dev): continue
  try: x=json.loads(run(['smartctl','-a','-j',dev],15))
  except (TypeError,json.JSONDecodeError): out.append({'device':dev,'error':'SMART data unavailable'}); continue
  h=x.get('nvme_smart_health_information_log',{}); used=h.get('percentage_used')
  # NVMe 的 data unit 固定为 512,000 bytes；这里换算成十进制 TB。
  def tb(v): return round(v*512000/1000000000000,1) if isinstance(v,(int,float)) else None
  out.append({'device':dev,'model':x.get('model_name') or x.get('model_number') or 'unknown','temperature_c':x.get('temperature',{}).get('current',h.get('temperature')),'health_percent':100-used if isinstance(used,(int,float)) else None,'smart_passed':x.get('smart_status',{}).get('passed'),'media_errors':h.get('media_errors'),'power_on_hours':x.get('power_on_time',{}).get('hours'),'power_cycle_count':x.get('power_cycle_count'),'read_tb':tb(h.get('data_units_read')),'written_tb':tb(h.get('data_units_written'))})
 return out
# 最终 JSON 同时包含采集时间、CPU 信息与 NVMe 列表。
data={'updated_at':int(time.time()),'cpu':{'temperatures_c':temps(),'frequency':freq()},'nvme':nvme()}
fd,tmp=tempfile.mkstemp(prefix='.pve-hwstatus-',dir='/run')
try:
 with os.fdopen(fd,'w') as f: json.dump(data,f,ensure_ascii=False)
 # 原子替换：PVE 恰好读取文件时，仍只会读到完整的旧文件或完整的新文件。
 os.chmod(tmp,0o644); os.replace(tmp,'/run/pve-hwstatus.json')
finally:
 if os.path.exists(tmp): os.unlink(tmp)
PY
chmod 755 "$COLLECTOR"
cat >"$SERVICE" <<EOF
[Unit]
Description=Collect cached PVE hardware status
After=local-fs.target
[Service]
Type=oneshot
ExecStart=$COLLECTOR
EOF
cat >"$TIMER" <<'EOF'
[Unit]
Description=Refresh cached PVE hardware status
[Timer]
OnBootSec=45s
OnUnitActiveSec=60s
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
# enable 使其开机自动运行；start 立即创建首份缓存，无需等待一分钟。
systemctl enable --now pve-hwstatus-cache.timer
systemctl start pve-hwstatus-cache.service
}
backend(){
 # Nodes.pm 是 PVE 后端。这里只注入读取 JSON 的 Perl 代码，
 # 绝不在 API 请求中运行 sensors 或 smartctl。
 grep -Fq '# pve-hwstatus-cache backend begin' "$NODES_PM" && return
 grep -Fq 'PVE::pvecfg::version_text()' "$NODES_PM" || die 'Nodes.pm anchor not found.'
 local t; t=$(mktemp)
 cat >"$t" <<EOF
        # pve-hwstatus-cache backend begin
        # Read a cache; never run SMART or sensors in the status API request.
        \$res->{hwstatus} = eval { decode_json(file_get_contents('$CACHE')) } // {};
        # pve-hwstatus-cache backend end
EOF
 sed -i "/PVE::pvecfg::version_text()/r $t" "$NODES_PM"; rm -f "$t"
}
frontend(){
 # pvemanagerlib.js 是 PVE 打包后的 ExtJS 前端文件。
 # Python 根据“Manager Version”这个稳定锚点插入三项，而不依赖固定行号。
 grep -Fq '// pve-hwstatus-cache frontend begin' "$MANAGER_JS" && return
 python3 - "$MANAGER_JS" <<'PY'
import pathlib,re,sys
p=pathlib.Path(sys.argv[1]); text=p.read_text()
b=r'''
        // pve-hwstatus-cache frontend begin
        // 三个组件共享同一个 hwstatus JSON 字段，各自只渲染需要的部分。
        {
            itemId: 'hwtemperature',
            colspan: 2,
            printBar: false,
            title: gettext('温度(°C)'),
            textField: 'hwstatus',
            renderer: (status) => {
                if (!status || !status.cpu) return gettext('No cached hardware data');
                const c = status.cpu;
                const t = (c.temperatures_c || []).map((x) => x.toFixed(1) + '°C').join(' / ') || '-';
                return 'CPU: ' + t;
            },
        },
        {
            itemId: 'hwfrequency',
            colspan: 2,
            printBar: false,
            title: gettext('CPU频率(GHz)'),
            textField: 'hwstatus',
            renderer: (status) => {
                if (!status || !status.cpu) return gettext('No cached hardware data');
                const f = status.cpu.frequency || {};
                const q = f.average_mhz ? (f.average_mhz / 1000).toFixed(2) + ' GHz (' + f.minimum_mhz + '-' + f.maximum_mhz + ' MHz)' : '-';
                const g = '调速器: ' + (f.governor || 'unavailable');
                return q + ' | ' + g;
            },
        },
        {
            itemId: 'hwnvme',
            colspan: 2,
            printBar: false,
            title: gettext('NVMe状态'),
            textField: 'hwstatus',
            renderer: (status) => {
                if (!status) return gettext('No cached hardware data');
                const n = (status.nvme || []).map((d) => {
                    if (d.error) return d.device + ': ' + d.error;
                    const a = d.temperature_c == null ? '-' : d.temperature_c + '°C';
                    const h = d.health_percent == null ? '-' : d.health_percent + '%';
                    const smart = d.smart_passed === true ? 'SMART OK' : (d.smart_passed === false ? 'SMART warning' : 'SMART unavailable');
                    const oe = d.media_errors == null ? '-' : d.media_errors;
                    const hours = d.power_on_hours == null ? '-' : d.power_on_hours + '时';
                    const cycles = d.power_cycle_count == null ? '-' : d.power_cycle_count + '次';
                    const read = d.read_tb == null ? '-' : d.read_tb + 'T';
                    const write = d.written_tb == null ? '-' : d.written_tb + 'T';
                    return d.model + ': ' + a + ' | 健康: ' + h + ' | 0E: ' + oe + ' | 通电: ' + hours + ', ' + cycles + ' | R/W: ' + read + '/' + write + ' | ' + smart;
                }).join(' | ') || 'No NVMe device';
                return n;
            },
        },
        // pve-hwstatus-cache frontend end
'''
a=re.compile(r"(\n\s*\{\n\s*itemId:\s*'version',.*?\n\s*textField:\s*'pveversion',.*?\n\s*value:\s*'',?\n\s*\},)",re.S)
new,n=a.subn(r'\1'+b,text,count=1)
if n!=1: raise SystemExit('Manager Version widget not found; unsupported PVE UI layout.')
height=re.compile(r"(alias:\s*'widget\.pveNodeStatus',[\s\S]{0,300}?height:\s*)(\d+)(,)")
def increase(match):
    # 增加三行信息需要的高度，并把原高度写入注释，供 restore 精确恢复。
    return match.group(1) + str(int(match.group(2)) + 90) + match.group(3) + ' // pve-hwstatus-cache original-height=' + match.group(2)
new,n=height.subn(increase,new,count=1)
if n!=1: raise SystemExit('PVE node-status height anchor not found; no file changed.')
p.write_text(new,encoding='utf-8')
PY
}
restore(){
 # 只删除带有 pve-hwstatus-cache 标记的内容，不直接覆盖 PVE 包文件。
 # 这可避免还原时误把用户或新版 PVE 的其他改动一起清除。
 python3 - "$NODES_PM" "$MANAGER_JS" <<'PY'
import pathlib,re,sys
a,b=map(pathlib.Path,sys.argv[1:])
t=a.read_text(); a.write_text(re.sub(r'\n\s*# pve-hwstatus-cache backend begin.*?# pve-hwstatus-cache backend end\n','\n',t,flags=re.S))
t=b.read_text(); t=re.sub(r'\n\s*// pve-hwstatus-cache frontend begin.*?// pve-hwstatus-cache frontend end\n','\n',t,flags=re.S)
t=re.sub(r'\d+, // pve-hwstatus-cache original-height=(\d+)',r'\1,',t)
t=t.replace('440, // pve-hwstatus-cache height','350,')
b.write_text(t)
PY
 systemctl disable --now pve-hwstatus-cache.timer 2>/dev/null || true
 rm -f "$SERVICE" "$TIMER" "$COLLECTOR" "$CACHE"
 systemctl daemon-reload; systemctl restart pveproxy
}
main(){
 # 默认 install；status 不修改任何文件，restore 用于完整撤销本脚本的改动。
 check_pve; local action=install; [[ $# -gt 0 ]] && action=$1
 case "$action" in
  install) dependencies; backup; collector; backend; frontend; systemctl restart pveproxy; info "Installed. Cache refreshes every 60 seconds; hard-refresh browser. Re-run after pve-manager upgrades." ;;
  restore|uninstall) restore; info "Removed patches and cache service. Backups remain in $BACKUP_DIR." ;;
  status) [[ -f $CACHE ]] && cat "$CACHE" || die "No cache yet: $CACHE" ;;
  *) echo "Usage: $0 {install|restore|status}" >&2; exit 2 ;;
 esac
}
main "$@"
