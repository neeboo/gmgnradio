#!/usr/bin/env python3
"""Real daemon HTTP/SQLite, private ready fixture; no model, claim or app."""
import copy,hashlib,json,os,sqlite3,struct,subprocess,sys,tempfile,time,urllib.request,uuid
from pathlib import Path
repo=Path(__file__).resolve().parents[3]
binary=Path(os.environ.get('TASKD_BIN',repo/'target/debug/gmgn-taskd'))
def wire(v):return json.dumps(v,separators=(',',':'),sort_keys=True)
with tempfile.TemporaryDirectory(prefix='gmgn-prop-authority-',dir='/private/tmp') as temporary:
 root=Path(temporary).resolve();endpoint=root/'endpoint.json';log=root/'daemon.log'
 with log.open('wb') as out:
  process=subprocess.Popen([str(binary),'--root',str(root),'--endpoint-file',str(endpoint),'--concurrency','1'],stdout=out,stderr=out)
  try:
   for _ in range(250):
    if endpoint.exists():break
    if process.poll() is not None:raise AssertionError(log.read_text())
    time.sleep(.02)
   ep=json.loads(endpoint.read_text())
   def rpc(method,params):
    req=urllib.request.Request('http://'+ep['address']+'/rpc',data=wire({'id':str(uuid.uuid4()),'method':method,'params':params}).encode(),headers={'Authorization':'Bearer '+ep['token'],'Content-Type':'application/json'})
    return json.loads(urllib.request.urlopen(req,timeout=10).read())
   def ok(method,p):
    r=rpc(method,p);assert 'error' not in r,(method,r);return r['result']
   def reject(method,p,code):
    r=rpc(method,p);assert code in wire(r),(method,r,code)
   world=str(uuid.uuid4());wish=str(uuid.uuid4());job=str(uuid.uuid4())
   common={'worldID':world,'residentScope':'private-resident','hostSessionID':'private-host'}
   transform={'position':{'x':0,'y':0,'z':0},'rotation':{'x':0,'y':0,'z':0,'w':1},'scale':{'x':1,'y':1,'z':1}}
   state={'worldID':world,'revision':0,'layoutRevision':0,'worldTime':1760000000000,'agentTransform':copy.deepcopy(transform),'activeActivity':None,'heldProp':None,'layoutReceipts':{},'objectStates':{}}
   raw=wire(state);ok('world_import',{'worldID':world,'requestID':'private-import','packageID':'private','packageVersion':'1','stateJson':raw,'stateSha256':hashlib.sha256(raw.encode()).hexdigest()})
   data=b'glTF'+struct.pack('<II',2,24)+struct.pack('<I',4)+b'JSON'+b'{}  ';digest=hashlib.sha256(data).hexdigest();path=root/(job+'.glb');path.write_bytes(data)
   ok('world_blob_put',{'sha256':digest,'mime':'model/gltf-binary','localPath':str(path)})
   ready={'id':wish,'jobID':job,'objectID':'output','worldID':world,'residentScope':'private-resident','stage':'ready','modelPath':str(path),'name':'actual-private-output','heightMeters':.3}
   core={'job':{'id':job,'name':'actual-private-output','endpoint':'https://example.invalid','imagePath':'unused','imageSHA256':'0'*64,'heightMeters':.3,'source':{'author':'fixture','license':'CC0'},'idempotencyKey':job,'receipt':{'state':'completed','result':{'inspection':{'bytes':len(data),'sha256':digest}}},'localModelPath':str(path),'context':{'worldID':world,'residentScope':'private-resident'}},'attempted':True}
   db=root/'tasks.sqlite3'
   with sqlite3.connect(db) as c:
    c.execute('INSERT INTO jobs(id,data) VALUES(?,?)',(job,wire(core)))
    c.execute('INSERT INTO wish_control_documents VALUES(?,?,0,?,NULL)',('private-owner','private-host',wire({'jobs':[ready]})))
   triangles=[[[-.15,0,-.15],[.15,0,-.15],[.15,.3,.15]],[[-.15,0,-.15],[.15,.3,.15],[-.15,.3,.15]]]
   before=ok('world_snapshot',{'worldID':world,'includeState':True})
   p=dict(common,requestID='readonly',expectedRevision=before['record']['recordRevision'],expectedLayoutRevision=0,wishID=wish,measurement={'blobRef':digest,'triangles':triangles})
   def counts():
    with sqlite3.connect(db) as c:return {t:c.execute('SELECT count(*) FROM "'+t+'"').fetchone()[0] for (t,) in c.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()}
   rows=counts();projection=ok('world_prop_output_preview',p)
   assert projection['prop']['assetID']=='sha256:'+digest and 'commit' not in projection and 'receipt' not in projection
   assert counts()==rows and ok('world_snapshot',{'worldID':world,'includeState':True})==before
   reject('world_prop_register',p,'world_prop_unauthorized')
   reject('world_prop_output_preview',dict(p,wishID=str(uuid.uuid4())),'world_prop_unauthorized')
   with sqlite3.connect(db) as c:
    ready['stage']='claimed';c.execute('UPDATE wish_control_documents SET payload=? WHERE session=?',(wire({'jobs':[ready]}),'private-host'))
   reject('world_prop_output_preview',p,'world_prop_unauthorized')
   assert counts()==rows
   print('PASS real daemon ready preview HTTP/SQLite: unchanged snapshots/row counts; unknown/claimed denied; no claim RPC')
   if '--catalog' in sys.argv:
    seeded=copy.deepcopy(state);seeded['worldID']=str(uuid.uuid4())
    pose=copy.deepcopy(transform);pose['position']={'x':1.1,'y':.02,'z':-2.2}
    seeded['objectStates']={'wish_machine.device':{'isEnabled':True,'transform':pose,'metadata':{'unrelated':'keep'}}}
    reviewed_asset='sha256:0eb955793605cbfe0680616f98991369f85fd46c317d1b51a877949b3fb36303'
    for object_id,asset,explicit in [('known-seat',reviewed_asset,None),('damaged-seat',reviewed_asset,'explicit-invalid'),('unknown-seat','sha256:'+digest,None)]:
     generated=copy.deepcopy(projection['prop']);generated['objectID']=object_id;generated['assetID']=asset
     metadata={'gmgn.generated-prop.v1':wire(generated)}
     if explicit is not None:metadata['gmgn.prop-seat.v1']=explicit
     seeded['objectStates'][object_id]={'isEnabled':False,'transform':copy.deepcopy(pose),'metadata':metadata}
    raw=wire(seeded);ok('world_import',{'worldID':seeded['worldID'],'requestID':'seeded-import','packageID':'private','packageVersion':'1','stateJson':raw,'stateSha256':hashlib.sha256(raw.encode()).hexdigest()})
    template=json.loads((repo/'apps/macos/Resources/Worlds/marble-living-cabin/wish-machine.json').read_text())
    catalog=dict(common,worldID=seeded['worldID'],templates=[template])
    registration=ok('world_device_catalog_install',catalog)
    adopted=registration['snapshot']['record']['state'];item=adopted['objectStates']['wish_machine.device']
    assert item['transform']==pose and item['metadata']['unrelated']=='keep' and adopted['layoutRevision']==1
    assert json.loads(item['metadata']['gmgn.prop-function-points.v1'])=={'objectID':'wish_machine.device','functionPoints':template['functionPoints']}
    seat=json.loads(adopted['objectStates']['known-seat']['metadata']['gmgn.prop-seat.v1'])
    assert seat['assetID']==reviewed_asset and seat['approachPoint']['y']==0
    assert adopted['objectStates']['known-seat']['transform']==pose
    assert adopted['objectStates']['damaged-seat']['metadata']['gmgn.prop-seat.v1']=='explicit-invalid'
    assert 'gmgn.prop-seat.v1' not in adopted['objectStates']['unknown-seat']['metadata']
    with sqlite3.connect(db) as c:
     sql_item=json.loads(c.execute("SELECT value FROM world_records WHERE world_id=? AND domain='objects' AND key='known-seat'",(seeded['worldID'],)).fetchone()[0])
     assert sql_item['metadata']['gmgn.prop-seat.v1']==adopted['objectStates']['known-seat']['metadata']['gmgn.prop-seat.v1']
     sql_points=json.loads(c.execute("SELECT value FROM world_records WHERE world_id=? AND domain='objects' AND key='wish_machine.device'",(seeded['worldID'],)).fetchone()[0])
     assert sql_points==item
    rows=counts();again=ok('world_device_catalog_install',catalog)
    assert again['didCommit'] is False and again['snapshot']==registration['snapshot'] and rows==counts()
    reject('world_prop_ui_intent',dict(common,worldID=seeded['worldID'],expectedRevision=1,expectedLayoutRevision=0,command={'op':'delete','objectID':'known-seat'}),'revision_conflict')
    assert counts()==rows
    invalid=copy.deepcopy(catalog);invalid['templates'][0]['id']='wall'
    reject('world_device_catalog_install',invalid,'world_device_invalid_catalog')
    assert ok('world_snapshot',{'worldID':seeded['worldID'],'includeState':True})==registration['snapshot'] and counts()==rows
    print('PASS real authored catalog HTTP/SQL records: raw emitter/interaction/standing points and exact-SHA seat persisted; unknown seat untouched; explicit malformed seat preserved; pose/unrelated metadata preserved; revision/layout fence; duplicate idempotent; wall spoof rollback')
   # Import two isolated archived inventories, then exercise the actual UI
   # capability reducer. No fabricated agent claim or model grant is involved.
   def imported(enabled,x):
    s=copy.deepcopy(state);s['worldID']=str(uuid.uuid4());item={'isEnabled':enabled,'transform':copy.deepcopy(transform),'metadata':{'gmgn.generated-prop.v1':wire(projection['prop'])}}
    item['transform']['position']['x']=x;s['objectStates']={'output':item};r=wire(s)
    ok('world_import',{'worldID':s['worldID'],'requestID':str(uuid.uuid4()),'packageID':'private','packageVersion':'1','stateJson':r,'stateSha256':hashlib.sha256(r.encode()).hexdigest()})
    return dict(common,worldID=s['worldID'])
   def snap(identity):return ok('world_snapshot',{'worldID':identity['worldID'],'includeState':True})
   def params(identity):
    s=snap(identity);return dict(identity,expectedRevision=s['record']['recordRevision'],expectedLayoutRevision=s['record']['state']['layoutRevision'],requestID=str(uuid.uuid4()))
   def observe(identity,avatar='old-avatar',selection=1,slots=None):
    p=params(identity);p['layoutRevision']=p.pop('expectedLayoutRevision')
    p['facts']={'environmentBlobRef':digest,'environment':{'triangles':[[[-3,0,-3],[3,0,-3],[3,0,3]],[[-3,0,-3],[3,0,3],[-3,0,3]]],'blockingVolumes':[],'bounds':{'minimumX':-3,'maximumX':3,'minimumZ':-3,'maximumZ':3},'seed':[0,0,0],'parameters':{}},'avatar':{'assetID':avatar,'selectionRevision':selection,'format':'pmx','slots':['rightHand'] if slots is None else slots},'objects':{'output':{'assetID':'sha256:'+digest,'blobRef':digest,'triangles':triangles}},'activityBindings':{},'anchorPositions':{}}
    return ok('world_prop_observe',p)['geometryID']
   def ui(identity,command,geometry,code=None):
    p=params(identity);intent=ok('world_prop_ui_intent',dict(p,command=command))
    p.update(geometryID=geometry,authority={'kind':'ui','intentID':intent['intentID'],'capability':intent['capability']})
    if code:reject('world_prop_command',p,code)
    else:return ok('world_prop_command',p)
   far=imported(True,2.5);geometry=observe(far);before_far=snap(far)
   ui(far,{'op':'hold','objectID':'output','slot':'rightHand'},geometry,'prop_out_of_reach')
   assert snap(far)==before_far
   held_identity=imported(False,1);geometry=observe(held_identity)
   held_reply=ui(held_identity,{'op':'hold','objectID':'output','slot':'rightHand'},geometry)
   reserved=held_reply['snapshot']['record']['state']['heldProp']['returnState']
   binding=ok('world_prop_system_avatar_return',dict(held_identity,readBinding=True))
   # Observe a real new selection lacking the previous bone: the narrow system
   # event must not silently choose another hand or rewrite the original state.
   geometry=observe(held_identity,'loaded-new-avatar',2,['back'])
   p=params(held_identity);p['geometryID']=geometry
   p['event']={'kind':'avatar_changed_rebind','objectID':'output','previousAvatarAssetID':'old-avatar','avatarAssetID':'loaded-new-avatar','selectionRevision':2,'heldBindingSHA256':binding['heldBindingSHA256']}
   before_rebind=snap(held_identity)
   reject('world_prop_system_avatar_return',p,'world_prop_slot_unavailable');assert snap(held_identity)==before_rebind
   wrong=copy.deepcopy(p);wrong['event']['selectionRevision']=3
   reject('world_prop_system_avatar_return',wrong,'world_prop_system_event_stale')
   geometry=observe(held_identity,'loaded-new-avatar',2,['rightHand']);p['geometryID']=geometry
   result=ok('world_prop_system_avatar_return',p)
   assert result['snapshot']['record']['state']['heldProp']['avatarAssetID']=='loaded-new-avatar'
   assert result['snapshot']['record']['state']['heldProp']['returnState']==reserved
   geometry=observe(held_identity,'loaded-new-avatar',2,['rightHand']);before_bad=snap(held_identity)
   ui(held_identity,{'op':'adjustGrip','objectID':'output','offset':[0,0,0],'rotation':[0,0,0,0]},geometry,'prop_grip_invalid')
   assert snap(held_identity)==before_bad
   print('PASS real observe/UI/system consumers: distant pickup rejected; unavailable new-avatar bone and unconfirmed selection rejected without state mutation; valid rebind preserves return reservation; zero quaternion rejected')
  finally:
   process.terminate()
   try:process.wait(timeout=5)
   except subprocess.TimeoutExpired:process.kill();process.wait(timeout=5)
   assert process.poll() is not None
 print('CLEANUP private daemon stopped; temporary DB/blob/endpoint removed on scope exit')
