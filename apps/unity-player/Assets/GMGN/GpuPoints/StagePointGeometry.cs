using UnityEngine;
namespace GMGN.UnityPlayer
{
    // Numeric geometry port of StageParticleGeometry.albumCanvas/ambientField.
    // Seeds are immutable and built once; all motion and artwork sampling is GPU.
    public static class StagePointGeometry
    {
        public const int Grid=144,PrimaryCount=Grid*Grid,AmbientCount=1800;
        struct Random{ulong state;public Random(ulong seed){state=seed==0?0x9E3779B97F4A7C15UL:seed;}public float Unit(){unchecked{state+=0x9E3779B97F4A7C15UL;var v=state;v=(v^(v>>30))*0xBF58476D1CE4E5B9UL;v=(v^(v>>27))*0x94D049BB133111EBUL;v^=v>>31;return (v>>40)/16777216f;}}}
        public static GpuPointSeed[] Build(){
            var seeds=new GpuPointSeed[PrimaryCount+AmbientCount];var random=new Random(0x474D474E);
            for(var row=0;row<Grid;row++)for(var col=0;col<Grid;col++){
                var u=(col+.5f)/Grid;var v=(row+.5f)/Grid;
                seeds[row*Grid+col]=new GpuPointSeed{position=new Vector4((u-.5f)*6,(v-.5f)*6,0,.82f+random.Unit()*.42f),color=new Vector4(.03f+u*.08f,.22f+(1-v)*.5f,.72f+u*.28f,1),timing=new Vector4(1,-1,4,random.Unit()*Mathf.PI*2)};
            }
            random=new Random(0x4D564658);var dust=(int)(AmbientCount*.65f);var shards=(int)(AmbientCount*.18f);
            for(var i=0;i<AmbientCount;i++){
                Vector3 position,a,b;float size;var region=5;
                if(i<dust){var depth=-10.5f+random.Unit()*14.5f;var spread=.62f+(depth+10.5f)/14.5f*.38f;position=new Vector3((random.Unit()*2-1)*9.5f*spread,(random.Unit()*2-1)*5.4f*spread,depth);size=.34f+random.Unit()*.72f;a=new Vector3(.28f,.68f,1);b=new Vector3(.78f,.48f,1);}
                else if(i<dust+shards){region=6;position=new Vector3((random.Unit()*2-1)*7.4f,(random.Unit()*2-1)*4.2f,-4.5f+random.Unit()*7.5f);size=1.4f+Mathf.Pow(random.Unit(),1.8f)*3.3f;a=new Vector3(.58f,.86f,1);b=new Vector3(1,.68f,.88f);}
                else{region=7;var lane=random.Unit();position=new Vector3((random.Unit()*2-1)*7.8f,-2.82f+lane*lane*.92f,-5.8f+random.Unit()*9.2f);size=.92f+Mathf.Pow(random.Unit(),1.5f)*3.1f;a=new Vector3(.4f,.78f,1);b=new Vector3(.88f,.94f,1);}
                var tint=Vector3.Lerp(a,b,random.Unit());seeds[PrimaryCount+i]=new GpuPointSeed{position=new Vector4(position.x,position.y,position.z,size),color=new Vector4(tint.x,tint.y,tint.z,1),timing=new Vector4(1,-1,region,random.Unit()*Mathf.PI*2)};
            }
            return seeds;
        }
        public static bool Resolve(string choice,out Vector3 weights,out float composition){
            composition=0;weights=Vector3.zero;
            switch(choice){case "flowingCanvas":weights=Vector3.right;return true;case "orbitalShell":weights=Vector3.up;composition=.24f;return true;case "openRibbon":weights=Vector3.forward;return true;case "vinylRecord":weights=Vector3.right;composition=2;return true;case "galaxyField":weights=Vector3.forward;composition=2;return true;case "tunnel":weights=Vector3.up;composition=2;return true;case "void":return true;case "automatic":return false;default:return false;}
        }
    }
}
