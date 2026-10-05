using System;
using System.Runtime.InteropServices;
using UnityEngine;
using UnityEditor;
using UnityEditor.Rendering;
namespace GMGN.UnityPlayer.Editor
{
 public static class StagePointsValidation
 {
  public static void Validate(){
   if(Marshal.SizeOf<GpuPointSeed>()!=48)throw new InvalidOperationException("Stage point stride mismatch");
   var points=StagePointGeometry.Build();var repeated=StagePointGeometry.Build();
   if(points.Length!=22536)throw new InvalidOperationException("Stage original point count mismatch");
   var counts=new int[8];
   for(var i=0;i<points.Length;i++){var p=points[i];if(float.IsNaN(p.position.x)||float.IsInfinity(p.position.x)||p.position.w<=0)throw new InvalidOperationException("Invalid stage seed");if(p.position!=repeated[i].position||p.timing!=repeated[i].timing)throw new InvalidOperationException("Stage seed is nondeterministic");counts[(int)p.timing.z]++;}
   if(counts[4]!=20736||counts[5]!=1170||counts[6]!=324||counts[7]!=306)throw new InvalidOperationException("Stage primary/dust/shard/floor counts differ from Swift");
   foreach(var mode in new[]{"flowingCanvas","orbitalShell","openRibbon","vinylRecord","galaxyField","tunnel","void"})if(!StagePointGeometry.Resolve(mode,out _,out _))throw new InvalidOperationException("Stage mode missing: "+mode);
   var compute=Resources.Load<ComputeShader>("GpuStagePointsUpdate");var shader=Resources.Load<Shader>("GpuPointsDraw");
   if(compute==null||shader==null)throw new InvalidOperationException("Stage GPU resources missing");
   if(SystemInfo.graphicsDeviceType!=UnityEngine.Rendering.GraphicsDeviceType.Null)compute.FindKernel("UpdatePoints");
   foreach(var message in ShaderUtil.GetComputeShaderMessages(compute))if(message.severity==ShaderCompilerMessageSeverity.Error)throw new InvalidOperationException(message.message);
   foreach(var message in ShaderUtil.GetShaderMessages(shader))if(message.severity==ShaderCompilerMessageSeverity.Error)throw new InvalidOperationException(message.message);
   Debug.Log("Stage GPU seed validation: 20736 primary + 1170 dust + 324 shard + 306 floor; 7 manual choices plus real timeline automatic contract. Runtime visual/performance not yet accepted.");
  }
 }
}
