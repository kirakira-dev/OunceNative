"""Compile translated archive programs to Metal with deduplicated, compressed libraries."""
from pathlib import Path
import concurrent.futures,sqlite3,zlib,sys,json,hashlib,subprocess,shutil,time,collections,os,argparse,threading
os.environ['DM_GAME']='0400A3A01EE4C000'
sys.path.insert(0, str(Path(__file__).resolve().parent))
import dmsh_nx2_build as builder
import dmsh_nx2_tess as tess
from nx2_glslc import parse
import nx2_glslc
import dmsh_nx2_spirv as bank_tools
ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--shaders',type=Path);ap.add_argument('translated');ap.add_argument('--wrapper',type=Path,required=True);ap.add_argument('--limit',type=int,default=0);ap.add_argument('--workers',type=int,default=6);ap.add_argument('--reuse',type=Path,action='append',default=[]);ap.add_argument('--priority-map',type=Path);ap.add_argument('--priority-dir',type=Path);args=ap.parse_args()
source_path=Path(args.translated).resolve();root=source_path.parent;w=root.parent
def file_hash(path):
 with open(path,'rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
source=sqlite3.connect(f'file:{source_path}?mode=ro',uri=True)
wrapper_source=Path(builder.__file__).with_name('dmsh_nx2_msl.cpp')
provenance=dict(tess_helper_sha256=file_hash(tess.__file__),wrapper_sha256=file_hash(args.wrapper),wrapper_source_sha256=file_hash(wrapper_source),
 spirv_cross_static_libraries={str(p):file_hash(p) for p in sorted(Path('/opt/homebrew/lib').glob('libspirv-cross-*.a'))},
 domain_control_points=3,domain_control_points_evidence='All 694 hull programs in this input declare OutputVertices 3; runtime pairing must validate.',
 builder_sha256=hashlib.sha256(Path(builder.__file__).read_bytes()).hexdigest(),
 parser_sha256=hashlib.sha256(Path(nx2_glslc.__file__).read_bytes()).hexdigest(),
 runner_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
 input_database_sha256=file_hash(source_path),
 input_translation_provenance=dict(source.execute('select key,value from provenance')),
 spirv_cross_options=builder.XC,
 spirv_cross_sha256=hashlib.sha256(Path(shutil.which('spirv-cross')).read_bytes()).hexdigest(),
 metal_version=builder.run(['xcrun','-sdk','macosx','metal','--version']),
 constant_bank_toolchain=bank_tools.toolchain_provenance(),
 metal_options=['-std=metal3.2','-c','-fpreserve-invariance','-fno-fast-math'])
variant=hashlib.sha256(json.dumps(provenance,sort_keys=True).encode()).hexdigest()[:12]
output_path=root/('metal-tess-'+variant+'.sqlite')
for reuse in args.reuse:
 db=sqlite3.connect(f'file:{reuse.resolve()}?mode=ro',uri=True)
 previous={k:json.loads(v) for k,v in db.execute('select key,value from provenance')};db.close()
 if not previous:previous=json.loads((reuse.parent/'metal-provenance.json').read_text())
 if any(previous.get(k)!=provenance[k] for k in ('metal_version','metal_options')):raise ValueError('reuse Metal tool/options mismatch')
snapshot=root/('metal-tess-sources-'+variant);snapshot.mkdir(exist_ok=True)
for path in (Path(builder.__file__),Path(nx2_glslc.__file__),Path(__file__),Path(tess.__file__),Path(bank_tools.__file__),wrapper_source,args.wrapper):
 target=snapshot/path.name
 if target.exists() and target.read_bytes()!=path.read_bytes():raise ValueError('source snapshot changed')
 if not target.exists():shutil.copy2(path,target)
out=sqlite3.connect(output_path);out.execute('PRAGMA journal_mode=WAL');out.executescript('''
CREATE TABLE IF NOT EXISTS programs (key TEXT PRIMARY KEY, sha256 TEXT, stage INTEGER, status TEXT, error TEXT, library_hash TEXT, reflection_zlib BLOB);
CREATE TABLE IF NOT EXISTS libraries (hash TEXT PRIMARY KEY, metal_zlib BLOB, metal_size INTEGER, source_zlib BLOB);
CREATE TABLE IF NOT EXISTS provenance (key TEXT PRIMARY KEY,value TEXT);
''');out.executemany('INSERT OR REPLACE INTO provenance VALUES (?,?)',[(k,json.dumps(v)) for k,v in provenance.items()]);out.commit()
frozen_wrapper=snapshot/args.wrapper.name
completed={r[0] for r in out.execute('select key from programs')};cached={r[0] for r in out.execute('select hash from libraries')};lock=threading.Lock();local=threading.local()
query='select key,sha256,stage,spirv_zlib,reflection_zlib from programs where status="ok" and stage in (3,4)'
if args.limit:query+=' limit '+str(args.limit)
counts=collections.Counter();started=time.monotonic();index=0

def worker(row,index):
 key,sha,stage,spv,metadata=row;d=root/f'metal-work-{variant}-{index:06d}';d.mkdir(exist_ok=True);lh=None;lib=None
 try:
  if stage not in (3,4):raise ValueError('not a tessellation shader')
  if not hasattr(local,'db'):local.db=sqlite3.connect((args.shaders or w/'shaders-v2.sqlite').resolve().as_uri()+'?mode=ro',uri=True)
  blob=zlib.decompress(local.db.execute('select glslc_zlib from shaders where sha256=?',(sha,)).fetchone()[0]);shader=parse(blob)
  inp=d/'input.spv';inp.write_bytes(zlib.decompress(spv));meta=json.loads(zlib.decompress(metadata))
  src,reflection=tess.prepare(inp,frozen_wrapper,stage,meta,3 if stage==4 else None)
  src=builder.precise_helpers(src)
  if stage==3 and reflection['nx2_tessellation']['control_points']!=3:raise ValueError('hull output control point count violates batch domain variant')
  if shader['c1']:reflection['c1']=shader['c1'].hex()
  if any(b['kind']=='c1' for b in reflection['bindings']) and not shader['c1']:raise ValueError('missing C1 segment')
  reflection.update(key=key,stage=builder.STAGES[stage],facts_source='GLSLC reflection',archive_shader_sha256=sha)
  lh=hashlib.sha256(src.encode()).hexdigest()
  with lock:hit=lh in cached
  if not hit and args.reuse:
   if not hasattr(local,'reuse'):local.reuse=[sqlite3.connect(f'file:{p.resolve()}?mode=ro',uri=True) for p in args.reuse]
   for previous in local.reuse:
    saved=previous.execute('select hash,metal_zlib,metal_size,source_zlib from libraries where hash=?',(lh,)).fetchone()
    if saved and zlib.decompress(saved[3]).decode()==src:lib=saved;hit=True;break
  if not hit:
   msl=d/'shader.metal';air=d/'shader.air';target=d/'shader.metallib';msl.write_text(src)
   builder.run(['xcrun','-sdk','macosx','metal',*provenance['metal_options'],msl,'-o',air])
   builder.run(['xcrun','-sdk','macosx','metallib',air,'-o',target]);binary=target.read_bytes()
   if not binary.startswith(b'MTLB'):raise ValueError('invalid Metal library signature')
   lib=(lh,zlib.compress(binary,3),len(binary),zlib.compress(src.encode(),3))
  result=(key,sha,stage,'ok',None,lh,zlib.compress(json.dumps(reflection,separators=(',',':')).encode(),3))
 except Exception as e:result=(key,sha,stage,'error',str(e),None,None)
 finally:shutil.rmtree(d)
 return result,lib

print('OUTPUT',output_path,flush=True)
with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
 futures=set()
 def collect(f):
  result,lib=f.result()
  if lib:
   out.execute('INSERT OR IGNORE INTO libraries VALUES (?,?,?,?)',lib)
   with lock:cached.add(lib[0])
  out.execute('INSERT OR REPLACE INTO programs VALUES (?,?,?,?,?,?,?)',result);counts[result[3]]+=1
  n=sum(counts.values())
  if n%64==0:out.commit()
  if n%128==0:
   print(n,dict(counts),'libraries',len(cached),'seconds',round(time.monotonic()-started,1),flush=True)
   if shutil.disk_usage(root).free<5*2**30:raise RuntimeError('less than 5 GiB free; preserving completed results')
 keys=[row[0] for row in source.execute(query.replace('key,sha256,stage,spirv_zlib,reflection_zlib','key')).fetchall()]
 if args.priority_map or args.priority_dir:
  priority={fields[3] for line in args.priority_map.read_text().splitlines() if len(fields:=line.split('\t'))>3 and len(fields[3])==16} if args.priority_map else set()
  if args.priority_dir:priority.update(path.stem for path in args.priority_dir.glob('*.ctl'))
  keys.sort(key=lambda key:key not in priority)
 for key in keys:
  if key in completed:continue
  row=source.execute('select key,sha256,stage,spirv_zlib,reflection_zlib from programs where key=?',(key,)).fetchone()
  futures.add(pool.submit(worker,row,index));index+=1
  if len(futures)>=2*args.workers:
   ready,futures=concurrent.futures.wait(futures,return_when=concurrent.futures.FIRST_COMPLETED)
   for f in ready:collect(f)
 for f in concurrent.futures.as_completed(futures):collect(f)
out.commit();print('COMPLETE',dict(counts),'libraries',len(cached),'seconds',round(time.monotonic()-started,1),flush=True)
