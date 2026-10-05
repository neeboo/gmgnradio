using System;
using System.Collections;
using UnityEngine;
using UnityEngine.Networking;
namespace GMGN.UnityPlayer
{
    // Loads only the real library artwork URL, once per URL change. No fixture
    // image substitutes for missing cover metadata or failed requests.
    public sealed class PointCloudArtworkLoader:MonoBehaviour
    {
        public string Status{get;private set;}="No artwork";
        string activeURL;Coroutine running;UnityWebRequest request;Texture2D texture;
        public void Load(string url){
            if(activeURL==url)return;
            activeURL=url;Cancel();var target=GetComponent<AudioSculpture>();target?.SetArtwork(null);
            if(texture!=null){Destroy(texture);texture=null;}
            if(string.IsNullOrWhiteSpace(url)){Status="No artwork";return;}
            if(!Uri.TryCreate(url,UriKind.Absolute,out var uri)||(uri.Scheme!="https"&&uri.Scheme!="http"&&uri.Scheme!="file")){Status="Artwork URL unavailable";Debug.LogWarning(Status,this);return;}
            running=StartCoroutine(Fetch(url,target));
        }
        IEnumerator Fetch(string url,AudioSculpture target){
            Status="Loading artwork";request=UnityWebRequestTexture.GetTexture(url,true);request.timeout=20;
            yield return request.SendWebRequest();
            if(request.result==UnityWebRequest.Result.Success){texture=DownloadHandlerTexture.GetContent(request);texture.wrapMode=TextureWrapMode.Clamp;texture.filterMode=FilterMode.Bilinear;target?.SetArtwork(texture);Status="Real library artwork loaded";Debug.Log(Status,this);}
            else{Status="Artwork request failed";Debug.LogWarning(Status+": HTTP "+request.responseCode,this);}
            request.Dispose();request=null;running=null;
        }
        void Cancel(){if(request!=null)request.Abort();if(running!=null)StopCoroutine(running);running=null;request?.Dispose();request=null;}
        void OnDestroy(){Cancel();if(texture!=null)Destroy(texture);}
    }
}
