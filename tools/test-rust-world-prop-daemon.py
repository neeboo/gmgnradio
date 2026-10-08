#!/usr/bin/env python3
"""Real taskd private DB + production Swift prop actor. No fake authorization rows."""
import hashlib, http.client, json, os, pathlib, sqlite3, struct, subprocess, tempfile, time, uuid
ROOT = pathlib.Path(__file__).resolve().parents[1]
APP = ROOT/'apps/macos/Sources/GMGNRadio/Presence'

def glb(path, triangles):
    vertices=[vertex for triangle in triangles for vertex in triangle]
    buffer=struct.pack('<'+'f'*len(vertices)*3, *[n for v in vertices for n in v])
    document={'asset':{'version':'2.0'},'buffers':[{'byteLength':len(buffer)}],
        'bufferViews':[{'buffer':0,'byteOffset':0,'byteLength':len(buffer),'target':34962}],
        'accessors':[{'bufferView':0,'componentType':5126,'count':len(vertices),'type':'VEC3',
            'min':[min(v[i] for v in vertices) for i in range(3)],'max':[max(v[i] for v in vertices) for i in range(3)]}],
        'meshes':[{'primitives':[{'attributes':{'POSITION':0},'mode':4}]}], 'nodes':[{'mesh':0}], 'scenes':[{'nodes':[0]}],'scene':0}
    encoded=json.dumps(document,separators=(',',':')).encode();encoded+=b' '*((-len(encoded))%4)
    data=b'glTF'+struct.pack('<II',2,12+8+len(encoded)+8+len(buffer))+struct.pack('<I4s',len(encoded),b'JSON')+encoded+struct.pack('<I4s',len(buffer),b'BIN\0')+buffer
    path.write_bytes(data);path.chmod(0o600)
    # Independently read the native loader's POSITION source from the real GLB,
    # rather than passing the pre-serialization authoring coordinates as facts.
    loaded=path.read_bytes();json_size=struct.unpack_from('<I',loaded,12)[0]
    parsed=json.loads(loaded[20:20+json_size]);accessor=parsed['accessors'][0]
    offset=20+json_size+8+parsed['bufferViews'][0].get('byteOffset',0)
    positions=[list(struct.unpack_from('<fff',loaded,offset+i*12)) for i in range(accessor['count'])]
    return hashlib.sha256(loaded).hexdigest(), [positions[i:i+3] for i in range(0,len(positions),3)]

