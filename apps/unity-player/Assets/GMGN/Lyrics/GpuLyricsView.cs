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
    // One descriptor per font glyph; compute animates shared display-unit
    // anchors, the draw shader samples SDF. CPU uploads only on content/layout
    // boundaries, never scans pixels or updates per-glyph Transforms per frame.
    [StructLayout(LayoutKind.Sequential)] struct LyricGlyphSeed
    {
        public Vector4 rectangle, atlas, timing, color, metadata, transform, transition, motion, effects;
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
        readonly Dictionary<FontAsset,int> fontPages=new();
        FontAsset boldFont,mediumFont,semiboldFont,lightFont,blackFont;
        string warmedSession;long warmedRevision=long.MinValue;
        Material material,backgroundMaterial,effectMaterial,blurMaterial,glowCompositeMaterial;
        MaterialPropertyBlock properties,backgroundProperties,effectProperties,glowCompositeProperties;
        RenderTexture glowA,glowB;
        CommandBuffer glowCommands;
        GraphicsBuffer glyphs, points;
        Texture2DArray atlasPages;
        int kernel;
        bool shown = true;
        bool currentChorus;
        bool hasGlow;
        Color primary = new(.9f,.93f,1), accent = new(.12f,.8f,1), secondary = new(.7f,.5f,1);
        string themeSignature;
        LyricVisualTheme theme;
        readonly List<int> groupStarts = new();
        float[] articleY=Array.Empty<float>();
        Vector4 currentTransform, currentTransition, currentEffects;
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
            for(var i=0;i<lines.Length;i++){articleY[i]=cursor;cursor+=.105f+Mathf.Min(VisibleTextLength(lines[i].text),32)*.0024f;}
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
            boldFont=Resources.Load<FontAsset>("PlayerLyricsBoldFont");mediumFont=Resources.Load<FontAsset>("PlayerLyricsMediumFont");semiboldFont=Resources.Load<FontAsset>("PlayerLyricsSemiboldFont");font=boldFont;
            lightFont=Resources.Load<FontAsset>("PlayerLyricsLightFont");blackFont=Resources.Load<FontAsset>("PlayerLyricsBlackFont");
            var cs = Resources.Load<ComputeShader>("GpuLyricsUpdate");
            var shader = Resources.Load<Shader>("GpuLyricsGlyphDraw");
            var blurShader=Resources.Load<Shader>("GpuLyricsBlur");var compositeShader=Resources.Load<Shader>("GpuLyricsGlowComposite");
            if (font == null || mediumFont==null || semiboldFont==null || lightFont==null || blackFont==null || cs == null || shader == null || !shader.isSupported || blurShader==null || compositeShader==null || !blurShader.isSupported || !compositeShader.isSupported) { Status = "GPU lyric weighted font/shader unavailable"; return false; }
            compute = Instantiate(cs); kernel = compute.FindKernel("UpdateLyrics");
            material = new Material(shader); properties = new MaterialPropertyBlock();backgroundProperties=new MaterialPropertyBlock();effectProperties=new MaterialPropertyBlock();
            backgroundMaterial=new Material(shader){renderQueue=material.renderQueue-2};effectMaterial=new Material(shader){renderQueue=material.renderQueue-1};
            blurMaterial=new Material(blurShader);glowCompositeMaterial=new Material(compositeShader){renderQueue=material.renderQueue-1};glowCompositeProperties=new MaterialPropertyBlock();
            glowCommands=new CommandBuffer{name="GMGN lyrics separable Gaussian glow"};
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
            properties.SetVector("_Primary",primary);
            properties.SetFloat("_Clock",clock);properties.SetInt("_Chorus",currentChorus?1:0);
            effectProperties.SetVector("_Viewport",new Vector4(width/scale,height/scale,0,0));effectProperties.SetVector("_Accent",accent);effectProperties.SetVector("_Secondary",secondary);
            effectProperties.SetFloat("_Clock",clock);effectProperties.SetInt("_Chorus",currentChorus?1:0);effectProperties.SetInt("_DrawLayer",2);effectProperties.SetInt("_EffectTarget",1);
            properties.SetInt("_EffectTarget",0);backgroundProperties.SetInt("_EffectTarget",0);
            backgroundProperties.SetVector("_Viewport",new Vector4(width/scale,height/scale,0,0));
            backgroundProperties.SetVector("_Accent",accent);backgroundProperties.SetVector("_Secondary",secondary);
            backgroundProperties.SetVector("_Primary",primary);effectProperties.SetVector("_Primary",primary);
            backgroundProperties.SetInt("_DrawLayer",0);properties.SetInt("_DrawLayer",1);
            var parameters = new RenderParams(material) { matProps = properties,
                worldBounds = new Bounds(Vector3.zero, Vector3.one * 100000),
                camera = Camera.main, shadowCastingMode = ShadowCastingMode.Off, receiveShadows = false };
            if(styleCode==7||styleCode==10){parameters.material=backgroundMaterial;parameters.matProps=backgroundProperties;Graphics.RenderPrimitives(parameters,MeshTopology.Triangles,6,PointCapacity);parameters.material=material;parameters.matProps=properties;}
            if(RenderGlow()){
                parameters.material=glowCompositeMaterial;parameters.matProps=glowCompositeProperties;
                Graphics.RenderPrimitives(parameters,MeshTopology.Triangles,6,1);
            }
            parameters.material=material;parameters.matProps=properties;
            Graphics.RenderPrimitives(parameters, MeshTopology.Triangles, 6, PointCapacity);
        }
        bool RenderGlow(){
            if(!hasGlow)return false;
            var targetWidth=Mathf.Max(1,Screen.width/4);var targetHeight=Mathf.Max(1,Screen.height/4);
            if(glowA==null||glowA.width!=targetWidth||glowA.height!=targetHeight){
                ReleaseGlowTargets();
                var format=SystemInfo.SupportsRenderTextureFormat(RenderTextureFormat.ARGBHalf)?RenderTextureFormat.ARGBHalf:RenderTextureFormat.ARGB32;
                glowA=new RenderTexture(targetWidth,targetHeight,0,format,RenderTextureReadWrite.Linear){name="GMGN lyrics glow horizontal",filterMode=FilterMode.Bilinear,wrapMode=TextureWrapMode.Clamp};
                glowB=new RenderTexture(targetWidth,targetHeight,0,format,RenderTextureReadWrite.Linear){name="GMGN lyrics glow vertical",filterMode=FilterMode.Bilinear,wrapMode=TextureWrapMode.Clamp};
                if(!glowA.Create()||!glowB.Create()){Status="GPU lyric glow render target unavailable";ReleaseGlowTargets();Debug.LogError(Status,this);return false;}
                Debug.Log($"GPU lyric glow targets: {targetWidth}x{targetHeight} {format}; no CPU readback",this);
            }
            blurMaterial.SetFloat("_Radius",(styleCode==1?22:18)*scale*.25f);
            glowCommands.Clear();glowCommands.SetRenderTarget(glowA);glowCommands.SetViewport(new Rect(0,0,targetWidth,targetHeight));
            glowCommands.ClearRenderTarget(false,true,Color.clear);
            glowCommands.DrawProcedural(Matrix4x4.identity,effectMaterial,0,MeshTopology.Triangles,6,PointCapacity,effectProperties);
            glowCommands.Blit(glowA,glowB,blurMaterial,0);glowCommands.Blit(glowB,glowA,blurMaterial,1);
            Graphics.ExecuteCommandBuffer(glowCommands);
            glowCompositeProperties.SetTexture("_GlowTexture",glowA);
            glowCompositeProperties.SetVector("_Viewport",new Vector4(width/scale,height/scale,0,0));
            return true;
        }
        void ReleaseGlowTargets(){if(glowA!=null){glowA.Release();Destroy(glowA);glowA=null;}if(glowB!=null){glowB.Release();Destroy(glowB);glowB=null;}}
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
            WarmFonts();font=boldFont;
            currentChorus=IsChorus(line);
            var logicalWidth = width/scale; var logicalHeight = height/scale;
            styleCode = StyleCode(Mode);
            var availableFraction=styleCode switch{1=>.58f,2=>.68f,6=>.62f,7=>.5f,8=>.76f,9=>.56f,10=>.6f,_=>1};
            var fontSize = TypographySize(line.text,logicalWidth*availableFraction);
            if(styleCode==3)fontSize=38;
            if(styleCode==4||styleCode==5)fontSize=Mathf.Clamp(logicalWidth*.7f/Mathf.Max(1,System.Globalization.StringInfo.ParseCombiningCharacters(line.text??"").Length),styleCode==4?26:25,styleCode==4?72:68);
            currentTransform = new Vector4(logicalWidth*.5f,logicalHeight*.48f,0,1); currentTransition=Vector4.zero;currentEffects=Vector4.zero;
            if(styleCode==1) {
                var left = Mathf.Max(60,logicalWidth*.075f)+31;
                var translationSize=Mathf.Max(15,fontSize*.2f);
                var translationRows=TranslationRows(line,translationSize,logicalWidth*.62f);
                var translationHeight=translationRows.Length*(translationSize*1.2f);
                for(var offset=-2;offset<=2;offset++) {
                    var idx=activeIndex+offset;if(idx<0||idx>=lines.Length)continue;
                    var selected=offset==0;var color=offset<0?secondary:primary;
                    color.a=selected?1:offset<0?.16f+.05f/Mathf.Abs(offset):.34f-(offset-1)*.07f;
                    var contextSize=Mathf.Clamp(fontSize*.34f,17,28);
                    var y=logicalHeight*.48f+(offset<0?-fontSize-24+(offset+1)*(contextSize+14):offset>0?translationHeight+28+contextSize+(offset-1)*(contextSize+14):0);
                    font=selected?boldFont:offset<0?mediumFont:semiboldFont;
                    currentEffects=selected?new Vector4(0,22,.18f,0):new Vector4(Mathf.Abs(offset)*.34f,0,0,0);
                    AddLeftLine(lines[idx],selected?fontSize:contextSize,left+Mathf.Abs(offset)*18+(offset>0?12:0),y,color,selected);
                }
                AddTranslationRows(translationRows,translationSize,left,logicalHeight*.48f+translationSize+10,.54f,true);
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
                for(var i=start;i<end;i++){font=i==activeIndex?blackFont:boldFont;AddLeftLine(lines[i],fontSize*.72f,logicalWidth*.18f,logicalHeight*.48f+(i-start-1.5f)*64,WithAlpha(i==activeIndex?accent:primary,i==activeIndex?1:i<activeIndex?.82f:.22f),i==activeIndex);}
                AddTranslation(line,16,logicalWidth*.5f,logicalHeight*.48f+(activeIndex-start-1.5f)*64+30,.58f);
            } else if(styleCode>=3) {
                BuildComposition(line,fontSize,logicalWidth,logicalHeight);
            } else {
                var contextSize=Mathf.Clamp(fontSize*.28f,15,24);var translationSize=Mathf.Max(16,fontSize*.22f);
                var hasTranslation=!string.IsNullOrEmpty(line.translation);
                var translationRows=TranslationRows(line,translationSize,Mathf.Min(720,logicalWidth-48));
                var translationHeight=translationRows.Length*translationSize*1.2f;
                var baseline=logicalHeight*.5f-8+fontSize*.5f-(hasTranslation?translationHeight*.5f+11:0);
                currentEffects=new Vector4(0,currentChorus?22:14,currentChorus?.3f:.22f,3);
                AddLine(line,fontSize,logicalWidth*.5f,baseline,primary,true);
                var contextLayout=FlowContextLayout(logicalWidth);
                if(activeIndex>0)AddFlowContext(lines[activeIndex-1],contextSize,contextLayout.x,contextLayout.y,baseline-fontSize-22,WithAlpha(primary,.18f),false);
                AddTranslationRows(translationRows,translationSize,logicalWidth*.5f,baseline+translationSize+22,.66f,false);
                if(activeIndex+1<lines.Length)AddFlowContext(lines[activeIndex+1],contextSize,contextLayout.x,contextLayout.z,baseline+translationHeight+44+contextSize,WithAlpha(primary,.28f),true);
            }
            if (descriptors.Count == 0) return;
            foreach(var seed in descriptors)if((seed.effects.y>0&&seed.effects.z>0&&seed.metadata.z>=0)||(seed.metadata.x!=0&&UsesFlowingGlyphStyle(styleCode))){hasGlow=true;break;}
            if (descriptors.Count > MaximumGlyphs) { Status = "GPU lyric glyph limit exceeded"; descriptors.Clear(); return; }
            glyphs = new GraphicsBuffer(GraphicsBuffer.Target.Structured, descriptors.Count, 144);
            points = new GraphicsBuffer(GraphicsBuffer.Target.Structured, descriptors.Count, 48);
            glyphs.SetData(descriptors.ToArray()); PointCapacity = descriptors.Count;
            compute.SetBuffer(kernel,"_Glyphs",glyphs); compute.SetBuffer(kernel,"_Points",points);
            var firstAtlas=boldFont.atlasTextures[0];
            var pageCount=0;foreach(var entry in fontPages)pageCount+=AtlasCount(entry.Key);
            atlasPages=new Texture2DArray(firstAtlas.width,firstAtlas.height,pageCount,firstAtlas.format,false){filterMode=FilterMode.Bilinear,wrapMode=TextureWrapMode.Clamp};
            foreach(var entry in fontPages)for(var page=0;page<AtlasCount(entry.Key);page++){
                var source=entry.Key.atlasTextures[page];
                if(source==null||source.width!=firstAtlas.width||source.height!=firstAtlas.height||source.format!=firstAtlas.format){Status="GPU lyric atlas dimensions differ";ReleaseBuffers();return;}
                Graphics.CopyTexture(source,0,0,atlasPages,entry.Value+page,0);
            }
            compute.SetTexture(kernel,"_FontAtlas",atlasPages);
            properties.SetBuffer("_Points",points);
            properties.SetBuffer("_Glyphs",glyphs);properties.SetTexture("_FontAtlas",atlasPages);
            backgroundProperties.SetBuffer("_Points",points);backgroundProperties.SetBuffer("_Glyphs",glyphs);backgroundProperties.SetTexture("_FontAtlas",atlasPages);
            effectProperties.SetBuffer("_Points",points);effectProperties.SetBuffer("_Glyphs",glyphs);effectProperties.SetTexture("_FontAtlas",atlasPages);
            Status = "GPU " + Mode + " lyrics: " + descriptors.Count + " glyphs";
            Debug.Log(Status + "; procedural glyph quads=" + PointCapacity + "; graphics=" + SystemInfo.graphicsDeviceType, this);
        }
        static int AtlasCount(FontAsset asset){var count=0;while(count<asset.atlasTextures.Length&&asset.atlasTextures[count]!=null)count++;return count;}
        static bool UsesFlowingGlyphStyle(int style)=>style==0||style==1||style==4||style==5||style==6||style==7||style==9||style==10;
        void WarmFonts(){
            if(warmedSession!=session||warmedRevision!=revision){
                var text=new StringBuilder();foreach(var lyric in lines){text.Append(lyric.text);text.Append(lyric.translation);if(lyric.words!=null)foreach(var word in lyric.words)text.Append(word.text);}text.Append('…');
                foreach(var asset in new[]{boldFont,mediumFont,semiboldFont,lightFont,blackFont})if(!asset.TryAddCharacters(text.ToString(),out var missing)&&!string.IsNullOrEmpty(missing))Debug.LogWarning($"GPU lyrics missing {asset.name} glyphs: {missing}",this);
                warmedSession=session;warmedRevision=revision;
            }
            fontPages.Clear();var offset=0;foreach(var asset in new[]{boldFont,mediumFont,semiboldFont,lightFont,blackFont}){fontPages.Add(asset,offset);offset+=AtlasCount(asset);}
        }
        static Color WithAlpha(Color color,float alpha){color.a=alpha;return color;}
        static float TypographySize(string text,float availableWidth){var visible=0;var elements=System.Globalization.StringInfo.GetTextElementEnumerator(text??"");while(elements.MoveNext())if(!string.IsNullOrWhiteSpace((string)elements.Current))visible++;return Mathf.Clamp(availableWidth*.78f/Mathf.Max(visible,6)*.92f,18,112);}
        static ulong StableHash(string value,ulong salt){var hash=14695981039346656037UL^salt;foreach(var b in Encoding.UTF8.GetBytes(value??""))hash=unchecked((hash^b)*1099511628211UL);return hash;}
        static float StableUnit(string id,int index,ulong salt)=>(StableHash((id??"")+"-"+index,salt)%10000)/9999f;
        static string Normalized(string text){var output=new StringBuilder();foreach(var c in (text??"").ToLowerInvariant())if(!char.IsWhiteSpace(c)&&!char.IsPunctuation(c))output.Append(c);return output.ToString();}
        bool IsChorus(LyricPointLine line){var target=Normalized(line.text);if(target.Length<2)return false;var count=0;foreach(var candidate in lines)if(Normalized(candidate.text)==target&&++count>1)return true;return false;}
        void BuildComposition(LyricPointLine line,float size,float w,float h)
        {
            if(styleCode==10){BuildDiorama(line,size,w,h);
            }else if(styleCode==3){
                for(var offset=-1;offset<=1;offset++){
                    var idx=activeIndex+offset;if(idx<0||idx>=lines.Length)continue;
                    var x=w*.5f+offset*(styleCode==3?92:w*.275f);var y=h*.5f+offset*(styleCode==3?96:h*.2f);
                    currentTransform=new Vector4(x,y,offset*(styleCode==3?-.21f:-.62f),offset==0?1:styleCode==3?.86f:.8f);
                    font=offset==0?boldFont:semiboldFont;
                    currentEffects=Vector4.zero;
                    AddLine(lines[idx],offset==0?size:24,x,y,WithAlpha(primary,offset==0?1:offset<0?.3f:.46f),offset==0);
                }
                currentTransform=new Vector4(w*.5f,h*.5f,0,1);AddTranslation(line,18,w*.5f,h*.5f+55,.54f);
            }else if(styleCode==9){
                var radius=Mathf.Min(w,h)*.48f;
                for(var offset=-4;offset<=4;offset++){
                    var idx=activeIndex+offset;if(idx<0||idx>=lines.Length)continue;var angle=offset*20.5f*Mathf.Deg2Rad;
                    var x=w*.04f+Mathf.Cos(angle)*radius;var y=h*.5f+Mathf.Sin(angle)*radius;
                    currentTransform=new Vector4(x,y,angle*.16f,offset==0?1.08f:Mathf.Max(.7f,1-Mathf.Abs(offset)*.08f));
                    font=offset==0?boldFont:semiboldFont;
                    currentEffects=Vector4.zero;
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
                    AddArticleContext(lines[idx],idx%2==0,w*(.5f+dx*1.45f),h*(.5f+dy*2.25f),17+Mathf.Max(0,1-distance*4)*8,w,WithAlpha(primary,Mathf.Max(.07f,.34f-distance*.72f)),distance);
                }
                font=boldFont;currentEffects=Vector4.zero;AddLine(line,size,w*.5f,h*.5f,primary,true);AddTranslation(line,18,w*.5f,h*.5f+50,.58f);
            }else if(styleCode==8){
                var text=line.text??"";var elements=System.Globalization.StringInfo.ParseCombiningCharacters(text);var count=elements.Length<=8?1:elements.Length<=16?2:elements.Length<=26?3:4;var tilted=(int)(StableHash(line.id,71)%(ulong)count);
                for(var i=0;i<count;i++){
                    var first=elements.Length*i/count;var last=elements.Length*(i+1)/count;
                    var start=first<elements.Length?elements[first]:text.Length;var end=last<elements.Length?elements[last]:text.Length;
                    var x=w*.5f+(i%2==0?i:-i)*w*.045f;var y=h*.5f+(i-(count-1)*.5f)*size*1.15f;
                    currentTransform=new Vector4(x,y,i==tilted?-7*Mathf.Deg2Rad:0,1);
                    font=i==tilted?lightFont:boldFont;
                    currentEffects=i==tilted?new Vector4(0,18,.32f,0):new Vector4(0,0,0,5);
                    currentTransition.w=i==tilted?1:0;
                    var segment=new LyricPointLine{text=text.Substring(start,end-start),startsAt=line.startsAt+(line.endsAt-line.startsAt)*i/count,endsAt=line.endsAt};
                    var begin=descriptors.Count;AddLine(segment,i==tilted?size*1.14f:size,x,y,i==tilted?secondary:primary,true);
                    for(var k=begin;k<descriptors.Count;k++){var seed=descriptors[k];seed.metadata.w=(float)segment.startsAt;descriptors[k]=seed;}
                }
                AddTranslation(line,18,w*.5f,h*.5f+count*size*.6f,.58f);
            }else { // Position display units as groups, preserving each word's glyph offsets.
                font=boldFont;var begin=descriptors.Count;AddLine(line,size,w*.5f,h*.5f,primary,true);
                var groups=new SortedDictionary<int,List<int>>();
                for(var i=begin;i<descriptors.Count;i++){var key=(int)descriptors[i].metadata.w;if(!groups.TryGetValue(key,out var members)){members=new List<int>();groups.Add(key,members);}members.Add(i);}
                var count=groups.Count;var groupIndex=0;
                var composition=IsChorus(line)?3:(int)(StableHash(line.id,17)%3);
                foreach(var group in groups){var i=groupIndex++;
                    var unit=count==1?.5f:(float)i/(count-1);var x=0f;var y=0f;var angle=0f;var zoom=1f;
                    if(styleCode==4){angle=(unit-.5f)*1.58f;x=Mathf.Sin(angle)*Mathf.Min(430,w*.38f);y=Mathf.Cos(angle)*-92;angle=(unit-.5f)*-.2f;}
                    else if(composition==0){var col=i%3;var rows=Mathf.CeilToInt(count/3f);x=(col-1)*w*.31f;y=((rows==1?.5f:(float)(i/3)/(rows-1))-.5f)*h*.78f+(col-1)*h*.035f;angle=(col-1)*-8*Mathf.Deg2Rad;}
                    else if(composition==1){x=(unit-.5f)*w*.82f;y=(unit-.5f)*h*.72f;zoom=.92f+Mathf.Sin(unit*Mathf.PI)*.14f;angle=(unit-.5f)*-14*Mathf.Deg2Rad;}
                    else if(composition==2){var phase=StableUnit(line.id,i,31)*Mathf.PI*2;var radius=.14f+.28f*Mathf.Sqrt(unit);x=Mathf.Cos(phase)*radius*w;y=Mathf.Sin(phase)*radius*.86f*h;zoom=.9f+StableUnit(line.id,i,47)*.2f;angle=(StableUnit(line.id,i,59)-.5f)*18*Mathf.Deg2Rad;}
                    else {var fan=-.72f+unit*1.44f;x=Mathf.Sin(fan)*w*.44f;y=(-Mathf.Cos(fan)*.3f+.1f)*h;zoom=.96f+Mathf.Sin(unit*Mathf.PI)*.12f;angle=fan*24*Mathf.Deg2Rad;}
                    PositionDisplayUnit(group.Value,new Vector4(w*.5f+x,h*.5f+y,angle,zoom),unit);
                }
                currentTransform=new Vector4(w*.5f,h*.5f,0,1);AddTranslation(line,17,w*.5f,styleCode==4?h*.5f+78:h*.84f,.48f);
            }
        }
        static int VisibleTextLength(string text){var count=0;var elements=StringInfo.GetTextElementEnumerator(text??"");while(elements.MoveNext())if(!string.IsNullOrWhiteSpace(elements.GetTextElement()))count++;return Mathf.Max(4,count);}
        static Vector3 ArticleBlockFrame(float viewport,float projectedCenter,int textLength){
            var frame=Mathf.Min(viewport*Mathf.Min(Mathf.Clamp(textLength/28f,.34f,.68f),.42f),Mathf.Max(1,viewport-48));
            var center=Mathf.Clamp(projectedCenter,24+frame*.5f,viewport-24-frame*.5f);
            return new Vector3(frame,center-frame*.5f,center+frame*.5f);
        }
        void AddArticleContext(LyricPointLine line,bool leading,float x,float y,float size,float viewport,Color color,float distance){
            font=semiboldFont;currentEffects=new Vector4(Mathf.Min(distance*3.2f,2.2f),0,0,0);
            var frame=ArticleBlockFrame(viewport,x,VisibleTextLength(line.text));
            var rows=WrapLines(line.text,frame.x,text=>Measure(text,size),3);var top=y-rows.Length*size*1.2f*.5f;
            var first=descriptors.Count;
            for(var i=0;i<rows.Length;i++){
                var row=new LyricPointLine{text=rows[i],startsAt=1,endsAt=-1};
                if(leading)AddLeftLine(row,size,frame.y,top+size+i*size*1.2f,color,false);
                else AddRightLine(row,size,frame.z,top+size+i*size*1.2f,color,false);
            }
            if(descriptors.Count>first){
                var bounds=GlyphRangeBounds(first);
                if(bounds.x<24-.01f||bounds.y>viewport-24+.01f)Debug.LogError($"GPU article context exceeds viewport: logical={viewport} frame={frame} bounds={bounds}",this);
                Debug.Log($"GPU article context {(leading?"leading":"trailing")}: logical={viewport} frame=[{frame.y:F2},{frame.z:F2}] actual=[{bounds.x:F2},{bounds.y:F2}] rows={rows.Length}",this);
            }
        }
        void PositionDisplayUnit(List<int> members,Vector4 placement,float phase){
            var originalCenter=descriptors[members[0]].timing;
            foreach(var index in members){var seed=descriptors[index];seed.rectangle.x+=placement.x-originalCenter.z;seed.rectangle.y+=placement.y-originalCenter.w;seed.transform=placement;seed.timing.z=placement.x;seed.timing.w=placement.y;seed.metadata.w=phase;descriptors[index]=seed;}
        }
        void DioramaPanel(float x,float y,float width,float height,float angle,float zoom,bool context){
            descriptors.Add(new LyricGlyphSeed{rectangle=new Vector4(x-width*.5f,y-height*.5f,width,height),metadata=new Vector4(0,10,-7,context?1:0),transform=new Vector4(x,y,angle,zoom),effects=context?new Vector4(1,1,1,.025f):new Vector4(0,0,0,.26f),motion=new Vector4(context?24:28,context?.8f:1,0,0),color=context?new Color(1,1,1,.07f):WithAlpha(accent,.5f)});
        }
        void BuildDiorama(LyricPointLine line,float size,float w,float h){
            for(var offset=-1;offset<=1;offset+=2){
                var index=activeIndex+offset;if(index<0||index>=lines.Length)continue;
                font=semiboldFont;var panelWidth=Mathf.Min(520,w*.46f);
                var rows=WrapTwoLines(lines[index].text,panelWidth,text=>Measure(text,24));
                var panelHeight=rows.Length*24*1.2f+44;var x=w*(offset<0?.23f:.78f);var y=h*(offset<0?.3f:.7f);
                var angle=(offset<0?34:-38)*Mathf.Deg2Rad;var zoom=offset<0?.76f:.82f;
                DioramaPanel(x,y,panelWidth,panelHeight,angle,zoom,true);
                currentTransform=new Vector4(x,y,angle,zoom);currentEffects=Vector4.zero;
                AddTranslationRows(rows,24,x,y-panelHeight*.5f+22+24,offset<0?.2f:.28f,false,semiboldFont);
            }
            font=boldFont;var translationSize=Mathf.Max(15,size*.18f);var translated=TranslationRows(line,translationSize,w*.6f);
            var panelWidthMain=Measure(line.text,size)+68;var panelHeightMain=size+56+(translated.Length>0?14+translated.Length*translationSize*1.2f:0);
            font=mediumFont;foreach(var row in translated)panelWidthMain=Mathf.Max(panelWidthMain,Measure(row,translationSize)+68);font=boldFont;
            DioramaPanel(w*.5f,h*.5f,panelWidthMain,panelHeightMain,0,1,false);
            currentTransform=new Vector4(w*.5f,h*.5f,0,1);currentEffects=new Vector4(0,26,.35f,0);
            var top=h*.5f-panelHeightMain*.5f;AddLine(line,size,w*.5f,top+28+size,primary,true);
            AddTranslationRows(translated,translationSize,w*.5f,top+28+size+14+translationSize,.54f,false);
            for(var i=0;i<180;i++)descriptors.Add(new LyricGlyphSeed{rectangle=new Vector4(0,0,w,h),metadata=new Vector4(0,10,-3,i),color=i%3==0?accent:i%3==1?secondary:primary});
        }
        float Measure(string text,float size){font.TryAddCharacters(text??"",out _);var result=0f;for(var i=0;i<(text??"").Length;i++){var code=(uint)char.ConvertToUtf32(text,i);if(char.IsHighSurrogate(text[i]))i++;if(font.characterLookupTable.TryGetValue(code,out var character))result+=character.glyph.metrics.horizontalAdvance*size/font.faceInfo.pointSize;}return result;}
        void Bubble(float x,float y,float width,float height,Color stroke,Color fill,bool context){descriptors.Add(new LyricGlyphSeed{rectangle=new Vector4(x,y,width,height),metadata=new Vector4(0,7,-4,context?1:0),color=stroke,transform=fill});}
        void VoiceMarker(float x,float y,float diameter,bool active,int voice){
            descriptors.Add(new LyricGlyphSeed{rectangle=new Vector4(x-diameter*.5f,y-diameter*.5f,diameter,diameter),metadata=new Vector4(0,7,-5,active?1:0),color=active?accent:WithAlpha(secondary,.12f)});
            var size=active?14:11;
            descriptors.Add(new LyricGlyphSeed{rectangle=new Vector4(x-size*.5f,y-size*.5f,size,size),metadata=new Vector4(0,7,-6,voice),color=active?primary:WithAlpha(secondary,.72f)});
        }
        void BuildConversation(LyricPointLine line,float size,float w,float h){
            font=boldFont;
            var translationSize=Mathf.Max(14,size*.19f);var hasTranslation=!string.IsNullOrEmpty(line.translation);
            var translationRows=TranslationRows(line,translationSize,Mathf.Max(1,Mathf.Min(860,w*.72f)-94));
            var textWidth=Measure(line.text,size)+Mathf.Max(0,DisplayUnits(line.text??"").Count-1)*size*.012f;
            font=mediumFont;var translationWidth=0f;foreach(var row in translationRows)translationWidth=Mathf.Max(translationWidth,Measure(row,translationSize));font=boldFont;
            var bubbleWidth=Mathf.Max(textWidth,translationWidth)+48;var bubbleHeight=size+36+(hasTranslation?translationRows.Length*translationSize*1.2f+10:0);
            var left=w*.5f-(bubbleWidth+46)*.5f+46;var top=h*.5f-bubbleHeight*.5f;
            var chorus=IsChorus(line);
            Bubble(left,top,bubbleWidth,bubbleHeight,WithAlpha(chorus?secondary:accent,chorus?.46f:.34f),new Color(0,0,0,.32f),false);
            var previousVoice=(int)(StableHash(activeIndex>0?lines[activeIndex-1].id:line.id+"-previous",11)%3);
            var activeVoice=chorus?3:(int)(StableHash(line.id,23)%3);
            var nextVoice=(int)(StableHash(activeIndex+1<lines.Length?lines[activeIndex+1].id:line.id+"-next",37)%3);if(nextVoice==previousVoice)nextVoice=(nextVoice+1)%3;
            VoiceMarker(left-29,top+bubbleHeight*.5f,34,true,activeVoice);
            currentEffects=new Vector4(0,chorus?22:14,chorus?.3f:.22f,0);
            AddLeftLine(line,size,left+24,top+18+size,primary,true);
            AddTranslationRows(translationRows,translationSize,left+24,top+18+size+10+translationSize,.56f,true);
            var containerWidth=Mathf.Min(860,w*.72f);
            for(var offset=-1;offset<=1;offset+=2){
                font=mediumFont;
                var idx=activeIndex+offset;if(idx<0||idx>=lines.Length)continue;var context=lines[idx];var cw=Measure(context.text,18)+32;
                var cx=offset<0?w*.5f+containerWidth*.5f-cw:w*.5f-containerWidth*.5f+36;
                var cy=offset<0?top-18-40:top+bubbleHeight+18;
                Bubble(cx,cy,cw,40,WithAlpha(primary,.08f),WithAlpha(primary,.045f),true);
                VoiceMarker(cx-22.5f,cy+20,27,false,offset<0?previousVoice:nextVoice);
                font=mediumFont;currentEffects=Vector4.zero;AddLeftLine(context,18,cx+16,cy+29,WithAlpha(primary,.36f),false);
            }
        }
        FontAsset TranslationFont=>styleCode==2||styleCode==9?semiboldFont:mediumFont;
        string[] TranslationRows(LyricPointLine line,float size,float availableWidth){var saved=font;font=TranslationFont;var rows=WrapTwoLines(line.translation,Mathf.Max(1,availableWidth),text=>Measure(text,size));font=saved;return rows;}
        // Break Latin at word boundaries, CJK at grapheme boundaries. Explicit
        // newlines count toward Swift's two-line limit; overflow is ellipsized.
        static string[] WrapTwoLines(string text,float availableWidth,Func<string,float> measure)=>WrapLines(text,availableWidth,measure,2);
        static string[] WrapLines(string text,float availableWidth,Func<string,float> measure,int maximumLines){
            if(string.IsNullOrWhiteSpace(text))return Array.Empty<string>();
            var rows=new List<string>();var current="";
            var tokens=new List<string>();
            var paragraphs=text.Replace("\r\n","\n").Split('\n');
            for(var p=0;p<paragraphs.Length;p++){tokens.AddRange(DisplayUnits(paragraphs[p]));if(p+1<paragraphs.Length)tokens.Add("\n");}
            for(var i=0;i<tokens.Count;i++){
                var token=tokens[i];
                if(token=="\n" || (current.Length>0&&measure(current+token)>availableWidth)){
                    if(rows.Count<maximumLines-1){rows.Add(current.TrimEnd());current="";if(token=="\n")continue;}
                    else {current=Ellipsize(current+token+string.Concat(tokens.GetRange(i+1,tokens.Count-i-1)),availableWidth,measure);rows.Add(current);return rows.ToArray();}
                }
                if(measure(token)>availableWidth){
                    var elements=StringInfo.GetTextElementEnumerator(token);
                    while(elements.MoveNext()){
                        var element=elements.GetTextElement();
                        if(current.Length>0&&measure(current+element)>availableWidth){
                            if(rows.Count<maximumLines-1){rows.Add(current);current="";}
                            else{rows.Add(Ellipsize(current+element+"…",availableWidth,measure));return rows.ToArray();}
                        }
                        current+=element;
                    }
                }else current+=token;
            }
            if(current.Length>0)rows.Add(current.TrimEnd());return rows.ToArray();
        }
        static string Ellipsize(string value,float availableWidth,Func<string,float> measure){
            var result=new StringBuilder();var elements=StringInfo.GetTextElementEnumerator(value.Replace("\n"," "));
            while(elements.MoveNext()){var element=elements.GetTextElement();if(measure(result.ToString()+element+"…")>availableWidth)break;result.Append(element);}
            return result+"…";
        }
        void AddTranslationRows(string[] rows,float size,float x,float firstBaseline,float alpha,bool leading,FontAsset role=null){
            var savedFont=font;font=role??TranslationFont;
            var savedEffects=currentEffects;currentEffects=new Vector4(0,0,0,styleCode==0?5:0);
            for(var i=0;i<rows.Length;i++){
                var display=new LyricPointLine{text=rows[i],startsAt=1,endsAt=-1};
                if(leading)AddLeftLine(display,size,x,firstBaseline+i*size*1.2f,WithAlpha(primary,alpha),false);
                else AddLine(display,size,x,firstBaseline+i*size*1.2f,WithAlpha(primary,alpha),false);
            }
            currentEffects=savedEffects;
            font=savedFont;
        }
        // Swift contextualLine: bounded 680-point frame, minimumScaleFactor(.72),
        // lineLimit(1). Work happens only on a line/viewport boundary, never per frame.
        static Vector3 FlowContextLayout(float viewport){
            // Narrow windows retain a 24-point readable gutter (the maximum
            // contextual font size). Wide windows preserve Swift's exact frame
            // and offsets; only the constrained frame width changes.
            var frame=Mathf.Min(680,Mathf.Max(1,viewport-2*(42+24)));
            return new Vector3(frame,viewport*.5f-frame*.5f-42,viewport*.5f+frame*.5f+42);
        }
        void AddFlowContext(LyricPointLine line,float size,float width,float anchor,float y,Color color,bool trailing) {
            var savedFont=font;font=semiboldFont;
            var text=line.text??"";
            var measured=Measure(text,size);
            size*=Mathf.Clamp(width/Mathf.Max(1,measured),.72f,1);
            if(Measure(text,size)>width){
                var elements=StringInfo.GetTextElementEnumerator(text);var fitted=new StringBuilder();
                while(elements.MoveNext()){
                    var element=elements.GetTextElement();
                    if(Measure(fitted.ToString()+element+"…",size)>width)break;
                    fitted.Append(element);
                }
                text=fitted+"…";
            }
            var display=new LyricPointLine{text=text,startsAt=1,endsAt=-1};
            var begin=descriptors.Count;
            currentEffects=new Vector4(trailing?.9f:1.5f,0,0,0);
            AddLine(display,size,anchor,y,color,false);
            font=savedFont;
            AlignGlyphRange(begin,anchor,trailing);
            if(descriptors.Count>begin){
                var bounds=GlyphRangeBounds(begin);
                var viewport=this.width/scale;
                if(bounds.x<24-.01f||bounds.y>viewport-24+.01f)
                    Debug.LogError($"Flow context outside viewport: logical={viewport}, bounds={bounds}, anchor={anchor}, frame={width}, scale={scale}",this);
                Debug.Log($"GPU Flow context {(trailing?"next":"previous")}: screen={this.width} scale={scale} logical={viewport} bounds=[{bounds.x:F2},{bounds.y:F2}] anchor={anchor:F2}",this);
            }
        }
        Vector2 GlyphRangeBounds(int begin){
            var minimum=float.PositiveInfinity;var maximum=float.NegativeInfinity;
            for(var i=begin;i<descriptors.Count;i++){var rect=descriptors[i].rectangle;minimum=Mathf.Min(minimum,rect.x);maximum=Mathf.Max(maximum,rect.x+rect.z);}
            return new Vector2(minimum,maximum);
        }
        void AlignGlyphRange(int begin,float anchor,bool trailing){
            if(descriptors.Count==begin)return;
            var bounds=GlyphRangeBounds(begin);var shift=anchor-(trailing?bounds.y:bounds.x);
            for(var i=begin;i<descriptors.Count;i++){var seed=descriptors[i];seed.rectangle.x+=shift;if(seed.metadata.x!=0&&(styleCode==0||styleCode==1||styleCode==7))seed.timing.z+=shift;descriptors[i]=seed;}
        }
        void AddTranslation(LyricPointLine line,float size,float x,float y,float alpha) {
            var savedFont=font;font=TranslationFont;var saved=currentTransform;currentTransform=new Vector4(x,y,0,1);
            if(!string.IsNullOrEmpty(line.translation))AddLine(new LyricPointLine{text=line.translation,startsAt=1,endsAt=-1},size,x,y,WithAlpha(primary,alpha),false);
            currentTransform=saved;font=savedFont;
        }
        void AddTranslationLeft(LyricPointLine line,float size,float x,float y,float alpha){if(!string.IsNullOrEmpty(line.translation))AddLeftLine(new LyricPointLine{text=line.translation,startsAt=1,endsAt=-1},size,x,y,WithAlpha(primary,alpha),false);}
        void AddRightLine(LyricPointLine line,float size,float x,float y,Color color,bool animated){var begin=descriptors.Count;AddLine(line,size,x,y,color,animated);AlignGlyphRange(begin,x,true);}
        void AddLeftLine(LyricPointLine line,float size,float x,float y,Color color,bool animated) {
            var begin=descriptors.Count;AddLine(line,size,x,y,color,animated);
            AlignGlyphRange(begin,x,false);
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
            var grouped=animated&&(styleCode==0||styleCode==1||styleCode==4||styleCode==5||styleCode==7);
            var unitGap=size*(styleCode==0?.015f:.012f);var innerTracking=-size*.018f;
            for(var i=0;i<units.Count;i++)if(font.characterLookupTable.TryGetValue(units[i].value,out var character)){
                advance+=character.glyph.metrics.horizontalAdvance*ratio;
                if(grouped&&i+1<units.Count)advance+=units[i].motionIndex==units[i+1].motionIndex?innerTracking:unitGap;
            }
            var x = centerX-advance*.5f;
            var atlas = font.atlasTextures[0];
            var groupRanges=new Dictionary<int,Vector4>();var descriptorStart=descriptors.Count;
            for(var unitIndex=0;unitIndex<units.Count;unitIndex++) {var unit=units[unitIndex];
                if (!font.characterLookupTable.TryGetValue(unit.value,out var character)) continue;
                var glyph = character.glyph; var metrics = glyph.metrics; var rect = glyph.glyphRect;
                atlas=font.atlasTextures[glyph.atlasIndex];
                descriptors.Add(new LyricGlyphSeed {
                    rectangle = new Vector4(x+metrics.horizontalBearingX*ratio,centerY-metrics.horizontalBearingY*ratio,metrics.width*ratio,metrics.height*ratio),
                    atlas = new Vector4((float)rect.x/atlas.width,(float)rect.y/atlas.height,(float)rect.width/atlas.width,(float)rect.height/atlas.height),
                    timing = animated ? new Vector4(unit.start,unit.end,0,0) : new Vector4(1,-1,0,0),
                    color = unit.color, metadata = new Vector4(animated?1:0, styleCode,fontPages[font]+glyph.atlasIndex,grouped?unit.motionIndex:0), transform=currentTransform, transition=currentTransition,effects=currentEffects,
                    motion=animated?new Vector4(-3+StableUnit(line.id,unit.motionIndex,11)*6,-8+StableUnit(line.id,unit.motionIndex,23)*16,(-2.8f+StableUnit(line.id,unit.motionIndex,37)*5.6f)*Mathf.Deg2Rad,.94f+StableUnit(line.id,unit.motionIndex,53)*.1f):new Vector4(0,0,0,1)
                });
                if(grouped){
                    var r=descriptors[descriptors.Count-1].rectangle;
                    if(!groupRanges.TryGetValue(unit.motionIndex,out var b))b=new Vector4(r.x,r.y,r.x+r.z,r.y+r.w);
                    else b=new Vector4(Mathf.Min(b.x,r.x),Mathf.Min(b.y,r.y),Mathf.Max(b.z,r.x+r.z),Mathf.Max(b.w,r.y+r.w));
                    groupRanges[unit.motionIndex]=b;
                }
                x += metrics.horizontalAdvance*ratio;
                if(grouped&&unitIndex+1<units.Count)x+=unit.motionIndex==units[unitIndex+1].motionIndex?innerTracking:unitGap;
            }
            if(grouped)for(var i=descriptorStart;i<descriptors.Count;i++){var seed=descriptors[i];var b=groupRanges[(int)seed.metadata.w];seed.timing.z=(b.x+b.z)*.5f;seed.timing.w=(b.y+b.w)*.5f;descriptors[i]=seed;}
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
        void ReleaseBuffers() { glyphs?.Dispose(); points?.Dispose(); glyphs=null;points=null;PointCapacity=0;hasGlow=false;if(atlasPages!=null)Destroy(atlasPages);atlasPages=null; }
        void OnDestroy() { ReleaseBuffers();ReleaseGlowTargets();glowCommands?.Release();if(blurMaterial!=null)Destroy(blurMaterial);if(glowCompositeMaterial!=null)Destroy(glowCompositeMaterial);if(material!=null)Destroy(material);if(backgroundMaterial!=null)Destroy(backgroundMaterial);if(effectMaterial!=null)Destroy(effectMaterial);if(compute!=null)Destroy(compute); }
    }
}
