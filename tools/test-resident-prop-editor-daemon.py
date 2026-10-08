#!/usr/bin/env python3
"""Existing full UI harness, real private Rust authority per repeated-ID context."""
import argparse
import hashlib
import json
import os
import pathlib
import signal
import struct
import subprocess
import tempfile
import uuid

REPO = pathlib.Path(__file__).resolve().parents[1]

def mesh(path, triangles):
    vertices = [v for t in triangles for v in t]
    binary = struct.pack('<'+'f'*len(vertices)*3, *[n for v in vertices for n in v])
    source = {'asset': {'version':'2.0'}, 'buffers':[{'byteLength':len(binary)}],
        'bufferViews':[{'buffer':0,'byteOffset':0,'byteLength':len(binary),'target':34962}],
        'accessors':[{'bufferView':0,'componentType':5126,'count':len(vertices),'type':'VEC3',
            'min':[min(v[i] for v in vertices) for i in range(3)], 'max':[max(v[i] for v in vertices) for i in range(3)]}],
        'meshes':[{'primitives':[{'attributes':{'POSITION':0},'mode':4}]}],
        'nodes':[{'mesh':0}],'scenes':[{'nodes':[0]}],'scene':0}
    encoded=json.dumps(source,separators=(',',':')).encode();encoded+=b' '*((-len(encoded))%4)
    data=b'glTF'+struct.pack('<II',2,12+8+len(encoded)+8+len(binary))+struct.pack('<I4s',len(encoded),b'JSON')+encoded+struct.pack('<I4s',len(binary),b'BIN\0')+binary
    path.write_bytes(data);path.chmod(0o600)
    # Facts are remeasured from the serialized GLB POSITION buffer.
    loaded=path.read_bytes();length=struct.unpack_from('<I',loaded,12)[0]
    parsed=json.loads(loaded[20:20+length]);accessor=parsed['accessors'][0]
    offset=20+length+8+parsed['bufferViews'][0].get('byteOffset',0)
    measured=[list(struct.unpack_from('<fff',loaded,offset+i*12)) for i in range(accessor['count'])]
    return hashlib.sha256(loaded).hexdigest(), [measured[i:i+3] for i in range(0,len(measured),3)]

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--daemon',required=True,type=pathlib.Path)
    parser.add_argument('--log',type=pathlib.Path,default=pathlib.Path('/tmp')/('gmgn-rust-prop-editor-'+str(uuid.uuid4())+'.log'))
    args=parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='gmgn-private-prop-editor-assets-') as temporary:
        root=pathlib.Path(temporary).resolve();root.chmod(0o700)
        floor=[[[-4,0,-4],[4,0,4],[4,0,-4]],[[-4,0,-4],[-4,0,4],[4,0,4]]]
        vertices=[[-.25,0,-.25],[.25,0,-.25],[.25,0,.25],[-.25,0,.25],[-.25,1,-.25],[.25,1,-.25],[.25,1,.25],[-.25,1,.25]]
        faces=[[0,2,1],[0,3,2],[4,5,6],[4,6,7],[0,1,5],[0,5,4],[1,2,6],[1,6,5],[2,3,7],[2,7,6],[3,0,4],[3,4,7]]
        floor_hash,floor_mesh=mesh(root/'floor.glb',floor)
        prop_hash,prop_mesh=mesh(root/'prop.glb',[[vertices[i] for i in face] for face in faces])
        facts={'environmentBlobRef':floor_hash,'environment':{'triangles':floor_mesh,'blockingVolumes':[],
            'bounds':{'minimumX':-4,'maximumX':4,'minimumZ':-4,'maximumZ':4},'seed':[0,0,0],'parameters':{}},
            'avatar':{'assetID':'pmx.2b-miss-0414-standard','selectionRevision':1,'format':'pmx','slots':['rightHand','back','waist']},
            'objects':{'cup':{'assetID':'sha256:'+prop_hash,'blobRef':prop_hash,'triangles':prop_mesh}},'activityBindings':{},'anchorPositions':{}}
        fixture=root/'fixture.json'
        fixture.write_text(json.dumps({'propHash':prop_hash,'facts':facts,'blobs':[{'path':str(root/'floor.glb'),'hash':floor_hash},{'path':str(root/'prop.glb'),'hash':prop_hash}]}));fixture.chmod(0o600)
        try:
            result=subprocess.run(['swift','tools/test-resident-prop-editor.swift','--private-daemon',str(args.daemon.resolve()),'--private-fixture',str(fixture)],cwd=REPO,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=180)
            args.log.write_bytes(result.stdout)
            print(result.stdout.decode(errors='replace'),end='')
            print('actual log:',args.log)
            result.check_returncode()
        finally:
            for pid_file in root.glob('gmgn-private-prop-editor-*/owned.pid'):
                pid=int(pid_file.read_text())
                try:os.killpg(pid,signal.SIGKILL)
                except ProcessLookupError:pass
                try:os.kill(pid,signal.SIGKILL)
                except ProcessLookupError:pass

if __name__=='__main__':main()
