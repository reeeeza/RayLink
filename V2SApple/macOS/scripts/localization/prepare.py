import json,pathlib,re,textwrap
ROOT=pathlib.Path(__file__).resolve().parents[2]
# Extract human-facing source literals, including custom view-helper parameters,
# model errors and privacy notices that Text-only extraction does not discover.
def literals(source):
 i=0
 while i<len(source):
  if source.startswith('//',i):
   i=source.find('\n',i)
   if i<0:return
   continue
  if source.startswith('/*',i):
   end=source.find('*/',i+2);i=len(source) if end<0 else end+2;continue
  if source[i]!='"':i+=1;continue
  triple=source.startswith('"""',i);term='"""' if triple else '"';i+=len(term);value=''
  while i<len(source):
   if source.startswith(term,i):i+=len(term);break
   if source.startswith('\\(',i):
    i+=2;depth=1
    while i<len(source) and depth:
     if source[i]=='"':
      i+=1
      while i<len(source):
       if source[i]=='\\':i+=2;continue
       if source[i]=='"':i+=1;break
       i+=1
      continue
     if source[i]=='(':depth+=1
     elif source[i]==')':depth-=1
     i+=1
    value+='%@';continue
   if source[i]=='\\' and i+1<len(source):
    nxt=source[i+1];value+={'n':'\n','r':'\r','t':'\t','"':'"','\\':'\\'}.get(nxt,'\\'+nxt);i+=2;continue
   value+=source[i];i+=1
  if triple:value=textwrap.dedent(value.lstrip('\n')).rstrip('\n')
  yield value

keys=set(json.loads((ROOT/'localization-work/extracted.json').read_text()))
paths=[p for folder in ['V2S','Shared'] for p in (ROOT/folder).glob('*.swift') if ' 2.' not in p.name and p.name!='V2SPresentation.swift']
for path in paths:
 for value in literals(path.read_text()):
  if not re.search(r'[A-Za-z]',value):continue
  if re.match(r'^[A-Za-z][A-Za-z0-9+.-]*://',value):continue
  if '\n' not in value and not re.search(r'[A-Za-z][A-Za-z ]* ',value) and not re.fullmatch(r'[A-Z][A-Za-z-]+',value):continue
  if re.search(r'^(?:ca\.|v2s\.|com\.|/|SELECT |INSERT |UPDATE |CREATE |DELETE |PRAGMA )',value):continue
  if re.search(r'\\[dwsb]|\[A-Za-z|\^\[',value):continue
  keys.add(value)
# Existing manually reviewed UI translations remain preferred for matching keys.
source=(ROOT/'V2S/V2SPresentation.swift').read_text()
overrides={}
for m in re.finditer(r'^\s*"([^"\n]+)": \["([^"\n]*)", "([^"\n]*)"\]',source,re.M):
 keys.add(m[1]);overrides[m[1]]={'fa':m[2],'fr':m[3]}
# Terms and reusable labels needed by runtime view/model helpers.
keys.update(['Language','LANGUAGE','English','Connected time','Location not provided','month','year','day','days','week','weeks','months','years','Monthly plan','Yearly plan','Premium information and navigation use the selected language.'])
keys={k for k in keys if k.strip() and k not in ['true','false','nil']}
(ROOT/'localization-work/source-keys.json').write_text(json.dumps(sorted(keys),ensure_ascii=False,indent=2))
(ROOT/'localization-work/manual-overrides.json').write_text(json.dumps(overrides,ensure_ascii=False,indent=2))
print('Public interface source strings:',len(keys),'characters:',sum(map(len,keys)))
