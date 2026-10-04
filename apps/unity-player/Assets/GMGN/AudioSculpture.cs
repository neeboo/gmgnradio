using UnityEngine;

namespace GMGN.UnityPlayer
{
    public sealed class AudioSculpture : MonoBehaviour
    {
        readonly Transform[] bars = new Transform[48];
        float bass, vocal, treble;
        bool playing;
        void Start()
        {
            var camera = Camera.main;
            if (camera == null) camera = new GameObject("Camera").AddComponent<Camera>();
            camera.tag = "MainCamera"; camera.transform.position = new Vector3(0, 3, -9);
            camera.clearFlags = CameraClearFlags.SolidColor;
            camera.transform.LookAt(new Vector3(-1.5f, 0, 0)); camera.backgroundColor = new Color(.025f,.035f,.065f);
            var material = Resources.Load<Material>("AudioMaterial");
            if (material == null) { Debug.LogError("Audio sculpture material was not prepared."); enabled = false; return; }
            for (var i = 0; i < bars.Length; i++) {
                var bar = GameObject.CreatePrimitive(PrimitiveType.Cube); Destroy(bar.GetComponent<Collider>());
                bar.name = "Audio bar " + i; bar.transform.SetParent(transform);
                var angle = i * Mathf.PI * 2 / bars.Length;
                bar.transform.position = new Vector3(-2 + Mathf.Cos(angle)*2, 0, Mathf.Sin(angle)*2);
                bar.GetComponent<Renderer>().sharedMaterial = material; bars[i] = bar.transform;
            }
        }
        public void SetFeatures(bool active, float low, float mid, float high) { playing = active; bass = low; vocal = mid; treble = high; }
        void Update()
        {
            for (var i = 0; i < bars.Length; i++) {
                if (bars[i] == null) continue;
                var energy = i % 3 == 0 ? bass : i % 3 == 1 ? vocal : treble;
                var target = .12f + (playing ? Mathf.Clamp01(energy) * 2.5f : 0);
                bars[i].localScale = Vector3.Lerp(bars[i].localScale, new Vector3(.13f, target, .13f), Time.deltaTime * 12);
            }
        }
    }
}
