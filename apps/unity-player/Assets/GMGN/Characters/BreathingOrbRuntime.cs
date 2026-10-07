using UnityEngine;
namespace GMGN.UnityPlayer.Characters {
 public sealed class BreathingOrbRuntime : MonoBehaviour {
  Material material;
  void Awake() {EnsureMaterial();}
  void EnsureMaterial() {
   if(material!=null)return;
   var shader=Resources.Load<Shader>("Characters/BreathingOrb");
   if(shader==null)throw new System.InvalidOperationException("呼吸球着色器缺失。");
   material=new Material(shader);GetComponent<Renderer>().sharedMaterial=material;
  }
  public void SetAppearance(Color accent,float flow) {EnsureMaterial();material.SetColor("_Accent",accent);material.SetFloat("_Flow",Mathf.Clamp01(flow));}
  void LateUpdate(){if(Camera.main!=null)transform.rotation=Quaternion.LookRotation(transform.position-Camera.main.transform.position);}
  void OnDestroy(){if(material!=null)Destroy(material);}
 }
}
