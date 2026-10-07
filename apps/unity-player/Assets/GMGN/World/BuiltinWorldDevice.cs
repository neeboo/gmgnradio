using System;
using System.Collections;
using System.IO;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace GMGN.UnityPlayer.World
{
    /// Presentation of a validated package declaration, with no world writes.
    public sealed class BuiltinWorldDevice : MonoBehaviour
    {
        public string ObjectID { get; private set; }
        public string RendererID { get; private set; }
        public event Action<string> Activated;
        Material status;
        Transform playButton;
        Material playButtonMaterial;
        float buttonPressedUntil;
        readonly CancellationTokenSource lifetime = new();
        public bool HasVerifiedVisual { get; private set; }
        public event Action VisualChanged;
        GameObject outputPreview;
        string previewIdentity;
        int previewEpoch;
        CancellationTokenSource previewLoading;
        JObject previewAck;
        Coroutine previewRenderReceipt;
        int previewRenderedFrame;
        float previewReceiptTime = float.NegativeInfinity;
        // Device reconstruction must not restart the sequence for a projection.
        static long previewReceiptSequence;
        public Action<JObject> OutputProjectionAcknowledged;
        readonly System.Collections.Generic.List<Material> materials = new();

        public static BuiltinWorldDevice CreateMarker(JObject declaration, Transform parent)
        {
            var size = declaration["size"] as JArray;
            if (size == null || size.Count != 3) throw new ArgumentException("Authored device dimensions are missing.");
            var root = new GameObject((string)declaration["id"]);
            root.transform.SetParent(parent, false);
            var device = root.AddComponent<BuiltinWorldDevice>();
            device.ObjectID = (string)declaration["id"]; device.RendererID = (string)declaration["renderer"];
            device.status = device.Mat(new Color(.15f,.65f,.75f),0,true);
            var dimensions = new Vector3((float)size[0],(float)size[1],(float)size[2]);
            device.Box("device.marker",dimensions,new Vector3(0,dimensions.y/2,0),device.status);
            if (device.RendererID == "builtin.wish_machine") {
                device.WishTray(new Vector3(dimensions.x,Mathf.Min(dimensions.y,.12f),dimensions.z));
                root.transform.Find("device.marker").GetComponent<Renderer>().enabled = false;
            }
            device.AddFunctionAnchors(declaration);
            device.LoadVerifiedVisual(dimensions);
            return device;
        }

        public static BuiltinWorldDevice Create(JObject declaration, Transform parent)
        {
            var id = (string)declaration["id"];
            var renderer = (string)declaration["renderer"];
            if (string.IsNullOrEmpty(id) || (renderer != "builtin.jukebox" && renderer != "builtin.wish_machine"))
                throw new ArgumentException("Unsupported procedural device declaration.");
            var p = declaration["position"] as JArray;
            if (p == null || p.Count != 3) throw new ArgumentException("Device position is missing.");
            var root = new GameObject(id);
            root.transform.SetParent(parent, false);
            root.transform.localPosition = new Vector3((float)p[0], (float)p[1], -(float)p[2]);
            root.transform.localRotation = Quaternion.Euler(0, -((float?)declaration["yaw"] ?? 0) * Mathf.Rad2Deg, 0);
            var device = root.AddComponent<BuiltinWorldDevice>();
            device.ObjectID = id; device.RendererID = renderer;
            if (renderer == "builtin.wish_machine") {
                var size = declaration["size"] as JArray ?? throw new ArgumentException("Authored tray dimensions missing.");
                device.WishTray(new Vector3((float)size[0],(float)size[1],(float)size[2]));
            } else device.Jukebox();
            device.AddFunctionAnchors(declaration);
            return device;
        }
        void AddFunctionAnchors(JObject declaration)
        {
            foreach (var point in declaration["functionPoints"] as JArray ?? new JArray())
            {
                var local = point["position"] as JArray;
                if (local == null || local.Count != 3) continue;
                var anchor = new GameObject("function." + (string)point["role"]);
                anchor.transform.SetParent(transform, false);
                anchor.transform.localPosition = new Vector3((float)local[0], (float)local[1], -(float)local[2]);
                anchor.transform.localRotation = Quaternion.Euler(0, -((float?)point["yaw"] ?? 0) * Mathf.Rad2Deg, 0);
                if(RendererID == "builtin.jukebox" && (string)point["role"] == "button" && (string)point["kind"] == "interaction") {
                    var button=GameObject.CreatePrimitive(PrimitiveType.Cylinder);
                    button.name="jukebox.play-button";button.transform.SetParent(anchor.transform,false);
                    button.transform.localRotation=Quaternion.Euler(0,0,90);
                    button.transform.localScale=new Vector3(.04f,.002f,.04f);
                    Destroy(button.GetComponent<Collider>());
                    playButtonMaterial=Mat(new Color(.15f,.75f,.85f),.6f,true);
                    button.GetComponent<Renderer>().sharedMaterial=playButtonMaterial;
                    playButton=button.transform;
                }
            }
        }

        async void LoadVerifiedVisual(Vector3 dimensions)
            => await LoadVerifiedVisual(dimensions, BundledDeviceDirectory(Application.dataPath));

        async Task LoadVerifiedVisual(Vector3 dimensions, string directory)
        {
            GameObject model = null;
            try {
                var name = RendererID == "builtin.jukebox" ? "jukebox-v1" : RendererID == "builtin.wish_machine" ? "wish-tray-v2" : null;
                if (name == null) return;
                // macOS standalone resources are outside Unity's Data folder.
                Debug.Log("[BuiltinDeviceVisual] stage=locate renderer="+RendererID);
                if (directory == null) { Debug.LogWarning("[BuiltinDeviceVisual] stage=missing-directory renderer="+RendererID); return; }
                var modelPath = Path.Combine(directory,name+".glb");
                var receiptPath = Path.Combine(directory,name+".receipt.json");
                if (!File.Exists(modelPath) || !File.Exists(receiptPath)) { Debug.LogWarning("[BuiltinDeviceVisual] stage=missing-package renderer="+RendererID); return; }
                var token = lifetime.Token;
                await Task.Run(() => VerifyReceipt(modelPath,receiptPath),token);
                token.ThrowIfCancellationRequested();
                Debug.Log("[BuiltinDeviceVisual] stage=import renderer="+RendererID);
                // These two bounded bundled models must load even when the room
                // already exceeds glTFast's per-frame budget. Its default defer
                // agent can otherwise keep awaiting texture work indefinitely.
                model = await new GltfWorldAssetLoader(new GLTFast.UninterruptedDeferAgent()).LoadSceneAsset(modelPath,token);
                token.ThrowIfCancellationRequested();
                model.transform.SetParent(transform,false);
                FitVisual(model.transform,dimensions);
                foreach (var collider in model.GetComponentsInChildren<Collider>()) Destroy(collider);
                // The authored box remains the placement/click proxy. Its bounds
                // enclose the proportional model; swapping visuals changes no ID,
                // functional anchor, collision contract or authority record.
                var marker = transform.Find("device.marker");
                if (marker != null) foreach(var renderer in marker.GetComponentsInChildren<Renderer>()) renderer.enabled = false;
                var tray = transform.Find("wish.tray.geometry");
                if (tray != null) foreach(var renderer in tray.GetComponentsInChildren<Renderer>()) renderer.enabled = false;
                HasVerifiedVisual = true; VisualChanged?.Invoke();
                Debug.Log("[BuiltinDeviceVisual] verified=true renderer="+RendererID);
            } catch (OperationCanceledException) { if (model != null) Destroy(model); }
            catch (Exception error) {
                if (model != null) Destroy(model);
                // Do not expose asset paths or claim the marker is the design.
                Debug.LogWarning("[BuiltinDeviceVisual] verified=false renderer="+RendererID+" code="+error.GetType().Name);
            }
        }
        public static string BundledDeviceDirectory(string dataPath)
        {
            for(var path=Path.GetFullPath(dataPath); !string.IsNullOrEmpty(path);path=Path.GetDirectoryName(path))
                if(Path.GetFileName(path).EndsWith(".app",StringComparison.OrdinalIgnoreCase))
                    return Path.Combine(path,"Contents/Resources/Devices");
            return null;
        }
        public static void VerifyReceipt(string modelPath,string receiptPath)
        {
            var receipt = JObject.Parse(File.ReadAllText(receiptPath));
            var inspection = receipt["result"]?["inspection"];
            if ((string)receipt["state"] != "completed" || inspection == null) throw new InvalidDataException("Device generation is not complete.");
            var expected = (string)inspection["sha256"];
            var bytes = (long?)inspection["bytes"];
            if (expected == null || expected.Length != 64 || bytes == null || bytes <= 0 || new FileInfo(modelPath).Length != bytes)
                throw new InvalidDataException("Device asset receipt is invalid.");
            using var stream = File.OpenRead(modelPath); using var sha = SHA256.Create();
            var actual = BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
            if (actual != expected) throw new InvalidDataException("Device asset checksum mismatch.");
        }
        public static void FitVisual(Transform model,Vector3 dimensions)
        {
            var filters = model.GetComponentsInChildren<MeshFilter>(true);
            var initialized = false; var bounds = new Bounds();
            foreach (var filter in filters) {
                if (filter.sharedMesh == null) continue;
                var local = filter.sharedMesh.bounds;
                for (var i=0;i<8;i++) {
                    var corner = new Vector3((i&1)==0?local.min.x:local.max.x,(i&2)==0?local.min.y:local.max.y,(i&4)==0?local.min.z:local.max.z);
                    var point = model.InverseTransformPoint(filter.transform.TransformPoint(corner));
                    if (!initialized) { bounds = new Bounds(point,Vector3.zero); initialized=true; } else bounds.Encapsulate(point);
                }
            }
            var extent = bounds.size;
            if (!initialized || extent.x<=.00001f || extent.y<=.00001f || extent.z<=.00001f || dimensions.x<=0 || dimensions.y<=0 || dimensions.z<=0)
                throw new InvalidDataException("Device visual bounds are invalid.");
            var scale = Mathf.Min(dimensions.x/extent.x,dimensions.y/extent.y,dimensions.z/extent.z);
            if (float.IsNaN(scale) || float.IsInfinity(scale) || scale<=0) throw new InvalidDataException("Device visual scale is invalid.");
            model.localScale = Vector3.one*scale;
            model.localPosition = -new Vector3(bounds.center.x,bounds.min.y,bounds.center.z)*scale;
        }

        public void Activate() => Activated?.Invoke(ObjectID);
        // Called only after Host accepts actual hand contact, never on click.
        public void PulseButton() { if(playButton!=null) buttonPressedUntil=Time.unscaledTime+.25f; }
        // Only a formal task-receipt catalog resolver may authorize this read.
        // A visible ready output remains a preview, never a claim or placement.
        public async void ShowOutputPreview(JObject descriptor, GeneratedAssetResolver resolver,string currentWorldID)
        {
            if (RendererID != "builtin.wish_machine" || resolver == null || string.IsNullOrEmpty(currentWorldID) || (string)descriptor?["worldID"] != currentWorldID ||
                (string)descriptor["stage"] != "ready" || !Guid.TryParse((string)descriptor["sourceWishID"],out _) ||
                !Guid.TryParse((string)descriptor["projectionSessionID"],out _) || !Guid.TryParse((string)descriptor["projectionID"],out _) ||
                string.IsNullOrEmpty((string)descriptor["objectID"]) || !resolver.Contains((string)descriptor["objectID"])) { HideOutputPreview(); return; }
            var identity = currentWorldID+":"+(string)descriptor["projectionSessionID"]+":"+(string)descriptor["projectionID"]+":"+(string)descriptor["sourceWishID"]+":"+(string)descriptor["assetID"];
            if (previewIdentity == identity) {
                // Repeated snapshots retry a dropped callback without reloading the asset.
                if(previewAck!=null && Time.unscaledTime-previewReceiptTime>=1f)
                    AcknowledgeOutput(previewRenderedFrame>0 && isActiveAndEnabled && outputPreview!=null && outputPreview.activeInHierarchy);
                return;
            }
            HideOutputPreview(); previewAck=null; previewIdentity = identity;
            descriptor = (JObject)descriptor.DeepClone();
            var epoch = previewEpoch;
            previewLoading = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
            var token = previewLoading.Token;
            GameObject model = null;
            try {
                var path = await resolver.Resolve(descriptor,token);
                token.ThrowIfCancellationRequested();
                if (epoch != previewEpoch) return;
                previewAck=new JObject { ["op"]="wish.output.projected",["worldID"]=currentWorldID,
                    ["projectionSessionID"]=(string)descriptor["projectionSessionID"],["projectionID"]=(string)descriptor["projectionID"],
                    ["wishID"]=(string)descriptor["sourceWishID"],["objectID"]=(string)descriptor["objectID"],["modelPath"]=path };
                model = await new GltfWorldAssetLoader().LoadPreparedAsset(path,descriptor,token);
                token.ThrowIfCancellationRequested();
                if (epoch != previewEpoch) { Destroy(model); return; }
                var outlet = transform.Find("function.outlet");
                if (outlet == null) throw new InvalidDataException("Authored output anchor missing.");
                // Sibling projection intentionally stays outside device placement
                // geometry: hovering output must not enlarge the saved device.
                model.transform.SetParent(transform.parent,false);
                model.transform.position = outlet.position;
                foreach(var collider in model.GetComponentsInChildren<Collider>()) Destroy(collider);
                outputPreview = model; outputPreview.name = "wish.ready-preview";
                outputPreview.SetActive(isActiveAndEnabled); SetWishStage("ready");
                if(isActiveAndEnabled) ScheduleRenderReceipt(); else AcknowledgeOutput(false);
            } catch (OperationCanceledException) { if(model!=null) Destroy(model); }
            catch(Exception error) {
                if(model!=null) Destroy(model);
                if(epoch == previewEpoch) { AcknowledgeOutput(false); previewAck=null; previewIdentity = null; }
                Debug.LogWarning("[WishOutputPreview] visible=false code="+error.GetType().Name);
            }
        }
        public void HideOutputPreview()
        {
            CancelRenderReceipt();
            // Keep the retired receipt until a new projection starts so repeated
            // empty snapshots can retry a dropped unload callback as well.
            if(previewIdentity!=null || Time.unscaledTime-previewReceiptTime>=1f) AcknowledgeOutput(false);
            previewEpoch++; previewIdentity=null;
            previewLoading?.Cancel(); previewLoading?.Dispose(); previewLoading=null;
            if(outputPreview!=null) Destroy(outputPreview); outputPreview=null;
        }
        void AcknowledgeOutput(bool rendered)
        {
            if(previewAck==null) return;
            if(rendered && previewRenderedFrame<=0) return;
            var sequence=Interlocked.Increment(ref previewReceiptSequence);
            var ack=(JObject)previewAck.DeepClone();ack["rendered"]=rendered;
            ack["renderedFrame"]=rendered?previewRenderedFrame:0; ack["receiptSequence"]=sequence;
            previewReceiptTime=Time.unscaledTime; OutputProjectionAcknowledged?.Invoke(ack);
        }
        void CancelRenderReceipt()
        {
            if(previewRenderReceipt!=null) StopCoroutine(previewRenderReceipt);
            previewRenderReceipt=null; previewRenderedFrame=0;
        }
        void ScheduleRenderReceipt()
        {
            CancelRenderReceipt();
            previewRenderReceipt=StartCoroutine(AcknowledgeAfterRenderedFrame(previewEpoch,outputPreview));
        }
        IEnumerator AcknowledgeAfterRenderedFrame(int epoch,GameObject model)
        {
            // Advance past activation, then wait until all cameras have rendered.
            // Loading and SetActive alone never establish a rendered receipt.
            yield return null;
            yield return new WaitForEndOfFrame();
            previewRenderReceipt=null;
            if(epoch!=previewEpoch || model==null || model!=outputPreview || !isActiveAndEnabled || !model.activeInHierarchy) yield break;
            previewRenderedFrame=Time.frameCount;
            AcknowledgeOutput(true);
        }
        void LateUpdate()
        {
            if(playButton!=null) {
                var pressed=Time.unscaledTime<buttonPressedUntil;
                playButton.localPosition=pressed ? Vector3.right*.003f : Vector3.zero;
                playButtonMaterial.SetColor("_EmissionColor",new Color(.15f,.75f,.85f)*(pressed?5:2));
            }
            if(outputPreview==null) return;
            var outlet=transform.Find("function.outlet");
            if(outlet!=null) outputPreview.transform.position=outlet.position+Vector3.up*(Mathf.Sin(Time.unscaledTime*1.5f)*.012f);
        }
        void OnDisable() { CancelRenderReceipt(); if(outputPreview!=null) { outputPreview.SetActive(false); AcknowledgeOutput(false); } }
        void OnEnable() { if(outputPreview!=null) { outputPreview.SetActive(true); ScheduleRenderReceipt(); } }
        public void SetWishStage(string stage)
        {
            if (status == null) return;
            var color = stage == "ready" ? Color.green : stage == "failed" ? Color.red :
                stage == "generating" ? new Color(1, .55f, .1f) : Color.cyan;
            status.SetColor("_BaseColor", color); status.SetColor("_EmissionColor", color * 2);
        }
        Material Mat(Color color, float metal = 0, bool glow = false)
        {
            var shader = Shader.Find("Universal Render Pipeline/Lit");
            if (shader == null) throw new InvalidOperationException("Device shader unavailable.");
            var mat = new Material(shader); materials.Add(mat);
            mat.SetColor("_BaseColor", color); mat.SetFloat("_Metallic", metal); mat.SetFloat("_Smoothness", .55f);
            if (glow) { mat.EnableKeyword("_EMISSION"); mat.SetColor("_EmissionColor", color * 2); }
            return mat;
        }
        void Box(string name, Vector3 size, Vector3 p, Material mat, Transform parent = null)
        {
            var box = GameObject.CreatePrimitive(PrimitiveType.Cube); box.name = name;
            box.transform.SetParent(parent ?? transform, false);
            box.transform.localPosition = new Vector3(p.x, p.y, -p.z); box.transform.localScale = size;
            box.GetComponent<Renderer>().sharedMaterial = mat;
        }
        void WishTray(Vector3 dimensions)
        {
            var visuals = new GameObject("wish.tray.geometry").transform; visuals.SetParent(transform,false);
            var dark = Mat(new Color(.055f,.065f,.08f),.6f); var tray = Mat(new Color(.25f,.3f,.34f),.65f);
            status = Mat(Color.cyan,0,true);
            Box("tray.base",new Vector3(dimensions.x,dimensions.y*.55f,dimensions.z),new Vector3(0,dimensions.y*.275f,0),dark,visuals);
            Box("tray.surface",new Vector3(dimensions.x*.9f,dimensions.y*.3f,dimensions.z*.9f),new Vector3(0,dimensions.y*.7f,0),tray,visuals);
            var rim = Mathf.Min(.025f,dimensions.y*.2f);
            foreach(var x in new[]{-1f,1f}) Box("tray.rim",new Vector3(rim,rim,dimensions.z*.95f),new Vector3(x*(dimensions.x-rim)*.5f,dimensions.y-rim*.5f,0),status,visuals);
            Box("tray.status",new Vector3(dimensions.x*.8f,rim,rim),new Vector3(0,dimensions.y-rim*.5f,-(dimensions.z-rim)*.5f),status,visuals);
        }
        void Jukebox()
        {
            var hull=Mat(new Color(.16f,.16f,.16f),.55f); var trim=Mat(new Color(.07f,.07f,.07f),.5f);
            var steel=Mat(new Color(.72f,.72f,.72f),.9f); var amber=Mat(new Color(1,.62f,.22f),0,true);
            Box("plinth",new Vector3(.5f,.1f,.42f),new Vector3(0,.05f,0),trim);
            Box("body",new Vector3(.44f,1.06f,.36f),new Vector3(0,.63f,0),hull);
            Box("top-cap",new Vector3(.38f,.05f,.3f),new Vector3(0,1.185f,0),steel);
            Box("top-light",new Vector3(.22f,.02f,.22f),new Vector3(0,1.22f,0),amber);
            Box("fascia",new Vector3(.03f,.88f,.3f),new Vector3(-.235f,.63f,0),trim);
            Box("dial",new Vector3(.03f,.17f,.17f),new Vector3(-.24f,.78f,0),amber);
            for(var i=0;i<3;i++) Box("equalizer",new Vector3(.015f,new[]{.24f,.3f,.2f}[i],.05f),new Vector3(-.24f,.32f,-.13f+i*.13f),amber);
        }
        void OnDestroy() { HideOutputPreview(); lifetime.Cancel(); lifetime.Dispose(); foreach(var mat in materials) Destroy(mat); }
    }
}
