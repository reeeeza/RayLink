import json,pathlib,re,collections
ROOT=pathlib.Path(__file__).resolve().parents[2];WORK=ROOT/'localization-work'
keys=json.loads((WORK/'source-keys.json').read_text());overrides=json.loads((WORK/'manual-overrides.json').read_text())
langmap={'fa':'fa','ar':'ar','zh-CN':'zh-Hans','ru':'ru','es':'es','pt':'pt','fr':'fr','de':'de'}
translations={langmap[code]:json.loads((WORK/('translations-'+code+'.json')).read_text()) for code in langmap}
strings={}
for key in keys:
 localizations={'en':{'stringUnit':{'state':'translated','value':key}}}
 for lang,values in translations.items():
  value=overrides.get(key,{}).get(lang,values[key])
  # Existing reviewed overrides use unnumbered arguments; number these safely.
  index=[0]
  def number(m): index[0]+=1;return '%'+str(index[0])+'$'+m[0][1:]
  if lang in overrides.get(key,{}):value=re.sub(r'%(?:lld|ld|d|f|@)',number,value)
  localizations[lang]={'stringUnit':{'state':'translated','value':value}}
 strings[key]={'extractionState':'manual','localizations':localizations}
result={'sourceLanguage':'en','strings':strings,'version':'1.0'}
(ROOT/'V2S/Localizable.xcstrings').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
print('CATALOG:',len(strings),'keys x',len(langmap)+1,'languages')
