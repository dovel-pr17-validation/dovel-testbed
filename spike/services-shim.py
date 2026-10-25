"""act host mode ignores `services:`. Start the job's service containers with docker, publishing their ports on
the host, as GitHub does for a job running directly on the runner. Usage: services-shim.py WORKFLOW JOB 'k=v,...'"""
import json,os,re,shlex,subprocess,sys,time,yaml
wf,job,matrix=sys.argv[1],sys.argv[2],dict(x.split('=',1) for x in sys.argv[3].split(',') if x)
w=yaml.safe_load(open(wf)); j=w['jobs'][job]
if 'uses' in j: j=list(yaml.safe_load(open(j['uses'].lstrip('./') if not os.path.exists(j['uses']) else j['uses']))['jobs'].values())[0]
env={**{k:str(v) for k,v in (w.get('env') or {}).items()},**{k:str(v) for k,v in (j.get('env') or {}).items()}}
def ev(s):
    s=str(s)
    def rep(m):
        x=m.group(1).strip()
        if x.startswith('matrix.'): return matrix.get(x[7:],'')
        if x.startswith('env.'): return env.get(x[4:],'')
        mm=re.match(r"matrix\.(\w+) == '([^']*)' && '([^']*)' \|\| '([^']*)'",x)
        if mm: return mm.group(3) if matrix.get(mm.group(1))==mm.group(2) else mm.group(4)
        return ''
    return re.sub(r'\$\{\{(.*?)\}\}',rep,s)
names=[]
for sid,sp in (j.get('services') or {}).items():
    img=ev(sp.get('image','')) if isinstance(sp,dict) else ev(sp)
    if not img: print(f'service {sid}: empty image, not started'); continue
    cmd=['docker','run','-d','--name',f'svc-{sid}']
    for k,v in (sp.get('env') or {}).items(): cmd+=['-e',f'{k}={ev(v)}']
    for p in sp.get('ports') or []: cmd+=['-p',str(ev(p)) if ':' in str(p) else f'{p}:{p}']
    if sp.get('options'): cmd+=shlex.split(ev(sp['options']))
    cmd.append(img); print('+',' '.join(cmd)); subprocess.run(cmd,check=True); names.append(f'svc-{sid}')
for n in names:
    for _ in range(60):
        st=subprocess.run(['docker','inspect','-f','{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}',n],capture_output=True,text=True).stdout.strip()
        if st in ('healthy','none'): break
        time.sleep(3)
    print(f'service {n}: {st}')
