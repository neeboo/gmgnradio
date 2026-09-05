// Materialize the reviewed generation + authored layout into an app world package.
// Run from the repository root after download and layout review. No network calls.
import { readFile, writeFile, mkdir, copyFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { join } from 'node:path';

const source = 'authoring/worlds/marble-living-cabin';
const destination = 'apps/macos/Resources/Worlds/marble-living-cabin';
const readJSON = async path => JSON.parse(await readFile(path, 'utf8'));
const operation = await readJSON(join(source, 'operation.json'));
if (operation.status !== 'completed' || !operation.world) throw new Error('Generation must complete first');
const world = operation.world.world ?? operation.world;
const worldID = world.world_id ?? world.id;
const layout = await readJSON(join(source, 'layout.json'));
if (layout.worldID !== worldID) throw new Error('Layout belongs to another generation');
const old = await readJSON('apps/macos/Resources/Worlds/living-pod-v1/world.json');
const point = ([x,y,z]) => ({x,y,z});
const rotation = (yaw=0, pitch=0) => ({x:Math.sin(pitch/2)*Math.cos(yaw/2),y:Math.cos(pitch/2)*Math.sin(yaw/2),z:-Math.sin(pitch/2)*Math.sin(yaw/2),w:Math.cos(pitch/2)*Math.cos(yaw/2)});
const transform = (position, yaw=0, pitch=0) => ({position:point(position),rotation:rotation(yaw,pitch),scale:{x:1,y:1,z:1}});
const positions = {'home.idle':layout.spawn.position,'home.walk':layout.walkPosition,'music.listen':layout.musicPosition};
const waypointIDs = {'home.idle':'wp.spawn','home.walk':'wp.center','music.listen':'wp.jukebox'};
const manifest = {
  schemaVersion:1, packageID:'marble-living-cabin', packageVersion:'1.0.0', worldID,
  displayName:'Marble 生活舱', calibration:{metersPerUnit:1,visualToGameplay:[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]},
  spawn:transform(layout.spawn.position, layout.spawn.yaw),
  collisionVolumes:layout.collisionVolumes,
  waypoints:Object.entries(positions).map(([id,p])=>({id:waypointIDs[id],position:point(p),arrivalRadius:0.2,enabled:true})),
  routes:[{id:'route.jukebox',waypointIDs:['wp.spawn','wp.center','wp.jukebox'],bidirectional:true,enabled:true}],
  activities:old.activities.filter(a=>a.id in positions).map(a=>({...a,transform:transform(positions[a.id],a.id==='music.listen'?layout.musicYaw:layout.spawn.yaw),motionID:null,propIDs:a.id==='music.listen'?['prop.jukebox']:[]})),
  activityDefinitions:old.activityDefinitions.filter(a=>a.id in positions).map(a=>a.id==='music.listen'?({...a,phases:a.phases.map(p=>({...p,durationSeconds:p.phase==='enter'?0.6:p.durationSeconds,propIDs:p.phase==='loop'?['prop.jukebox']:[]}))}):a),
  cameras:[{id:'living.establishing',transform:transform(layout.camera.position,layout.camera.yaw,layout.camera.pitch),fieldOfViewDegrees:66,nearPlane:0.05,farPlane:250}],
  capabilities:['activity:home.idle','activity:home.walk','activity:music.listen','camera:living.establishing'], resources:[]
};
await mkdir(destination,{recursive:true});
const files = [['world-500k.spz','scene-500k.spz','scene.spz','scene.marble'],['collider.glb','collider.glb','collision.glb','collision.marble']];
for(const [from,to,kind,id] of files){
  const input=join(source,'assets',from);
  await copyFile(input,join(destination,to));
  manifest.resources.push({id,path:to,kind,sha256:createHash('sha256').update(await readFile(input)).digest('hex')});
}
const writeResource=async (file,data,kind,id)=>{
  const bytes=JSON.stringify(data,null,2)+'\n';
  await writeFile(join(destination,file),bytes);
  manifest.resources.push({id,path:file,kind,sha256:createHash('sha256').update(bytes).digest('hex')});
};
await writeResource('marble.json',{world,framing:layout.framing,camera:layout.camera,jukebox:layout.jukebox},'scene.configuration','scene.configuration');
await writeResource('jukebox.json',{id:'jukebox',renderer:'builtin.jukebox',position:layout.jukebox.position,yaw:layout.jukebox.yaw,activityID:'music.listen',effect:'player.resume'},'prop.procedural','prop.jukebox');
await writeFile(join(destination,'world.json'),JSON.stringify(manifest,null,2)+'\n');
console.log(JSON.stringify({worldID,destination,resources:manifest.resources.length,activities:manifest.activities.map(a=>a.id)},null,2));
