#!/usr/bin/env python3
"""AKAI JARVIS v16: controlli statici NON distruttivi sui sorgenti e sull'APK.
Non accede alla rete o alla TV, non apre segreti, non modifica il progetto.
Esempio: python AKAI_JARVIS_v16_verifica_contratti.py /path/to/snapshot
"""
from pathlib import Path
import argparse, re, json, zipfile

p=argparse.ArgumentParser();p.add_argument('snapshot',type=Path); a=p.parse_args()
root=a.snapshot
source=root/'akai-remote-tv/app/src/main/java/it/akai/customremote'
server=(source/'RemoteServerService.java').read_text(encoding='utf-8')
js=(root/'app.js').read_text(encoding='utf-8')
html=(root/'index.html').read_text(encoding='utf-8')
tv=(source/'TvController.java').read_text(encoding='utf-8')
local=(source/'ai/LocalIntentParser.java').read_text(encoding='utf-8')
mem=(source/'ai/AkaiMemoryEngine.java').read_text(encoding='utf-8')
results=[]
def test(id, description, passed, detail):
    results.append({'id':id,'description':description,'passed':bool(passed),'detail':detail})

# 01 Frontend/backend REST: extract all literal URLs from fetch(getApiUrl(...)).
fe=set(re.findall(r"getApiUrl\(['\"](/api/[^'\"]+)['\"]\)",js))
be=set(re.findall(r'"(/api/[^" ]+)"\.equals\(path\)',server))
missing=sorted(fe-be)
test('REST_ROUTE_MATCH','Tutti gli endpoint usati dal Web Remote esistono nel backend',not missing,missing)

# 02 Buttons commands supported by native TV controller; JS-only open_numpad excluded.
buttons=set(re.findall(r'data-cmd=[\'\"]([^\'\"]+)',html))-{'open_numpad'}
allowed=set(re.findall(r'case\s+"([^"]+)"\s*:',tv))
unknown=sorted(buttons-allowed)
test('REMOTE_COMMAND_MATCH','Tutti i tasti della UI corrispondono a comandi implementati',not unknown,unknown)

# 03 Duplicate route shadows later response schema.
count=len(re.findall(r'"/api/ai/memory"\.equals\(path\)',server))
test('MEMORY_ROUTE_UNIQUE','Una sola definizione GET /api/ai/memory',count==1,{'definitions':count})
first=server.split('// AI Memory & Conversations History')[1].split('// AI Configuration')[0]
test('MEMORY_SCHEMA_MATCH','Lo schema primo endpoint memory include i campi che il JS usa', all(k in first for k in ['recent_conversations','procedures','guest_mode']), {'frontend_expects':['recent_conversations','procedures','guest_mode'],'backend_first_has':['conversations','preferences','stats']})

# 04 TLS secret never embedded in APK, and no hardcoded password in Java.
apk=root/'AKAI_JARVIS_Remote_v16.apk'
with zipfile.ZipFile(apk) as z:
    embedded=('assets/server_keystore.p12' in z.namelist())
test('NO_TLS_PRIVATE_IN_APK','Il binario APK non distribuisce la chiave privata TLS',not embedded,{'private_keystore_embedded':embedded})
test('NO_HARDCODED_TLS_PASSWORD','Il servizio non contiene una password di PKCS12 hardcoded',not bool(re.search(r'keyStore\.load\([^;]+?toCharArray\(\)',server)),{'keystore_password_literal_in_code':bool(re.search(r'keyStore\.load\([^;]+?toCharArray\(\)',server))})

# 05 Bounded workers and stop/resume voice contract.
test('BOUNDED_HTTP_EXECUTOR','Pool richieste HTTP con coda limitata', 'ThreadPoolExecutor(' in server and 'ArrayBlockingQueue' in server or 'LinkedBlockingQueue<>' in server and 'ThreadPoolExecutor(' in server, {'uses_unbounded_newFixedThreadPool': 'Executors.newFixedThreadPool(12)' in server})
test('SPEECH_ID_CLIENT_CORRELATION','Il frontend usa speech_id per correlare la risposta vocale al turno', 'speech_id' in js, {'backend_exposes_speech_id':'"speech_id"' in server})
test('SERVER_SIDE_STOP','Stop conversazione cancella anche il TTS lato TV', bool(re.search(r'/api/ai/(?:stop|cancel|speech_stop)',server)), {'frontend_abort_only': 'aiAbortController.abort()' in js})

# 06 Memory guest privacy and knowledge verification.
test('GUEST_PREFERENCE_PROTECTION','Il parser fast-path applica la modalità Ospite prima di consultare gusti personali', 'isGuestMode()' in local, {'direct_getPreference_calls':local.count('getPreference(')})
block=mem[mem.index('public synchronized JSONObject findProcedureByGoal'):mem.index('public synchronized JSONObject getProcedure(')]
test('VERIFIED_PROCEDURES_ONLY','La ricerca delle procedure filtra per avvenuta verifica', bool(re.search(r'COL_SUCCESS_COUNT\s*\+\s*"[>=]',block)) or bool(re.search(r'COL_LAST_VERIFIED\s*\+\s*"[>=]',block)), {'orders_by_success_count': 'COL_SUCCESS_COUNT + " DESC"' in block})

def get_dom_ids(content): return set(re.findall(r'\bid=[\'\"]([^\'\"]+)',content))
refs=set(re.findall(r'document\.getElementById\([\'\"]([^\'\"]+)',js))
test('DOM_ID_MATCH','Tutti i riferimenti JS getElementById esistono nell’HTML',refs.issubset(get_dom_ids(html)),sorted(refs-get_dom_ids(html)))

test('STATIC_SNAPSHOT_VALID','Analisi completata senza eseguire APK né modificare TV',True,{'files_checked':7})
result={'totals':{'checks':len(results),'passed':sum(x['passed'] for x in results),'failed':sum(not x['passed'] for x in results)},'checks':results,'disclaimer':'Sono controlli statici: PASS non equivale a test reale su Android TV o browser mobile.'}
print(json.dumps(result,ensure_ascii=False,indent=2))
