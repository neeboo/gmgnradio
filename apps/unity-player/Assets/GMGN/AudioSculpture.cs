using UnityEngine;

namespace GMGN.UnityPlayer
{
    public sealed class AudioSculpture : MonoBehaviour
    {
        GpuPointCloud cloud;
        float bass, vocal, treble;
        bool playing;
        Vector3 weights=Vector3.right;float composition,intensity=1,particleSize=1;
        float primaryVisibility=1,ambientVisibility=.72f;Texture artwork;Vector4 rhythm,waveA,waveB;
        public string Choice {get;private set;}="automatic";
        void Start()
        {
            var camera = Camera.main;
            if (camera == null) camera = new GameObject("Camera").AddComponent<Camera>();
            camera.tag = "MainCamera"; camera.transform.position = new Vector3(0, 0, -9);
            camera.clearFlags = CameraClearFlags.SolidColor;
            camera.transform.LookAt(Vector3.zero); camera.backgroundColor = new Color(.025f,.035f,.065f);
            cloud = gameObject.AddComponent<GpuPointCloud>();
            cloud.StageRendering=true;cloud.localBounds=new Bounds(Vector3.zero,new Vector3(24,15,28));
            gameObject.AddComponent<StagePointRotationController>().Configure(this, cloud);
            var seeds=StagePointGeometry.Build();
            if (!cloud.SetPoints(seeds)) { Debug.LogError(cloud.Status, this); enabled = false; }
            else Debug.Log("Audio sculpture GPU ready: points=" + cloud.PointCount + ", graphics=" + SystemInfo.graphicsDeviceType, this);
        }
        public void SetFeatures(bool active, float low, float mid, float high) { playing = active; bass = low; vocal = mid; treble = high; }
        public void SetVisual(string choice,float amount,float size,Vector3 automaticWeights,float automaticComposition){Choice=choice??"automatic";if(!StagePointGeometry.Resolve(Choice,out weights,out composition)){weights=automaticWeights;composition=automaticComposition;}intensity=Mathf.Clamp01(amount);particleSize=Mathf.Clamp(size,.6f,1.6f);primaryVisibility=Choice=="void"?0:Choice=="galaxyField"?.42f:1;ambientVisibility=Choice=="void"?0:Choice=="galaxyField"?1.08f:Choice=="vinylRecord"?.52f:.72f;}
        public void SetArtwork(Texture texture){artwork=texture;}
        public void SetRhythm(Vector4 value,Vector4 waveformA,Vector4 waveformB){rhythm=value;waveA=waveformA;waveB=waveformB;}
        void Update()
        {
            cloud?.SetPlayback(Time.unscaledTime, playing, bass, vocal, treble);
            if(cloud!=null){cloud.SetStageVisual(weights,composition,intensity,particleSize,primaryVisibility,ambientVisibility);cloud.SetArtwork(artwork);cloud.SetRhythm(rhythm,waveA,waveB);}
        }
    }
}
