using System;
using UnityEngine;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer
{
    /// Passive UI Toolkit equivalent of SpatialEnvironmentEffectsView's Canvas.
    public sealed class WorldWeatherOverlay : VisualElement
    {
        public readonly struct RainStroke {
            public readonly Vector2 Start, End;
            public readonly float Width, EndAlpha;
            public RainStroke(Vector2 start, Vector2 end, float width, float alpha)
            { Start = start; End = end; Width = width; EndAlpha = alpha; }
        }
        public string Weather { get; private set; } = "clear";
        public bool PresentationVisible { get; private set; }
        public ulong Revision { get; private set; }
        public ulong LastPaintedRevision { get; private set; }
        public int LastPaintedFrame { get; private set; } = -1;
        public int FirstPaintedFrame { get; private set; } = -1;
        public int LastPaintedStrokeCount { get; private set; }
        public float LastLightningOpacity { get; private set; }
        public bool HasPainted { get; private set; }
        double referenceTime;

        public WorldWeatherOverlay()
        {
            name = "world-weather-overlay";
            pickingMode = PickingMode.Ignore;
            focusable = false;
            style.position = Position.Absolute;
            style.overflow = Overflow.Hidden;
            style.left = 0; style.right = 0; style.top = 0; style.bottom = 0;
            style.display = DisplayStyle.None;
            generateVisualContent += Paint;
        }
        public void SetPresentation(string weather, ulong revision, bool visible)
        {
            if (weather != "clear" && weather != "rain" && weather != "thunderstorm")
                throw new ArgumentException("invalid_spatial_weather");
            bool changed = Weather != weather || Revision != revision || PresentationVisible != visible;
            Weather = weather; Revision = revision; PresentationVisible = visible;
            style.display = visible ? DisplayStyle.Flex : DisplayStyle.None;
            if (changed) { HasPainted = false; FirstPaintedFrame = -1; MarkDirtyRepaint(); }
        }
        public void Tick(double secondsSince2001)
        {
            referenceTime = secondsSince2001;
            if (PresentationVisible) MarkDirtyRepaint();
        }
        public static double SecondsSinceReferenceDate(DateTimeOffset date)
            => (date - new DateTimeOffset(2001, 1, 1, 0, 0, 0, TimeSpan.Zero)).TotalSeconds;
        public static float LightningOpacity(double secondsSince2001)
        {
            double phase = secondsSince2001 % 5.4;
            if (phase < .07) return .46f;
            if (phase > .15 && phase < .22) return .22f;
            return 0;
        }
        public static RainStroke[] RainStrokes(double time, float width, float height, float intensity)
        {
            int count = Math.Max(80, (int)(width / 9));
            var strokes = new RainStroke[count];
            for (int index = 0; index < count; index++) {
                double seed = index * 73 % count;
                float x = (float)(seed / count * width);
                double speed = 420 + index * 37 % 260;
                float y = (float)((time * speed + index * 97) % (height + 120) - 60);
                strokes[index] = new RainStroke(new Vector2(x + 16, y - 32), new Vector2(x, y + 18),
                    index % 5 == 0 ? 1.4f : .7f, .34f * intensity);
            }
            return strokes;
        }
        void Paint(MeshGenerationContext context)
        {
            if (!PresentationVisible || contentRect.width <= 0 || contentRect.height <= 0) return;
            LastPaintedStrokeCount = 0; LastLightningOpacity = 0;
            if (Weather != "clear") {
                float intensity = Weather == "rain" ? .64f : .92f;
                var strokes = RainStrokes(referenceTime, contentRect.width, contentRect.height, intensity);
                bool lightning = Weather == "thunderstorm" && LightningOpacity(referenceTime) > 0;
                LastPaintedStrokeCount = strokes.Length;
                LastLightningOpacity = lightning ? LightningOpacity(referenceTime) : 0;
                int quads = strokes.Length + 1 + (lightning ? 1 : 0);
                var vertices = new Vertex[quads * 4]; var indices = new ushort[quads * 6];
                int quad = 0;
                AddQuad(vertices, indices, quad++, Vector2.zero, new Vector2(contentRect.width, 0),
                    new Vector2(contentRect.width, contentRect.height), new Vector2(0, contentRect.height),
                    new Color(.3451f, .3373f, .8392f, .08f * intensity), new Color(.3451f, .3373f, .8392f, .08f * intensity),
                    new Color(0, 0, 0, .16f * intensity), new Color(0, 0, 0, .16f * intensity));
                foreach (var stroke in strokes) {
                    var line = stroke.End - stroke.Start;
                    var normal = new Vector2(-line.y, line.x).normalized * (stroke.Width * .5f);
                    AddQuad(vertices, indices, quad++, stroke.Start + normal, stroke.Start - normal,
                        stroke.End - normal, stroke.End + normal,
                        Color.clear, Color.clear, new Color(0, 1, 1, stroke.EndAlpha), new Color(0, 1, 1, stroke.EndAlpha));
                }
                if (lightning) {
                    var white = new Color(1, 1, 1, LightningOpacity(referenceTime));
                    AddQuad(vertices, indices, quad, Vector2.zero, new Vector2(contentRect.width, 0),
                        new Vector2(contentRect.width, contentRect.height), new Vector2(0, contentRect.height), white, white, white, white);
                }
                var mesh = context.Allocate(vertices.Length, indices.Length);
                mesh.SetAllVertices(vertices); mesh.SetAllIndices(indices);
            }
            if (!HasPainted) FirstPaintedFrame = Time.frameCount;
            LastPaintedRevision = Revision; LastPaintedFrame = Time.frameCount; HasPainted = true;
        }
        static void AddQuad(Vertex[] vertices, ushort[] indices, int quad,
            Vector2 a, Vector2 b, Vector2 c, Vector2 d, Color ca, Color cb, Color cc, Color cd)
        {
            int start = quad * 4;
            vertices[start] = VertexAt(a, ca); vertices[start+1] = VertexAt(b, cb);
            vertices[start+2] = VertexAt(c, cc); vertices[start+3] = VertexAt(d, cd);
            int offset = quad * 6;
            indices[offset] = (ushort)start; indices[offset+1] = (ushort)(start+1); indices[offset+2] = (ushort)(start+2);
            indices[offset+3] = (ushort)start; indices[offset+4] = (ushort)(start+2); indices[offset+5] = (ushort)(start+3);
        }
        static Vertex VertexAt(Vector2 point, Color color) => new Vertex {
            position = new Vector3(point.x, point.y, Vertex.nearZ), tint = color, uv = Vector2.zero
        };
    }
}
