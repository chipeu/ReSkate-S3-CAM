from pathlib import Path
import json,subprocess,sys
root=Path(__file__).resolve().parents[1]
report=json.loads((root/'release/DynamicCamera-1.2.18-TEST-validation.json').read_text(encoding='utf-8'))
results=[]
for test in report['tests']:
 source=root/Path(test['source'].replace('\\','/'))
 cmd=[str(root/'tools/luau_run.exe'),'-I',str(source),'-I',str(root/'tests'),'-I',str(root/'tools/trace/out'),str(root/'tests'/test['test']),*test['args']]
 run=subprocess.run(cmd,cwd=root,capture_output=True,text=True)
 results.append({'test':test['test'],'args':test['args'],'exit':run.returncode,'output':run.stdout+run.stderr})
 print(test['test'],test['args'],run.returncode,flush=True)
 if run.returncode:break
(root/'migration/revalidation.json').write_text(json.dumps(results,indent=2),encoding='utf-8')
sys.exit(0 if len(results)==len(report['tests']) and all(r['exit']==0 for r in results) else 1)
