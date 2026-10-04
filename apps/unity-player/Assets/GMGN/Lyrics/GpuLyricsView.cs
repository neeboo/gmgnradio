using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
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
        public Vector4 rectangle, atlas, timing, color, metadata, transform, transition;
    }
    public sealed class GpuLyricsView : MonoBehaviour
    {
        public string Status { get; private set; } = "Not initialized";
        public int PointCapacity { get; private set; }
        public bool IsGpuReady => compute != null && material != null;
        public bool EnsureGpuReady() => Initialize();
        public string Mode { get; private set; } = "luminous";
        const int Grid = 24, PointsPerGlyph = Grid * Grid, MaximumGlyphs = 512;
        readonly List<LyricGlyphSeed> descriptors = new();
        readonly List<(uint value, float start, float end, Color color)> units = new();
        LyricPointLine[] lines = Array.Empty<LyricPointLine>();
        string session;
        long revision;
        int activeIndex = -2, width, height;
        float scale = 1, clock, bass, vocal, treble;
        FontAsset font;
        ComputeShader compute;
        Material material;
        MaterialPropertyBlock properties;
        GraphicsBuffer glyphs, points;
        Texture2DArray atlasPages;
        int kernel;
        bool shown = true;
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
            var shader = Resources.Load<Shader>("GpuLyricsDraw");
            if (font == null || cs == null || shader == null || !shader.isSupported) { Status = "GPU lyric font/shader unavailable"; return false; }
            compute = Instantiate(cs); kernel = compute.FindKernel("UpdateLyrics");
            material = new Material(shader); properties = new MaterialPropertyBlock();
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
            compute.SetFloat("_Clock", clock);
            compute.SetVector("_Audio", new Vector4(bass, vocal, treble, 0));
            compute.SetVector("_Accent", accent);
            compute.SetVector("_Secondary", secondary);
            compute.SetVector("_Viewport", new Vector4(width/scale,height/scale,0,0));
            compute.Dispatch(kernel, (PointCapacity + 63)/64, 1, 1);
            properties.SetVector("_Viewport", new Vector4(width/scale, height/scale, 0, 0));
            var parameters = new RenderParams(material) { matProps = properties,
                worldBounds = new Bounds(Vector3.zero, Vector3.one * 100000),
                camera = Camera.main, shadowCastingMode = ShadowCastingMode.Off, receiveShadows = false };
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
            var logicalWidth = width/scale; var logicalHeight = height/scale;
            var fontSize = Mathf.Clamp(logicalWidth / Mathf.Max(10, (line.text ?? "").Length) * .75f, 28, 68);
            currentTransform = new Vector4(logicalWidth*.5f,logicalHeight*.48f,0,1); currentTransition=Vector4.zero;
            styleCode = StyleCode(Mode);
            if(styleCode==1) {
                var left = Mathf.Max(60,logicalWidth*.075f)+31;
                for(var offset=-2;offset<=2;offset++) {
                    var idx=activeIndex+offset;if(idx<0||idx>=lines.Length)continue;
                    var selected=offset==0;var color=offset<0?secondary:primary;
                    color.a=selected?1:offset<0?.16f+.05f/Mathf.Abs(offset):.34f-(offset-1)*.07f;
                    AddLeftLine(lines[idx],selected?fontSize:Mathf.Clamp(fontSize*.34f,17,28),left+Mathf.Abs(offset)*18+(offset>0?12:0),logicalHeight*.48f+offset*68,color,selected);
                }
                AddTranslation(line,Mathf.Max(15,fontSize*.2f),left+logicalWidth*.28f,logicalHeight*.48f+38,.54f);
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
                AddLine(line,fontSize,logicalWidth*.5f,logicalHeight*.48f,primary,true);
                if(activeIndex>0)AddLine(lines[activeIndex-1],20,logicalWidth*.5f-42,logicalHeight*.48f-90,WithAlpha(primary,.18f),false);
                if(activeIndex+1<lines.Length)AddLine(lines[activeIndex+1],20,logicalWidth*.5f+42,logicalHeight*.48f+90,WithAlpha(primary,.28f),false);
                AddTranslation(line,18,logicalWidth*.5f,logicalHeight*.48f+55,.66f);
            }
            if (descriptors.Count == 0) return;
            if (descriptors.Count > MaximumGlyphs) { Status = "GPU lyric glyph limit exceeded"; descriptors.Clear(); return; }
            glyphs = new GraphicsBuffer(GraphicsBuffer.Target.Structured, descriptors.Count, 112);
            points = new GraphicsBuffer(GraphicsBuffer.Target.Structured, descriptors.Count*PointsPerGlyph, 48);
            glyphs.SetData(descriptors.ToArray()); PointCapacity = descriptors.Count*PointsPerGlyph;
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
            Status = "GPU " + Mode + " lyrics: " + descriptors.Count + " glyphs";
            Debug.Log(Status + "; sampled point capacity=" + PointCapacity + "; graphics=" + SystemInfo.graphicsDeviceType, this);
        }
        static Color WithAlpha(Color color,float alpha){color.a=alpha;return color;}
        static ulong StableHash(string value,ulong salt){var hash=14695981039346656037UL^salt;foreach(var b in Encoding.UTF8.GetBytes(value??""))hash=unchecked((hash^b)*1099511628211UL);return hash;}
        static float StableUnit(string id,int index,ulong salt)=>(StableHash((id??"")+"-"+index,salt)%10000)/9999f;
        bool IsChorus(LyricPointLine line){var count=0;foreach(var candidate in lines)if(candidate.text==line.text&&++count>1)return true;return false;}
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
                for(var offset=-1;offset<=1;offset++){
                    var idx=activeIndex+offset;if(idx<0||idx>=lines.Length)continue;var x=w*(offset==-1?.62f:offset==1?.38f:.5f);var y=h*.48f+offset*95;
                    AddLine(lines[idx],offset==0?size:18,x,y,WithAlpha(primary,offset==0?1:.36f),offset==0);
                    descriptors.Add(new LyricGlyphSeed{rectangle=new Vector4(x-(offset==0?w*.28f:w*.2f),y-(offset==0?size:18)-12,offset==0?w*.56f:w*.4f,offset==0?size+30:48),metadata=new Vector4(0,7,-4,offset),color=WithAlpha(accent,offset==0?.3f:.1f)});
                }
                AddTranslation(line,16,w*.5f,h*.48f+37,.56f);
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
        void AddTranslation(LyricPointLine line,float size,float x,float y,float alpha) {
            if(!string.IsNullOrEmpty(line.translation))AddLine(new LyricPointLine{text=line.translation,startsAt=1,endsAt=-1},size,x,y,WithAlpha(primary,alpha),false);
        }
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
            font.TryAddCharacters(text, out var missing);
            if (!string.IsNullOrEmpty(missing)) { Status = "Missing lyric glyphs: " + missing; Debug.LogWarning(Status,this); }
            units.Clear();
            var words = line.words != null && line.words.Length > 0 ? line.words : new[]{new LyricPointWord{text=text,startsAt=line.startsAt,endsAt=line.endsAt}};
            foreach (var word in words) {
                var value = word.text ?? "";
                var elements=System.Globalization.StringInfo.ParseCombiningCharacters(value);
                var semantic=color;
                if(animated&&theme?.wordColors!=null)foreach(var mapping in theme.wordColors)if(!string.IsNullOrEmpty(mapping.word)&&value.Contains(mapping.word)){semantic=ParseColor(mapping.color,color);break;}
                for(var i=0;i<elements.Length;i++){
                    var start=elements[i];var end=i+1<elements.Length?elements[i+1]:value.Length;
                    var begins=(float)(word.startsAt+(word.endsAt-word.startsAt)*i/Mathf.Max(1,elements.Length));
                    var ends=(float)(word.startsAt+(word.endsAt-word.startsAt)*(i+1)/Mathf.Max(1,elements.Length));
                    for(var code=start;code<end;code++){var scalar=(uint)char.ConvertToUtf32(value,code);if(char.IsHighSurrogate(value[code]))code++;units.Add((scalar,begins,ends,semantic));}
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
                    color = unit.color, metadata = new Vector4(animated?1:0, styleCode,glyph.atlasIndex,0), transform=currentTransform, transition=currentTransition
                });
                x += metrics.horizontalAdvance*ratio;
            }
        }
        public void Clear() { ReleaseBuffers(); lines=Array.Empty<LyricPointLine>(); activeIndex=-2; session=null;revision=long.MinValue; }
        void ReleaseBuffers() { glyphs?.Dispose(); points?.Dispose(); glyphs=null;points=null;PointCapacity=0;if(atlasPages!=null)Destroy(atlasPages);atlasPages=null; }
        void OnDestroy() { ReleaseBuffers(); if(material!=null)Destroy(material);if(compute!=null)Destroy(compute); }
    }
}
