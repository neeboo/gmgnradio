using System;
using UnityEngine;
using UnityEngine.UIElements;
using UnityEditor;
using UnityEngine.InputSystem;
using UnityEngine.InputSystem.LowLevel;

namespace GMGN.UnityPlayer.Editor
{
    public static class FullscreenMouseReleaseChecks
    {
        public static void VerifySplitInput()
        {
            var previousMouse=Mouse.current;
            var manager=typeof(InputSystem).GetField("s_Manager",System.Reflection.BindingFlags.Static|System.Reflection.BindingFlags.NonPublic).GetValue(null);
            var runInEditor=manager.GetType().GetProperty("runPlayerUpdatesInEditMode");
            var previousRun=(bool)runInEditor.GetValue(manager); runInEditor.SetValue(manager,true);
            var mouse=InputSystem.AddDevice<Mouse>("fullscreen-release-fixture");
            var point=new InputAction(type:InputActionType.PassThrough,binding:"<Mouse>/position");
            var click=new InputAction(type:InputActionType.PassThrough,binding:"<Mouse>/leftButton");
            bool fullscreen=true;
            var framebuffer=new Vector2(4096,2304);
            var native=new Vector2(.8f,.3f);
            var cached=Vector2.zero; var releasedAt=Vector2.zero; int releases=0,repairs=0;
            point.performed+=ctx=>cached=ctx.ReadValue<Vector2>();
            click.performed+=ctx=> { if(!ctx.ReadValueAsButton()) { releasedAt=cached; releases++; } };
            System.Action<InputEventPtr,InputDevice> repair=(evt,device)=> {
                if(device==mouse && FullscreenMouseReleaseBridge.RepairInput(evt,device,fullscreen,framebuffer,()=>native)) repairs++;
            };
            try {
                point.Enable(); click.Enable(); InputSystem.onEvent+=repair;
                // Editor's public Update defaults to Editor, which intentionally
                // does not run gameplay InputActions. Exercise the real Dynamic
                // action path using the package's internal test update entry.
                var update=typeof(InputSystem).GetMethod("Update",System.Reflection.BindingFlags.Static|System.Reflection.BindingFlags.NonPublic,
                    null,new[] { typeof(InputUpdateType) },null);
                void Pump()=>update.Invoke(null,new object[] { InputUpdateType.Dynamic });
                void Position(Vector2 value) { InputSystem.QueueDeltaStateEvent(mouse.position,value); Pump(); }
                void Button(byte value) { InputSystem.QueueDeltaStateEvent(mouse.leftButton,value); Pump(); }
                var expected=Vector2.Scale(native,framebuffer);
                Position(new Vector2(700,800)); Button(1);
                Position(Vector2.zero); Button(0);
                if(repairs!=1 || releases!=1 || releasedAt!=expected || mouse.position.ReadValue()!=expected)
                    throw new Exception($"Split position/button delta failed InputForUI-style cache: repairs={repairs},releases={releases},cached={releasedAt},expected={expected}");
                // The device may already be zero before the repair hook sees a
                // button-only release. Its point action must update first.
                Position(new Vector2(500,600)); Button(1); fullscreen=false; Position(Vector2.zero); fullscreen=true; Button(0);
                if(repairs!=2 || releases!=2 || releasedAt!=expected)
                    throw new Exception($"Button-only release did not update cached pointer first: {releasedAt}");
                // A true native zero is legal; do not invent a previous location.
                native=Vector2.zero; Position(new Vector2(500,600)); Button(1); Position(Vector2.zero); Button(0);
                if(repairs!=2 || releases!=3 || releasedAt!=Vector2.zero)
                    throw new Exception("Genuine native bottom-left pointer changed.");
                native=new Vector2(1.1f,.3f); expected=Vector2.Scale(native,framebuffer);
                Position(new Vector2(500,600)); Button(1); Position(Vector2.zero); Button(0);
                if(repairs!=3 || releases!=4 || releasedAt!=expected || releasedAt.x<=framebuffer.x)
                    throw new Exception("Native drag-out was clamped back inside window.");
                fullscreen=false; Position(new Vector2(500,600)); Button(1); Position(Vector2.zero); Button(0);
                if(repairs!=3 || releases!=5 || releasedAt!=Vector2.zero)
                    throw new Exception("Windowed input semantics changed.");
                Debug.Log("PASS actual InputSystem split deltas: held zero-position then button-only release; zero cached before release updates point action first; native origin, drag-out and windowed preserved.");
            } finally {
                InputSystem.onEvent-=repair; point.Dispose(); click.Dispose(); InputSystem.RemoveDevice(mouse); previousMouse?.MakeCurrent();
                runInEditor.SetValue(manager,previousRun);
            }
        }
        public static void VerifyButton()
        {
            var go=new GameObject("fullscreen-release-button-fixture");
            var settings=UnityEngine.Object.Instantiate(Resources.Load<PanelSettings>("PlayerPanel"));
            settings.scale=2;
            var doc=go.AddComponent<UIDocument>(); doc.panelSettings=settings;
            var button=new Button(); button.style.position=Position.Absolute; button.style.left=20; button.style.top=20;
            button.style.width=100; button.style.height=40; doc.rootVisualElement.Add(button);
            int clicks=0; button.clicked+=()=>clicks++;
            var deadline=EditorApplication.timeSinceStartup+.5;
            EditorApplication.CallbackFunction check=null;
            check=()=> {
                if(EditorApplication.timeSinceStartup<deadline) return;
                try {
                    var panel=doc.rootVisualElement.panel;
                    var screen=new Vector2(Screen.width,Screen.height);
                    var origin=RuntimePanelUtils.ScreenToPanel(panel,Vector2.zero);
                    var end=RuntimePanelUtils.ScreenToPanel(panel,screen);
                    Vector2 RepairToPanel(Vector2 point) {
                        var input=WorldInteractionController.PanelPointToScreen(point,origin,end,screen);
                        var native=Vector2.Scale(input,new Vector2(1/screen.x,1/screen.y));
                        var repaired=FullscreenMouseReleaseBridge.ContentToFramebuffer(native,screen);
                        return RuntimePanelUtils.ScreenToPanel(panel,new Vector2(repaired.x,screen.y-repaired.y));
                    }
                    void Press(Vector2 position) {
                        using var evt=PointerDownEvent.GetPooled(new UnityEngine.Event { type=EventType.MouseDown,button=0,mousePosition=position });
                        button.SendEvent(evt);
                    }
                    void Release(Vector2 position) {
                        using var evt=PointerUpEvent.GetPooled(new UnityEngine.Event { type=EventType.MouseUp,button=0,mousePosition=position });
                        button.SendEvent(evt);
                    }
                    var center=button.worldBound.center;
                    Press(center); Release(RepairToPanel(center));
                    if(clicks!=1) throw new Exception("Real Clickable did not click after repaired Retina release.");
                    Press(center); Release(RepairToPanel(center+new Vector2(200,0)));
                    if(clicks!=1) throw new Exception("Real Clickable clicked after dragging outside button.");
                    Debug.Log("PASS real runtime Button: repaired Retina down/up clicked once, drag-out release cancelled.");
                    EditorApplication.update-=check; UnityEngine.Object.DestroyImmediate(go); UnityEngine.Object.DestroyImmediate(settings); EditorApplication.Exit(0);
                } catch(Exception error) {
                    Debug.LogException(error); EditorApplication.update-=check; UnityEngine.Object.DestroyImmediate(go); UnityEngine.Object.DestroyImmediate(settings); EditorApplication.Exit(1);
                }
            };
            EditorApplication.update+=check;
        }
        public static void Validate()
        {
            if (!FullscreenMouseReleaseBridge.IsBrokenRelease(true,Vector2.zero,true,false) ||
                FullscreenMouseReleaseBridge.IsBrokenRelease(false,Vector2.zero,true,false) ||
                FullscreenMouseReleaseBridge.IsBrokenRelease(true,Vector2.one,true,false) ||
                FullscreenMouseReleaseBridge.IsBrokenRelease(true,Vector2.zero,false,false) ||
                FullscreenMouseReleaseBridge.IsBrokenRelease(true,Vector2.zero,true,true))
                throw new Exception("Release repair must exclude windowed, valid position, move and press events.");
            var documentObject = new GameObject("fullscreen-input-coordinate-fixture");
            var settings = ScriptableObject.CreateInstance<PanelSettings>();
            try {
                settings.scaleMode=PanelScaleMode.ConstantPixelSize; settings.scale=2;
                var document=documentObject.AddComponent<UIDocument>(); document.panelSettings=settings;
                var panel=document.rootVisualElement.panel;
                if(panel==null) throw new Exception("Coordinate regression requires an attached runtime panel.");
                var origin=RuntimePanelUtils.ScreenToPanel(panel,Vector2.zero);
                var end=RuntimePanelUtils.ScreenToPanel(panel,new Vector2(4096,2304));
                var framebuffer=new Vector2(4096,2304);
                var down= new Vector2(1968.5f,45.5f);
                var screen=WorldInteractionController.PanelPointToScreen(down,origin,end,framebuffer);
                var corrected=FullscreenMouseReleaseBridge.ContentToFramebuffer(Vector2.Scale(screen,new Vector2(1f/4096,1f/2304)),framebuffer);
                // InputForUI.InputSystemProvider.ScreenBottomLeftToPanelPosition
                // flips Y BEFORE RuntimePanelUtils.ScreenToPanel scales to points.
                var up=RuntimePanelUtils.ScreenToPanel(panel,new Vector2(corrected.x,framebuffer.y-corrected.y));
                if(Vector2.Distance(down,up)>.01f) throw new Exception("Retina fullscreen release differs from actual panel press coordinates.");
                var outside=new Vector2(2100,45.5f);
                var outsideScreen=WorldInteractionController.PanelPointToScreen(outside,origin,end,framebuffer);
                var outsideCorrected=FullscreenMouseReleaseBridge.ContentToFramebuffer(Vector2.Scale(outsideScreen,new Vector2(1f/4096,1f/2304)),framebuffer);
                if(Vector2.Distance(RuntimePanelUtils.ScreenToPanel(panel,new Vector2(outsideCorrected.x,framebuffer.y-outsideCorrected.y)),outside)>.01f)
                    throw new Exception("Repair clamped a drag-out release into a clickable region.");
                if(FullscreenMouseReleaseBridge.ContentToFramebuffer(Vector2.zero,framebuffer)!=Vector2.zero)
                    throw new Exception("Genuine native bottom-left position must remain zero.");
                Debug.Log("PASS fullscreen release: runtime panel Retina down/up coordinates, drag-out preserved, native bottom-left and release-only gate; no live fullscreen click claim.");
            } finally { UnityEngine.Object.DestroyImmediate(documentObject); UnityEngine.Object.DestroyImmediate(settings); }
        }
    }
}
