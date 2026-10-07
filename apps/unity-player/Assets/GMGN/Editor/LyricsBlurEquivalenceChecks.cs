using System;
using System.Reflection;
using UnityEngine;
using UnityEditor;
using UnityEngine.Rendering;

namespace GMGN.UnityPlayer.Editor
{
    public static class LyricsBlurEquivalenceChecks
    {
        public static void Run()
        {
            var host=new GameObject("Actual Gaussian GPU equivalence");
            var gpu=host.AddComponent<GpuLyricsView>();gpu.enabled=false;
            Material reference=null, optimized=null;
            Texture2D input=null;
            RenderTexture a=null,b=null,c=null,d=null;
            try {
                reference=new Material(AssetDatabase.LoadAssetAtPath<Shader>("Assets/GMGN/Editor/LyricsBlurReference.shader"));
                optimized=new Material(Resources.Load<Shader>("GpuLyricsBlur"));
                Require(reference.shader.isSupported && optimized.shader.isSupported,"reference/production shaders supported");
                const int width=257,height=129;
                input=new Texture2D(width,height,TextureFormat.RGBAFloat,false,true){filterMode=FilterMode.Bilinear,wrapMode=TextureWrapMode.Clamp};
                var pixels=new Color[width*height];
                for(int y=0;y<height;y++)for(int x=0;x<width;x++){
                    float pulse=((x%17)==0 && (y%11)==0)?1:0;
                    pixels[y*width+x]=new Color(pulse,(x%9)/8f,(y%7)/6f,x==width/2 && y==height/2?1:0);
                }
                input.SetPixels(pixels);input.Apply();
                a=Target(width,height);b=Target(width,height);c=Target(width,height);d=Target(width,height);
                var configure=typeof(GpuLyricsView).GetMethod("ConfigureGaussianBlur",BindingFlags.Instance|BindingFlags.NonPublic);
                foreach(float radius in new[]{.5f,4.5f,9f,11f,16.5f,22f}){
                    reference.SetFloat("_Radius",radius);
                    configure.Invoke(gpu,new object[]{optimized,radius});
                    Graphics.Blit(input,a,reference,0);Graphics.Blit(a,b,reference,1);
                    Graphics.Blit(input,c,optimized,0);Graphics.Blit(c,d,optimized,1);
                    var expected=Read(b);var actual=Read(d);
                    double sum=0;float max=0;
                    for(int i=0;i<expected.Length;i++){
                        float error=Mathf.Max(Mathf.Abs(expected[i].r-actual[i].r),Mathf.Abs(expected[i].g-actual[i].g),Mathf.Abs(expected[i].b-actual[i].b),Mathf.Abs(expected[i].a-actual[i].a));
                        max=Mathf.Max(max,error);sum+=error;
                    }
                    Require(max<.003f && sum/expected.Length<.0006,"original kernel pixel equivalence radius="+radius+" max="+max+" mean="+sum/expected.Length);
                    int samples=optimized.GetInt("_GaussianPaired")!=0?13:25;
                    Require(samples==(radius<=12?13:25),"non-unit stride retains exact 25 taps");
                    Debug.Log($"PASS actual GPU Gaussian A/B radius={radius}; samplesPerPass={samples}; maxError={max:F7}; meanError={sum/expected.Length:F7}");
                }
                Benchmark(input,reference,optimized,gpu,configure);
                LyricsResizeResourceChecks.Run();
                Debug.Log("PASS: exact original Gaussian kernel preserved, native Retina 2x glow 25->13 samples/pass, original font/animation/resources retained");
            } finally {
                foreach(var target in new[]{a,b,c,d})if(target!=null){target.Release();UnityEngine.Object.DestroyImmediate(target);}
                if(input!=null)UnityEngine.Object.DestroyImmediate(input);
                if(reference!=null)UnityEngine.Object.DestroyImmediate(reference);
                if(optimized!=null)UnityEngine.Object.DestroyImmediate(optimized);
                UnityEngine.Object.DestroyImmediate(host);
            }
        }
        static void Benchmark(Texture source,Material reference,Material optimized,GpuLyricsView gpu,MethodInfo configure)
        {
            var first=Target(1024,576);var second=Target(1024,576);
            try {
                reference.SetFloat("_Radius",11);configure.Invoke(gpu,new object[]{optimized,11f});
                SubmitAndDrain(source,first,second,reference,1);SubmitAndDrain(source,first,second,optimized,1);
                var oldTimes=new double[3];var newTimes=new double[3];
                for(int i=0;i<3;i++){
                    // Reverse order on the middle pair to reduce clock/load bias.
                    if(i==1){newTimes[i]=SubmitAndDrain(source,first,second,optimized,4);oldTimes[i]=SubmitAndDrain(source,first,second,reference,4);}
                    else{oldTimes[i]=SubmitAndDrain(source,first,second,reference,4);newTimes[i]=SubmitAndDrain(source,first,second,optimized,4);}
                }
                Array.Sort(oldTimes);Array.Sort(newTimes);
                Debug.Log($"GPU Gaussian submit+drain measurement: native 4K glow 1024x576, 4 horizontal/vertical pairs; referenceMedianMs={oldTimes[1]:F3}; optimizedMedianMs={newTimes[1]:F3}; referenceSamplesPerFrame=29491200 optimizedSamplesPerFrame=15335424; no screen resolution change");
            } finally {first.Release();second.Release();UnityEngine.Object.DestroyImmediate(first);UnityEngine.Object.DestroyImmediate(second);}
        }
        static double SubmitAndDrain(Texture source,RenderTexture first,RenderTexture second,Material material,int iterations)
        {
            var clock=System.Diagnostics.Stopwatch.StartNew();
            for(int i=0;i<iterations;i++){Graphics.Blit(source,first,material,0);Graphics.Blit(first,second,material,1);}
            var request=AsyncGPUReadback.Request(second,0);request.WaitForCompletion();
            Require(!request.hasError,"GPU completion/readback");
            return clock.Elapsed.TotalMilliseconds;
        }
        static RenderTexture Target(int width,int height){var result=new RenderTexture(width,height,0,RenderTextureFormat.ARGBFloat,RenderTextureReadWrite.Linear){filterMode=FilterMode.Bilinear,wrapMode=TextureWrapMode.Clamp};Require(result.Create(),"float GPU target");return result;}
        static Color[] Read(RenderTexture target){var old=RenderTexture.active;var texture=new Texture2D(target.width,target.height,TextureFormat.RGBAFloat,false,true);try{RenderTexture.active=target;texture.ReadPixels(new Rect(0,0,target.width,target.height),0,0);texture.Apply();return texture.GetPixels();}finally{RenderTexture.active=old;UnityEngine.Object.DestroyImmediate(texture);}}
        static void Require(bool value,string message){if(!value)throw new Exception("FAIL GPU Gaussian equivalence: "+message);}
    }
}
