using GMGN.UnityPlayer.Characters;
using UnityEngine;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer
{
    public sealed class ResidentThinkingCloud : MonoBehaviour
    {
        ThoughtCloud cloud;
        VisualElement root;
        CharacterWorldAdapter character;
        bool pending;
        float nextLookup, nextPaint;
        public bool IsPending => pending;

        public static bool TryAnchor(Vector2 head, float characterScreenHeight, Vector2 viewport, out Vector2 origin)
        {
            var gap = Mathf.Clamp(characterScreenHeight * .15f, 20, 38);
            origin = new Vector2(head.x - 40, head.y - gap - 66);
            return viewport.x > 0 && viewport.y > 0 && head.x >= 0 && head.x <= viewport.x
                && head.y >= 0 && head.y <= viewport.y && origin.y >= 0;
        }

        public void Initialize(VisualElement parent)
        {
            root = parent;
            cloud = new ThoughtCloud { pickingMode = PickingMode.Ignore };
            cloud.style.position = Position.Absolute;
            cloud.style.width = 80; cloud.style.height = 100;
            cloud.style.display = DisplayStyle.None;
            root.Add(cloud);
        }
        public void SetPending(bool value)
        {
            pending = value;
            if (!value && cloud != null) cloud.style.display = DisplayStyle.None;
        }
        void LateUpdate()
        {
            if (!pending || cloud == null || root.panel == null) return;
            if (character == null && Time.unscaledTime >= nextLookup) {
                character = FindAnyObjectByType<CharacterWorldAdapter>();
                nextLookup = Time.unscaledTime + .5f;
            }
            var camera = Camera.main;
            if (character == null || !character.gameObject.activeInHierarchy || camera == null) { cloud.style.display = DisplayStyle.None; return; }
            var top = character.transform.TransformPoint(new Vector3(0, 1.65f, 0));
            var projected = camera.WorldToViewportPoint(top);
            var head = RuntimePanelUtils.CameraTransformWorldToPanel(root.panel, top, camera);
            var foot = RuntimePanelUtils.CameraTransformWorldToPanel(root.panel, character.transform.position, camera);
            var localHead = root.WorldToLocal(head);
            if (projected.z <= 0 || !TryAnchor(localHead, Mathf.Abs(foot.y - head.y), root.contentRect.size, out var origin)) {
                cloud.style.display = DisplayStyle.None; return;
            }
            cloud.style.display = DisplayStyle.Flex;
            cloud.style.translate = new Translate(origin.x, origin.y);
            if (Time.unscaledTime >= nextPaint) {
                cloud.Seconds = Time.unscaledTime;
                cloud.MarkDirtyRepaint();
                nextPaint = Time.unscaledTime + 1f / 30;
            }
        }
        void OnDestroy() => cloud?.RemoveFromHierarchy();

        sealed class ThoughtCloud : VisualElement
        {
            public float Seconds;
            static readonly Color Outline = new(.12f, .14f, .18f, .55f);
            static readonly Color Fill = new(1, 1, 1, .96f);
            public ThoughtCloud() { generateVisualContent += Draw; }
            void Draw(MeshGenerationContext context)
            {
                if (contentRect.width < 1 || contentRect.height < 1) return;
                var p = context.painter2D;
                void Circle(float x, float y, float radius, Color color) {
                    p.fillColor = color; p.BeginPath(); p.Arc(new Vector2(x, y), radius, 0, 360); p.Fill();
                }
                float bob = Mathf.Sin(Seconds * Mathf.PI) * 2.5f;
                var radii = new[] { 4.2f, 3f, 2f };
                var samples = new[] { .18f, .52f, .85f };
                for (int i = 0; i < 3; i++) {
                    Circle(40, 36 + samples[i] * 30, radii[i] + 1.4f, Outline);
                    Circle(40, 36 + samples[i] * 30, radii[i], Fill);
                }
                void RoundRect(float x, float y, float w, float h, float r, Color color) {
                    p.fillColor = color; p.BeginPath(); p.MoveTo(new Vector2(x + r, y));
                    p.LineTo(new Vector2(x + w - r, y)); p.ArcTo(new Vector2(x + w, y), new Vector2(x + w, y + r), r);
                    p.LineTo(new Vector2(x + w, y + h - r)); p.ArcTo(new Vector2(x + w, y + h), new Vector2(x + w - r, y + h), r);
                    p.LineTo(new Vector2(x + r, y + h)); p.ArcTo(new Vector2(x, y + h), new Vector2(x, y + h - r), r);
                    p.LineTo(new Vector2(x, y + r)); p.ArcTo(new Vector2(x, y), new Vector2(x + r, y), r); p.ClosePath(); p.Fill();
                }
                for (int pass = 0; pass < 2; pass++) {
                    float extra = pass == 0 ? 1.4f : 0;
                    var color = pass == 0 ? Outline : Fill;
                    RoundRect(21.5f - extra, 15.12f + bob - extra, 37 + extra * 2, 18 + extra * 2, 9 + extra, color);
                    Circle(29, 17.28f + bob, 8.64f + extra, color);
                    Circle(40, 12.96f + bob, 10.44f + extra, color);
                    Circle(51.5f, 18 + bob, 7.92f + extra, color);
                }
                // A vector thinking face avoids unsupported OS-only emoji fonts.
                float breath = 1 + Mathf.Sin(Seconds * Mathf.PI * 2 / 1.2f) * .08f;
                Circle(40, 18 + bob, 8 * breath, new Color(1, .78f, .22f));
                Circle(37, 16 + bob, .8f, new Color(.2f, .15f, .1f));
                Circle(43, 16 + bob, .8f, new Color(.2f, .15f, .1f));
                p.strokeColor = new Color(.2f, .15f, .1f); p.lineWidth = 1; p.lineCap = LineCap.Round;
                p.BeginPath(); p.MoveTo(new Vector2(38, 21 + bob)); p.LineTo(new Vector2(43, 20 + bob)); p.Stroke();
                p.strokeColor = new Color(.9f, .55f, .1f); p.lineWidth = 3;
                p.BeginPath(); p.MoveTo(new Vector2(41, 24 + bob)); p.LineTo(new Vector2(45, 22 + bob)); p.LineTo(new Vector2(45, 19 + bob)); p.Stroke();
            }
        }
    }
}
