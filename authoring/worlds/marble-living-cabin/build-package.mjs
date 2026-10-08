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
// 道具功能点的几何只有一份：本体坐标系下的声明。导航路点是**导航数据**（由烘焙器写进
// layout.navigation），所以构建期要断言"声明 × 摆放"与它的路点一致 —— 不一致就拒绝出包，
// 两份数据没有悄悄分叉的空间。旋转式与运行时注册表（WorldPropAnchorRegistry.worldPosition）
// 逐字相同：角色前方 -Z，yaw 只绕 +Y。
const localToWorld = (local, position, yaw = 0) => {
  const cosine = Math.cos(yaw), sine = Math.sin(yaw);
  return [position[0] + cosine*local[0] + sine*local[2], position[1] + local[1], position[2] - sine*local[0] + cosine*local[2]];
};
const functionPoint = (declaration, role) => {
  const point = (declaration.functionPoints ?? []).find(candidate => candidate.role === role);
  if (!point) throw new Error(`Prop ${declaration.id ?? ''} declares no ${role} function point`);
  return point;
};
const anchorDrift = (declaration, role, waypoint) => Math.hypot(
  localToWorld(functionPoint(declaration, role).position, declaration.position, declaration.yaw)[0] - waypoint[0],
  localToWorld(functionPoint(declaration, role).position, declaration.position, declaration.yaw)[1] - waypoint[1],
  localToWorld(functionPoint(declaration, role).position, declaration.position, declaration.yaw)[2] - waypoint[2]);

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
  activities:old.activities.filter(a=>a.id in positions).map(a=>a.id==='music.listen'
    ? {id:'music.listen',action:'listenMusic',functionPoint:{propID:'prop.jukebox'},motionID:null,propIDs:['prop.jukebox'],interruptible:true}
    : {...a,transform:transform(positions[a.id],layout.spawn.yaw),motionID:null,propIDs:[]}),
  activityDefinitions:old.activityDefinitions.filter(a=>a.id in positions).map(a=>({...a,phases:a.phases.map(p=>({...p,motionIDs:residentMotionIDs(p.motionIDs),...(a.id==='music.listen'?{durationSeconds:p.phase==='enter'?0.6:p.durationSeconds,propIDs:p.phase==='loop'?['prop.jukebox']:[]}:{} )}))})),
  cameras:[{id:'living.establishing',transform:transform(layout.camera.position,layout.camera.yaw,layout.camera.pitch),fieldOfViewDegrees:66,nearPlane:0.05,farPlane:250}],
  capabilities:['activity:home.idle','activity:home.walk','activity:music.listen','camera:living.establishing'], resources:[]
};
const wish = layout.wishMachine, jukebox = layout.jukebox;
const jukeboxDrift = anchorDrift(jukebox, 'interact', positions['music.listen']);
if (!(jukeboxDrift <= 0.01)) throw new Error(`Jukebox interact function point drifted ${jukeboxDrift.toFixed(4)} m from wp.jukebox`);
const bakedPickup = (layout.navigation?.source?.manualWaypoints ?? []).find(candidate => candidate.id === 'wish_machine.pickup');
if (bakedPickup) {
  const drift = anchorDrift(wish, 'pickup', [bakedPickup.position.x, bakedPickup.position.y, bakedPickup.position.z]);
  if (!(drift <= 0.01)) throw new Error(`Wish machine pickup function point drifted ${drift.toFixed(4)} m from its baked navigation waypoint`);
}
manifest.waypoints.unshift(bakedPickup ?? {id:'wish_machine.pickup',position:point(localToWorld(functionPoint(wish,'pickup').position,wish.position,wish.yaw)),arrivalRadius:0.2,enabled:true});
manifest.routes.unshift({id:'wish_machine.route',waypointIDs:['wp.spawn','wp.center','wish_machine.pickup'],bidirectional:true,enabled:true});
manifest.activities.unshift({id:'wish_machine.collect',action:'interact',functionPoint:{propID:'wish_machine.device'},motionID:null,propIDs:['wish_machine.device'],interruptible:true});
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
  if (navigation.schemaVersion !== 1 || navigation.generator !== 'production-capsule-grid-v1' ||
      navigation.source?.worldID !== worldID || navigation.source?.colliderSHA256 !== colliderSHA256 ||
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
// 场景配置只留视觉放置：功能点**不进** marble.json，避免同一件事有第二份真相。
await writeResource('marble.json',{world,framing:layout.framing,camera:layout.camera,jukebox:{position:jukebox.position,yaw:jukebox.yaw}},'scene.configuration','scene.configuration');
await writeResource('jukebox.json',{id:'prop.jukebox',kind:'prop.procedural',renderer:'builtin.jukebox',position:jukebox.position,yaw:jukebox.yaw,activityID:'music.listen',effect:'player.resume',functionPoints:jukebox.functionPoints,placeBindings:jukebox.placeBindings},'prop.procedural','prop.jukebox');
await writeResource('wish-machine.json',{id:'wish_machine.device',kind:'prop.procedural',renderer:'builtin.wish_machine',position:wish.position,yaw:wish.yaw,size:wish.size,activityID:'wish_machine.collect',functionPoints:wish.functionPoints,placeBindings:wish.placeBindings},'prop.procedural','wish_machine.device');
await writeFile(join(destination,'world.json'),JSON.stringify(manifest,null,2)+'\n');
console.log(JSON.stringify({worldID,destination,resources:manifest.resources.length,activities:manifest.activities.map(a=>a.id)},null,2));
