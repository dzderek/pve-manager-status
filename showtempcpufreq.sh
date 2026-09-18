#!/usr/bin/env bash
# PVE 9.2 cached hardware status patcher. Run as root: ./showtempcpufreq.sh [install|restore|status]
set -Eeuo pipefail
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
  [[ $EUID -eq 0 ]] || die 'Run as root.'
  command -v pveversion >/dev/null || die 'Not a Proxmox VE host.'
  [[ -f $NODES_PM && -f $MANAGER_JS ]] || die 'Expected PVE files are missing.'
}
dependencies(){
  local packages=''
  command -v sensors >/dev/null || packages="$packages lm-sensors"
  command -v smartctl >/dev/null || packages="$packages smartmontools"
  command -v python3 >/dev/null || packages="$packages python3"
  [[ -z $packages ]] && return
  info "Installing required packages:$packages"
  apt-get update
  # packages is assembled above from fixed package names only.
  apt-get install -y $packages
}
backup(){
  install -d -m 700 "$BACKUP_DIR"
  [[ -f $BACKUP_DIR/Nodes.pm.original ]] || cp -p "$NODES_PM" "$BACKUP_DIR/Nodes.pm.original"
  [[ -f $BACKUP_DIR/pvemanagerlib.js.original ]] || cp -p "$MANAGER_JS" "$BACKUP_DIR/pvemanagerlib.js.original"
}
collector(){
cat >"$COLLECTOR" <<'PY'
#!/usr/bin/env python3
import glob,json,os,re,subprocess,tempfile,time
def run(a,t):
 try:
  p=subprocess.run(a,text=True,capture_output=True,timeout=t,check=False); return p.stdout
 except (OSError,subprocess.TimeoutExpired): return ''
def temps():
 try: x=json.loads(run(['sensors','-j'],8))
 except (TypeError,json.JSONDecodeError): return []
 out=[]
 for chip,groups in x.items():
  if not re.search(r'coretemp|k10temp|zenpower|cpu|peci',chip,re.I): continue
  for group in groups.values():
   if isinstance(group,dict): out += [round(float(v),1) for k,v in group.items() if k.endswith('_input') and isinstance(v,(int,float))]
 return out
def freq():
 x=[]
 for p in glob.glob('/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq'):
  try:
   with open(p) as f: x.append(int(f.read())/1000)
  except (OSError,ValueError): pass
 return {'average_mhz':round(sum(x)/len(x)) if x else None,'minimum_mhz':round(min(x)) if x else None,'maximum_mhz':round(max(x)) if x else None}
def nvme():
 out=[]
 for dev in sorted(glob.glob('/dev/nvme[0-9]*')):
  if not re.fullmatch(r'/dev/nvme[0-9]+',dev): continue
  try: x=json.loads(run(['smartctl','-a','-j',dev],15))
  except (TypeError,json.JSONDecodeError): out.append({'device':dev,'error':'SMART data unavailable'}); continue
  h=x.get('nvme_smart_health_information_log',{}); used=h.get('percentage_used')
  out.append({'device':dev,'model':x.get('model_name') or x.get('model_number') or 'unknown','temperature_c':x.get('temperature',{}).get('current',h.get('temperature')),'health_percent':100-used if isinstance(used,(int,float)) else None,'smart_passed':x.get('smart_status',{}).get('passed'),'power_on_hours':x.get('power_on_time',{}).get('hours')})
 return out
data={'updated_at':int(time.time()),'cpu':{'temperatures_c':temps(),'frequency':freq()},'nvme':nvme()}
fd,tmp=tempfile.mkstemp(prefix='.pve-hwstatus-',dir='/run')
try:
 with os.fdopen(fd,'w') as f: json.dump(data,f,ensure_ascii=False)
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
systemctl enable --now pve-hwstatus-cache.timer
systemctl start pve-hwstatus-cache.service
}
backend(){
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
 grep -Fq '// pve-hwstatus-cache frontend begin' "$MANAGER_JS" && return
 python3 - "$MANAGER_JS" <<'PY'
import pathlib,re,sys
p=pathlib.Path(sys.argv[1]); text=p.read_text()
b=r'''
        // pve-hwstatus-cache frontend begin
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
                return q;
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
                    return d.model + ': ' + a + ', health ' + h + ', ' + smart;
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
    return match.group(1) + str(int(match.group(2)) + 90) + match.group(3) + ' // pve-hwstatus-cache original-height=' + match.group(2)
new,n=height.subn(increase,new,count=1)
if n!=1: raise SystemExit('PVE node-status height anchor not found; no file changed.')
p.write_text(new,encoding='utf-8')
PY
}
restore(){
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
 check_pve; local action=install; [[ $# -gt 0 ]] && action=$1
 case "$action" in
  install) dependencies; backup; collector; backend; frontend; systemctl restart pveproxy; info "Installed. Cache refreshes every 60 seconds; hard-refresh browser. Re-run after pve-manager upgrades." ;;
  restore|uninstall) restore; info "Removed patches and cache service. Backups remain in $BACKUP_DIR." ;;
  status) [[ -f $CACHE ]] && cat "$CACHE" || die "No cache yet: $CACHE" ;;
  *) echo "Usage: $0 {install|restore|status}" >&2; exit 2 ;;
 esac
}
main "$@"
