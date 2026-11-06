"""Translate only extracted public interface prose, never runtime/customer data.
Keep placeholders, URLs and protocol/brand names intact, with bounded retries.
"""
import concurrent.futures,json,pathlib,re,time,urllib.parse,urllib.request
ROOT=pathlib.Path(__file__).resolve().parents[2]
WORK=ROOT/'localization-work';keys=json.loads((WORK/'source-keys.json').read_text())
terms=['V2S','VLESS','VMess','Trojan','TROJAN','Shadowsocks','WireGuard','OpenVPN','Xray','V2Ray','IPv4','IPv6','HTTPS','HTTP','DNS','TLS','Mux','macOS','Mac App Store','App Store','Keychain','NetworkExtension','Apple Account','Apple','Cloudflare','Google','Wi-Fi','USB','Thunderbolt','On Demand']
protected=re.compile(r'https?://[^\s]+|%(?:\d+\$)?(?:lld|ld|d|f|@)|'+ '|'.join(re.escape(t) for t in sorted(terms,key=len,reverse=True)))

def protect(text):
    values=[];argument=0
    def keep(m):
        nonlocal argument
        original=m[0]
        if original.startswith('%') and '$' not in original:
            argument+=1;original='%'+str(argument)+'$'+original[1:]
        values.append(original)
        return '__V2SP'+str(len(values)-1)+'__' 
    return protected.sub(keep,text),values

def request(text,lang):
    url='https://translate.googleapis.com/translate_a/single?'+urllib.parse.urlencode({'client':'gtx','sl':'en','tl':lang,'dt':'t','q':text})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(url,timeout=25) as response:data=json.load(response)
            return ''.join(segment[0] for segment in data[0] if segment[0])
        except Exception:
            if attempt==2:raise
            time.sleep(1+attempt*2)

def translate_language(lang):
    destination=WORK/('translations-'+lang+'.json')
    done=json.loads(destination.read_text()) if destination.exists() else {}
    pending=[(i,key) for i,key in enumerate(keys) if key not in done]
    batches=[];batch=[];length=0
    for i,key in pending:
        text,values=protect(key);piece='[[V2S%04d]]\n'%i+text+'\n'
        if batch and length+len(piece)>3200:batches.append(batch);batch=[];length=0
        batch.append((i,key,text,values,piece));length+=len(piece)
    if batch:batches.append(batch)
    for batch_number,batch in enumerate(batches):
        translated=request(''.join(entry[4] for entry in batch),lang)
        sections=list(re.finditer(r'\[\[V2S\s*(\d+)\]\]',translated))
        found={int(m[1]):translated[m.end():sections[j+1].start() if j+1<len(sections) else len(translated)].strip() for j,m in enumerate(sections)}
        for i,key,text,values,piece in batch:
            value=found.get(i,'')
            markers=lambda v: sorted(re.findall(r'__V2SP\d+__',v))
            if not value or markers(value)!=markers(text):value=request(text,lang).strip()
            if markers(value)!=markers(text):raise ValueError('Placeholder changed in '+lang+' key '+str(i))
            for j,original in enumerate(values):value=value.replace('__V2SP'+str(j)+'__',original)
            if not value:raise ValueError('Empty translation')
            done[key]=value
        destination.write_text(json.dumps(done,ensure_ascii=False,indent=2))
        print(lang+': batch '+str(batch_number+1)+'/'+str(len(batches))+'; '+str(len(done))+' strings saved',flush=True)
    return lang,len(done)

with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    for language,count in pool.map(translate_language,['fa','ar','zh-CN','ru','es','pt','fr','de']):print('COMPLETE',language,count,flush=True)
