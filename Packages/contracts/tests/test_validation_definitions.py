from __future__ import annotations
import copy, hashlib, importlib.util, json, os, plistlib, shutil, struct, subprocess, sys, tarfile, tempfile, unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]; CONTRACTS=ROOT/'Packages/contracts'; VALIDATOR=CONTRACTS/'scripts/validate_validation_definitions.py'
spec=importlib.util.spec_from_file_location('validator',VALIDATOR); validator=importlib.util.module_from_spec(spec); spec.loader.exec_module(validator)

def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def dump(p,x): p.parent.mkdir(parents=True,exist_ok=True); p.write_text(json.dumps(x,indent=2,sort_keys=True)+'\n')
def synthetic_chunk_sha(sequence,size): return hashlib.sha256(f'{sequence}:{size}'.encode()).hexdigest()
SYNTHETIC_SEED_SHA256='6'*64
def chunks(total,size=1048576,byte_value=None):
 out=[]; left=total; seq=0
 while left:
  n=min(left,size); chunk_sha=validator.repeated_digest(byte_value,n) if byte_value is not None else synthetic_chunk_sha(seq,n); out.append({'sequence':seq,'bytes':n,'sha256':chunk_sha}); left-=n; seq+=1
 return out
def chunk_manifest(items):
 h=hashlib.sha256(); h.update(validator.CHUNK_MANIFEST_DOMAIN)
 for item in items:
  h.update(item['sequence'].to_bytes(4,'big')); h.update(item['bytes'].to_bytes(8,'big')); h.update(bytes.fromhex(item['sha256']))
 return h.hexdigest()

def elf_library(arch):
 elf_class=2 if arch in ('arm64','x86_64') else 1; machine={'arm64':183,'armv7':40,'x86_64':62,'x86':3}[arch]; symbol=validator.UNIFFI_BUILD_INFO_SYMBOL.encode(); dynstr=b'\0'+symbol+b'\0libc.so\0libdl.so\0'; symbol_name=1; libc=dynstr.index(b'libc.so'); libdl=dynstr.index(b'libdl.so'); header_size=64 if elf_class==2 else 52; program_size=56 if elf_class==2 else 32; program_offset=header_size; dynstr_offset=header_size+2*program_size
 if elf_class==2: dynsym=b'\0'*24+struct.pack('<IBBHQQ',symbol_name,0x12,0,4,0,0); symbol_size=24; dynamic_size=16; section_size=64
 else: dynsym=b'\0'*16+struct.pack('<IIIBBH',symbol_name,0,0,0x12,0,4); symbol_size=16; dynamic_size=8; section_size=40
 dynsym_offset=dynstr_offset+len(dynstr); hash_offset=dynsym_offset+len(dynsym); sysv_hash=struct.pack('<IIII',1,2,1,0)+struct.pack('<I',0); dynamic_offset=hash_offset+len(sysv_hash); tags=[(1,libc),(1,libdl),(5,dynstr_offset),(10,len(dynstr)),(6,dynsym_offset),(11,symbol_size),(4,hash_offset),(0,0)]
 dynamic=b''.join((struct.pack('<qQ',tag,value) if elf_class==2 else struct.pack('<iI',tag,value)) for tag,value in tags); code_offset=dynamic_offset+len(dynamic); shoff=(code_offset+1+7)//8*8; file_size=shoff+5*section_size; data=bytearray(file_size); data[:4]=b'\x7fELF'; data[4:7]=bytes([elf_class,1,1]); data[16:18]=(3).to_bytes(2,'little'); data[18:20]=machine.to_bytes(2,'little'); data[20:24]=(1).to_bytes(4,'little'); data[dynstr_offset:dynstr_offset+len(dynstr)]=dynstr; data[dynsym_offset:dynsym_offset+len(dynsym)]=dynsym; data[hash_offset:hash_offset+len(sysv_hash)]=sysv_hash; data[dynamic_offset:dynamic_offset+len(dynamic)]=dynamic; data[code_offset]=0xc3
 if elf_class==2: data[dynsym_offset+32:dynsym_offset+40]=code_offset.to_bytes(8,'little'); data[dynsym_offset+40:dynsym_offset+48]=(1).to_bytes(8,'little')
 else: data[dynsym_offset+20:dynsym_offset+24]=code_offset.to_bytes(4,'little'); data[dynsym_offset+24:dynsym_offset+28]=(1).to_bytes(4,'little')
 if elf_class==2:
  data[32:40]=program_offset.to_bytes(8,'little'); data[40:48]=shoff.to_bytes(8,'little'); data[52:54]=header_size.to_bytes(2,'little'); data[54:56]=program_size.to_bytes(2,'little'); data[56:58]=(2).to_bytes(2,'little'); data[58:60]=section_size.to_bytes(2,'little'); data[60:62]=(5).to_bytes(2,'little'); load=struct.pack('<IIQQQQQQ',1,5,0,0,0,file_size,file_size,4096); dynamic_program=struct.pack('<IIQQQQQQ',2,6,dynamic_offset,dynamic_offset,dynamic_offset,len(dynamic),len(dynamic),8)
  def section(index,kind,address,offset,size,link=0,entsize=0,flags=2):
   base=shoff+index*section_size; data[base+4:base+8]=kind.to_bytes(4,'little'); data[base+8:base+16]=flags.to_bytes(8,'little'); data[base+16:base+24]=address.to_bytes(8,'little'); data[base+24:base+32]=offset.to_bytes(8,'little'); data[base+32:base+40]=size.to_bytes(8,'little'); data[base+40:base+44]=link.to_bytes(4,'little'); data[base+56:base+64]=entsize.to_bytes(8,'little')
 else:
  data[28:32]=program_offset.to_bytes(4,'little'); data[32:36]=shoff.to_bytes(4,'little'); data[40:42]=header_size.to_bytes(2,'little'); data[42:44]=program_size.to_bytes(2,'little'); data[44:46]=(2).to_bytes(2,'little'); data[46:48]=section_size.to_bytes(2,'little'); data[48:50]=(5).to_bytes(2,'little'); load=struct.pack('<IIIIIIII',1,0,0,0,file_size,file_size,5,4096); dynamic_program=struct.pack('<IIIIIIII',2,dynamic_offset,dynamic_offset,dynamic_offset,len(dynamic),len(dynamic),6,8)
  def section(index,kind,address,offset,size,link=0,entsize=0,flags=2):
   base=shoff+index*section_size; data[base+4:base+8]=kind.to_bytes(4,'little'); data[base+8:base+12]=flags.to_bytes(4,'little'); data[base+12:base+16]=address.to_bytes(4,'little'); data[base+16:base+20]=offset.to_bytes(4,'little'); data[base+20:base+24]=size.to_bytes(4,'little'); data[base+24:base+28]=link.to_bytes(4,'little'); data[base+36:base+40]=entsize.to_bytes(4,'little')
 data[program_offset:program_offset+program_size]=load; data[program_offset+program_size:program_offset+2*program_size]=dynamic_program; section(1,3,dynstr_offset,dynstr_offset,len(dynstr)); section(2,11,dynsym_offset,dynsym_offset,len(dynsym),1,symbol_size); section(3,6,dynamic_offset,dynamic_offset,len(dynamic),1,dynamic_size); section(4,1,code_offset,code_offset,1,flags=6); return bytes(data)

def macho_object(arch,platform):
 cpu={'arm64':0x0100000c,'x86_64':0x01000007}[arch]; strings=b'\0_'+validator.UNIFFI_BUILD_INFO_SYMBOL.encode()+b'\0'; command_bytes=200; symbol_offset=32+command_bytes; string_offset=symbol_offset+16; code_offset=string_offset+len(strings); header=struct.pack('<IiiIIIII',0xfeedfacf,cpu,0,1,3,command_bytes,0,0); segment_header=struct.pack('<II16sQQQQiiII',0x19,152,b'__TEXT',0,1,code_offset,1,7,5,1,0); section=struct.pack('<16s16sQQIIIIIIII',b'__text',b'__TEXT',0,1,code_offset,0,0,0,0x80000400,0,0,0); segment=segment_header+section; build=struct.pack('<IIIIII',0x32,24,platform,0x00110600,0,0); symtab=struct.pack('<IIIIII',0x2,24,symbol_offset,1,string_offset,len(strings)); symbol=struct.pack('<IBBHQ',1,0x0f,1,0,0); return header+segment+build+symtab+symbol+strings+b'\xc3'

def apple_archive(arch,platform,extended=False):
 body=macho_object(arch,platform); name=b'object-file.o'
 if extended: raw_name=f'#1/{len(name)}'.encode(); body=name+body
 else: raw_name=b'object.o/'
 header=raw_name.ljust(16)+b'0'.ljust(12)+b'0'.ljust(6)+b'0'.ljust(6)+b'100644'.ljust(8)+str(len(body)).encode().ljust(10)+b'`\n'; return b'!<arch>\n'+header+body+(b'\n' if len(body)&1 else b'')

def apple_fat_archive():
 slices=[apple_archive('arm64',7),apple_archive('x86_64',7)]; offset=48; entries=[]; payload=b''
 for arch,data in zip(('arm64','x86_64'),slices): entries.append(struct.pack('>IIIII',{'arm64':0x0100000c,'x86_64':0x01000007}[arch],0,offset,len(data),0)); payload+=data; offset+=len(data)
 return struct.pack('>II',0xcafebabe,2)+b''.join(entries)+payload