with tempfile.TemporaryDirectory(prefix='gmgn-real-prop-') as temporary:
    root=pathlib.Path(temporary).resolve();root.chmod(0o700)
    binary=root/'swift-test'
    subprocess.run(['swiftc','-swift-version','6','-parse-as-library',str(APP/'TaskdHTTPTransport.swift'),str(APP/'RustWorldPropClient.swift'),str(pathlib.Path(__file__).with_suffix('.swift')),'-o',str(binary)],check=True)
    floor=[[[-3,0,-3],[3,0,3],[3,0,-3]],[[-3,0,-3],[-3,0,3],[3,0,3]]]
    vertices=[[-.15,0,-.15],[.15,0,-.15],[.15,0,.15],[-.15,0,.15],[-.15,.3,-.15],[.15,.3,-.15],[.15,.3,.15],[-.15,.3,.15]]
    faces=[[0,2,1],[0,3,2],[4,5,6],[4,6,7],[0,1,5],[0,5,4],[1,2,6],[1,6,5],[2,3,7],[2,7,6],[3,0,4],[3,4,7]]
    floor_hash,floor_mesh=glb(root/'floor.glb',floor)
    prop_hash,prop_mesh=glb(root/'prop.glb',[[vertices[i] for i in face] for face in faces])
    world=str(uuid.uuid4());wish=str(uuid.uuid4())
    transform={'position':{'x':0,'y':0,'z':0},'rotation':{'x':0,'y':0,'z':0,'w':1},'scale':{'x':1,'y':1,'z':1}}
    prop={'objectID':'private-prop','sourceWishID':wish,'assetID':'sha256:'+prop_hash,'displayName':'private measured cube','sourceHeight':.3,'size':{'x':.3,'y':.3,'z':.3}}
    state={'worldID':world,'revision':0,'layoutRevision':0,'worldTime':1760000000000,'agentTransform':transform,'activeActivity':None,'heldProp':None,'layoutReceipts':{},'objectStates':{'private-prop':{'isEnabled':False,'transform':transform,'metadata':{'gmgn.generated-prop.v1':json.dumps(prop),'fixture-note':'preserve'}}}}
    facts={'environmentBlobRef':floor_hash,'environment':{'triangles':floor_mesh,'blockingVolumes':[],
        'bounds':{'minimumX':-3,'maximumX':3,'minimumZ':-3,'maximumZ':3},'seed':[0,0,0],'parameters':{}},
        'avatar':{'assetID':'fixture-avatar','selectionRevision':1,'format':'pmx','slots':['rightHand','back','waist']},
        'objects':{'private-prop':{'assetID':'sha256:'+prop_hash,'blobRef':prop_hash,'triangles':prop_mesh}},'activityBindings':{},'anchorPositions':{}}
    fixture={'worldID':world,'wishID':wish,'propHash':prop_hash,'facts':facts,'blobs':[{'path':str(root/'floor.glb'),'hash':floor_hash},{'path':str(root/'prop.glb'),'hash':prop_hash}]}
    fixture_path=root/'fixture.json';fixture_path.write_text(json.dumps(fixture))
    endpoint=root/'taskd.endpoint.json'; daemon=None
    def stop():
        global daemon
        if daemon is None:return
        pid=daemon.pid
        if daemon.poll() is None:
            daemon.terminate()
            try:daemon.wait(timeout=3)
            except subprocess.TimeoutExpired:daemon.kill();daemon.wait(timeout=3)
        daemon.communicate(timeout=3)
        try:os.kill(pid,0)
        except ProcessLookupError:pass
        else:raise AssertionError('owned daemon PID still alive')
        try:os.killpg(pid,0)
        except ProcessLookupError:pass
        else:raise AssertionError('owned private session process group still alive')
        daemon=None
    def start():
        global daemon
        daemon=subprocess.Popen([str(ROOT/'target/debug/gmgn-taskd'),'--root',str(root),'--endpoint-file',str(endpoint),'--concurrency','1'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
        for _ in range(300):
            if daemon.poll() is not None:raise AssertionError(daemon.communicate()[1].decode())
            try:
                rpc('world_list');return
            except (OSError,ValueError,KeyError):time.sleep(.02)
        raise AssertionError('private daemon failed to expose endpoint')
    def rpc(method,params=None):
        descriptor=json.loads(endpoint.read_text());host,port=descriptor['address'].split(':')
        connection=http.client.HTTPConnection(host,int(port),timeout=10)
        connection.request('POST','/rpc',json.dumps({'id':'private-prop','method':method,'params':params or {}}),{'Authorization':'Bearer '+descriptor['token'],'Content-Type':'application/json'})
        response=connection.getresponse();reply=json.loads(response.read());connection.close();assert response.status==200
        return reply
    try:
        start(); state_json=json.dumps(state,separators=(',',':'))
        imported=rpc('world_import',{'worldID':world,'requestID':'private-import','packageID':'private-native-fixture','packageVersion':'1','stateSha256':hashlib.sha256(state_json.encode()).hexdigest(),'stateJson':state_json})
        assert 'result' in imported,imported
        subprocess.run([str(binary),str(endpoint),str(fixture_path)],check=True,timeout=30)
        before=rpc('world_snapshot',{'worldID':world,'includeState':True})['result']['record']
        database=next(root.glob('*.sqlite*'))
        with sqlite3.connect(database) as db:
            commands=db.execute('SELECT request FROM world_prop_commands ORDER BY request').fetchall()
            assert len(commands)==5,commands
            assert db.execute('SELECT count(*) FROM world_prop_intents WHERE used=1').fetchone()[0]==5
            assert db.execute('SELECT count(*) FROM world_prop_native').fetchone()[0]==1
        stop();stop();start()
        after=rpc('world_snapshot',{'worldID':world,'includeState':True})['result']['record']
        assert before==after,'restart changed committed projection'
        assert after['state']['objectStates']['private-prop']['metadata']['fixture-note']=='preserve'
        with sqlite3.connect(database) as db:
            assert db.execute('SELECT count(*) FROM world_prop_native').fetchone()[0]==0
            assert db.execute('SELECT count(*) FROM world_prop_intents').fetchone()[0]==0
            assert db.execute('SELECT count(*) FROM world_prop_commands').fetchone()[0]==5
        print('PASS SQLite: five committed commands, one-use UI intents, restart projection durable; native facts and capabilities cleared on recovery')
    finally:stop();stop()
    print('PASS double stop: both private daemon PIDs and their dedicated session process groups reaped')
