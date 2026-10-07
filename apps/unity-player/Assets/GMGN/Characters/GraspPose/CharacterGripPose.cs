using System;
using System.Collections.Generic;
using UnityEngine;

namespace GMGN.UnityPlayer.Characters
{
    /// Transient finger layer. The authored animation remains the base pose;
    /// only complete finger chains are refined around measured handle geometry.
    public sealed class CharacterGripPose
    {
        public static Quaternion PalmLocalRotation(Transform wrist,Transform index,Transform middle,Transform little,Vector3 referenceUp)
        {
            var forward=(middle.position-wrist.position).normalized;
            var spread=index.position-little.position;
            var normal=Vector3.Cross(forward,spread).normalized;
            if(normal.sqrMagnitude<.9f)throw new InvalidOperationException("Hand palm plane is degenerate");
            var orientation=Vector3.Dot(normal,wrist.up);
            if(Mathf.Abs(orientation)<.15f)orientation=Vector3.Dot(normal,referenceUp);
            if(orientation<0)normal=-normal;
            var right=Vector3.ProjectOnPlane(forward,normal).normalized;
            var front=Vector3.Cross(right,normal).normalized;
            return Quaternion.Inverse(wrist.rotation)*Quaternion.LookRotation(front,normal);
        }
        readonly List<Transform[]> chains = new();
        readonly Dictionary<Transform,Quaternion> original = new();
        Vector3 centre, axis;
        float radius;
        bool active;
        public int ContactCount { get; private set; }
        public float MaximumContactError { get; private set; }
        public readonly List<string> ContactDiagnostics=new();
        public void Add(Transform[] chain) { if(chain!=null && chain.Length>=3 && Array.TrueForAll(chain,t=>t!=null))chains.Add(chain); }
        public void Set(Vector3 point,Vector3 direction,float measuredRadius)
        {
            active=float.IsFinite(measuredRadius)&&measuredRadius>.001f&&measuredRadius<.08f&&direction.sqrMagnitude>.9f;
            centre=point;axis=direction.normalized;radius=measuredRadius;
        }
        public void Clear() { Restore();active=false;ContactCount=0;MaximumContactError=0; }
        public void Restore()
        {
            foreach(var pair in original) if(pair.Key!=null)pair.Key.localRotation=pair.Value;
            original.Clear();
        }
        public void Apply()
        {
            Restore();ContactCount=0;MaximumContactError=0;ContactDiagnostics.Clear();
            if(!active)return;
            foreach(var chain in chains) {
                foreach(var joint in chain)if(!original.ContainsKey(joint))original.Add(joint,joint.localRotation);
                var tip=chain[chain.Length-1];
                var lineCentre=centre+axis*Vector3.Dot(chain[0].position-centre,axis);
                var radial=Vector3.ProjectOnPlane(chain[0].position-lineCentre,axis);
                if(radial.sqrMagnitude<.000001f)continue;
                // Fingers curl onto the shaft's side nearest the index/thumb
                // side of this actual hand. A far-side target behind the palm
                // can demand impossible hyperflexion on small avatar hands.
                var tangent=Vector3.Cross(axis,radial).normalized;
                var indexSide=chains[0][0].position-chains[chains.Count-1][0].position;
                if(Vector3.Dot(tangent,indexSide)<0)tangent=-tangent;
                var target=lineCentre+tangent*(radius+.002f);
                var accumulated=new float[chain.Length-1];
                for(var iteration=0;iteration<18;iteration++) {
                    for(var index=chain.Length-2;index>=0;index--) {
                        var joint=chain[index];
                        var from=Vector3.ProjectOnPlane(tip.position-joint.position,axis);
                        var to=Vector3.ProjectOnPlane(target-joint.position,axis);
                        if(from.sqrMagnitude<.0000001f||to.sqrMagnitude<.0000001f)continue;
                        var delta=Mathf.Clamp(Vector3.SignedAngle(from,to,axis),-12,12);
                        // Anatomical flexion ranges for proximal, intermediate
                        // and distal joints; no bone translation or stretching.
                        var limit=index==0?90f:index==1?110f:80f;
                        var next=Mathf.Clamp(accumulated[index]+delta,-limit,limit);
                        delta=next-accumulated[index];accumulated[index]=next;
                        joint.rotation=Quaternion.AngleAxis(delta,axis)*joint.rotation;
                    }
                    if(Vector3.Distance(tip.position,target)<.003f)break;
                }
                // CCD may cross the cylindrical surface while pursuing its
                // tangential target. Stop the transient flexion at the first
                // real contact instead of leaving a fingertip inside the shaft.
                var radialDistance=Vector3.ProjectOnPlane(tip.position-centre,axis).magnitude;
                if(radialDistance<radius+.002f) {
                    var result=new Quaternion[chain.Length-1];
                    for(var index=0;index<result.Length;index++)result[index]=chain[index].localRotation;
                    var low=0f;var high=1f;
                    for(var step=0;step<24;step++) {
                        var fraction=(low+high)*.5f;
                        for(var index=0;index<result.Length;index++)
                            chain[index].localRotation=Quaternion.Slerp(original[chain[index]],result[index],fraction);
                        if(Vector3.ProjectOnPlane(tip.position-centre,axis).magnitude>radius+.002f)low=fraction;else high=fraction;
                    }
                    for(var index=0;index<result.Length;index++)
                        chain[index].localRotation=Quaternion.Slerp(original[chain[index]],result[index],low);
                }
                var distance=Mathf.Abs(Vector3.ProjectOnPlane(tip.position-centre,axis).magnitude-(radius+.002f));
                MaximumContactError=Mathf.Max(MaximumContactError,distance);
                if(distance<.006f)ContactCount++;
#if UNITY_EDITOR
                ContactDiagnostics.Add($"finger={chain[0].name} error={distance:F5} baseRadius={radial.magnitude:F5} tip={tip.position-lineCentre:F5} target={target-lineCentre:F5} angles={string.Join(",",accumulated)}");
#endif
            }
        }
    }
}
