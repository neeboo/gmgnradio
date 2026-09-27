// Materialize the reviewed generation + authored layout into an app world package.
// Run from the repository root after download and layout review. No network calls.
import { readFile, writeFile, mkdir, copyFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { join } from 'node:path';
import { isDeepStrictEqual } from 'node:util';

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
const residentMotionIDs = ids => ids.filter(id => id.startsWith('gmgn.motion.bones.') || id === 'gmgn.motion.ardy-backflip' || id === 'listen.music');
const manifest = {
  schemaVersion:1, packageID:'marble-living-cabin', packageVersion:'1.2.0', worldID,
  displayName:'Marble 生活舱', calibration:{metersPerUnit:1,visualToGameplay:[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]},
  spawn:transform(layout.spawn.position, layout.spawn.yaw),
  collisionVolumes:layout.collisionVolumes,
  waypoints:Object.entries(positions).map(([id,p])=>({id:waypointIDs[id],position:point(p),arrivalRadius:0.2,enabled:true})),
  routes:[{id:'route.jukebox',waypointIDs:['wp.spawn','wp.center','wp.jukebox'],bidirectional:true,enabled:true}],
  activities:old.activities.filter(a=>a.id in positions).map(a=>({...a,transform:transform(positions[a.id],a.id==='music.listen'?layout.musicYaw:layout.spawn.yaw),motionID:null,propIDs:a.id==='music.listen'?['prop.jukebox']:[]})),
  activityDefinitions:old.activityDefinitions.filter(a=>a.id in positions).map(a=>({...a,phases:a.phases.map(p=>({...p,motionIDs:residentMotionIDs(p.motionIDs),...(a.id==='music.listen'?{durationSeconds:p.phase==='enter'?0.6:p.durationSeconds,propIDs:p.phase==='loop'?['prop.jukebox']:[]}:{} )}))})),
  cameras:[{id:'living.establishing',transform:transform(layout.camera.position,layout.camera.yaw,layout.camera.pitch),fieldOfViewDegrees:66,nearPlane:0.05,farPlane:250}],
  capabilities:['activity:home.idle','activity:home.walk','activity:music.listen','camera:living.establishing'], resources:[]
};
const wish = layout.wishMachine;
manifest.waypoints.unshift({id:'wish_machine.pickup',position:point(wish.pickupPosition),arrivalRadius:0.2,enabled:true});
manifest.routes.unshift({id:'wish_machine.route',waypointIDs:['wp.spawn','wp.center','wish_machine.pickup'],bidirectional:true,enabled:true});
manifest.activities.unshift({id:'wish_machine.collect',action:'interact',entryWaypointID:'wish_machine.pickup',transform:transform(wish.pickupPosition,wish.pickupYaw),motionID:null,propIDs:['wish_machine.device'],interruptible:true});
manifest.activityDefinitions.unshift({
  id:'wish_machine.collect',displayName:'到许愿机出料口等候领取（到位后调用领取工具）',
  activity:{type:'interact',anchorID:'wish_machine.collect'},
  phases:['approach','enter','loop','exit','interrupt','failed'].map(phase=>({
    phase,requiredAnchorIDs:phase==='approach'?['wish_machine.collect']:[],motionIDs:[],
    propIDs:phase==='loop'?['wish_machine.device']:[],durationSeconds:phase==='enter'?0.6:null
  })),interruptible:true,cooldownSeconds:0
});
manifest.capabilities.unshift('activity:wish_machine.collect');
// Private, already-installed product clips. No third-party motion is copied
// into the world package; the dispatcher advertises them only for matching PMX.
for (const performance of [
  {id:'performance.backflip',name:'原地后空翻表演（不跨越障碍）',motion:'gmgn.motion.ardy-backflip',duration:4},
  {id:'performance.jumping_jacks',name:'原地开合跳表演',motion:'gmgn.motion.bones.jumping-jacks-pmx',duration:10}
]) {
  manifest.activities.push({id:performance.id,action:'interact',entryWaypointID:'wp.spawn',transform:transform(layout.spawn.position,layout.spawn.yaw),motionID:null,propIDs:[],interruptible:true});
  manifest.activityDefinitions.push({
    id:performance.id,displayName:performance.name,activity:{type:'interact',anchorID:performance.id},
    phases:['approach','enter','loop','exit','interrupt','failed'].map(phase=>({
      phase,requiredAnchorIDs:phase==='approach'?[performance.id]:[],
      motionIDs:phase==='approach'?['gmgn.motion.bones.walk-loop-pmx','gmgn.motion.bones.walk-loop-vrm']:phase==='loop'?[performance.motion]:[],
      propIDs:[],durationSeconds:phase==='enter'?0.2:phase==='loop'?performance.duration:phase==='exit'?0.2:null
    })),interruptible:true,cooldownSeconds:5
  });
  manifest.capabilities.push(`activity:${performance.id}`);
}
if (layout.navigation) {
  const navigation = layout.navigation;
  const colliderSHA256 = createHash('sha256').update(await readFile(join(source,'assets','collider.glb'))).digest('hex');
  const propSupportConfigurationSHA256 = createHash('sha256').update(await readFile('apps/macos/Sources/GMGNRadio/Presence/ResidentPropPlacementConfiguration.swift')).digest('hex');
  if (navigation.schemaVersion !== 1 || navigation.generator !== 'production-capsule-grid-v1' ||
      navigation.source?.worldID !== worldID || navigation.source?.colliderSHA256 !== colliderSHA256 ||
      navigation.source?.propSupportConfigurationSHA256 !== propSupportConfigurationSHA256 ||
      !isDeepStrictEqual(navigation.source?.framing, layout.framing) ||
      !isDeepStrictEqual(navigation.source?.collisionVolumes, layout.collisionVolumes) ||
      !isDeepStrictEqual(navigation.source?.manualWaypoints, manifest.waypoints)) {
    throw new Error('Baked navigation is stale; regenerate and verify against current collider, framing, furniture, prop supports and anchors');
  }
  manifest.waypoints = navigation.waypoints;
  manifest.routes = navigation.routes;
}
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
await writeResource('wish-machine.json',{id:'wish_machine.device',renderer:'builtin.wish_machine',...wish,activityID:'wish_machine.collect'},'prop.procedural','wish_machine.device');
await writeFile(join(destination,'world.json'),JSON.stringify(manifest,null,2)+'\n');
console.log(JSON.stringify({worldID,destination,resources:manifest.resources.length,activities:manifest.activities.map(a=>a.id)},null,2));
