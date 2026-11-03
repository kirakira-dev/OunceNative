"""Bounded-memory whole-archive translation; compressed outputs stay beside the dump."""
from pathlib import Path
import concurrent.futures,sqlite3,zlib,sys,json,hashlib,subprocess,shutil,time,collections,argparse
sys.path.insert(0, str(Path(__file__).resolve().parent))
from nx2_glslc import parse,offline_job
ap=argparse.ArgumentParser(description=__doc__)
ap.add_argument('shaders',type=Path)
ap.add_argument('compiler',type=Path)
ap.add_argument('fork',type=Path)
ap.add_argument('--workers',type=int,default=4)
args=ap.parse_args()
w=args.shaders.resolve().parent
compiler=args.compiler.resolve();stamp=hashlib.sha256(compiler.read_bytes()+Path(__file__).with_name('nx2_glslc.py').read_bytes()+Path(__file__).read_bytes()).hexdigest()[:12]
root=w/('bulk-'+stamp);root.mkdir(exist_ok=True)
frozen=root/'nx2-offline'
if not frozen.exists():shutil.copy2(compiler,frozen)
compiler=frozen
snapshots=root/'compiler-sources';snapshots.mkdir(exist_ok=True)
provenance={'compiler_sha256':hashlib.sha256(compiler.read_bytes()).hexdigest()}
for path in (Path(__file__).with_name('nx2_glslc.py'),(args.fork/'src/shader_recompiler/nx2_offline.cpp'),(args.fork/'src/shader_recompiler/frontend/ampere/lower_to_maxwell.h'),(args.fork/'src/shader_recompiler/ir_opt/constant_propagation_pass.cpp'),(args.fork/'src/shader_recompiler/backend/spirv/spirv_emit_context.h'),(args.fork/'src/shader_recompiler/backend/spirv/spirv_emit_context.cpp'),(args.fork/'src/shader_recompiler/backend/spirv/emit_spirv_context_get_set.cpp'),(args.fork/'src/shader_recompiler/backend/spirv/emit_spirv.cpp'),(args.fork/'src/shader_recompiler/runtime_info.h'),Path(__file__)):
 if path.suffix in ('.cpp','.h') and path.stat().st_mtime_ns>compiler.stat().st_mtime_ns:raise ValueError('compiler sources changed after build')
 target=snapshots/path.name
 if target.exists() and target.read_bytes()!=path.read_bytes():raise ValueError('compiler source snapshot changed')
 if not target.exists():shutil.copy2(path,target)
 provenance[path.name+'_sha256']=hashlib.sha256(target.read_bytes()).hexdigest()
provenance['fork_commit']=subprocess.run(['git','-C',args.fork,'rev-parse','HEAD'],capture_output=True,text=True,check=True).stdout.strip()
validator=Path(shutil.which('spirv-val'));provenance['spirv_val_sha256']=hashlib.sha256(validator.read_bytes()).hexdigest();provenance['spirv_val_target']='vulkan1.2'
out=sqlite3.connect(root/'translated.sqlite')
out.execute('PRAGMA journal_mode=WAL')
out.executescript('CREATE TABLE IF NOT EXISTS programs (key TEXT PRIMARY KEY, sha256 TEXT, stage INTEGER, status TEXT, error TEXT, spirv_zlib BLOB, reflection_zlib BLOB); CREATE TABLE IF NOT EXISTS provenance (key TEXT PRIMARY KEY,value TEXT);')
out.executemany('INSERT OR REPLACE INTO provenance VALUES (?,?)',provenance.items());out.commit()
source=sqlite3.connect(args.shaders.resolve().as_uri()+'?mode=ro',uri=True);done={r[0] for r in out.execute('select sha256 from programs')}
started=time.monotonic();counts=collections.Counter();submitted=0

def work(batch,index):
 d=root/f'chunk-{index:05d}';d.mkdir(exist_ok=True);jobs=[];items=[];keyinfo={}
 for sha,compressed in batch:
  sh=None
  try:
   sh=parse(zlib.decompress(compressed));job=offline_job(sh);keyinfo[sh['key']]=(sha,sh['stage']);jobs.append(job)
  except Exception as e:items.append((sh['key'] if sh else sha[:16],sha,sh['stage'] if sh else -1,'metadata_error',str(e),None,None))
 p=d/'jobs.json';p.write_text(json.dumps(jobs,separators=(',',':')))
 try:
  r=subprocess.run([str(compiler),str(p),str(d)],capture_output=True,text=True,timeout=90)
  reports={a['key']:a for a in map(json.loads,(d/'compile-report.jsonl').read_text().splitlines())} if (d/'compile-report.jsonl').exists() else {}
 except subprocess.TimeoutExpired:reports={}
 for j in jobs:
  k=j['key'];sha,st=keyinfo[k];report=reports.get(k,{})
  if report.get('status')=='ok':
   checked=subprocess.run([validator,'--target-env','vulkan1.2',d/(k+'.spv')],capture_output=True,text=True,timeout=30)
   items.append((k,sha,st,'ok' if checked.returncode==0 else 'validation_error',None if checked.returncode==0 else checked.stdout+checked.stderr,zlib.compress((d/(k+'.spv')).read_bytes(),3),zlib.compress((d/(k+'.json')).read_bytes(),3)))
  else:items.append((k,sha,st,'compiler_error',report.get('error','compiler process did not finish this job'),None,None))
 shutil.rmtree(d)
 return items

print('OUTPUT',root,flush=True)
with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
 futures=set();batch=[]
 def collect(future):
  global submitted
  rows=future.result();out.executemany('INSERT OR REPLACE INTO programs VALUES (?,?,?,?,?,?,?)',rows);out.commit();counts.update(x[3] for x in rows)
  if sum(counts.values())//2048 > submitted:
   submitted=sum(counts.values())//2048;print(sum(counts.values()),dict(counts),'seconds',round(time.monotonic()-started,1),flush=True)
 index=0
 for row in source.execute('select sha256,glslc_zlib from shaders'):
  if row[0] in done:continue
  batch.append(row)
  if len(batch)<128:continue
  futures.add(pool.submit(work,batch,index));batch=[];index+=1
  if len(futures)>=8:
   completed,futures=concurrent.futures.wait(futures,return_when=concurrent.futures.FIRST_COMPLETED)
   for f in completed:collect(f)
 if batch:futures.add(pool.submit(work,batch,index))
 for f in concurrent.futures.as_completed(futures):collect(f)
print('COMPLETE',dict(counts),'seconds',round(time.monotonic()-started,1),flush=True)
