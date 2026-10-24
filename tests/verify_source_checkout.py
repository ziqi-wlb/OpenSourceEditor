#!/usr/bin/env python3
"""Build the staged editor subtree in isolation; compare release byte identity."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('name')
    parser.add_argument('--arch',default='universal',choices=['arm64','x86_64','universal'])
    args=parser.parse_args()
    app=Path(__file__).resolve().parents[1];repo=app.parent
    result_dir=app/'.build/test-results'/args.name
    result=json.loads((result_dir/'results.json').read_text())
    assert result['status']=='passed'
    output=result_dir/'source-checkout.json'
    assert not output.exists(), 'Use a unique run name'
    tree=subprocess.check_output(['git','write-tree'],cwd=repo,text=True).strip()
    folder=Path(tempfile.mkdtemp(prefix='source-editor-'))
    archive=folder/'editor.tar'
    subprocess.run(['git','archive','--format=tar','--output='+str(archive),tree,'editor'],cwd=repo,check=True)
    subprocess.run(['tar','-xf',str(archive),'-C',str(folder)],check=True)
    fresh=folder/'editor'
    assert not (fresh/'.build').exists() and not (folder/'sublime_text').exists()
    for item in result['sources']:
        assert sha(app/item['path'])==item['sha256'] and sha(fresh/item['path'])==item['sha256'],item['path']
    subprocess.run(['bash','build.sh','--arch',args.arch],cwd=fresh,check=True)
    binary=fresh/'.build/Source Editor.app/Contents/MacOS/source-editor'
    assert sha(binary)==result['release_binary']['sha256']
    version=subprocess.check_output([str(binary),'--version'],text=True).strip()
    subprocess.run(['bash','build.sh','--tests'],cwd=fresh,check=True)
    tests=fresh/'.build/Source Editor Tests.app/Contents/MacOS/source-editor'
    service=json.loads(subprocess.check_output([str(tests),'--service-test'],text=True))
    assert service['failed']==0 and service['passed']>0
    summary={'status':'passed','source_tree':tree,'editor_only_archive':True,'release_binary_sha256':sha(binary),'version':version,'services_passed':service['passed']}
    output.write_text(json.dumps(summary,indent=2)+'\n')
    print(json.dumps(summary))
if __name__=='__main__':main()
