using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Globalization;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.TextCore.Text;

// Composition math is ported from GMGN StagePresentationModel and
// FoliaSceneDetailModels (Folia-derived concepts, GNU AGPL v3).
// See repository THIRD_PARTY_NOTICES.md; rendering is a new GPU implementation.

namespace GMGN.UnityPlayer
{
    [Serializable] public sealed class LyricPointWord { public string text; public double startsAt, endsAt; }
    [Serializable] public sealed class LyricPointLine
    {
        public string id, text, translation;
        public double startsAt, endsAt;
        public LyricPointWord[] words = Array.Empty<LyricPointWord>();
    }
    // Each descriptor is one font glyph. Compute samples its SDF into points;
    // CPU never scans pixels or updates a point/Transform per frame.
    [StructLayout(LayoutKind.Sequential)] struct LyricGlyphSeed
    {
        public Vector4 rectangle, atlas, timing, color, metadata, transform, transition, motion;
    }
    public sealed class GpuLyricsView : MonoBehaviour
    {
        public string Status { get; private set; } = "Not initialized";
        public int PointCapacity { get; private set; }
        public bool IsGpuReady => compute != null && material != null;
        public bool EnsureGpuReady() => Initialize();
        public string Mode { get; private set; } = "luminous";
        const int MaximumGlyphs = 512;
        readonly List<LyricGlyphSeed> descriptors = new();
        readonly List<(uint value, float start, float end, Color color, int motionIndex)> units = new();
        LyricPointLine[] lines = Array.Empty<LyricPointLine>();
        string session;
        long revision;
        int activeIndex = -2, width, height;
        float scale = 1, clock, bass, vocal, treble;
        FontAsset font;
        ComputeShader compute;
        Material material,backgroundMaterial;
        MaterialPropertyBlock properties,backgroundProperties;
        GraphicsBuffer glyphs, points;
        Texture2DArray atlasPages;
        int kernel;
        bool shown = true;
        bool currentChorus;
        Color primary = new(.9f,.93f,1), accent = new(.12f,.8f,1), secondary = new(.7f,.5f,1);
        string themeSignature;
        LyricVisualTheme theme;
        readonly List<int> groupStarts = new();
        float[] articleY=Array.Empty<float>();
        Vector4 currentTransform, currentTransition;
        int styleCode;
        public bool SupportsMode(string mode) => StyleCode(mode)>=0;
        static int StyleCode(string mode) => mode switch {
            "luminous" or "flowing_line"=>0,"monet_poster" or "poster_rail"=>1,"folding_verse" or "folding"=>2,
            "mindscape" or "depth_stack"=>3,"claddagh" or "orbit_arc"=>4,"cloud_steps"=>5,
            "article" or "editorial_field"=>6,"chorus_chat"=>7,"confession" or "cinematic_split"=>8,
            "pendulum"=>9,"diorama"=>10,_=>-1};
        public void SetTheme(LyricVisualTheme value)
        {
            if (ReferenceEquals(theme,value) && themeSignature != null) return;
            var signature = value == null ? "" : JsonUtility.ToJson(value);
            if (signature == themeSignature) return;
            themeSignature = signature; theme = value;
            primary = ParseColor(value?.primaryColor, new Color(.9f,.93f,1));
            accent = ParseColor(value?.accentColor, new Color(.12f,.8f,1));
            secondary = ParseColor(value?.secondaryColor, new Color(.7f,.5f,1));
            activeIndex = -2;
        }
        static Color ParseColor(string value, Color fallback) => !string.IsNullOrEmpty(value) && ColorUtility.TryParseHtmlString(value, out var result) ? result : fallback;
        public void SetLyrics(string trackSession, long lyricRevision, LyricPointLine[] content, string mode)
        {
            if (session == trackSession && revision == lyricRevision && Mode == mode) return;
            Clear(); // Clear before accepting new content; no previous track survives failures.
            session = trackSession; revision = lyricRevision; Mode = mode;
            lines = content ?? Array.Empty<LyricPointLine>(); activeIndex = -2;
            groupStarts.Clear();
            articleY=new float[lines.Length];var cursor=.08f;
            for(var i=0;i<lines.Length;i++){articleY[i]=cursor;cursor+=.105f+Mathf.Min(Mathf.Max(4,(lines[i].text??"").Replace(" ","").Length),32)*.0024f;}
            for(var i=0;i<lines.Length;i++) if(i==0 || i-groupStarts[groupStarts.Count-1]>=4 || lines[i].startsAt-lines[i-1].startsAt>=5) groupStarts.Add(i);
            if (!SupportsMode(mode)) { Status = "GPU lyric style not migrated: " + mode; Debug.LogWarning(Status, this); }
        }
        public void SetPlayback(double seconds, float low, float mid, float high)
        { clock = (float)seconds; bass = low; vocal = mid; treble = high; }
        public void SetVisible(bool visible) { shown = visible; }
        bool Initialize()
        {
            if (material != null) return true;
            if (!SystemInfo.supportsComputeShaders) { Status = "GPU lyrics require Compute Shader"; return false; }
            font = Resources.Load<FontAsset>("PlayerRegularFont");
            var cs = Resources.Load<ComputeShader>("GpuLyricsUpdate");
            var shader = Resources.Load<Shader>("GpuLyricsGlyphDraw");
            if (font == null || cs == null || shader == null || !shader.isSupported) { Status = "GPU lyric font/shader unavailable"; return false; }
            compute = Instantiate(cs); kernel = compute.FindKernel("UpdateLyrics");
            material = new Material(shader); properties = new MaterialPropertyBlock();backgroundProperties=new MaterialPropertyBlock();
            backgroundMaterial=new Material(shader){renderQueue=material.renderQueue-1};
            return true;
        }
        void LateUpdate()
        {
            if (!shown || !SupportsMode(Mode) || lines.Length == 0 || !Initialize()) return;
            var document = GetComponent<UnityEngine.UIElements.UIDocument>();
            var panelScale = document != null && document.panelSettings != null ? document.panelSettings.scale : 1;
            var index = ActiveLineIndex(clock);
            if (index != activeIndex || width != Screen.width || height != Screen.height || !Mathf.Approximately(panelScale, scale)) {
                activeIndex = index; width = Screen.width; height = Screen.height; scale = panelScale;
                Rebuild();
            }
            if (PointCapacity == 0) return;
            compute.SetInt("_PointCount", PointCapacity);
            compute.SetInt("_GlyphRendering", 1);
            compute.SetFloat("_Clock", clock);
            compute.SetVector("_Audio", new Vector4(bass, vocal, treble, 0));
            compute.SetVector("_Accent", accent);
            compute.SetVector("_Secondary", secondary);
            compute.SetVector("_Primary", primary);
            compute.SetInt("_Chorus",currentChorus?1:0);
            compute.SetFloat("_AnimationClock",Time.unscaledTime);
            compute.SetVector("_Viewport", new Vector4(width/scale,height/scale,0,0));
            compute.Dispatch(kernel, (PointCapacity + 63)/64, 1, 1);
            properties.SetVector("_Viewport", new Vector4(width/scale, height/scale, 0, 0));
            properties.SetVector("_Accent",accent);properties.SetVector("_Secondary",secondary);
            backgroundProperties.SetVector("_Viewport",new Vector4(width/scale,height/scale,0,0));
            backgroundProperties.SetVector("_Accent",accent);backgroundProperties.SetVector("_Secondary",secondary);
            backgroundProperties.SetInt("_DrawLayer",0);properties.SetInt("_DrawLayer",1);
            var parameters = new RenderParams(material) { matProps = properties,
                worldBounds = new Bounds(Vector3.zero, Vector3.one * 100000),
                camera = Camera.main, shadowCastingMode = ShadowCastingMode.Off, receiveShadows = false };
            if(styleCode==7){parameters.material=backgroundMaterial;parameters.matProps=backgroundProperties;Graphics.RenderPrimitives(parameters,MeshTopology.Triangles,6,PointCapacity);parameters.material=material;parameters.matProps=properties;}
            Graphics.RenderPrimitives(parameters, MeshTopology.Triangles, 6, PointCapacity);
        }
        int ActiveLineIndex(float seconds)
        {
            var low = 0; var high = lines.Length;
            while (low < high) {
                var middle = low + (high-low)/2;
                if (lines[middle].startsAt <= seconds) low = middle+1;
                else high = middle;
            }
            return low-1;
        }
        void Rebuild()
        {
            ReleaseBuffers(); descriptors.Clear();
            if (activeIndex < 0) return;
            var line = lines[activeIndex];
            currentChorus=IsChorus(line);
            var logicalWidth = width/scale; var logicalHeight = height/scale;
            styleCode = StyleCode(Mode);
            var availableFraction=styleCode switch{1=>.58f,2=>.68f,6=>.62f,7=>.5f,8=>.76f,9=>.56f,10=>.6f,_=>1};
            var fontSize = TypographySize(line.text,logicalWidth*availableFraction);
            if(styleCode==3)fontSize=38;
            if(styleCode==4||styleCode==5)fontSize=Mathf.Clamp(logicalWidth*.7f/Mathf.Max(1,System.Globalization.StringInfo.ParseCombiningCharacters(line.text??"").Length),styleCode==4?26:25,styleCode==4?72:68);
            currentTransform = new Vector4(logicalWidth*.5f,logicalHeight*.48f,0,1); currentTransition=Vector4.zero;
            if(styleCode==1) {
                var left = Mathf.Max(60,logicalWidth*.075f)+31;
                for(var offset=-2;offset<=2;offset++) {
                    var idx=activeIndex+offset;if(idx<0||idx>=lines.Length)continue;
                    var selected=offset==0;var color=offset<0?secondary:primary;
                    color.a=selected?1:offset<0?.16f+.05f/Mathf.Abs(offset):.34f-(offset-1)*.07f;
                    var contextSize=Mathf.Clamp(fontSize*.34f,17,28);
                    var y=logicalHeight*.48f+(offset<0?-fontSize-24+(offset+1)*(contextSize+14):offset>0?Mathf.Max(15,fontSize*.2f)*2+28+contextSize+(offset-1)*(contextSize+14):0);
                    AddLeftLine(lines[idx],selected?fontSize:contextSize,left+Mathf.Abs(offset)*18+(offset>0?12:0),y,color,selected);
                }
                AddTranslationLeft(line,Mathf.Max(15,fontSize*.2f),left,logicalHeight*.48f+Mathf.Max(15,fontSize*.2f)+10,.54f);
                // The rail is sampled procedurally by the same compute pass, not a CPU point cloud.
                descriptors.Add(new LyricGlyphSeed{rectangle=new Vector4(left-31,logicalHeight*.15f,3,Mathf.Min(520,logicalHeight*.7f)),color=accent,metadata=new Vector4(0,1,-1,0),transform=currentTransform});
            } else if(styleCode==2) {
                var group=0;while(group+1<groupStarts.Count&&groupStarts[group+1]<=activeIndex)group++;
                var start=groupStarts[group];var end=group+1<groupStarts.Count?groupStarts[group+1]:lines.Length;
                var direction=group%2==0?-1f:1f;
                currentTransform=new Vector4(direction<0?logicalWidth*.18f:logicalWidth*.82f,logicalHeight*.48f,0,1);
                currentTransition=new Vector4((float)lines[start].startsAt,.72f,direction,0);
                if(group>0){
                    currentTransition.w=1;
                    for(var i=groupStarts[group-1];i<start;i++)AddLeftLine(lines[i],fontSize*.72f,logicalWidth*.18f,logicalHeight*.48f+(i-groupStarts[group-1]-1.5f)*64,WithAlpha(primary,.5f),false);
                }
                currentTransition.w=0;
                for(var i=start;i<end;i++)AddLeftLine(lines[i],fontSize*.72f,logicalWidth*.18f,logicalHeight*.48f+(i-start-1.5f)*64,WithAlpha(i==activeIndex?accent:primary,i==activeIndex?1:i<activeIndex?.82f:.22f),i==activeIndex);
                AddTranslation(line,16,logicalWidth*.5f,logicalHeight*.48f+(activeIndex-start-1.5f)*64+30,.58f);
            } else if(styleCode>=3) {
                BuildComposition(line,fontSize,logicalWidth,logicalHeight);
            } else {
                var contextSize=Mathf.Clamp(fontSize*.28f,15,24);var translationSize=Mathf.Max(16,fontSize*.22f);
                var hasTranslation=!string.IsNullOrEmpty(line.translation);
                var baseline=logicalHeight*.5f-8+fontSize*.5f-(hasTranslation?translationSize*.5f+11:0);
                AddLine(line,fontSize,logicalWidth*.5f,baseline,primary,true);
                if(activeIndex>0)AddLeftLine(lines[activeIndex-1],contextSize,logicalWidth*.5f-340-42,baseline-fontSize-22,WithAlpha(primary,.18f),false);
                AddTranslation(line,translationSize,logicalWidth*.5f,baseline+translationSize+22,.66f);
                if(activeIndex+1<lines.Length)AddRightLine(lines[activeIndex+1],contextSize,logicalWidth*.5f+340+42,baseline+(hasTranslation?translationSize*2:0)+44+contextSize,WithAlpha(primary,.28f),false);
            }
            if (descriptors.Count == 0) return;
            if (descriptors.Count > MaximumGlyphs) { Status = "GPU lyric glyph limit exceeded"; descriptors.Clear(); return; }
            glyphs = new GraphicsBuffer(GraphicsBuffer.Target.Structured, descriptors.Count, 128);
            points = new GraphicsBuffer(GraphicsBuffer.Target.Structured, descriptors.Count, 48);
            glyphs.SetData(descriptors.ToArray()); PointCapacity = descriptors.Count;
            compute.SetBuffer(kernel,"_Glyphs",glyphs); compute.SetBuffer(kernel,"_Points",points);
            var firstAtlas=font.atlasTextures[0];
            var pageCount=0;while(pageCount<font.atlasTextures.Length&&font.atlasTextures[pageCount]!=null)pageCount++;
            atlasPages=new Texture2DArray(firstAtlas.width,firstAtlas.height,pageCount,firstAtlas.format,false){filterMode=FilterMode.Bilinear,wrapMode=TextureWrapMode.Clamp};
            for(var page=0;page<pageCount;page++){
                var source=font.atlasTextures[page];
                if(source==null||source.width!=firstAtlas.width||source.height!=firstAtlas.height||source.format!=firstAtlas.format){Status="GPU lyric atlas dimensions differ";ReleaseBuffers();return;}
                Graphics.CopyTexture(source,0,0,atlasPages,page,0);
            }
            compute.SetTexture(kernel,"_FontAtlas",atlasPages);
            properties.SetBuffer("_Points",points);
            properties.SetBuffer("_Glyphs",glyphs);properties.SetTexture("_FontAtlas",atlasPages);
            backgroundProperties.SetBuffer("_Points",points);backgroundProperties.SetBuffer("_Glyphs",glyphs);backgroundProperties.SetTexture("_FontAtlas",atlasPages);
            Status = "GPU " + Mode + " lyrics: " + descriptors.Count + " glyphs";
            Debug.Log(Status + "; procedural glyph quads=" + PointCapacity + "; graphics=" + SystemInfo.graphicsDeviceType, this);
        }
        static Color WithAlpha(Color color,float alpha){color.a=alpha;return color;}
        static float TypographySize(string text,float availableWidth){var visible=0;var elements=System.Globalization.StringInfo.GetTextElementEnumerator(text??"");while(elements.MoveNext())if(!string.IsNullOrWhiteSpace((string)elements.Current))visible++;return Mathf.Clamp(availableWidth*.78f/Mathf.Max(visible,6)*.92f,18,112);}
        static ulong StableHash(string value,ulong salt){var hash=14695981039346656037UL^salt;foreach(var b in Encoding.UTF8.GetBytes(value??""))hash=unchecked((hash^b)*1099511628211UL);return hash;}
        static float StableUnit(string id,int index,ulong salt)=>(StableHash((id??"")+"-"+index,salt)%10000)/9999f;
        static string Normalized(string text){var output=new StringBuilder();foreach(var c in (text??"").ToLowerInvariant())if(!char.IsWhiteSpace(c)&&!char.IsPunctuation(c))output.Append(c);return output.ToString();}
        bool IsChorus(LyricPointLine line){var target=Normalized(line.text);if(target.Length<2)return false;var count=0;foreach(var candidate in lines)if(Normalized(candidate.text)==target&&++count>1)return true;return false;}
        void BuildComposition(LyricPointLine line,float size,float w,float h)
        {
            if(styleCode==3 || styleCode==10){
                for(var offset=-1;offset<=1;offset++){
                    var idx=activeIndex+offset;if(idx<0||idx>=lines.Length)continue;
                    var x=w*.5f+offset*(styleCode==3?92:w*.275f);var y=h*.5f+offset*(styleCode==3?96:h*.2f);
                    currentTransform=new Vector4(x,y,offset*(styleCode==3?-.21f:-.62f),offset==0?1:styleCode==3?.86f:.8f);
                    AddLine(lines[idx],offset==0?size:24,x,y,WithAlpha(primary,offset==0?1:offset<0?.3f:.46f),offset==0);
                }
                currentTransform=new Vector4(w*.5f,h*.5f,0,1);AddTranslation(line,18,w*.5f,h*.5f+55,.54f);
                if(styleCode==10)for(var i=0;i<180;i++)descriptors.Add(new LyricGlyphSeed{rectangle=new Vector4(0,0,w,h),metadata=new Vector4(0,10,-3,i),color=i%3==0?accent:i%3==1?secondary:primary});
            }else if(styleCode==9){
                var radius=Mathf.Min(w,h)*.48f;
                for(var offset=-4;offset<=4;offset++){
                    var idx=activeIndex+offset;if(idx<0||idx>=lines.Length)continue;var angle=offset*20.5f*Mathf.Deg2Rad;
                    var x=w*.04f+Mathf.Cos(angle)*radius;var y=h*.5f+Mathf.Sin(angle)*radius;
                    currentTransform=new Vector4(x,y,angle*.16f,offset==0?1.08f:Mathf.Max(.7f,1-Mathf.Abs(offset)*.08f));
                    AddLeftLine(lines[idx],offset==0?size:24,x,y,WithAlpha(offset<0?secondary:primary,Mathf.Max(.12f,1-Mathf.Abs(offset)*.19f)),offset==0);
                }
                currentTransform=new Vector4(w*.04f,h*.5f,0,1);
                descriptors.Add(new LyricGlyphSeed{rectangle=new Vector4(w*.04f,h*.5f,radius,radius),metadata=new Vector4(0,9,-2,0),color=accent});
                AddTranslation(line,18,w*.5f,h*.5f+60,.58f);
            }else if(styleCode==7){
                BuildConversation(line,size,w,h);
            }else if(styleCode==6){
                var cx=activeIndex%2==0?.36f:.62f;var cy=articleY[activeIndex];
                for(var idx=Mathf.Max(0,activeIndex-4);idx<Mathf.Min(lines.Length,activeIndex+5);idx++){
                    if(idx==activeIndex)continue;var dx=(idx%2==0?.36f:.62f)-cx;var dy=articleY[idx]-cy;var distance=Mathf.Abs(dy);
                    AddLine(lines[idx],17+Mathf.Max(0,1-distance*4)*8,w*(.5f+dx*1.45f),h*(.5f+dy*2.25f),WithAlpha(primary,Mathf.Max(.07f,.34f-distance*.72f)),false);
                }
                AddLine(line,size,w*.5f,h*.5f,primary,true);AddTranslation(line,18,w*.5f,h*.5f+50,.58f);
            }else if(styleCode==8){
                var text=line.text??"";var elements=System.Globalization.StringInfo.ParseCombiningCharacters(text);var count=elements.Length<=8?1:elements.Length<=16?2:elements.Length<=26?3:4;var tilted=(int)(StableHash(line.id,71)%(ulong)count);
                for(var i=0;i<count;i++){
                    var first=elements.Length*i/count;var last=elements.Length*(i+1)/count;
                    var start=first<elements.Length?elements[first]:text.Length;var end=last<elements.Length?elements[last]:text.Length;
                    var x=w*.5f+(i%2==0?i:-i)*w*.045f;var y=h*.5f+(i-(count-1)*.5f)*size*1.15f;
                    currentTransform=new Vector4(x,y,i==tilted?-7*Mathf.Deg2Rad:0,1);
                    var segment=new LyricPointLine{text=text.Substring(start,end-start),startsAt=line.startsAt+(line.endsAt-line.startsAt)*i/count,endsAt=line.endsAt};
                    var begin=descriptors.Count;AddLine(segment,i==tilted?size*1.14f:size,x,y,i==tilted?secondary:primary,true);
                    for(var k=begin;k<descriptors.Count;k++){var seed=descriptors[k];seed.metadata.w=(float)segment.startsAt;descriptors[k]=seed;}
                }
                AddTranslation(line,18,w*.5f,h*.5f+count*size*.6f,.58f);
            }else { // Arc and Partita operate on glyph descriptors; GPU animates their points.
                var begin=descriptors.Count;AddLine(line,size,w*.5f,h*.5f,primary,true);var count=descriptors.Count-begin;
                var composition=IsChorus(line)?3:(int)(StableHash(line.id,17)%3);
                for(var i=0;i<count;i++){
                    var seed=descriptors[begin+i];var unit=count==1?.5f:(float)i/(count-1);var x=0f;var y=0f;var angle=0f;var zoom=1f;
                    if(styleCode==4){angle=(unit-.5f)*1.58f;x=Mathf.Sin(angle)*Mathf.Min(430,w*.38f);y=Mathf.Cos(angle)*-92;angle=(unit-.5f)*-.2f;}
                    else if(composition==0){var col=i%3;var rows=Mathf.CeilToInt(count/3f);x=(col-1)*w*.31f;y=((rows==1?.5f:(float)(i/3)/(rows-1))-.5f)*h*.78f+(col-1)*h*.035f;angle=(col-1)*-8*Mathf.Deg2Rad;}
                    else if(composition==1){x=(unit-.5f)*w*.82f;y=(unit-.5f)*h*.72f;zoom=.92f+Mathf.Sin(unit*Mathf.PI)*.14f;angle=(unit-.5f)*-14*Mathf.Deg2Rad;}
                    else if(composition==2){var phase=StableUnit(line.id,i,31)*Mathf.PI*2;var radius=.14f+.28f*Mathf.Sqrt(unit);x=Mathf.Cos(phase)*radius*w;y=Mathf.Sin(phase)*radius*.86f*h;zoom=.9f+StableUnit(line.id,i,47)*.2f;angle=(StableUnit(line.id,i,59)-.5f)*18*Mathf.Deg2Rad;}
                    else {var fan=-.72f+unit*1.44f;x=Mathf.Sin(fan)*w*.44f;y=(-Mathf.Cos(fan)*.3f+.1f)*h;zoom=.96f+Mathf.Sin(unit*Mathf.PI)*.12f;angle=fan*24*Mathf.Deg2Rad;}
                    seed.rectangle.x=w*.5f+x-seed.rectangle.z*.5f;seed.rectangle.y=h*.5f+y-seed.rectangle.w*.5f;
                    seed.transform=new Vector4(w*.5f+x,h*.5f+y,angle,zoom);seed.metadata.w=unit;descriptors[begin+i]=seed;
                }
                currentTransform=new Vector4(w*.5f,h*.5f,0,1);AddTranslation(line,17,w*.5f,styleCode==4?h*.5f+78:h*.84f,.48f);
            }
        }
        float Measure(string text,float size){font.TryAddCharacters(text??"",out _);var result=0f;for(var i=0;i<(text??"").Length;i++){var code=(uint)char.ConvertToUtf32(text,i);if(char.IsHighSurrogate(text[i]))i++;if(font.characterLookupTable.TryGetValue(code,out var character))result+=character.glyph.metrics.horizontalAdvance*size/font.faceInfo.pointSize;}return result;}
        void Bubble(float x,float y,float width,float height,Color stroke,Color fill,bool context){descriptors.Add(new LyricGlyphSeed{rectangle=new Vector4(x,y,width,height),metadata=new Vector4(0,7,-4,context?1:0),color=stroke,transform=fill});}
        void VoiceMarker(float x,float y,float diameter,bool active,int voice){
            descriptors.Add(new LyricGlyphSeed{rectangle=new Vector4(x-diameter*.5f,y-diameter*.5f,diameter,diameter),metadata=new Vector4(0,7,-5,active?1:0),color=active?accent:WithAlpha(secondary,.12f)});
            var size=active?14:11;
            descriptors.Add(new LyricGlyphSeed{rectangle=new Vector4(x-size*.5f,y-size*.5f,size,size),metadata=new Vector4(0,7,-6,voice),color=active?primary:WithAlpha(secondary,.72f)});
        }
        void BuildConversation(LyricPointLine line,float size,float w,float h){
            var translationSize=Mathf.Max(14,size*.19f);var hasTranslation=!string.IsNullOrEmpty(line.translation);
            var textWidth=Measure(line.text,size);var translationWidth=hasTranslation?Measure(line.translation,translationSize):0;
            var bubbleWidth=Mathf.Max(textWidth,translationWidth)+48;var bubbleHeight=size+36+(hasTranslation?translationSize+10:0);
            var left=w*.5f-(bubbleWidth+46)*.5f+46;var top=h*.5f-bubbleHeight*.5f;
            var chorus=IsChorus(line);
            Bubble(left,top,bubbleWidth,bubbleHeight,WithAlpha(chorus?secondary:accent,chorus?.46f:.34f),new Color(0,0,0,.32f),false);
            var previousVoice=(int)(StableHash(activeIndex>0?lines[activeIndex-1].id:line.id+"-previous",11)%3);
            var activeVoice=chorus?3:(int)(StableHash(line.id,23)%3);
            var nextVoice=(int)(StableHash(activeIndex+1<lines.Length?lines[activeIndex+1].id:line.id+"-next",37)%3);if(nextVoice==previousVoice)nextVoice=(nextVoice+1)%3;
            VoiceMarker(left-29,top+bubbleHeight*.5f,34,true,activeVoice);
            AddLeftLine(line,size,left+24,top+18+size,primary,true);
            if(hasTranslation)AddTranslationLeft(line,translationSize,left+24,top+18+size+10+translationSize,.56f);
            var containerWidth=Mathf.Min(860,w*.72f);
            for(var offset=-1;offset<=1;offset+=2){
                var idx=activeIndex+offset;if(idx<0||idx>=lines.Length)continue;var context=lines[idx];var cw=Measure(context.text,18)+32;
                var cx=offset<0?w*.5f+containerWidth*.5f-cw:w*.5f-containerWidth*.5f+36;
                var cy=offset<0?top-18-40:top+bubbleHeight+18;
                Bubble(cx,cy,cw,40,WithAlpha(primary,.08f),WithAlpha(primary,.045f),true);
                VoiceMarker(cx-22.5f,cy+20,27,false,offset<0?previousVoice:nextVoice);
                AddLeftLine(context,18,cx+16,cy+29,WithAlpha(primary,.36f),false);
            }
        }
        void AddTranslation(LyricPointLine line,float size,float x,float y,float alpha) {
            var saved=currentTransform;currentTransform=new Vector4(x,y,0,1);
            if(!string.IsNullOrEmpty(line.translation))AddLine(new LyricPointLine{text=line.translation,startsAt=1,endsAt=-1},size,x,y,WithAlpha(primary,alpha),false);
            currentTransform=saved;
        }
        void AddTranslationLeft(LyricPointLine line,float size,float x,float y,float alpha){if(!string.IsNullOrEmpty(line.translation))AddLeftLine(new LyricPointLine{text=line.translation,startsAt=1,endsAt=-1},size,x,y,WithAlpha(primary,alpha),false);}
        void AddRightLine(LyricPointLine line,float size,float x,float y,Color color,bool animated){var begin=descriptors.Count;AddLine(line,size,x,y,color,animated);if(descriptors.Count==begin)return;var last=descriptors[descriptors.Count-1].rectangle;var shift=x-last.x-last.z;for(var i=begin;i<descriptors.Count;i++){var seed=descriptors[i];seed.rectangle.x+=shift;descriptors[i]=seed;}}
        void AddLeftLine(LyricPointLine line,float size,float x,float y,Color color,bool animated) {
            var begin=descriptors.Count;AddLine(line,size,x,y,color,animated);
            if(descriptors.Count==begin)return;
            var shift=x-descriptors[begin].rectangle.x;
            for(var i=begin;i<descriptors.Count;i++){var seed=descriptors[i];seed.rectangle.x+=shift;descriptors[i]=seed;}
        }
        void AddLine(LyricPointLine line, float size, float centerX, float centerY, Color color, bool animated)
        {
            var text = line.text ?? "";
            if (text.Length == 0) return;
            var added=font.TryAddCharacters(text, out var missing);
            if (!added&&!string.IsNullOrEmpty(missing)) { Status = "Missing lyric glyphs: " + missing; Debug.LogWarning(Status,this); }
            units.Clear();
            var motionIndex=0;
            var words = line.words != null && line.words.Length > 0 ? line.words : new[]{new LyricPointWord{text=text,startsAt=line.startsAt,endsAt=line.endsAt}};
            foreach (var word in words) {
                var value = word.text ?? "";
                var elements=DisplayUnits(value);
                var semantic=animated&&IsChorus(line)?secondary:color;
                if(animated&&theme?.wordColors!=null)foreach(var mapping in theme.wordColors)if(!string.IsNullOrEmpty(mapping.word)&&value.Contains(mapping.word)){semantic=ParseColor(mapping.color,color);break;}
                for(var i=0;i<elements.Count;i++){
                    var token=elements[i];
                    var begins=(float)(word.startsAt+(word.endsAt-word.startsAt)*i/Mathf.Max(1,elements.Count));
                    var ends=(float)(word.startsAt+(word.endsAt-word.startsAt)*(i+1)/Mathf.Max(1,elements.Count));
                    for(var code=0;code<token.Length;code++){var scalar=(uint)char.ConvertToUtf32(token,code);if(char.IsHighSurrogate(token[code]))code++;units.Add((scalar,begins,ends,semantic,motionIndex));}
                    motionIndex++;
                }
            }
            var ratio = size/font.faceInfo.pointSize;
            var advance = 0f;
            foreach (var unit in units) if (font.characterLookupTable.TryGetValue(unit.value,out var character)) advance += character.glyph.metrics.horizontalAdvance*ratio;
            var x = centerX-advance*.5f;
            var atlas = font.atlasTextures[0];
            foreach (var unit in units) {
                if (!font.characterLookupTable.TryGetValue(unit.value,out var character)) continue;
                var glyph = character.glyph; var metrics = glyph.metrics; var rect = glyph.glyphRect;
                atlas=font.atlasTextures[glyph.atlasIndex];
                descriptors.Add(new LyricGlyphSeed {
                    rectangle = new Vector4(x+metrics.horizontalBearingX*ratio,centerY-metrics.horizontalBearingY*ratio,metrics.width*ratio,metrics.height*ratio),
                    atlas = new Vector4((float)rect.x/atlas.width,(float)rect.y/atlas.height,(float)rect.width/atlas.width,(float)rect.height/atlas.height),
                    timing = animated ? new Vector4(unit.start,unit.end,0,0) : new Vector4(1,-1,0,0),
                    color = unit.color, metadata = new Vector4(animated?1:0, styleCode,glyph.atlasIndex,0), transform=currentTransform, transition=currentTransition,
                    motion=animated?new Vector4(-3+StableUnit(line.id,unit.motionIndex,11)*6,-8+StableUnit(line.id,unit.motionIndex,23)*16,(-2.8f+StableUnit(line.id,unit.motionIndex,37)*5.6f)*Mathf.Deg2Rad,.94f+StableUnit(line.id,unit.motionIndex,53)*.1f):new Vector4(0,0,0,1)
                });
                x += metrics.horizontalAdvance*ratio;
            }
        }
        static List<string> DisplayUnits(string text){
            var result=new List<string>();var word=new StringBuilder();var elements=StringInfo.GetTextElementEnumerator(text);
            while(elements.MoveNext()){
                var element=(string)elements.Current;var scalar=char.ConvertToUtf32(element,0);var cjk=scalar>=0x3400&&scalar<=0x4DBF||scalar>=0x4E00&&scalar<=0x9FFF||scalar>=0xF900&&scalar<=0xFAFF||scalar>=0x20000&&scalar<=0x2CEAF;
                if(cjk){if(word.Length>0){result.Add(word.ToString());word.Clear();}result.Add(element);}
                else if(string.IsNullOrWhiteSpace(element)){if(word.Length>0){word.Append(element);result.Add(word.ToString());word.Clear();}else if(result.Count>0)result[result.Count-1]+=element;else word.Append(element);}
                else if(char.IsPunctuation(element,0)){if(word.Length>0)word.Append(element);else if(result.Count>0)result[result.Count-1]+=element;else word.Append(element);}
                else word.Append(element);
            }
            if(word.Length>0)result.Add(word.ToString());return result;
        }
        public void Clear() { ReleaseBuffers(); lines=Array.Empty<LyricPointLine>(); activeIndex=-2; session=null;revision=long.MinValue; }
        void ReleaseBuffers() { glyphs?.Dispose(); points?.Dispose(); glyphs=null;points=null;PointCapacity=0;if(atlasPages!=null)Destroy(atlasPages);atlasPages=null; }
        void OnDestroy() { ReleaseBuffers(); if(material!=null)Destroy(material);if(backgroundMaterial!=null)Destroy(backgroundMaterial);if(compute!=null)Destroy(compute); }
    }
}