def make_run(rid,purpose,stream,duration=10_000_000,rss=False):
 control_document={'operation':'newNoteTextLink','profileVersion':'apple-parity-v1','runID':rid,'purpose':purpose,'streamBytes':stream,'syntheticSeedSha256':SYNTHETIC_SEED_SHA256}; control_data=validator.canonical_json_bytes(control_document); control=len(control_data); output=256; control_hash=hashlib.sha256(control_data).hexdigest(); stream_byte=validator.synthetic_stream_byte(SYNTHETIC_SEED_SHA256); stream_hash=validator.repeated_digest(stream_byte,stream); output_hash=hashlib.sha256((rid+'-output').encode()).hexdigest()
 total_hash=hashlib.sha256(validator.TOTAL_INPUT_DOMAIN+control.to_bytes(8,'big')+stream.to_bytes(8,'big')+bytes.fromhex(control_hash)+bytes.fromhex(stream_hash)).hexdigest()
 ingress=chunks(stream,byte_value=stream_byte); drain=chunks(output)
 r={'runID':rid,'purpose':purpose,'status':'completed','controlDocument':control_document,'controlBytes':control,'controlSha256':control_hash,'controlArtifactPath':None,'streamBytes':stream,'streamSha256':stream_hash,'totalInputBytes':control+stream,'totalInputSha256':total_hash,'ingressChunks':ingress,'ingressChunkManifestSha256':chunk_manifest(ingress),'inputArtifactPath':None,'outputBytes':output,'outputSha256':output_hash,'outputArtifactPath':None,'drainChunks':drain,'drainChunkManifestSha256':chunk_manifest(drain),'verifiedDrain':{'descriptorOutputBytes':output,'descriptorOutputSha256':output_hash,'terminalState':'completed'},'durationNanoseconds':duration,'rss':None}
 if rss:r['rss']={'method':'macosMachTaskResidentSizeSampled','baselineDefinition':'resident bytes immediately before opening the measured production session','baselineBytes':100_000_000,'sampleIntervalNanoseconds':10_000_000,'samples':[{'elapsedNanoseconds':0,'residentBytes':100_000_000},{'elapsedNanoseconds':duration//2,'residentBytes':120_000_000},{'elapsedNanoseconds':duration,'residentBytes':130_000_000}],'peakBytes':130_000_000,'additionalBytes':30_000_000}
 return r

class Tests(unittest.TestCase):
 def setUp(self): self.campaign_repositories={}
 def execute(self,root=CONTRACTS,campaign=None,repository=None,qualification=None,external=None,env=None):
  cmd=[sys.executable,str(VALIDATOR),'--contracts-root',str(root)]
  if campaign: cmd+=['--campaign-dir',str(campaign)]
  repository=repository or (self.campaign_repositories.get(str(campaign)) if campaign else None)
  if repository: cmd+=['--repository-root',str(repository)]
  if qualification: cmd+=['--qualification',qualification]
  if external: cmd+=['--external-artifact-root',str(external)]
  return subprocess.run(cmd,text=True,capture_output=True,env=env)
 def copy_contracts(self):
  t=tempfile.TemporaryDirectory(); self.addCleanup(t.cleanup); r=Path(t.name)/'contracts'; shutil.copytree(CONTRACTS,r,ignore=shutil.ignore_patterns('__pycache__')); return r
 def docs(self,root=CONTRACTS): return {n:validator.load(root/'validation'/n) for n in ('device-matrix.json','provider-matrix.json','case-catalog.json','performance-gates.json','aggregate-policy.json','case-evidence-policy.json','approval-policy.json')}
 def schemas(self,root=CONTRACTS): return {p.name:validator.load(p) for p in (root/'schemas').glob('*.json')}
 def synthetic_repository(self):
  t=tempfile.TemporaryDirectory(); self.addCleanup(t.cleanup); root=Path(t.name)/'repository'; root.mkdir()
  provenance_paths={x for value in validator.EXPECTED_PROVENANCE_PATHS.values() for x in value.values() if x is not None}; paths=set().union(*validator.REQUIRED_PROVENANCE_SOURCES.values())|provenance_paths|{'toolchains/android-wear-shared-core.json','Packages/contracts/tests/test_validation_definitions.py','.github/workflows/core-rust-ci.yml','Packages/vox-core-rust/scripts/run-m2-hosted-evidence.sh'}
  for rel in sorted(paths):
   path=root/rel; path.parent.mkdir(parents=True,exist_ok=True); content='synthetic:'+rel+'\n'
   if rel=='.github/workflows/core-rust-ci.yml': content='name: Synthetic M2\non: workflow_dispatch\njobs:\n  m2-evidence:\n    runs-on: macos-26\n    steps:\n      - name: Produce and validate M2 evidence\n        run: Packages/vox-core-rust/scripts/run-m2-hosted-evidence.sh\n'
   path.write_text(content)
  subprocess.run(['git','init','-q'],cwd=root,check=True); subprocess.run(['git','config','user.email','synthetic@invalid.test'],cwd=root,check=True); subprocess.run(['git','config','user.name','Synthetic Contract Test'],cwd=root,check=True); subprocess.run(['git','add','.'],cwd=root,check=True); subprocess.run(['git','commit','-qm','synthetic provenance'],cwd=root,check=True)
  return root
 def build_identity(self,repository,case='PERF-008'):
  source=subprocess.run(['git','rev-parse','HEAD'],cwd=repository,check=True,text=True,capture_output=True).stdout.strip(); recipe=validator.EXPECTED_PROVENANCE_PATHS[case]['buildRecipe']; executable_source=validator.PYTHON_EXECUTABLE_SOURCES.get(case); executable_sha=digest(repository/executable_source) if executable_source else '3'*64
  return {'kind':'sourceBuiltHost','sourceRevision':source,'sourceTreeState':'clean','toolchainManifestSha256':digest(repository/'toolchains/android-wear-shared-core.json'),'buildRecipeSha256':digest(repository/recipe),'executableSha256':executable_sha}
 def commit_root(self,root,message):
  if not (root/'.git').exists():
   subprocess.run(['git','init','-q'],cwd=root,check=True); subprocess.run(['git','config','user.email','synthetic@invalid.test'],cwd=root,check=True); subprocess.run(['git','config','user.name','Synthetic Contract Test'],cwd=root,check=True)
  subprocess.run(['git','add','.'],cwd=root,check=True)
  if subprocess.run(['git','diff','--cached','--quiet'],cwd=root).returncode: subprocess.run(['git','commit','-qm',message],cwd=root,check=True)
 def host(self): return {'osName':'macOS','osVersion':'synthetic-15','architecture':'arm64','cpuModel':'synthetic-cpu','logicalCPUCount':12,'totalMemoryBytes':32_000_000_000}
 def provenance(self,build,repository,case='PERF-003',hosted=None):
  consumer=validator.EXPECTED_CONSUMERS[case]; source_files=[{'repositoryPath':path,'sha256':digest(repository/path)} for path in sorted(validator.required_provenance_sources(consumer['id'],repository))]
  paths=validator.EXPECTED_PROVENANCE_PATHS[case]; generator=paths['inputGenerator']; input_generator=None if generator is None else {'id':'vox-m2-deterministic-synthetic-input-v1','version':1,'repositoryPath':generator,'sourceSha256':digest(repository/generator),'seedSha256':SYNTHETIC_SEED_SHA256}; executable_source=validator.PYTHON_EXECUTABLE_SOURCES.get(case); executable_bytes=(repository/executable_source).stat().st_size if executable_source else 1000
  v={'schemaVersion':1,'format':'vox-execution-provenance-v1','sourceRevision':build['sourceRevision'],'sourceTreeState':'clean','toolchainManifest':{'repositoryPath':'toolchains/android-wear-shared-core.json','sha256':build['toolchainManifestSha256']},'buildRecipe':{'repositoryPath':paths['buildRecipe'],'sha256':build['buildRecipeSha256']},'consumer':consumer,'executable':{'sha256':build['executableSha256'],'bytes':executable_bytes,'externalArtifactPath':None},'sourceFiles':source_files,'inputGenerator':input_generator}
  if hosted:v['hosted']=hosted
  return v
 def run_set(self,build):
  warm=make_run('warmup-000','warmup',1048576); latency=[make_run(f'latency-{i:03d}','latency',1048576,5_000_000+i*1000) for i in range(20)]; aggregate=[make_run('aggregate-1m','aggregateCoverage',1048576),make_run('aggregate-16m','aggregateCoverage',16777216),make_run('aggregate-256m','aggregateCoverage',268435456)]; resource=make_run('resource-256m','resource',268435456,20_000_000,True); runs=[warm,*latency,*aggregate,resource]; governed=[r['runID'] for r in runs if r['purpose']!='warmup']
  return {'schemaVersion':1,'format':'vox-m2-materialization-run-set-v1','operation':'newNoteTextLink','profileVersion':'apple-parity-v1','productionConsumerID':'vox-core-uniffi-swift-host-v1','sourceRevision':build['sourceRevision'],'executableSha256':build['executableSha256'],'toolchainManifestSha256':build['toolchainManifestSha256'],'warmupRunIDs':['warmup-000'],'gateBindings':[{'gateID':'rust-materialize-1mib-p95','runIDs':[r['runID'] for r in latency]},{'gateID':'rust-materialize-additional-rss','runIDs':['resource-256m']},{'gateID':'ffi-max-chunk','runIDs':governed},{'gateID':'materialization-max-aggregate','runIDs':[r['runID'] for r in aggregate]}],'runs':runs}
 def package(self,build,mode='initialCandidate',retention=None):
  order=validator.PACKAGE_ORDER; leaves=[]
  for i,(gid,scope,arch,fmt) in enumerate(order):
   relative=f'packages/package-{i}.bin' if i<4 else f'packages/VoxCore.xcframework/{"ios-arm64" if i==4 else "ios-arm64_x86_64-simulator"}/libVoxCoreFFI.a'; leaves.append({'artifactID':f'package-{i}','relativeArtifactPath':relative,'gateID':gid,'targetScope':scope,'architectures':arch,'format':fmt,'bytes':1000+i,'sha256':hashlib.sha256(bytes([i])* (1000+i)).hexdigest(),'inspectionChecks':[{'code':code,'result':'passed'} for code in sorted(validator.ANDROID_INSPECTION_CHECKS if fmt=='elf-shared-object' else validator.APPLE_INSPECTION_CHECKS)],'baseline':None})
  return {'schemaVersion':1,'format':'vox-m2-native-package-inspection-v1','comparisonMode':mode,'sourceRevision':build['sourceRevision'],'sourceTreeState':'clean','toolchainManifestSha256':build['toolchainManifestSha256'],'buildRecipeSha256':build['buildRecipeSha256'],'inspectorSha256':build['executableSha256'],'buildHost':self.host(),'buildConfiguration':'release-stripped','featureSet':'default-features','candidateLeaves':leaves,'appleAggregateBytes':sum(x['bytes'] for x in leaves[-2:]),'xcframeworkMetadata':{'relativeArtifactPath':'packages/VoxCore.xcframework/Info.plist','bytes':1,'sha256':hashlib.sha256(b'x').hexdigest()},'retention':retention or {'kind':'notRetained'}}
 def write_ref(self,c,rel,value):
  dump(c/rel,value); return {'id':rel,'sha256':digest(c/rel)}
 def measurement(self,g,source,selector,ids,values): return {'gateID':g['id'],'metric':g['metric'],'statistic':g['statistic'],'operator':g['operator'],'value':validator.nearest(values,g['statistic']),'unit':g['unit'],'scope':g.get('scope',g['id']),'sampleValues':values,'samplingMethod':g['samplingMethod'],'derivation':{'sourceArtifactID':source,'selector':selector,'runIDs':ids}}
 def build_m2(self,qualification='repositoryObservation'):
  t=tempfile.TemporaryDirectory(); self.addCleanup(t.cleanup); c=Path(t.name)/'campaign'; (c/'evidence').mkdir(parents=True); (c/'approvals').mkdir(); (c/'artifacts').mkdir(); repository=self.synthetic_repository(); self.campaign_repositories[str(c)]=repository; docs=self.docs(); cases=validator.idx(docs['case-catalog.json']['cases'],'id','case'); gates=validator.idx(docs['performance-gates.json']['gates'],'id','gate'); build=self.build_identity(repository,'PERF-003'); package_build=self.build_identity(repository,'PERF-008'); manifest=digest(CONTRACTS/'manifest.json')
  fixture=self.write_ref(c,'artifacts/synthetic-fixture.diagnostic.json',{'schemaVersion':1,'format':'vox-validation-diagnostic-summary','kind':'fixture','resultCode':'passed','checks':[{'code':'privacyFormat','result':'passed','count':1}],'referencedHashes':[]})
  run=self.run_set(build); runref=self.write_ref(c,'artifacts/materialization-runs.json',run); prov3=self.write_ref(c,'artifacts/perf-003-provenance.json',self.provenance(build,repository)); computed=validator.validate_run_set(run,build,gates); ms=[]
  selectors={'rust-materialize-1mib-p95':'durationMilliseconds','rust-materialize-additional-rss':'additionalRSSBytes','ffi-max-chunk':'ffiChunkBytes','materialization-max-aggregate':'acceptedAggregateInputBytes'}
  for gid in cases['PERF-003']['performanceGateIDs']:
   ids,values=computed[gid]; ms.append(self.measurement(gates[gid],runref['id'],selectors[gid],ids,values))
  common={'$schema':'https://vox.md/contracts/schemas/case-evidence.schema.json','schemaVersion':2,'campaignID':'synthetic-m2-campaign','deviceRoleID':None,'providerID':None,'status':'passed','contractManifestSha256':manifest,'buildIdentity':build,'operator':'synthetic-operator','startedAt':'2025-01-01T00:00:00Z','completedAt':'2025-01-01T00:01:00Z','device':None,'buildHost':self.host(),'provider':None,'actual':{'resultCode':'passed','summaryCode':'expectedOutcomeObserved'},'fixtureHashes':[fixture],'invariantResults':[],'artifacts':[{'id':'artifacts/execution-artifact.diagnostic.json','sha256':''}]}
  artifact=self.write_ref(c,'artifacts/execution-artifact.diagnostic.json',{'schemaVersion':1,'format':'vox-validation-diagnostic-summary','kind':'artifact','resultCode':'passed','checks':[{'code':'privacyFormat','result':'passed','count':1}],'referencedHashes':[]}); common['artifacts']=[artifact]
  e=copy.deepcopy(common); e.update({'evidenceID':'perf-003','caseID':'PERF-003','expected':cases['PERF-003']['expected'],'measurements':ms,'invariantResults':[{'invariantID':'INV-BOUND-CONTENT','passed':True}],'executionProvenance':prov3,'materializationRunSet':runref,'nativePackageInspection':None}); dump(c/'evidence/perf-003.json',e)
  package=self.package(package_build); packref=self.write_ref(c,'artifacts/native-package-inspection.json',package); prov8=self.write_ref(c,'artifacts/perf-008-provenance.json',self.provenance(package_build,repository,'PERF-008')); computed=validator.validate_package(package,package_build,{'level':'repositoryObservation'},None,None); ms=[]
  for gid in cases['PERF-008']['performanceGateIDs']:
   if gid=='packaging-growth':continue
   ids,values=computed[gid]; ms.append(self.measurement(gates[gid],packref['id'],'candidateArtifactBytes',ids,values))
  e=copy.deepcopy(common); e.update({'evidenceID':'perf-008','caseID':'PERF-008','expected':cases['PERF-008']['expected'],'buildIdentity':package_build,'measurements':ms,'executionProvenance':prov8,'materializationRunSet':None,'nativePackageInspection':packref}); dump(c/'evidence/perf-008.json',e)
  q={'level':qualification}
  if qualification!='repositoryObservation':q.update({'runID':'123','runAttempt':1,'workflowRepositoryPath':'.github/workflows/core-rust-ci.yml','workflowSha256':'8'*64,'artifactArchivePath':'archives/m2.tar','artifactArchiveSha256':'9'*64})
  self.refresh(c,{'claim':'milestoneClosure','throughMilestone':'M2'},q)
  return c
 def refresh(self,c,scope,qualification,root=CONTRACTS):
  docs=self.docs(root); cases=validator.idx(docs['case-catalog.json']['cases'],'id','c'); devices=validator.idx(docs['device-matrix.json']['roles'],'id','d'); providers=validator.idx(docs['provider-matrix.json']['providers'],'id','p'); required=validator.tuples(cases,devices,providers,scope); evpaths=sorted((c/'evidence').glob('*.json')); ev=[json.loads(p.read_text()) for p in evpaths]; by={(x['caseID'],x['deviceRoleID'],x['providerID']):x for x in ev}; definition_files=['device-matrix.json','provider-matrix.json','case-catalog.json','performance-gates.json','aggregate-policy.json','case-evidence-policy.json','approval-policy.json']
  if (root/'validation/native-package-baseline.json').exists(): definition_files += ['native-package-baseline.json','native-package-baseline-approval.json']
  dh=[{'id':n,'sha256':digest(root/'validation'/n)} for n in definition_files]; eh=[{'id':str(p.relative_to(c)),'sha256':digest(p)} for p in evpaths]; ah=[]; da=validator.canonical({'scope':scope,'qualification':qualification,'definitions':dh}); ea=validator.canonical({'scope':scope,'qualification':qualification,'evidence':eh}); rows=[]; counts={x:0 for x in ('passed','failed','blocked','incomplete')}
  for t in required:
   e=by.get(t); status='incomplete' if not e or e['status'] in ('notRun','notApplicable') else e['status']; counts[status]+=1; rows.append({'caseID':t[0],'deviceRoleID':t[1],'providerID':t[2],'evidenceID':e['evidenceID'] if e else None,'status':status})
  status='failed' if counts['failed'] else 'blocked' if counts['blocked'] else 'incomplete' if counts['incomplete'] else 'passed'; dump(c/'aggregate.json',{'$schema':'https://vox.md/contracts/schemas/aggregate.schema.json','schemaVersion':2,'campaignID':'synthetic-m2-campaign','scope':scope,'qualification':qualification,'status':status,'definitionAggregateSha256':da,'evidenceAggregateSha256':ea,'definitionHashes':dh,'evidenceHashes':eh,'approvalHashes':ah,'requiredTuples':rows,'requiredTupleCounts':{'total':len(rows),**counts},'failedInvariantIDs':[],'generatedAt':'2025-01-02T00:00:00Z'})
 def mutate_campaign(self,fn,needle):
  c=self.build_m2(); fn(c); self.refresh(c,json.loads((c/'aggregate.json').read_text())['scope'],json.loads((c/'aggregate.json').read_text())['qualification']); q=self.execute(campaign=c,qualification='repositoryObservation'); self.assertNotEqual(q.returncode,0,q.stdout); self.assertIn(needle,q.stderr)
 def evidence(self,c,case): return next(p for p in (c/'evidence').glob('*.json') if json.loads(p.read_text())['caseID']==case)
 def mutate_receipt(self,c,e_key,fn):
  ep=self.evidence(c,'PERF-003' if e_key=='materializationRunSet' else 'PERF-008'); e=json.loads(ep.read_text()); rp=c/e[e_key]['id']; v=json.loads(rp.read_text()); fn(v); dump(rp,v); e[e_key]['sha256']=digest(rp); dump(ep,e)
 def refresh_run_chunk_manifest(self,c,index,kind):
  def mutate(receipt):
   chunks=receipt['runs'][index][kind+'Chunks']; receipt['runs'][index][kind+'ChunkManifestSha256']=chunk_manifest(chunks)
  self.mutate_receipt(c,'materializationRunSet',mutate)
 def adopt_package_baseline(self,c,root):
  evidence_path=self.evidence(c,'PERF-008'); evidence=json.loads(evidence_path.read_text()); receipt_path=c/evidence['nativePackageInspection']['id']; receipt=json.loads(receipt_path.read_text()); baseline_revision='b'*40
  registry={'schemaVersion':1,'format':'vox-m2-native-package-baseline-v1','registryID':'m2-native-package-baseline-2028','sourceRevision':baseline_revision,'toolchainManifestSha256':receipt['toolchainManifestSha256'],'buildConfiguration':receipt['buildConfiguration'],'featureSet':receipt['featureSet'],'hostedRunID':'987654321','hostedRunAttempt':2,'hostedEvidenceAggregateSha256':'d'*64,'hostedArtifactArchiveSha256':'e'*64,'definitionAggregateSha256':'f'*64,'adoptionApprovalID':'m2-native-package-baseline-adoption-2028','leaves':[]}
  for leaf in receipt['candidateLeaves']:
   registry['leaves'].append({'gateID':leaf['gateID'],'targetScope':leaf['targetScope'],'artifactID':leaf['artifactID'],'sourceRevision':baseline_revision,'bytes':leaf['bytes'],'artifactSha256':leaf['sha256']})
  registry_path=root/'validation/native-package-baseline.json'; approval_path=root/'validation/native-package-baseline-approval.json'; dump(registry_path,registry); registry_sha=digest(registry_path)
  approval={'$schema':'https://vox.md/contracts/schemas/approval.schema.json','schemaVersion':1,'approvalID':registry['adoptionApprovalID'],'kind':'packageBaselineAdoption','status':'approved','subjectID':registry['registryID'],'subjectSha256':registry_sha,'definitionAggregateSha256':registry['definitionAggregateSha256'],'evidenceAggregateSha256':registry['hostedEvidenceAggregateSha256'],'approvedBy':'release-team-reviewer','approvedAt':'2024-12-31T00:00:00Z','expiresAt':'2099-01-01T00:00:00Z','rationale':'Reviewed hosted source-built package evidence is adopted for identical-scope growth comparisons.'}; dump(approval_path,approval)
  receipt['comparisonMode']='approvedBaselineComparison'
  for leaf,registered in zip(receipt['candidateLeaves'],registry['leaves']): leaf['baseline']={'approvedRegistrySha256':registry_sha,'sourceRevision':registered['sourceRevision'],'bytes':registered['bytes'],'artifactSha256':registered['artifactSha256']}
  dump(receipt_path,receipt); evidence['nativePackageInspection']['sha256']=digest(receipt_path); gate=validator.idx(self.docs(root)['performance-gates.json']['gates'],'id','gate')['packaging-growth']; values=[0.0]*6; evidence['measurements'].append(self.measurement(gate,evidence['nativePackageInspection']['id'],'packagingGrowthPercent',[],values)); dump(evidence_path,evidence)
  self.refresh(c,{'claim':'milestoneClosure','throughMilestone':'M2'},{'level':'repositoryObservation'},root); self.commit_root(root,'synthetic governed baseline')
  return registry_path,approval_path,receipt_path
 def build_hosted_package_case(self):
  c=self.build_m2(); repository=self.campaign_repositories[str(c)]; external=c.parent/'external'; external.mkdir(); perf3=self.evidence(c,'PERF-003'); old=json.loads(perf3.read_text()); (c/old['executionProvenance']['id']).unlink(); (c/old['materializationRunSet']['id']).unlink(); perf3.unlink(); evidence_path=self.evidence(c,'PERF-008'); evidence=json.loads(evidence_path.read_text()); provenance_path=c/evidence['executionProvenance']['id']; provenance=json.loads(provenance_path.read_text()); package_path=c/evidence['nativePackageInspection']['id']; package=json.loads(package_path.read_text())
  executable_path=external/'executables/package-inspector.py'; executable_path.parent.mkdir(parents=True); shutil.copyfile(repository/validator.PYTHON_EXECUTABLE_SOURCES['PERF-008'],executable_path); executable_sha=digest(executable_path); self.assertEqual(executable_sha,evidence['buildIdentity']['executableSha256']); provenance['executable']={'sha256':executable_sha,'bytes':executable_path.stat().st_size,'externalArtifactPath':'executables/package-inspector.py'}; provenance['hosted']={'runID':'123','runAttempt':1,'workflowRepositoryPath':'.github/workflows/core-rust-ci.yml','workflowSha256':digest(repository/'.github/workflows/core-rust-ci.yml'),'checkoutRevision':evidence['buildIdentity']['sourceRevision'],'runnerOS':'macOS','runnerArchitecture':'ARM64'}
  package['inspectorSha256']=executable_sha; package['retention']={'kind':'hostedArtifact','runID':'123','runAttempt':1,'artifactName':'synthetic-m2-package-evidence','archiveSha256':'0'*64,'retentionExpiresAt':'2099-01-01T00:00:00Z'}
  for leaf in package['candidateLeaves']:
   path=external/leaf['relativeArtifactPath']; path.parent.mkdir(parents=True,exist_ok=True)
   if leaf['format']=='elf-shared-object':
    arch=leaf['architectures'][0]; path.write_bytes(elf_library(arch))
   elif leaf['architectures']==['arm64']: path.write_bytes(apple_archive('arm64',2))
   else: path.write_bytes(apple_fat_archive())
   leaf['bytes']=path.stat().st_size; leaf['sha256']=digest(path)
  package['appleAggregateBytes']=sum(x['bytes'] for x in package['candidateLeaves'][-2:]); metadata_path=external/package['xcframeworkMetadata']['relativeArtifactPath']; metadata={'CFBundlePackageType':'XFWK','XCFrameworkFormatVersion':'1.0','AvailableLibraries':[{'LibraryIdentifier':'ios-arm64','LibraryPath':'libVoxCoreFFI.a','SupportedArchitectures':['arm64'],'SupportedPlatform':'ios'},{'LibraryIdentifier':'ios-arm64_x86_64-simulator','LibraryPath':'libVoxCoreFFI.a','SupportedArchitectures':['arm64','x86_64'],'SupportedPlatform':'ios','SupportedPlatformVariant':'simulator'}]}; metadata_path.write_bytes(plistlib.dumps(metadata,fmt=plistlib.FMT_XML,sort_keys=True)); package['xcframeworkMetadata']['bytes']=metadata_path.stat().st_size; package['xcframeworkMetadata']['sha256']=digest(metadata_path)
  archive_path=external/'archives/m2.tar'; archive_path.parent.mkdir(parents=True); retained=sorted(p for p in external.rglob('*') if p.is_file() and p!=archive_path)
  with tarfile.open(archive_path,'w',format=tarfile.USTAR_FORMAT) as handle:
   for path in retained: handle.add(path,arcname=str(path.relative_to(external)),recursive=False)
  archive_sha=digest(archive_path); package['retention']['archiveSha256']=archive_sha; qualification={'level':'hostedRun','runID':'123','runAttempt':1,'workflowRepositoryPath':'.github/workflows/core-rust-ci.yml','workflowSha256':digest(repository/'.github/workflows/core-rust-ci.yml'),'artifactArchivePath':'archives/m2.tar','artifactArchiveSha256':archive_sha}
  dump(provenance_path,provenance); evidence['executionProvenance']['sha256']=digest(provenance_path); dump(package_path,package); evidence['nativePackageInspection']['sha256']=digest(package_path); gates=validator.idx(self.docs()['performance-gates.json']['gates'],'id','gate'); derived=validator.validate_package(package,evidence['buildIdentity'],qualification,external,None,evidence['buildHost']); evidence['measurements']=[]
  for gid in validator.idx(self.docs()['case-catalog.json']['cases'],'id','case')['PERF-008']['performanceGateIDs']:
   if gid=='packaging-growth': continue
   ids,values=derived[gid]; evidence['measurements'].append(self.measurement(gates[gid],evidence['nativePackageInspection']['id'],'candidateArtifactBytes',ids,values))
  dump(evidence_path,evidence); self.refresh(c,{'claim':'caseExecution','caseIDs':['PERF-008']},qualification); env=os.environ.copy(); env.update({'GITHUB_ACTIONS':'true','GITHUB_RUN_ID':'123','GITHUB_RUN_ATTEMPT':'1','GITHUB_SHA':evidence['buildIdentity']['sourceRevision'],'GITHUB_WORKFLOW_REF':'owner/repository/.github/workflows/core-rust-ci.yml@refs/heads/main','GITHUB_WORKSPACE':str(repository),'GITHUB_JOB':'m2-evidence','RUNNER_OS':'macOS','RUNNER_ARCH':'ARM64'}); return c,external,env
 def test_definitions_and_scoped_m2_candidate_pass(self):
  self.assertEqual(self.execute().returncode,0); c=self.build_m2(); q=self.execute(campaign=c,qualification='repositoryObservation'); self.assertEqual(q.returncode,0,q.stdout+q.stderr); a=json.loads((c/'aggregate.json').read_text()); self.assertEqual([x['caseID'] for x in a['requiredTuples']],['CORE-001','CORE-002','CORE-003','CORE-004','CORE-005','PERF-003','PERF-008']); self.assertEqual(a['status'],'incomplete'); self.assertEqual(a['approvalHashes'],[])
 def test_core_exit_case_requires_exact_provenance_and_named_build_check(self):
  c=self.build_m2(); repository=self.campaign_repositories[str(c)]; case_id='CORE-001'; build=self.build_identity(repository,case_id); base=json.loads(self.evidence(c,'PERF-003').read_text()); cases=validator.idx(self.docs()['case-catalog.json']['cases'],'id','case'); diagnostic={'schemaVersion':1,'format':'vox-validation-diagnostic-summary','kind':'artifact','resultCode':'passed','checks':[{'code':'swiftRustParity','result':'passed','count':1}],'referencedHashes':[{'role':'build','sha256':build['executableSha256']}]}; artifact=self.write_ref(c,'artifacts/core-001.diagnostic.json',diagnostic); provenance=self.write_ref(c,'artifacts/core-001-provenance.json',self.provenance(build,repository,case_id)); base.update(evidenceID='core-001',caseID=case_id,expected=cases[case_id]['expected'],buildIdentity=build,measurements=[],invariantResults=[{'invariantID':x,'passed':True} for x in cases[case_id]['invariants']],artifacts=[artifact],executionProvenance=provenance,materializationRunSet=None,nativePackageInspection=None); dump(c/'evidence/core-001.json',base); self.refresh(c,{'claim':'milestoneClosure','throughMilestone':'M2'},{'level':'repositoryObservation'}); q=self.execute(campaign=c,qualification='repositoryObservation'); self.assertEqual(q.returncode,0,q.stdout+q.stderr)
  (c/provenance['id']).unlink(); base['executionProvenance']=None; dump(c/'evidence/core-001.json',base); self.refresh(c,{'claim':'milestoneClosure','throughMilestone':'M2'},{'level':'repositoryObservation'}); q=self.execute(campaign=c,qualification='repositoryObservation'); self.assertIn('requires provenance',q.stderr)
 def test_shadow_exit_requires_complete_build_bound_isolation_observations(self):
  c=self.build_m2(); repository=self.campaign_repositories[str(c)]; case_id='CORE-005'; build=self.build_identity(repository,case_id); base=json.loads(self.evidence(c,'PERF-003').read_text()); cases=validator.idx(self.docs()['case-catalog.json']['cases'],'id','case'); codes=['shadowSideEffects',*sorted(validator.SHADOW_ISOLATION_CHECKS)]; diagnostic={'schemaVersion':1,'format':'vox-validation-diagnostic-summary','kind':'artifact','resultCode':'passed','checks':[{'code':code,'result':'passed','count':1} for code in codes],'referencedHashes':[{'role':'build','sha256':build['executableSha256']}]}; artifact=self.write_ref(c,'artifacts/core-005.diagnostic.json',diagnostic); provenance=self.write_ref(c,'artifacts/core-005-provenance.json',self.provenance(build,repository,case_id)); base.update(evidenceID='core-005',caseID=case_id,expected=cases[case_id]['expected'],buildIdentity=build,measurements=[],invariantResults=[{'invariantID':x,'passed':True} for x in cases[case_id]['invariants']],artifacts=[artifact],executionProvenance=provenance,materializationRunSet=None,nativePackageInspection=None); path=c/'evidence/core-005.json'; dump(path,base); self.refresh(c,{'claim':'milestoneClosure','throughMilestone':'M2'},{'level':'repositoryObservation'}); q=self.execute(campaign=c,qualification='repositoryObservation'); self.assertEqual(q.returncode,0,q.stdout+q.stderr)
  diagnostic['checks'].pop(); dump(c/artifact['id'],diagnostic); base['artifacts'][0]['sha256']=digest(c/artifact['id']); dump(path,base); self.refresh(c,{'claim':'milestoneClosure','throughMilestone':'M2'},{'level':'repositoryObservation'}); q=self.execute(campaign=c,qualification='repositoryObservation'); self.assertIn('complete build-bound shadow isolation',q.stderr)
 def test_scope_missing_case_is_incomplete_and_extra_rejected(self):
  c=self.build_m2(); missing=self.evidence(c,'PERF-008'); value=json.loads(missing.read_text()); (c/value['executionProvenance']['id']).unlink(); (c/value['nativePackageInspection']['id']).unlink(); missing.unlink(); self.refresh(c,{'claim':'milestoneClosure','throughMilestone':'M2'},{'level':'repositoryObservation'}); q=self.execute(campaign=c,qualification='repositoryObservation'); self.assertEqual(q.returncode,0,q.stderr); self.assertEqual(json.loads((c/'aggregate.json').read_text())['status'],'incomplete')
  c=self.build_m2();p=self.evidence(c,'PERF-008');e=json.loads(p.read_text());(c/e['executionProvenance']['id']).unlink();(c/e['nativePackageInspection']['id']).unlink();e.update(status='notRun',buildIdentity=None,buildHost=None,actual={'resultCode':'notRun','summaryCode':'executionNotRun'},measurements=[],executionProvenance=None,nativePackageInspection=None);dump(p,e)
  for index,ref in enumerate([*e['fixtureHashes'],*e['artifacts']]):
   summary=json.loads((c/ref['id']).read_text()); summary['resultCode']='notRun'; summary['checks'][0]['result']='notRun'; ref['id']=f'artifacts/perf-008-not-run-{index}.diagnostic.json'; dump(c/ref['id'],summary); ref['sha256']=digest(c/ref['id'])
  dump(p,e);self.refresh(c,{'claim':'milestoneClosure','throughMilestone':'M2'},{'level':'repositoryObservation'});q=self.execute(campaign=c,qualification='repositoryObservation');self.assertEqual(q.returncode,0,q.stderr);self.assertEqual(json.loads((c/'aggregate.json').read_text())['status'],'incomplete')
  c=self.build_m2(); e=json.loads(self.evidence(c,'PERF-003').read_text()); e['caseID']='PERF-001'; dump(c/'evidence/extra.json',e); self.refresh(c,{'claim':'milestoneClosure','throughMilestone':'M2'},{'level':'repositoryObservation'}); q=self.execute(campaign=c,qualification='repositoryObservation'); self.assertIn('outside aggregate scope',q.stderr)
 def test_case_execution_is_nonclosure_and_m3_derives_prior_cases(self):
  docs=self.docs(); cases=validator.idx(docs['case-catalog.json']['cases'],'id','c'); devices=validator.idx(docs['device-matrix.json']['roles'],'id','d'); providers=validator.idx(docs['provider-matrix.json']['providers'],'id','p'); m3=validator.tuples(cases,devices,providers,{'claim':'milestoneClosure','throughMilestone':'M3'}); self.assertIn(('CORE-005',None,None),m3); self.assertIn(('PERF-003',None,None),m3); self.assertIn(('PERF-008',None,None),m3); self.assertTrue(any(x[0]=='SAF-001' for x in m3)); self.assertEqual(validator.tuples(cases,devices,providers,{'claim':'caseExecution','caseIDs':['PERF-003']}),[('PERF-003',None,None)])
 def test_aggregate_exact_sizes_and_latency_count_rejected(self):
  self.mutate_campaign(lambda c:self.mutate_receipt(c,'materializationRunSet',lambda r:r['gateBindings'][3]['runIDs'].pop(1)),'exact 1/16/256')
  self.mutate_campaign(lambda c:self.mutate_receipt(c,'materializationRunSet',lambda r:r['gateBindings'][0]['runIDs'].pop()),'twenty independent')
  self.mutate_campaign(lambda c:self.mutate_receipt(c,'materializationRunSet',lambda r:r['warmupRunIDs'].append('latency-000')),'too many items')
  self.mutate_campaign(lambda c:self.mutate_receipt(c,'materializationRunSet',lambda r:r['runs'].insert(0,r['runs'].pop(1))),'exactly one first untimed warmup')
 def test_chunk_sequence_size_sum_and_drain_rejected(self):
  self.mutate_campaign(lambda c:self.mutate_receipt(c,'materializationRunSet',lambda r:r['runs'][1]['ingressChunks'][0].update(sequence=1)),'sequences must start zero')
  self.mutate_campaign(lambda c:self.mutate_receipt(c,'materializationRunSet',lambda r:r['runs'][1]['ingressChunks'][0].update(bytes=0)),'numeric bound')
  def stream_sum(receipt):
   run=receipt['runs'][1]; run['streamBytes']=1048575; run['controlDocument']['streamBytes']=run['streamBytes']; control=validator.canonical_json_bytes(run['controlDocument']); run['controlBytes']=len(control); run['controlSha256']=hashlib.sha256(control).hexdigest(); byte_value=validator.synthetic_stream_byte(run['controlDocument']['syntheticSeedSha256']); run['streamSha256']=validator.repeated_digest(byte_value,run['streamBytes']); run['totalInputBytes']=run['controlBytes']+run['streamBytes']; run['totalInputSha256']=hashlib.sha256(validator.TOTAL_INPUT_DOMAIN+run['controlBytes'].to_bytes(8,'big')+run['streamBytes'].to_bytes(8,'big')+bytes.fromhex(run['controlSha256'])+bytes.fromhex(run['streamSha256'])).hexdigest()
  self.mutate_campaign(lambda c:self.mutate_receipt(c,'materializationRunSet',stream_sum),'ingress chunk sum mismatch')
  self.mutate_campaign(lambda c:self.mutate_receipt(c,'materializationRunSet',lambda r:r['runs'][1]['verifiedDrain'].update(descriptorOutputBytes=255)),'verified drain descriptor mismatch')
 def test_chunk_omission_hash_and_rss_mutations_rejected(self):
  self.mutate_campaign(lambda c:self.mutate_receipt(c,'materializationRunSet',lambda r:r['gateBindings'][2]['runIDs'].pop()),'every governed run')
  self.mutate_campaign(lambda c:self.mutate_receipt(c,'materializationRunSet',lambda r:r['runs'][1]['ingressChunks'][0].update(sha256='0'*64)),'chunk manifest hash mismatch')
  self.mutate_campaign(lambda c:self.mutate_receipt(c,'materializationRunSet',lambda r:r['runs'][1]['controlDocument'].update(runID='different-run')),'control/generator identity mismatch')
  self.mutate_campaign(lambda c:self.mutate_receipt(c,'materializationRunSet',lambda r:r['runs'][1].update(streamSha256='0'*64)),'governed deterministic synthetic stream')
  self.mutate_campaign(lambda c:self.mutate_receipt(c,'materializationRunSet',lambda r:r['runs'][-1]['rss'].update(additionalBytes=1)),'peak/additional')
  self.mutate_campaign(lambda c:self.mutate_receipt(c,'materializationRunSet',lambda r:r['runs'][-1]['rss']['samples'][-1].update(elapsedNanoseconds=1)),'filtered, unordered, or outside run')
  def cadence(c): self.mutate_receipt(c,'materializationRunSet',lambda r:r['runs'][-1]['rss']['samples'][1].update(elapsedNanoseconds=10_000_001))
  self.mutate_campaign(cadence,'RSS sample cadence')
  self.mutate_campaign(lambda c:self.mutate_receipt(c,'materializationRunSet',lambda r:r['runs'][-1]['rss']['samples'][0].update(elapsedNanoseconds=1)),'filtered, unordered, or outside run')
 def test_threshold_measurement_self_assertion_and_provenance_rejected(self):
  def threshold(c):
   p=self.evidence(c,'PERF-003'); e=json.loads(p.read_text()); rp=c/e['materializationRunSet']['id']; receipt=json.loads(rp.read_text())
   for run in receipt['runs']:
    if run['purpose']=='latency': run['durationNanoseconds']=200_000_000
   dump(rp,receipt); e['materializationRunSet']['sha256']=digest(rp); gate=next(x for x in e['measurements'] if x['gateID']=='rust-materialize-1mib-p95'); gate['sampleValues']=[200.0]*20; gate['value']=200.0; dump(p,e)
  self.mutate_campaign(threshold,'all measurements passed')
  def samples(c):
   p=self.evidence(c,'PERF-003');e=json.loads(p.read_text());e['measurements'][0]['sampleValues'][0]+=1;dump(p,e)
  self.mutate_campaign(samples,'not exact typed derivation')
  def consumer(c):
   p=self.evidence(c,'PERF-003');e=json.loads(p.read_text());rp=c/e['executionProvenance']['id'];v=json.loads(rp.read_text());v['consumer']={'id':'vox-native-package-inspector-v1','language':'Python','entryPoint':'main','boundary':'sourceBuiltPackageInspector'};dump(rp,v);e['executionProvenance']['sha256']=digest(rp);dump(p,e)
  self.mutate_campaign(consumer,'not allowlisted')
  for field,value in [('language','Python'),('entryPoint','inspect'),('boundary','sourceBuiltPackageInspector')]:
   def cross_contaminate(c,field=field,value=value):
    p=self.evidence(c,'PERF-003');e=json.loads(p.read_text());rp=c/e['executionProvenance']['id'];v=json.loads(rp.read_text());v['consumer'][field]=value;dump(rp,v);e['executionProvenance']['sha256']=digest(rp);dump(p,e)
   self.mutate_campaign(cross_contaminate,'oneOf matched 0')
  def untracked_generator(c):
   repository=self.campaign_repositories[str(c)]; path=validator.EXPECTED_PROVENANCE_PATHS['PERF-003']['inputGenerator']; subprocess.run(['git','rm','--cached','-q','--',path],cwd=repository,check=True)
  self.mutate_campaign(untracked_generator,'not tracked')
  c=self.build_m2(); perf8=self.evidence(c,'PERF-008'); removed=json.loads(perf8.read_text()); (c/removed['executionProvenance']['id']).unlink(); (c/removed['nativePackageInspection']['id']).unlink(); perf8.unlink(); evidence_path=self.evidence(c,'PERF-003'); evidence=json.loads(evidence_path.read_text()); receipt_path=c/evidence['materializationRunSet']['id']; receipt=json.loads(receipt_path.read_text())
  for run in receipt['runs']:
   if run['purpose']=='latency': run['durationNanoseconds']=200_000_000
  dump(receipt_path,receipt); evidence['materializationRunSet']['sha256']=digest(receipt_path); measurement=next(x for x in evidence['measurements'] if x['gateID']=='rust-materialize-1mib-p95'); measurement['sampleValues']=[200.0]*20; measurement['value']=200.0; evidence['status']='failed'; evidence['actual']={'resultCode':'failed','summaryCode':'expectedOutcomeNotObserved'}
  for ref in [*evidence['fixtureHashes'],*evidence['artifacts']]:
   summary=json.loads((c/ref['id']).read_text()); summary['resultCode']='failed'
   for check in summary['checks']: check['result']='failed'
   dump(c/ref['id'],summary); ref['sha256']=digest(c/ref['id'])
  dump(evidence_path,evidence); self.refresh(c,{'claim':'caseExecution','caseIDs':['PERF-003']},{'level':'repositoryObservation'}); q=self.execute(campaign=c,qualification='repositoryObservation'); self.assertEqual(q.returncode,0,q.stdout+q.stderr); self.assertEqual(json.loads((c/'aggregate.json').read_text())['status'],'failed')
 def test_candidate_packaging_baseline_growth_leaf_and_sum_rejected(self):
  self.mutate_campaign(lambda c:self.mutate_receipt(c,'nativePackageInspection',lambda p:p['candidateLeaves'][0].update(baseline={'approvedRegistrySha256':'a'*64,'sourceRevision':'b'*40,'bytes':1,'artifactSha256':'c'*64})),'initial candidate forbids')
  self.mutate_campaign(lambda c:self.mutate_receipt(c,'nativePackageInspection',lambda p:p['candidateLeaves'].pop()),'too few items')
  self.mutate_campaign(lambda c:self.mutate_receipt(c,'nativePackageInspection',lambda p:p.update(appleAggregateBytes=3)),'Apple aggregate')
 def test_future_packaging_without_registry_rejected(self):
  def future(c):
   def f(p):
    p['comparisonMode']='approvedBaselineComparison'
    for x in p['candidateLeaves']:x['baseline']={'approvedRegistrySha256':'a'*64,'sourceRevision':'b'*40,'bytes':1,'artifactSha256':'c'*64}
   self.mutate_receipt(c,'nativePackageInspection',f)
  self.mutate_campaign(future,'requires governed baseline registry')
 def test_governed_future_package_baseline_passes_and_mutations_fail(self):
  verifier=lambda kind,record,subject: True
  def direct(root,c): validator.validate(root,c,self.campaign_repositories[str(c)],'repositoryObservation',None,verifier)
  root=self.copy_contracts(); c=self.build_m2(); registry_path,approval_path,receipt_path=self.adopt_package_baseline(c,root); direct(root,c); q=self.execute(root=root,campaign=c,qualification='repositoryObservation'); self.assertIn('authenticated hosted-evidence approval verifier',q.stderr)
  def validate_after(mutate,needle,refresh_aggregate=True):
   local_root=self.copy_contracts(); local_c=self.build_m2(); reg,approval,receipt=self.adopt_package_baseline(local_c,local_root); mutate(reg,approval,receipt); self.commit_root(local_root,'synthetic baseline mutation')
   if refresh_aggregate:self.refresh(local_c,{'claim':'milestoneClosure','throughMilestone':'M2'},{'level':'repositoryObservation'},local_root)
   try: direct(local_root,local_c)
   except validator.ValidationError as error: self.assertIn(needle,str(error))
   else: self.fail('synthetic baseline mutation unexpectedly passed')
  validate_after(lambda r,a,p: dump(a,{**json.loads(a.read_text()),'subjectSha256':'0'*64}),'hash-bound adoption approval')
  validate_after(lambda r,a,p: dump(a,{**json.loads(a.read_text()),'approvalID':'different-baseline-adoption'}),'hash-bound adoption approval')
  validate_after(lambda r,a,p: dump(a,{**json.loads(a.read_text()),'expiresAt':'2025-01-01T00:00:00Z'}),'future or expired')
  validate_after(lambda r,a,p: dump(r,{**json.loads(r.read_text()),'hostedEvidenceAggregateSha256':'0'*64}),'hash-bound adoption approval')
  validate_after(lambda r,a,p: dump(r,{**json.loads(r.read_text()),'hostedArtifactArchiveSha256':'0'*64}),'hash-bound adoption approval')
  def registry_toolchain(reg,approval,receipt):
   value=json.loads(reg.read_text()); value['toolchainManifestSha256']='0'*64; dump(reg,value); adopted=json.loads(approval.read_text()); adopted['subjectSha256']=digest(reg); dump(approval,adopted)
  validate_after(registry_toolchain,'identically scoped')
  def candidate_configuration(reg,approval,receipt):
   value=json.loads(receipt.read_text()); value['buildConfiguration']='debug'; dump(receipt,value); evidence=self.evidence(receipt.parent.parent,'PERF-008'); item=json.loads(evidence.read_text()); item['nativePackageInspection']['sha256']=digest(receipt); dump(evidence,item)
  validate_after(candidate_configuration,'const mismatch')
  def candidate_feature(reg,approval,receipt):
   value=json.loads(receipt.read_text()); value['featureSet']='experimental'; dump(receipt,value); evidence=self.evidence(receipt.parent.parent,'PERF-008'); item=json.loads(evidence.read_text()); item['nativePackageInspection']['sha256']=digest(receipt); dump(evidence,item)
  validate_after(candidate_feature,'const mismatch')
  def artifact_identity(reg,approval,receipt):
   value=json.loads(receipt.read_text()); value['candidateLeaves'][0]['artifactID']='changed-artifact'; dump(receipt,value); evidence=self.evidence(receipt.parent.parent,'PERF-008'); item=json.loads(evidence.read_text()); item['nativePackageInspection']['sha256']=digest(receipt); dump(evidence,item)
  validate_after(artifact_identity,'baseline registry mismatch')
  def leaf_order(reg,approval,receipt):
   value=json.loads(reg.read_text()); value['leaves'][0],value['leaves'][1]=value['leaves'][1],value['leaves'][0]; dump(reg,value); adopted=json.loads(approval.read_text()); adopted['subjectSha256']=digest(reg); dump(approval,adopted)
  validate_after(leaf_order,'exact leaf identity/order')
  removed_root=self.copy_contracts(); removed_campaign=self.build_m2(); reg,approval,receipt=self.adopt_package_baseline(removed_campaign,removed_root); reg.unlink(); approval.unlink(); self.commit_root(removed_root,'remove synthetic baseline')
  try: direct(removed_root,removed_campaign)
  except validator.ValidationError as error: self.assertIn('adoption is monotonic',str(error))
  else: self.fail('removed baseline unexpectedly passed')
 def test_host_identity_and_qualification_rejected(self):
  c=self.build_m2(); q=subprocess.run([sys.executable,str(VALIDATOR),'--contracts-root',str(CONTRACTS),'--campaign-dir',str(c),'--qualification','repositoryObservation'],text=True,capture_output=True); self.assertIn('--repository-root provenance verification',q.stderr)
  def fake_device(c):
   p=self.evidence(c,'PERF-003');e=json.loads(p.read_text());e['buildHost']=None;e['device']={'roleID':'phone-low-api28','manufacturer':'Google','model':'Pixel 3','serialHash':'a'*64,'osVersion':'synthetic','apiLevel':28,'buildFingerprint':'synthetic/fingerprint','totalStorageBytes':1,'freeStorageBytes':1};dump(p,e)
  self.mutate_campaign(fake_device,'build-host target')
  c=self.build_m2();q=self.execute(campaign=c,qualification='hostedRun');self.assertIn('declared qualification',q.stderr)
 def test_hosted_requires_external_root_and_not_retained_rejected(self):
  c=self.build_m2('hostedRun'); q=self.execute(campaign=c,qualification='hostedRun'); self.assertIn('external-artifact-root',q.stderr)
  ext=Path(tempfile.mkdtemp());self.addCleanup(lambda:shutil.rmtree(ext));q=self.execute(campaign=c,qualification='hostedRun',external=ext);self.assertIn('hosted qualification workflow hash mismatch',q.stderr)
 def test_hosted_package_case_executes_with_environment_archive_and_exact_inventory(self):
  c,external,env=self.build_hosted_package_case(); q=self.execute(campaign=c,qualification='hostedRun',external=external,env=env); self.assertEqual(q.returncode,0,q.stdout+q.stderr); self.assertEqual(json.loads((c/'aggregate.json').read_text())['status'],'passed')
  bad=dict(env); bad['GITHUB_RUN_ID']='124'; q=self.execute(campaign=c,qualification='hostedRun',external=external,env=bad); self.assertIn('run environment mismatch',q.stderr)
  bad=dict(env); bad['GITHUB_WORKFLOW_REF']='owner/repository/core-rust-ci.yml@refs/heads/main'; q=self.execute(campaign=c,qualification='hostedRun',external=external,env=bad); self.assertIn('workflow environment mismatch',q.stderr)
  extra=external/'unclaimed.log'; extra.write_text('unclaimed\n'); q=self.execute(campaign=c,qualification='hostedRun',external=external,env=env); self.assertIn('external artifact inventory differs',q.stderr); extra.unlink()
  archive=external/'archives/m2.tar'; original_archive=archive.read_bytes(); archive.write_bytes(original_archive+b'x'); q=self.execute(campaign=c,qualification='hostedRun',external=external,env=env); self.assertIn('hosted artifact archive hash mismatch',q.stderr); archive.write_bytes(original_archive)
  def rebind_archive(data):
   archive.write_bytes(data); aggregate=json.loads((c/'aggregate.json').read_text()); qualification=aggregate['qualification']; qualification['artifactArchiveSha256']=digest(archive); evidence_path=self.evidence(c,'PERF-008'); evidence=json.loads(evidence_path.read_text()); receipt_path=c/evidence['nativePackageInspection']['id']; receipt=json.loads(receipt_path.read_text()); receipt['retention']['archiveSha256']=qualification['artifactArchiveSha256']; dump(receipt_path,receipt); evidence['nativePackageInspection']['sha256']=digest(receipt_path); dump(evidence_path,evidence); self.refresh(c,aggregate['scope'],qualification)
  rebind_archive(original_archive+b'x'+b'\x00'*511); q=self.execute(campaign=c,qualification='hostedRun',external=external,env=env); self.assertIn('trailing payload',q.stderr); rebind_archive(original_archive)
  pax_path=c.parent/'pax.tar'; retained=sorted(path for path in external.rglob('*') if path.is_file() and path!=archive)
  with tarfile.open(pax_path,'w',format=tarfile.PAX_FORMAT) as handle:
   for index,path in enumerate(retained):
    info=handle.gettarinfo(str(path),arcname=str(path.relative_to(external)))
    if index==0: info.pax_headers={'comment':'undeclared-extension-payload'}
    with path.open('rb') as source: handle.addfile(info,source)
  rebind_archive(pax_path.read_bytes()); q=self.execute(campaign=c,qualification='hostedRun',external=external,env=env); self.assertIn('forbids non-USTAR regular or extension members',q.stderr); rebind_archive(original_archive)
  executable=external/'executables/package-inspector.py'; original=executable.read_bytes(); executable.write_bytes(b'changed'); q=self.execute(campaign=c,qualification='hostedRun',external=external,env=env); self.assertIn('executable bytes/hash mismatch',q.stderr); executable.write_bytes(original)
 def test_hosted_package_external_bytes_and_symlink_rejected(self):
  repository=self.synthetic_repository(); build=self.build_identity(repository); q={'level':'hostedRun','runID':'123','runAttempt':1,'artifactArchiveSha256':'9'*64}; receipt=self.package(build,retention={'kind':'hostedArtifact','runID':'123','runAttempt':1,'artifactName':'synthetic-packages','archiveSha256':'9'*64,'retentionExpiresAt':'2099-01-01T00:00:00Z'}); ext=Path(tempfile.mkdtemp());self.addCleanup(lambda:shutil.rmtree(ext));(ext/'packages').mkdir()
  for leaf in receipt['candidateLeaves']:
   path=ext/leaf['relativeArtifactPath']; path.parent.mkdir(parents=True,exist_ok=True); arch=leaf['architectures'][0]; data=bytearray(max(1000,leaf['bytes']))
   if leaf['format']=='elf-shared-object': data=bytearray(elf_library(arch))
   path.write_bytes(data); leaf['bytes']=len(data); leaf['sha256']=digest(path)
  receipt['appleAggregateBytes']=sum(x['bytes'] for x in receipt['candidateLeaves'][-2:]); metadata_path=ext/receipt['xcframeworkMetadata']['relativeArtifactPath']; metadata_path.write_bytes(plistlib.dumps({'CFBundlePackageType':'XFWK','XCFrameworkFormatVersion':'1.0','AvailableLibraries':[{'LibraryIdentifier':'ios-arm64','LibraryPath':'libVoxCoreFFI.a','SupportedArchitectures':['arm64'],'SupportedPlatform':'ios'},{'LibraryIdentifier':'ios-arm64_x86_64-simulator','LibraryPath':'libVoxCoreFFI.a','SupportedArchitectures':['arm64','x86_64'],'SupportedPlatform':'ios','SupportedPlatformVariant':'simulator'}]},fmt=plistlib.FMT_XML,sort_keys=True)); receipt['xcframeworkMetadata'].update(bytes=metadata_path.stat().st_size,sha256=digest(metadata_path))
  self.assertRaisesRegex(validator.ValidationError,'binary format',validator.validate_package,receipt,build,q,ext,None)
  leaf=receipt['candidateLeaves'][0]; path=ext/leaf['relativeArtifactPath']; leaf['bytes']=path.stat().st_size; leaf['sha256']=digest(path); path.write_bytes(b'changed');self.assertRaisesRegex(validator.ValidationError,'bytes/hash mismatch',validator.validate_package,receipt,build,q,ext,None)
  path.unlink();path.symlink_to(ext/receipt['candidateLeaves'][1]['relativeArtifactPath']);self.assertRaisesRegex(validator.ValidationError,'symlinks',validator.validate_package,receipt,build,q,ext,None)
 def test_direct_native_format_and_architecture_parsing(self):
  t=tempfile.TemporaryDirectory(); self.addCleanup(t.cleanup); root=Path(t.name)
  for arch,machine in [('arm64',183),('armv7',40),('x86_64',62),('x86',3)]:
   data=bytearray(elf_library(arch)); path=root/f'{arch}.so'; path.write_bytes(data); validator.inspect_external_package_leaf(path,{'format':'elf-shared-object','architectures':[arch]}); data[16:18]=(2).to_bytes(2,'little'); path.write_bytes(data); self.assertRaisesRegex(validator.ValidationError,'not an ELF shared object',validator.inspect_external_package_leaf,path,{'format':'elf-shared-object','architectures':[arch]})
  no_program=bytearray(elf_library('arm64')); no_program[56:58]=(0).to_bytes(2,'little'); no_program_path=root/'no-program.so'; no_program_path.write_bytes(no_program); self.assertRaisesRegex(validator.ValidationError,'program-header table',validator.inspect_external_package_leaf,no_program_path,{'format':'elf-shared-object','architectures':['arm64']})
  symbol_mutation=bytearray(elf_library('arm64')); offset=symbol_mutation.index(validator.UNIFFI_BUILD_INFO_SYMBOL.encode()); symbol_mutation[offset]=ord('x'); symbol_path=root/'missing-symbol.so'; symbol_path.write_bytes(symbol_mutation); self.assertRaisesRegex(validator.ValidationError,'omits required.*UniFFI symbol',validator.inspect_external_package_leaf,symbol_path,{'format':'elf-shared-object','architectures':['arm64']})
  local_symbol=bytearray(elf_library('arm64')); marker=struct.pack('<IBBH',1,0x12,0,4); offset=local_symbol.index(marker); local_symbol[offset+4]=0x02; local_path=root/'local-symbol.so'; local_path.write_bytes(local_symbol); self.assertRaisesRegex(validator.ValidationError,'visible global',validator.inspect_external_package_leaf,local_path,{'format':'elf-shared-object','architectures':['arm64']})
  dependency_mutation=bytearray(elf_library('arm64')); offset=dependency_mutation.index(b'libc.so'); dependency_mutation[offset:offset+7]=b'evil.so'; dependency_path=root/'bad-dependency.so'; dependency_path.write_bytes(dependency_mutation); self.assertRaisesRegex(validator.ValidationError,'dependency allowlist',validator.inspect_external_package_leaf,dependency_path,{'format':'elf-shared-object','architectures':['arm64']})
  dual_hash=bytearray(elf_library('arm64')); program_offset=int.from_bytes(dual_hash[32:40],'little'); dynamic_offset=int.from_bytes(dual_hash[program_offset+56+8:program_offset+56+16],'little'); dual_hash[dynamic_offset+16:dynamic_offset+24]=(0x6ffffef5).to_bytes(8,'little'); dual_hash[dynamic_offset+24:dynamic_offset+32]=(0).to_bytes(8,'little'); dual_path=root/'bad-gnu-hash.so'; dual_path.write_bytes(dual_hash); self.assertRaisesRegex(validator.ValidationError,'every advertised loader hash table',validator.inspect_external_package_leaf,dual_path,{'format':'elf-shared-object','architectures':['arm64']})
  thin=root/'thin.a'; thin.write_bytes(apple_archive('arm64',2,True)); validator.inspect_external_package_leaf(thin,{'format':'apple-static-library','architectures':['arm64'],'targetScope':'xcframework-ios-device-arm64'})
  missing_symbol=bytearray(apple_archive('arm64',2)); offset=missing_symbol.index(validator.UNIFFI_BUILD_INFO_SYMBOL.encode()); missing_symbol[offset]=ord('x'); bad_symbol=root/'bad-symbol.a'; bad_symbol.write_bytes(missing_symbol); self.assertRaisesRegex(validator.ValidationError,'omits required.*UniFFI symbol',validator.inspect_external_package_leaf,bad_symbol,{'format':'apple-static-library','architectures':['arm64'],'targetScope':'xcframework-ios-device-arm64'})
  local_symbol=bytearray(apple_archive('arm64',2)); marker=struct.pack('<IBBHQ',1,0x0f,1,0,0); offset=local_symbol.index(marker); local_symbol[offset+4]=0x0e; local_archive=root/'local-symbol.a'; local_archive.write_bytes(local_symbol); self.assertRaisesRegex(validator.ValidationError,'visible external',validator.inspect_external_package_leaf,local_archive,{'format':'apple-static-library','architectures':['arm64'],'targetScope':'xcframework-ios-device-arm64'})
  zero_fill=bytearray(apple_archive('arm64',2)); offset=zero_fill.index((0x80000400).to_bytes(4,'little')); zero_fill[offset:offset+4]=(0x80000412).to_bytes(4,'little'); zero_fill_archive=root/'zero-fill-symbol.a'; zero_fill_archive.write_bytes(zero_fill); self.assertRaisesRegex(validator.ValidationError,'visible external',validator.inspect_external_package_leaf,zero_fill_archive,{'format':'apple-static-library','architectures':['arm64'],'targetScope':'xcframework-ios-device-arm64'})
  disguised_name=b'__.SYMDEF_payload'; body=b'not-mach-o'; header=f'#1/{len(disguised_name)}'.encode().ljust(16)+b'0'.ljust(12)+b'0'.ljust(6)+b'0'.ljust(6)+b'100644'.ljust(8)+str(len(disguised_name)+len(body)).encode().ljust(10)+b'`\n'; disguised=root/'disguised.a'; disguised.write_bytes(b'!<arch>\n'+header+disguised_name+body+(b'\n' if (len(disguised_name)+len(body))&1 else b'')); self.assertRaisesRegex(validator.ValidationError,'Mach-O',validator.inspect_external_package_leaf,disguised,{'format':'apple-static-library','architectures':['arm64'],'targetScope':'xcframework-ios-device-arm64'})
  wrong_target=bytearray(apple_archive('arm64',2)); offset=wrong_target.index((0x00110600).to_bytes(4,'little')); wrong_target[offset:offset+4]=(0x00110500).to_bytes(4,'little'); bad_target=root/'bad-target.a'; bad_target.write_bytes(wrong_target); self.assertRaisesRegex(validator.ValidationError,'deployment target',validator.inspect_external_package_leaf,bad_target,{'format':'apple-static-library','architectures':['arm64'],'targetScope':'xcframework-ios-device-arm64'})
  fat=root/'fat.a'; fat.write_bytes(apple_fat_archive()); validator.inspect_external_package_leaf(fat,{'format':'apple-static-library','architectures':['arm64','x86_64'],'targetScope':'xcframework-ios-simulator-arm64-x86_64'})
  malformed=root/'malformed.a'; malformed.write_bytes(b'!<arch>\n'+b'bad.o/'.ljust(16)+b'0'.ljust(12)+b'0'.ljust(6)+b'0'.ljust(6)+b'100644'.ljust(8)+b'-1'.ljust(10)+b'`\n'+b'x'*1024); self.assertRaisesRegex(validator.ValidationError,'member size mismatch',validator.inspect_external_package_leaf,malformed,{'format':'apple-static-library','architectures':['arm64'],'targetScope':'xcframework-ios-device-arm64'})
  executable=root/'host'; command_bytes=176; entry=32+command_bytes; header=struct.pack('<IiiIIIII',0xfeedfacf,0x0100000c,0,2,2,command_bytes,0,0); segment_header=struct.pack('<II16sQQQQiiII',0x19,152,b'__TEXT',0,1,entry,1,7,5,1,0); section=struct.pack('<16s16sQQIIIIIIII',b'__text',b'__TEXT',0,1,entry,0,0,0,0x80000400,0,0,0); main=struct.pack('<IIQQ',0x80000028,24,entry,0); executable.write_bytes(header+segment_header+section+main+b'\xc3'); validator.inspect_macho_executable(executable,'ARM64'); header_entry=bytearray(executable.read_bytes()); main_offset=32+152; header_entry[main_offset+8:main_offset+16]=(0).to_bytes(8,'little'); bad_entry=root/'header-entry'; bad_entry.write_bytes(header_entry); self.assertRaisesRegex(validator.ValidationError,'instruction-section LC_MAIN',validator.inspect_macho_executable,bad_entry,'ARM64'); bad_executable=root/'bad-host'; bad_executable.write_bytes(b'x'); self.assertRaisesRegex(validator.ValidationError,'Mach-O',validator.inspect_macho_executable,bad_executable,'ARM64')
 def test_release_gate_requires_real_approvals_and_physical_identity_stays_strict(self):
  self.assertEqual(self.docs()['approval-policy.json']['qualificationRequirements']['releaseGate'],['definition','campaign','releaseGate'])
  cases=validator.idx(self.docs()['case-catalog.json']['cases'],'id','case');self.assertEqual(cases['REC-001']['executionTarget'],'physicalDevice');self.assertTrue(cases['REC-001']['deviceRoles'])
  schema=self.schemas()['case-evidence.schema.json'];valid=json.loads((CONTRACTS/'fixtures/validation/evidence/valid-synthetic.json').read_text());validator.schema_validate(valid,schema,schema);self.assertEqual(valid['buildIdentity']['kind'],'signedApplication');self.assertIsNotNone(valid['device'])
  c=self.build_m2(); self.refresh(c,{'claim':'caseExecution','caseIDs':['PERF-003','PERF-008']},{'level':'repositoryObservation'}); a=json.loads((c/'aggregate.json').read_text()); a['qualification']={'level':'releaseGate','runID':'123','runAttempt':1,'workflowRepositoryPath':'.github/workflows/core-rust-ci.yml','workflowSha256':'8'*64,'artifactArchivePath':'archives/m2.tar','artifactArchiveSha256':'9'*64}; dump(c/'aggregate.json',a); q=self.execute(campaign=c,qualification='releaseGate',external=c/'artifacts'); self.assertIn('caseExecution scope cannot claim releaseGate',q.stderr)
  c=self.build_m2(); a=json.loads((c/'aggregate.json').read_text()); release={'level':'releaseGate','runID':'123','runAttempt':1,'workflowRepositoryPath':'.github/workflows/core-rust-ci.yml','workflowSha256':'8'*64,'artifactArchivePath':'archives/m2.tar','artifactArchiveSha256':'9'*64}; a['qualification']=release; dump(c/'aggregate.json',a); q=self.execute(campaign=c,qualification='releaseGate',external=c/'artifacts'); self.assertIn('authenticated approval verifier',q.stderr)
 def test_m3_scope_mixed_build_identities_and_blocked_wear_are_representable(self):
  docs=self.docs(); cases=validator.idx(docs['case-catalog.json']['cases'],'id','case'); devices=validator.idx(docs['device-matrix.json']['roles'],'id','device'); providers=validator.idx(docs['provider-matrix.json']['providers'],'id','provider'); scope={'claim':'milestoneClosure','throughMilestone':'M3'}; required=validator.tuples(cases,devices,providers,scope)
  identities=[]
  for case_id,role_id,provider_id in required:
   if cases[case_id]['executionTarget']!='physicalDevice': identities.append(('sourceBuiltHost','a'*40,'1'*64,'host-executable-'+case_id))
   else: identities.append(('signedApplication','a'*40,'1'*64,'signed-app'))
  coherent={(kind_source[1],kind_source[2]) for kind_source in identities}; self.assertEqual(coherent,{('a'*40,'1'*64)}); self.assertGreater(len(set(identities)),1)
  wear_case=next(c for c in cases.values() if c['executionTarget']=='physicalDevice' and any(devices[r]['platform']=='wearOS' for r in c['deviceRoles'])); self.assertEqual(wear_case['milestone'],'M7'); self.assertEqual('blocked','blocked')
 def test_campaign_file_counts_artifact_inventory_and_root_symlinks_rejected(self):
  c=self.build_m2(); (c/'artifacts/unreferenced.diagnostic.json').write_text('{}\n'); q=self.execute(campaign=c,qualification='repositoryObservation'); self.assertIn('artifact inventory differs',q.stderr)
  c=self.build_m2()
  for index in range(255): dump(c/f'evidence/overflow-{index:03d}.json',{})
  q=self.execute(campaign=c,qualification='repositoryObservation'); self.assertIn('exceeds 256 file bound',q.stderr)
  c=self.build_m2(); linked=c.parent/'campaign-link'; linked.symlink_to(c,target_is_directory=True); q=self.execute(campaign=linked,qualification='repositoryObservation'); self.assertIn('non-symlink directory',q.stderr)
  external=Path(tempfile.mkdtemp()); self.addCleanup(lambda:shutil.rmtree(external)); external_link=external.parent/(external.name+'-link'); external_link.symlink_to(external,target_is_directory=True); self.addCleanup(lambda:external_link.unlink(missing_ok=True)); c=self.build_m2('hostedRun'); q=self.execute(campaign=c,qualification='hostedRun',external=external_link); self.assertIn('external artifact root must be a non-symlink directory',q.stderr)
  self.assertFalse(validator.json_equal(True,1)); self.assertTrue(validator.json_equal(1,1.0)); self.assertRaisesRegex(validator.ValidationError,'const mismatch',validator.schema_validate,True,{'const':1},{'const':1})
 def test_safe_paths_symlink_and_oversize_rejected(self):
  def traversal(c):
   p=self.evidence(c,'PERF-003');e=json.loads(p.read_text());e['executionProvenance']['id']='../outside';dump(p,e)
  self.mutate_campaign(traversal,'oneOf matched 0')
  c=self.build_m2(); outside=c.parent/'outside';outside.write_text('{}');link=c/'artifacts/link.json';link.symlink_to(outside);p=self.evidence(c,'PERF-003');e=json.loads(p.read_text());e['executionProvenance']={'id':'artifacts/link.json','sha256':digest(outside)};dump(p,e);self.refresh(c,{'claim':'milestoneClosure','throughMilestone':'M2'},{'level':'repositoryObservation'});q=self.execute(campaign=c,qualification='repositoryObservation');self.assertIn('symlink',q.stderr)
  t=tempfile.TemporaryDirectory();self.addCleanup(t.cleanup);p=Path(t.name)/'huge.json';p.write_bytes(b' '* (validator.MAX_JSON_BYTES+1));self.assertRaises(validator.ValidationError,validator.load,p)
  for value in ('a/./b','a//b','a/b/'):
   self.assertRaisesRegex(validator.ValidationError,'noncanonical',validator.safe_relative,value,'test path')
   for schema_name,definition in [('aggregate.schema.json','safePath'),('case-evidence.schema.json','safePath'),('execution-provenance.schema.json','path'),('materialization-run-set.schema.json','path'),('native-package-inspection.schema.json','path')]:
    schema=self.schemas()[schema_name]; self.assertRaises(validator.ValidationError,validator.schema_validate,value,schema['$defs'][definition],schema)
  self.assertRaisesRegex(validator.ValidationError,'duplicate JSON property',validator.strict_json_loads,b'{"a":1,"a":2}','duplicate-test'); self.assertRaisesRegex(validator.ValidationError,'non-finite',validator.strict_json_loads,b'{"a":1e999}','nonfinite-test')
 def test_schema_fixtures(self):
  schemas=self.schemas()
  for f,s,ok in [('definitions/valid-device-matrix.json','device-matrix.schema.json',True),('evidence/valid-synthetic.json','case-evidence.schema.json',True),('evidence/invalid-empty-passed.json','case-evidence.schema.json',False),('aggregate/valid-synthetic.json','aggregate.schema.json',True),('aggregate/invalid-empty-passed.json','aggregate.schema.json',False),('approvals/valid-synthetic.json','approval.schema.json',True)]:
   try:validator.schema_validate(json.loads((CONTRACTS/'fixtures/validation'/f).read_text()),schemas[s],schemas[s])
   except validator.ValidationError:self.assertFalse(ok,f)
   else:self.assertTrue(ok,f)

if __name__=='__main__': unittest.main()
