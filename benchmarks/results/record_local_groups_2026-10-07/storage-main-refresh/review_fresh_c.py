import re,json,difflib,hashlib,sys
from pathlib import Path
root=Path(sys.argv[1])
header=re.compile(r'(?m)^([A-Za-z_][^\n;{}]*\b([A-Za-z_]\w*)\([^\n]*\) \{\n)')
local=re.compile(r'brp_v(?:n?_[A-Za-z0-9]+|d_[A-Za-z0-9_]+)')
token=re.compile(r""""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|/\*.*?\*/|//[^\n]*|[{}]""",re.S)
def parts(text):
 result={}; outside=[]; prev=0
 for m in header.finditer(text):
  if m.start()<prev: continue
  depth=1;end=None
  for t in token.finditer(text,m.end()):
   if t.group()=='{': depth+=1
   elif t.group()=='}':
    depth-=1
    if depth==0: end=t.end();break
  if end is None: raise ValueError(m.group(2))
  outside.append(text[prev:m.start()]);prev=end
  result[m.group(2)]=text[m.start():end]
 outside.append(text[prev:]);return result,''.join(outside)
def alpha(text):
 names={}
 def replace(m):
  return names.setdefault(m.group(),f'local_{len(names)}')
 return local.sub(replace,text)
a=(root/'baseline-main-self.c').read_text();b=(root/'candidate-main-self.c').read_text()
x,ox=parts(a);y,oy=parts(b)
raw=[];meaningful=[];diff=[]
for name in sorted(x.keys()|y.keys()):
 if x.get(name)!=y.get(name):
  raw.append(name)
  before=alpha(x.get(name,''));after=alpha(y.get(name,''))
  if before!=after:
   meaningful.append({'symbol':name,'before_bytes':len(x.get(name,'')),'after_bytes':len(y.get(name,''))})
   diff.extend(difflib.unified_diff(before.splitlines(True),after.splitlines(True),fromfile='baseline:'+name,tofile='candidate:'+name))
summary={'baseline_bytes':len(a),'candidate_bytes':len(b),'delta':len(b)-len(a),'baseline_sha256':hashlib.sha256(a.encode()).hexdigest(),'candidate_sha256':hashlib.sha256(b.encode()).hexdigest(),'outside_functions_identical':ox==oy,'outside_after_local_names_identical':local.sub('LOCAL',ox)==local.sub('LOCAL',oy),'functions_added':sorted(y.keys()-x.keys()),'functions_removed':sorted(x.keys()-y.keys()),'raw_changed':raw,'meaningful_changed':meaningful,'parser_functions':len(x)}
(root/'fresh-c-review-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
(root/'fresh-c-review-alpha.diff').write_text(''.join(diff))
(root/'fresh-c-review-outside.diff').write_text(''.join(difflib.unified_diff(local.sub('LOCAL',ox).splitlines(True),local.sub('LOCAL',oy).splitlines(True),fromfile='baseline-outside',tofile='candidate-outside')))
print(json.dumps({**{k:v for k,v in summary.items() if k not in ('raw_changed','meaningful_changed')},'raw_count':len(raw),'meaningful_changed':meaningful},indent=2))
