"""Summarize act --json output into per-job/per-step results. Usage: summarize.py OUTDIR RC SETUP_SECS ACT_SECS"""
import json,sys,os,collections
out,rc,setup,actsecs=sys.argv[1],int(sys.argv[2]),int(sys.argv[3]),int(sys.argv[4])
jobs=collections.OrderedDict()
def J(e):
    k=(e.get('jobID') or e.get('job') or '?')+(' '+json.dumps(e.get('matrix'),sort_keys=True) if e.get('matrix') else '')
    return jobs.setdefault(k,{"job":e.get('job'),"jobID":e.get('jobID'),"matrix":e.get('matrix'),"result":None,"steps":collections.OrderedDict(),"tail":[]})
lines=0;bad=0
for line in open(os.path.join(out,'act.jsonl'),errors='replace'):
    lines+=1
    try: e=json.loads(line)
    except Exception: bad+=1; continue
    if not isinstance(e,dict): continue
    j=J(e); msg=str(e.get('msg',''))
    if e.get('jobResult'): j['result']=e['jobResult']
    sid=e.get('stepID'); 
    if isinstance(sid,list): sid='/'.join(map(str,sid))
    if e.get('step') or sid:
        key=f"{e.get('stage','')}|{sid}|{e.get('step','')}"
        st=j['steps'].setdefault(key,{"stage":e.get('stage'),"stepID":sid,"name":e.get('step'),"result":None,"t0":e.get('time'),"t1":None,"tail":[]})
        st['t1']=e.get('time')
        if e.get('stepResult'): st['result']=e['stepResult']
        if e.get('raw_output') or e.get('level') in ('error','warning') or 'exitcode' in msg.lower() or 'error' in msg.lower():
            st['tail'].append(msg.rstrip()[:400]); st['tail']=st['tail'][-40:]
    else:
        j['tail'].append(msg.rstrip()[:400]); j['tail']=j['tail'][-25:]
res={"rc":rc,"setup_secs":setup,"act_secs":actsecs,"json_lines":lines,"unparsed":bad,"jobs":[]}
for k,j in jobs.items():
    steps=[]
    for st in j['steps'].values():
        d={x:st[x] for x in ('stage','stepID','name','result','t0','t1')}
        if st['result'] not in ('success','skipped'): d['tail']=st['tail'][-30:]
        steps.append(d)
    res['jobs'].append({"key":k,"job":j['job'],"jobID":j['jobID'],"matrix":j['matrix'],"result":j['result'],"steps":steps,"tail":j['tail'] if j['result']!='success' else []})
try: res['stderr_tail']=open(os.path.join(out,'act.stderr'),errors='replace').read()[-3000:]
except Exception: pass
print(json.dumps(res,indent=1))
