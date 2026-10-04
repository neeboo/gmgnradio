using UnityEngine;

namespace GMGN.UnityPlayer
{
    public sealed class AudioSculpture : MonoBehaviour
    {
        GpuPointCloud cloud;
        float bass, vocal, treble;
        bool playing;
        void Start()
        {
            var camera = Camera.main;
            if (camera == null) camera = new GameObject("Camera").AddComponent<Camera>();
            camera.tag = "MainCamera"; camera.transform.position = new Vector3(0, 3, -9);
            camera.clearFlags = CameraClearFlags.SolidColor;
            camera.transform.LookAt(new Vector3(-1.5f, 0, 0)); camera.backgroundColor = new Color(.025f,.035f,.065f);
            cloud = gameObject.AddComponent<GpuPointCloud>();
            cloud.localBounds = new Bounds(new Vector3(-2, 0, 0), new Vector3(5, 2, 5));
            var seeds = new GpuPointSeed[48];
            for (var i = 0; i < seeds.Length; i++) {
                var angle = i * Mathf.PI * 2 / seeds.Length;
                seeds[i] = new GpuPointSeed {
                    position = new Vector4(-2 + Mathf.Cos(angle)*2, 0, Mathf.Sin(angle)*2, .075f),
                    color = new Vector4(.1f, .75f, .95f, 1),
                    timing = new Vector4(1, -1, i % 3, angle)
                };
            }
            if (!cloud.SetPoints(seeds)) { Debug.LogError(cloud.Status, this); enabled = false; }
            else Debug.Log("Audio sculpture GPU ready: points=" + cloud.PointCount + ", graphics=" + SystemInfo.graphicsDeviceType, this);
        }
        public void SetFeatures(bool active, float low, float mid, float high) { playing = active; bass = low; vocal = mid; treble = high; }
        void Update()
        {
            cloud?.SetPlayback(Time.unscaledTime, playing, bass, vocal, treble);
        }
    }
}
