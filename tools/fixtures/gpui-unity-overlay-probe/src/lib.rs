//! GPUI presentation of the existing Unity host's chat. No second backend/world.
use gpui_kit::*;
use gpui_kit::component::{Theme, ThemeMode};
use gpui_kit::component::input::{InputState,TextareaState,EditorState};
use gmgn_gpui_ui::{ResidentChatPane, state::{ChatCommand,TranscriptLine}};
use serde_json::{Value,json};
use raw_window_handle::{HasWindowHandle, RawWindowHandle};
use std::{cell::{Cell, RefCell}, collections::VecDeque, ffi::c_void, path::{Path, PathBuf}, rc::Rc, sync::Arc};
use futures::channel::oneshot;
mod inventory_ui;
use inventory_ui::InventoryPane;
mod shell_ui;
mod settings_ui;
pub mod media_ui;
use shell_ui::ShellPane;
use settings_ui::SettingsPane;
use media_ui::MediaPane;

pub type UiCommandQueue=Rc<RefCell<VecDeque<Value>>>;
pub fn enqueue_ui_command(queue:&UiCommandQueue,command:Value)->bool {
    let mut queue=queue.borrow_mut();
    if queue.len()>=32 {return false;}
    queue.push_back(command);true
}


// Delegation preserves the pinned Mac text/atlas/input implementation. Crucially,
// run never calls MacPlatform::run: the external host retains NSApp and its delegate.
struct EmbeddedPlatform(gpui_macos::MacPlatform);
macro_rules! forward {
    ($(fn $name:ident(&self $(, $arg:ident : $ty:ty)*) $(-> $ret:ty)?;)*) => {
        $(fn $name(&self $(, $arg:$ty)*) $(-> $ret)? { self.0.$name($($arg),*) })*
    };
}
impl Platform for EmbeddedPlatform {
    fn run(&self, launched:Box<dyn FnOnce()>) { launched(); }
    fn quit(&self) {} // Never terminates the foreign host.
    fn restart(&self, _:Option<PathBuf>, _:Vec<std::ffi::OsString>) {}
    fn activate(&self, _:bool) {}
    fn hide(&self) {}
    fn hide_other_apps(&self) {}
    fn unhide_other_apps(&self) {}
    fn set_menus(&self, _:Vec<Menu>, _: &Keymap) {}
    fn set_dock_menu(&self, _:Vec<MenuItem>, _: &Keymap) {}
    forward! {
        fn background_executor(&self)->BackgroundExecutor;
        fn foreground_executor(&self)->ForegroundExecutor;
        fn text_system(&self)->Arc<dyn PlatformTextSystem>;
        fn displays(&self)->Vec<Rc<dyn PlatformDisplay>>;
        fn primary_display(&self)->Option<Rc<dyn PlatformDisplay>>;
        fn active_window(&self)->Option<AnyWindowHandle>;
        fn window_appearance(&self)->WindowAppearance;
        fn open_url(&self, url:&str);
        fn on_open_urls(&self, callback:Box<dyn FnMut(Vec<String>)>);
        fn register_url_scheme(&self, url:&str)->Task<anyhow::Result<()>>;
        fn prompt_for_paths(&self, options:PathPromptOptions)->oneshot::Receiver<anyhow::Result<Option<Vec<PathBuf>>>>;
        fn prompt_for_new_path(&self, directory:&Path, suggested_name:Option<&str>)->oneshot::Receiver<anyhow::Result<Option<PathBuf>>>;
        fn can_select_mixed_files_and_dirs(&self)->bool;
        fn reveal_path(&self, path:&Path);
        fn open_with_system(&self, path:&Path);
        fn on_quit(&self, callback:Box<dyn FnMut()->bool>);
        fn on_reopen(&self, callback:Box<dyn FnMut()>);
        fn on_system_sleep(&self, callback:Box<dyn FnMut()>);
        fn on_system_wake(&self, callback:Box<dyn FnMut()>);
        fn on_app_menu_action(&self, callback:Box<dyn FnMut(&dyn Action)>);
        fn on_will_open_app_menu(&self, callback:Box<dyn FnMut()>);
        fn on_validate_app_menu_command(&self, callback:Box<dyn FnMut(&dyn Action)->bool>);
        fn thermal_state(&self)->ThermalState;
        fn on_thermal_state_change(&self, callback:Box<dyn FnMut()>);
        fn prevent_idle_sleep(&self, reason:&str)->Task<anyhow::Result<ActivityGuard>>;
        fn app_path(&self)->anyhow::Result<PathBuf>;
        fn path_for_auxiliary_executable(&self, name:&str)->anyhow::Result<PathBuf>;
        fn set_cursor_style(&self, style:CursorStyle);
        fn hide_cursor_until_mouse_moves(&self);
        fn is_cursor_visible(&self)->bool;
        fn should_auto_hide_scrollbars(&self)->bool;
        fn read_from_clipboard(&self)->Option<ClipboardItem>;
        fn write_to_clipboard(&self, item:ClipboardItem);
        fn read_from_find_pasteboard(&self)->Option<ClipboardItem>;
        fn write_to_find_pasteboard(&self, item:ClipboardItem);
        fn keyboard_layout(&self)->Box<dyn PlatformKeyboardLayout>;
        fn keyboard_mapper(&self)->Rc<dyn PlatformKeyboardMapper>;
        fn on_keyboard_layout_change(&self, callback:Box<dyn FnMut()>);
    }
    // Application secrets remain in the existing private-file authority store.
    // Never delegate these optional platform hooks to macOS Keychain.
    fn write_credentials(&self,_:&str,_:&str,_:&[u8])->Task<anyhow::Result<()>> {
        Task::ready(Err(anyhow::anyhow!("platform_credentials_disabled")))
    }
    fn read_credentials(&self,_:&str)->Task<anyhow::Result<Option<(String,Vec<u8>)>>> {
        Task::ready(Err(anyhow::anyhow!("platform_credentials_disabled")))
    }
    fn delete_credentials(&self,_:&str)->Task<anyhow::Result<()>> {
        Task::ready(Err(anyhow::anyhow!("platform_credentials_disabled")))
    }
    fn open_window(&self, handle:AnyWindowHandle, options:WindowParams)->anyhow::Result<Box<dyn PlatformWindow>> {
        self.0.open_window(handle, options)
    }
}

thread_local! {
    static APPLICATION:RefCell<Option<ApplicationHandle>>=const { RefCell::new(None) };
    static MOUNTED:RefCell<*mut c_void>=const { RefCell::new(std::ptr::null_mut()) };
    static DONOR:RefCell<Option<WindowHandle<gpui_kit::base::Root>>>=const { RefCell::new(None) };
    static PANE:RefCell<Option<Entity<ResidentChatPane>>>=const { RefCell::new(None) };
    static INVENTORY:RefCell<Option<Entity<InventoryPane>>>=const { RefCell::new(None) };
    static SHELL:RefCell<Option<Entity<ShellPane>>>=const { RefCell::new(None) };
    static SETTINGS:RefCell<Option<Entity<SettingsPane>>>=const { RefCell::new(None) };
    static SETTINGS_WINDOW:RefCell<Option<WindowHandle<gpui_kit::base::Root>>>=const { RefCell::new(None) };
    static MEDIA:RefCell<Option<Entity<MediaPane>>>=const { RefCell::new(None) };
    static COMMANDS:UiCommandQueue=Rc::new(RefCell::new(VecDeque::new()));
    static SNAPSHOT:RefCell<Value>=const { RefCell::new(Value::Null) };
    /// The derivations of the accepted `SNAPSHOT` (`normalize_chat`, then
    /// `visual_projection`). `None` means "not derived yet"; the first reader
    /// derives them from `Value::Null`, which is what an empty snapshot is.
    static DERIVED:RefCell<Option<(Value,Value)>>=const { RefCell::new(None) };
    /// Derivation counters, thread-local so the parallel test threads cannot
    /// pollute one another. Each is bumped once per poll at most.
    static NORMALIZE_CALLS:Cell<usize>=const { Cell::new(0) };
    static VISUAL_CALLS:Cell<usize>=const { Cell::new(0) };
    static VOICE_CURSOR:RefCell<VoiceCursor>=const {RefCell::new(VoiceCursor {context:None,revision:0})};
    static PENDING_REQUEST:RefCell<Option<u64>>=const { RefCell::new(None) };
    static CHAT_DROP_BOUNDS:RefCell<Option<Bounds<Pixels>>>=const { RefCell::new(None) };
    static INPUTS:RefCell<Vec<KitInput>>=const {RefCell::new(Vec::new())};
    static TEXT_INPUT_REPORTED:RefCell<Option<(bool,bool)>>=const {RefCell::new(None)};
    static ESCAPE_CONSUMED:RefCell<ConsumedEscape>=const {RefCell::new(ConsumedEscape(false))};
}
#[derive(Default)]
struct ConsumedEscape(bool);
impl ConsumedEscape {
    fn record(&mut self) {self.0=true;}
    fn take(&mut self)->bool {std::mem::take(&mut self.0)}
}
pub(crate) fn record_panel_escape() {ESCAPE_CONSUMED.with(|v|v.borrow_mut().record());}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gmgn_gpui_take_escape_consumed()->i32 {
    if unsafe {pthread_main_np()}==0 {return 0;}
    i32::from(ESCAPE_CONSUMED.with(|v|v.borrow_mut().take()))
}
enum KitInput { Input(WeakEntity<InputState>), Textarea(WeakEntity<TextareaState>), Editor(WeakEntity<EditorState>) }
impl KitInput {
    fn facts(&self,window:&mut Window,cx:&mut App)->Option<(bool,bool)> {
        macro_rules! facts {($entity:expr)=>{{
            let entity=$entity.upgrade()?;
            Some(entity.update(cx,|state,cx| {
                let focused=state.focus_handle(cx).is_focused(window);
                (focused,focused && EntityInputHandler::marked_text_range(state,window,cx).is_some())
            }))
        }}}
        match self {Self::Input(v)=>facts!(v),Self::Textarea(v)=>facts!(v),Self::Editor(v)=>facts!(v)}
    }
}
fn register_kit_inputs(cx:&App) {
    cx.observe_new::<InputState>(|_,_,cx|INPUTS.with(|v|v.borrow_mut().push(KitInput::Input(cx.entity().downgrade())))).detach();
    cx.observe_new::<TextareaState>(|_,_,cx|INPUTS.with(|v|v.borrow_mut().push(KitInput::Textarea(cx.entity().downgrade())))).detach();
    cx.observe_new::<EditorState>(|_,_,cx|INPUTS.with(|v|v.borrow_mut().push(KitInput::Editor(cx.entity().downgrade())))).detach();
}
pub(crate) fn kit_text_input_facts(window:&mut Window,cx:&mut App)->(bool,bool) {
    let mut facts=(false,false);
    if unsafe {probe_native_text_input_focused()}==1 {
        INPUTS.with(|inputs|inputs.borrow_mut().retain(|input| {
            let Some((focused,composing))=input.facts(window,cx) else {return false;};
            facts.0|=focused;facts.1|=composing;true
        }));
    }
    facts
}
fn report_kit_text_input(window:&mut Window,cx:&mut App) {
    let facts=kit_text_input_facts(window,cx);
    TEXT_INPUT_REPORTED.with(|reported| {
        if *reported.borrow()!=Some(facts) && COMMANDS.with(|q|enqueue_ui_command(q,json!({"op":"ui.textInput","focused":facts.0,"composing":facts.1}))) {
            *reported.borrow_mut()=Some(facts);
        }
    });
}
unsafe extern "C" {
    fn pthread_main_np()->i32;
    fn probe_attach_view(parent:*mut c_void,child:*mut c_void,w:f32,h:f32)->i32;
    fn probe_detach_view(child:*mut c_void)->i32;
    fn probe_native_register_unity_window(window:*mut c_void)->i32;
    fn probe_native_register_current_unity_window()->i32;
    fn probe_native_unity_content_view()->*mut c_void;
    fn probe_native_geometry_revision()->u64;
    fn probe_native_backing_scale()->f64;
    fn probe_native_host_size(width:*mut f32,height:*mut f32)->i32;
    fn probe_native_sync_geometry()->i32;
    fn probe_native_owns_input()->i32;
    fn probe_native_wake_frames();
    fn probe_native_text_input_focused()->i32;
    fn probe_native_set_panel_expanded(expanded:i32)->i32;
    fn probe_native_set_hit_regions(rects:*const f32,count:i32);
    fn probe_native_normalize_chat_rect(x:f32,y:f32,w:f32,h:f32,nx:*mut f32,ny:*mut f32,nw:*mut f32,nh:*mut f32)->i32;
}
#[unsafe(no_mangle)]
pub extern "C" fn gmgn_overlay_register_unity_window(window:*mut c_void)->i32 { unsafe { probe_native_register_unity_window(window) } }
#[unsafe(no_mangle)]
pub extern "C" fn gmgn_overlay_register_current_unity_window()->i32 { unsafe { probe_native_register_current_unity_window() } }
#[unsafe(no_mangle)]
pub extern "C" fn gmgn_overlay_unity_content_view()->*mut c_void { unsafe { probe_native_unity_content_view() } }
#[unsafe(no_mangle)]
pub extern "C" fn gmgn_overlay_geometry_revision()->u64 { unsafe { probe_native_geometry_revision() } }
#[unsafe(no_mangle)]
pub extern "C" fn gmgn_overlay_backing_scale()->f64 { unsafe { probe_native_backing_scale() } }
#[unsafe(no_mangle)]
pub extern "C" fn gmgn_overlay_owns_input()->i32 { unsafe { probe_native_owns_input() } }
#[unsafe(no_mangle)]
pub extern "C" fn gmgn_overlay_set_panel_expanded(expanded:i32)->i32 { unsafe {probe_native_set_panel_expanded(expanded)} }
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gmgn_overlay_normalize_chat_rect(x:f32,y:f32,w:f32,h:f32,nx:*mut f32,ny:*mut f32,nw:*mut f32,nh:*mut f32)->i32 {
    if nx.is_null()||ny.is_null()||nw.is_null()||nh.is_null() {return 0;}
    unsafe {probe_native_normalize_chat_rect(x,y,w,h,nx,ny,nw,nh)}
}

/// Measured GPUI child bounds only; the native bridge converts actual viewport
/// coordinates to Unity's content view and imports real dragging pasteboard.
pub(crate) fn report_chat_drop_bounds(bounds:Option<Bounds<Pixels>>) {
    CHAT_DROP_BOUNDS.with(|last| {
        if *last.borrow()==bounds {return;}
        let b=bounds.unwrap_or_default();
        let command=json!({"op":"ui.chat.dropRegion","x":b.origin.x.as_f32(),"y":b.origin.y.as_f32(),
            "width":b.size.width.as_f32(),"height":b.size.height.as_f32()});
        if COMMANDS.with(|q|enqueue_ui_command(q,command)) {*last.borrow_mut()=bounds;}
    });
}

/// Only painted interactive UI intercepts the underlying Unity scene.
pub(crate) fn report_ui_hit_bounds(bounds:&[Bounds<Pixels>]) {
    let rects:Vec<f32>=bounds.iter().flat_map(|b|[
        b.origin.x.as_f32(),b.origin.y.as_f32(),
        b.size.width.as_f32(),b.size.height.as_f32(),
    ]).collect();
    trace_hit_regions(&rects);
    unsafe {probe_native_set_hit_regions(rects.as_ptr(),bounds.len() as i32);}
}

/// Ask the Unity host for frames. The startup gate needs this when the host is
/// otherwise idle: a step change (or a retry) must be painted even though no
/// snapshot arrived, and the host only wakes GPUI on its own command traffic.
pub(crate) fn wake_host_frames() { unsafe {probe_native_wake_frames();} }

pub(crate) fn input_diagnostics()->bool {
    std::env::var("GMGN_GPUI_INPUT_DIAGNOSTICS").as_deref()==Ok("1")
}
pub(crate) fn trace_ms()->u128 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d|d.as_millis()).unwrap_or(0)
}

/// The host window owns the viewport, but gpui only learns about a native
/// resize through its platform callback: `set_frame_size` invokes
/// `resize_callback`, which is an `AsyncWindowContext::update` and therefore
/// goes through `try_borrow_mut`. When that borrow cannot be taken the update
/// is dropped and only logged, so the window keeps its old `viewport_size`,
/// its cached layer tiles stay keyed to the old size, and the floating shell
/// is composited at the previous bottom-right corner of a now larger window.
/// Re-assert the real host size from the host's per-frame command poll:
/// change gated on both sides, so a steady frame compares two numbers and
/// touches nothing.
fn reconcile_host_geometry(window:&mut Window,cx:&mut App)->bool {
    let native_changed=unsafe {probe_native_sync_geometry()}==1;
    let (mut width,mut height)=(0f32,0f32);
    if unsafe {probe_native_host_size(&mut width,&mut height)}!=1 {return native_changed;}
    let host=size(px(width),px(height));
    if window.viewport_size()==host {return native_changed;}
    if input_diagnostics() {
        let stale=window.viewport_size();
        eprintln!("[GPUIOverlayTrace] ms={} event=hostViewportStale host={width}x{height} gpui={}x{} nativeChanged={native_changed}",
            trace_ms(),f32::from(stale.width),f32::from(stale.height));
    }
    window.bounds_changed(cx);
    window.refresh();
    true
}

/// Read-only hit-region tracing for `GMGN_GPUI_INPUT_DIAGNOSTICS=1`, change
/// gated so a steady frame prints nothing. It shows what the overlay actually
/// claims to own, which is the same list the native hit test uses.
fn trace_hit_regions(rects:&[f32]) {
    use std::sync::atomic::{AtomicU64, Ordering};
    static LAST: AtomicU64 = AtomicU64::new(u64::MAX);
    if std::env::var("GMGN_GPUI_INPUT_DIAGNOSTICS").as_deref()!=Ok("1") {return;}
    let mut key=rects.len() as u64;
    for value in rects {key=key.rotate_left(5)^(value.to_bits() as u64);}
    if LAST.swap(key,Ordering::Relaxed)==key {return;}
    let ms=std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d|d.as_millis()).unwrap_or(0);
    let first:Vec<String>=rects.chunks(4).take(6).map(|r|format!("({:.0},{:.0},{:.0}x{:.0})",r[0],r[1],r[2],r[3])).collect();
    eprintln!("[GPUIOverlayTrace] ms={ms} event=hitRegions count={} {}",rects.len()/4,first.join(" "));
}

pub(crate) fn select_media_section(section:&str,cx:&mut App) {
    MEDIA.with(|slot| {
        if let Some(media)=slot.borrow().as_ref() {
            media.update(cx,|view,cx|view.select_section(section,cx));
        }
    });
}

/// Collapse the overlay panel from a component that does not own the shell
/// (`inventory_ui.rs` 物品 面板's ×). Deferred by the caller, never called
/// while the shell is rendering. The `ui.overlay.panel` command stays in the
/// queue so the Unity probe still shrinks the native hit region.
pub(crate) fn close_overlay_panel(cx:&mut App) {
    SHELL.with(|slot| {
        if let Some(shell)=slot.borrow().as_ref() {
            shell.update(cx,|view,cx| {view.close_panel_without_window(cx);});
        }
    });
}

/// Host must call on its main thread after registering its NSWindow. Returns -1
/// if a panel is already mounted. The single application runtime remains alive
/// across unmount: native close and foreground callbacks hold weak app handles.
/// The library must remain loaded until host process exit.
#[unsafe(no_mangle)]
pub extern "C" fn gmgn_gpui_probe_mount(parent:*mut c_void)->i32 {
    if parent.is_null() || unsafe { pthread_main_np() } == 0 { return -3; }
    APPLICATION.with(|slot| {
        if MOUNTED.with(|v|!v.borrow().is_null()) { return -1; }
        if slot.borrow().is_none() {
            let app=Application::with_platform(Rc::new(EmbeddedPlatform(gpui_macos::MacPlatform::new(false))))
                .with_assets(gpui_kit::assets::AllAssets);
            let handle=app.run_embedded(|cx| {
                gpui_kit::init(cx);
                Theme::change(ThemeMode::Dark,None,cx);
                register_kit_inputs(cx);
            });
            *slot.borrow_mut()=Some(handle);
        }
        let runtime=slot.borrow();
        let handle=runtime.as_ref().expect("application runtime initialized");
        handle.update(move |cx| {
            let result=cx.open_window(WindowOptions { window_bounds:Some(WindowBounds::Windowed(Bounds::new(point(px(0.),px(0.)),size(px(1280.),px(720.))))), window_background:WindowBackgroundAppearance::Transparent, show:false, focus:false, ..Default::default() },|window,cx| {
                let chat=cx.new(|cx|ResidentChatPane::new(window,cx));
                PANE.with(|v|*v.borrow_mut()=Some(chat.clone()));
                let commands=COMMANDS.with(Clone::clone);
                let inventory=cx.new(|cx|InventoryPane::new(window,cx,commands.clone()));
                INVENTORY.with(|v|*v.borrow_mut()=Some(inventory.clone()));
                let media=cx.new(|cx|MediaPane::new(window,cx,commands.clone()));
                MEDIA.with(|v|*v.borrow_mut()=Some(media.clone()));
                let panes=vec![("聊天".into(),chat.into()),("物品".into(),inventory.into()),
                    ("音乐与空间".into(),media.into())];
                let panel=cx.new(|cx|ShellPane::new(window,cx,commands,panes));
                SHELL.with(|v|*v.borrow_mut()=Some(panel.clone()));
                SNAPSHOT.with(|v|*v.borrow_mut()=Value::Null);
                DERIVED.with(|d|*d.borrow_mut()=None);
                // Match the product's kit root contract: styled component font,
                // window presentation plugin and standard input key context.
                cx.new(|cx|gpui_kit::base::Root::new(panel,window,cx).bg(rgba(0x00000000)))
            });
            // Keep the donor registered in GPUI. Its native NSView is moved, not
            // copied or displayed in an independent transparent overlay window.
            if let Ok(window)=result { DONOR.with(|v|*v.borrow_mut()=Some(window)); let _=window.update(cx,|_,window,_| {
                if let Ok(raw)=HasWindowHandle::window_handle(window) { if let RawWindowHandle::AppKit(h)=raw.as_raw() {
                    if unsafe { probe_attach_view(parent,h.ns_view.as_ptr(),1280.,720.) } == 1 {
                        MOUNTED.with(|v|*v.borrow_mut()=h.ns_view.as_ptr());
                    }
                }}
            }); }
        });
        if MOUNTED.with(|v|v.borrow().is_null()) {
            DONOR.with(|v| { if let Some(window)=v.borrow_mut().take() { handle.update(|cx| { let _=window.update(cx,|_,w,_|w.remove_window()); }); } });
            return -2;
        }
        0
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn gmgn_gpui_probe_unmount() {
    if unsafe { pthread_main_np() } == 0 { return; }
    MOUNTED.with(|v| { let view=v.replace(std::ptr::null_mut()); if !view.is_null() { unsafe { probe_detach_view(view); } } });
    APPLICATION.with(|slot| {
        if let Some(handle)=slot.borrow().as_ref() {
            let settings_window=SETTINGS_WINDOW.with(|v|v.borrow_mut().take());
            if let Some(window)=settings_window { handle.update(|cx| { let _=window.update(cx,|_,w,_|w.remove_window()); }); }
            DONOR.with(|v| { if let Some(window)=v.borrow_mut().take() { handle.update(|cx| { let _=window.update(cx,|_,w,_|w.remove_window()); }); } });
        }
    });
    PANE.with(|v| { v.borrow_mut().take(); });
    INVENTORY.with(|v| { v.borrow_mut().take(); });
    SHELL.with(|v| { v.borrow_mut().take(); });
    SETTINGS.with(|v| { v.borrow_mut().take(); });
    MEDIA.with(|v| { v.borrow_mut().take(); });
    COMMANDS.with(|v|v.borrow_mut().clear());
    CHAT_DROP_BOUNDS.with(|v|v.borrow_mut().take());
    PENDING_REQUEST.with(|v|v.borrow_mut().take());
    VOICE_CURSOR.with(|v|*v.borrow_mut()=VoiceCursor::default());
    INPUTS.with(|v|v.borrow_mut().clear());
    TEXT_INPUT_REPORTED.with(|v|v.borrow_mut().take());
    ESCAPE_CONSUMED.with(|v|*v.borrow_mut()=ConsumedEscape::default());
}

fn with_chat(f:impl FnOnce(&mut ResidentChatPane,&mut Window,&mut Context<ResidentChatPane>))->bool {
    APPLICATION.with(|app|DONOR.with(|donor|PANE.with(|pane| {
        let runtime=app.borrow();
        let (Some(app),Some(donor),Some(pane))=(runtime.as_ref(),*donor.borrow(),pane.borrow().clone()) else {return false};
        app.update(|cx|donor.update(cx,|_,window,cx|pane.update(cx,|pane,cx|f(pane,window,cx))).is_ok())
    })))
}

/// The only top-level envelope keys the overlay renders. Everything else the
/// host publishes — the full `world` snapshot, grid and point-cloud blobs,
/// native physics — is dropped without ever being copied.
const RETAINED_KEYS:[&str;30]=["chat","state","events","chatAttachments","voice","replySpeech",
    "unityInventory","unityWorldAuthority","inventoryMutation","unityUICommandResult",
    "settings","stage","supportedCommands","music","musicLibrary","musicQueue",
    "screenVideo","wish","inbox","worldSelection","selection","activity",
    "spatialPresentation","visualSettingsCommand","uiIntents","notice","locale",
    "builtinDevices","ui","settingsCommandResult"];

/// The overlay's own view of a host envelope: the retained keys and nothing else.
/// The parsed envelope is moved and the rest dropped; rebuilding a second map
/// cloned every retained top-level value on every poll.
pub(crate) fn retained_envelope(mut value:Value)->Option<Value> {
    let Value::Object(ref mut retained)=value else {return None};
    retained.retain(|key,_|RETAINED_KEYS.contains(&key.as_str()));
    Some(value)
}

/// Everything one host poll derives from the envelope it just received, plus the
/// two comparisons that used to re-derive the *previous* envelope to make them.
pub(crate) struct SnapshotStep {
    pub state:Value, pub visual:Value,
    pub changed:bool, pub old_context:Value, pub visual_changed:bool,
}

/// One `normalize_chat` and one `visual_projection` for the incoming envelope;
/// the previous envelope's derivations are passed in, never recomputed. Deriving
/// them here instead cost three `normalize_chat` and two `visual_projection` tree
/// passes per poll on a ~158 KB envelope at 20 Hz, on the Unity main thread.
pub(crate) fn snapshot_step(previous_state:&Value,previous_visual:&Value,value:&Value)->Option<SnapshotStep> {
    let state=normalize_chat(value);
    if !state.is_object() {return None;}
    let visual=visual_projection(value);
    Some(SnapshotStep {changed:*previous_state!=state, old_context:previous_state["contextID"].clone(),
        visual_changed:*previous_visual!=visual, state, visual})
}

/// Reads the accepted envelope's derivations, deriving them from the initial
/// empty snapshot exactly once if no snapshot has been accepted yet.
fn previous_derivations<R>(f:impl FnOnce(&Value,&Value)->R)->R {
    DERIVED.with(|d| {
        let mut d=d.borrow_mut();
        if d.is_none() {*d=Some((normalize_chat(&Value::Null),visual_projection(&Value::Null)));}
        let (state,visual)=d.as_ref().expect("derivations initialised above");
        f(state,visual)
    })
}

/// Records an accepted envelope together with the derivations already made from
/// it, so the next poll compares against them instead of re-deriving this one.
fn accept_snapshot(value:Value,state:Value,visual:Value) {
    DERIVED.with(|d|*d.borrow_mut()=Some((state,visual)));
    SNAPSHOT.with(|v|*v.borrow_mut()=value);
}

fn normalize_chat(value:&Value)->Value {
    NORMALIZE_CALLS.with(|count|count.set(count.get()+1));
    let mut state=value["chat"]["state"].clone();
    if !state.is_object() { state=value["state"].clone(); }
    if !state.is_object() { return Value::Null; }
    let images=&value["chatAttachments"];
    state["attachments"]=Value::Array(images["attachments"].as_array().into_iter().flatten().map(|v|json!({"id":v["id"],"fileName":v["name"],"thumbnailPNG":v["thumbnailPNG"]})).collect());
    state["attachmentsPreparing"]=json!(images["isPreparing"]==true || images["isSelecting"]==true);
    state["attachmentError"]=images["error"].clone();
    state["voiceActive"]=json!(matches!(value["voice"]["state"].as_str(),Some("connecting"|"listening"|"transcribing")));
    state["voiceState"]=value["voice"]["state"].clone();
    state["voiceErrorCode"]=if value["voice"]["state"]=="error" {
        json!(gmgn_gpui_ui::safe_asr_error_code(value["voice"]["errorCode"].as_str()))
    } else {Value::Null};
    state["isSpeaking"]=value["replySpeech"]["isPlaying"].clone();
    state["ttsError"]=value["replySpeech"]["error"].clone();
    state
}

#[derive(Default)]
struct VoiceCursor { context:Option<Value>, revision:u64 }
impl VoiceCursor {
    fn observe(&mut self, context:&Value, voice:&Value)->Option<String> {
        let revision=voice["transcriptRevision"].as_u64()?;
        if self.context.as_ref()!=Some(context) {
            self.context=Some(context.clone()); self.revision=revision; return None;
        }
        if revision<=self.revision {return None;}
        self.revision=revision;
        voice["transcript"].as_str().map(str::trim).filter(|s|!s.is_empty()).map(str::to_owned)
    }
}

/// Only fields actually rendered by the toolbar. Audio frames never invalidate it.
pub(crate) fn shell_projection(value:&Value)->Value {
    let mut music=serde_json::Map::new();
    for key in ["title","isPlaying","volume","canPrevious","canNext","notice","noticeSeverity"] {
        music.insert(key.into(),value["music"][key].clone());
    }
    for key in ["position","duration"] {
        music.insert(key.into(),value["music"][key].as_f64().filter(|v|v.is_finite()).map(|v|json!(v.floor())).unwrap_or(Value::Null));
    }
    let mut ui=value["ui"].as_object().cloned().unwrap_or_default();
    ui.insert("settingsWindowOpen".into(),json!(SETTINGS_WINDOW.with(|v|v.borrow().is_some())));
    json!({"music":music,"ui":ui})
}

fn refresh_shell(cx:&mut App) {
    let snapshot=SNAPSHOT.with(|v|v.borrow().clone());
    let donor=DONOR.with(|v|*v.borrow());
    let shell=SHELL.with(|v|v.borrow().clone());
    if let (Some(donor),Some(shell))=(donor,shell) {
        let _=donor.update(cx,|_,window,cx|shell.update(cx,|view,cx|view.update_snapshot(&snapshot,window,cx)));
    }
}

fn open_settings_window(cx:&mut App) {
    let existing=SETTINGS_WINDOW.with(|v|*v.borrow());
    if let Some(handle)=existing {
        // `settings.open.presence` on an already-open window: focus it and land
        // on 角色管理 through the pane's own `select_page` (the navigation the
        // original `openPresenceSettings()` performs).
        if settings_ui::take_pending_presence_page() {
            let settings=SETTINGS.with(|v|v.borrow().clone());
            if let Some(settings)=settings {
                let _=handle.update(cx,|_,window,cx| {
                    settings.update(cx,|view,cx| {view.select_presence_page(window,cx);});
                    window.activate_window();
                });
            }
        }
        if handle.update(cx,|_,window,_|window.activate_window()).is_ok() {return;}
        SETTINGS_WINDOW.with(|v|v.borrow_mut().take());
    }
    let commands=COMMANDS.with(Clone::clone);
    let snapshot=SNAPSHOT.with(|v|v.borrow().clone());
    let presence_page=settings_ui::take_pending_presence_page();
    let result=cx.open_window(WindowOptions {
        window_bounds:Some(WindowBounds::Windowed(Bounds::centered(None,size(px(860.),px(700.)),cx))),
        window_min_size:Some(size(px(760.),px(540.))),
        titlebar:Some(TitlebarOptions {title:Some("设置".into()),..Default::default()}),
        show:true,focus:true,..Default::default()
    },|window,cx| {
        let settings=cx.new(|cx|SettingsPane::new(window,cx,commands));
        settings.update(cx,|view,cx| {
            view.update_snapshot(&snapshot,window,cx);
            if presence_page {view.select_presence_page(window,cx);}
        });
        SETTINGS.with(|v|*v.borrow_mut()=Some(settings.clone()));
        window.on_window_should_close(cx,|window,cx| {
            let snapshot=SNAPSHOT.with(|v|v.borrow().clone());
            let settings=SETTINGS.with(|v|v.borrow().clone());
            if let Some(settings)=settings {
                let can_close=settings.update(cx,|view,cx| {
                    view.update_snapshot(&snapshot,window,cx);
                    view.can_close(cx)
                });
                if !can_close {return false;}
            }
            SETTINGS_WINDOW.with(|v|v.borrow_mut().take());
            cx.defer(refresh_shell);
            unsafe {probe_native_wake_frames();}
            true
        });
        cx.new(|cx|gpui_kit::base::Root::new(settings,window,cx))
    });
    if let Ok(handle)=result {
        SETTINGS_WINDOW.with(|v|*v.borrow_mut()=Some(handle));
        refresh_shell(cx);
    }
}
fn visual_projection(value:&Value)->Value {
    VISUAL_CALLS.with(|count|count.set(count.get()+1));
    let screens:Vec<_>=value["screenVideo"]["screens"].as_array().into_iter().flatten()
        .map(|s|json!({"objectID":s["objectID"],"name":s["name"],"state":s["state"]})).collect();
    let mut result=json!({"shell":shell_projection(value),"screens":screens,
        "screenNotice":value["screenVideo"]["commandNotice"],"queue":value["music"]["queue"],
        "queueIndex":value["music"]["queueIndex"],"world":value["world"]});
    result["settings"]=settings_projection(&value["settings"]);
    for key in ["settingsCommandResult","musicLibrary","musicQueue","wish","inbox"] {
        result[key]=value[key].clone();
    }
    result
}
pub(crate) fn settings_projection(envelope:&Value)->Value {
    // Everything the overlay's settings adapter reads, at the single root it
    // reads it from: the settings dictionary (which the panes render), `stage`
    // (the stage surface the StagePanelsPane renders), `characterPosition` (the
    // CAS revisions + pose `presence.position` needs), `spaceLibrary` (the world
    // package ids `stage.world.enter` must name), `presence.motions` (the motion
    // ids `stage.motion.activate` must name), `generation` (the saved
    // configuration `space.prop.save`/`check` gate on) and the whitelist the
    // panes gate their controls on. A focused copy, not the whole envelope: this
    // value is compared on every poll.
    //
    // The host envelope (`UnityMediaHost.settingsSnapshot`) nests all of those
    // **inside** the dictionary it publishes as `settings`: on the wire the
    // settings dictionary is `settings.settings`, the stage is
    // `settings.settings.stage` and only `supportedCommands` sits beside it. So
    // `envelope["stage"]`, `envelope["presence"]`, `envelope["spaceLibrary"]`,
    // `envelope["characterPosition"]` and `envelope["generation"]` are all null
    // — reading them made the StagePanelsPane render an empty stage and refused
    // seven stage ops inside the window (2026-10-09). Every field below is read
    // from the dictionary, never from the envelope root.
    let settings=&envelope["settings"];
    let presence=&settings["presence"];
    json!({"settings":settings,"stage":settings["stage"],
        "characterPosition":settings["characterPosition"],
        "spaceLibrary":settings["spaceLibrary"],
        "generation":settings["generation"],
        "presence":{"motions":presence["motions"],"activeMotionID":presence["activeMotionID"],
            "working":presence["working"],"notice":presence["notice"],"hasError":presence["hasError"]},
        "supportedCommands":envelope["supportedCommands"]})
}

fn translate_command(command:ChatCommand,snapshot:&Value)->Option<Value> {
    Some(match command {
        ChatCommand::Send{request_id,text,attachment_ids}=> {
            let mut value=json!({"op":"chat.send","requestID":request_id,"text":text});
            if !attachment_ids.is_empty() {
                value["attachmentIDs"]=json!(attachment_ids);
                value["attachmentGeneration"]=snapshot["chatAttachments"]["generation"].clone();
            }
            value
        }
        ChatCommand::Cancel{request_id}=>json!({"op":"chat.cancel","requestID":request_id}),
        ChatCommand::PickAttachments=>json!({"op":"chat.attachments.pick"}),
        ChatCommand::PasteAttachments=>json!({"op":"chat.attachments.paste"}),
        ChatCommand::RemoveAttachment{id}=>json!({"op":"chat.attachments.remove","id":id}),
        ChatCommand::BeginVoice=>json!({"op":"voice.press"}),
        ChatCommand::FinishVoice=>json!({"op":"voice.release"}),
        ChatCommand::StopSpeech=>json!({"op":"tts.stop"}),
        ChatCommand::StopTask=> {
            let id=PENDING_REQUEST.with(|v|*v.borrow())?;
            json!({"op":"chat.cancel","requestID":id})
        }
        ChatCommand::FocusInput=>return None,
        // File picker/drop is native-only. Never accept arbitrary paths from UI/model.
        ChatCommand::ImportAttachments{..}=>return None,
    })
}

/// Receives the existing single host poll, including events. No second poll.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gmgn_gpui_chat_snapshot(bytes:*const u8,len:usize)->i32 {
    if unsafe { pthread_main_np() }==0 || bytes.is_null() || len==0 || len>4*1024*1024 {return -1;}
    let Ok(value)=serde_json::from_slice::<Value>(unsafe {std::slice::from_raw_parts(bytes,len)}) else {return -1};
    // Retain only UI projections, not full world/grid blobs or native physics.
    let Some(mut value)=retained_envelope(value) else {return -1};
    value["world"]=json!({"worldID":value["unityWorldAuthority"]["state"]["worldID"]});
    let Some(step)=previous_derivations(|previous_state,previous_visual|snapshot_step(previous_state,previous_visual,&value)) else {return -1;};
    let SnapshotStep {state,visual,changed,old_context,visual_changed}=step;
    let events=value["chat"]["events"].as_array().or_else(||value["events"].as_array()).cloned().unwrap_or_default();
    let has_events=!events.is_empty();
    let inventory_changed=SNAPSHOT.with(|v| {
        let old=v.borrow();["unityInventory","unityWorldAuthority","inventoryMutation","unityUICommandResult"].iter().any(|key|old[*key]!=value[*key])
    });
    let new_ui_receipt=SNAPSHOT.with(|v|v.borrow()["unityUICommandResult"]!=value["unityUICommandResult"]);
    let placement_started=new_ui_receipt && value["unityUICommandResult"]["status"]=="started"
        && matches!(value["unityUICommandResult"]["op"].as_str(),Some("ui.inventory.place"|"ui.device.place"));
    let context_changed=!old_context.is_null() && old_context!=state["contextID"];
    let voice_text=VOICE_CURSOR.with(|v|v.borrow_mut().observe(&state["contextID"],&value["voice"]));
    let applied=with_chat(|pane,window,cx| {
        if context_changed {pane.reset_context(window,cx);}
        if let Some(text)=&voice_text {pane.append_voice_transcript(text,window,cx);pane.focus_composer(window,cx);}
        for event in events {
            let Some(id)=event["requestID"].as_u64() else {continue};
            match event["kind"].as_str().unwrap_or("") {
                "accepted"=>pane.accepted(id,window,cx),
                "delta"|"progress"=>pane.progress(id,event["text"].as_str().unwrap_or("").into(),cx),
                "reply"=>pane.reply(id,event["text"].as_str().unwrap_or("").into(),cx),
                "completed"=>pane.complete_without_reply(id,cx),
                "failure"|"cancelled"=>pane.failed(id,event["message"].as_str().unwrap_or("本次回复未完成。").into(),window,cx),
                _=>{}
            }
            if matches!(event["kind"].as_str(),Some("reply"|"completed"|"failure"|"cancelled")) {
                PENDING_REQUEST.with(|v| {if *v.borrow()==Some(id) {v.borrow_mut().take();}});
            }
        }
        if changed {
            let transcript=state["transcript"].as_array().into_iter().flatten().filter_map(|line| {
                Some(TranscriptLine {speaker:match line["role"].as_str()? {"user"=>"你","agent"=>"居民","notice"=>"系统",_=>return None}.into(),text:line["text"].as_str()?.into()})
            }).collect();
            pane.set_transcript(transcript,cx);
            pane.update_snapshot(state.clone(),cx);
            window.refresh();
        }
    });
    if inventory_changed { APPLICATION.with(|app|DONOR.with(|donor|INVENTORY.with(|inventory| {
        let runtime=app.borrow();
        if let (Some(app),Some(donor),Some(inventory))=(runtime.as_ref(),*donor.borrow(),inventory.borrow().clone()) {
            app.update(|cx| {let _=donor.update(cx,|_,_,cx|inventory.update(cx,|v,cx|v.update_snapshot(&value,cx)));});
        }
    }))); }
    APPLICATION.with(|app|DONOR.with(|donor| {
        let runtime=app.borrow();
        if let (Some(app),Some(donor))=(runtime.as_ref(),*donor.borrow()) {
            app.update(|cx| {let _=donor.update(cx,|_,window,cx| {
                MEDIA.with(|v| {if let Some(view)=v.borrow().as_ref() {view.update(cx,|v,cx|v.update_snapshot(&value,window,cx));}});
                SHELL.with(|v| {if let Some(view)=v.borrow().as_ref() {view.update(cx,|v,cx| {
                    v.update_snapshot(&value,window,cx);
                    if placement_started {v.close_panel(window,cx);}
                    if voice_text.is_some() {v.open_panel("聊天",window,cx);}
                });}});
            });});
        }
    }));
    APPLICATION.with(|app| {
        if let Some(app)=app.borrow().as_ref() {
            let handle=SETTINGS_WINDOW.with(|v|*v.borrow());
            let settings=SETTINGS.with(|v|v.borrow().clone());
            if let (Some(handle),Some(settings))=(handle,settings) {
                app.update(|cx| {let _=handle.update(cx,|_,window,cx|settings.update(cx,|view,cx| {
                    if view.update_snapshot(&value,window,cx) {view.select_presence_page(window,cx);}
                }));});
            }
        }
    });
    accept_snapshot(value,state,visual);
    if applied { if changed || has_events || inventory_changed || visual_changed || voice_text.is_some() {unsafe {probe_native_wake_frames();}} 0 } else {-2}
}

fn navigation_command(bytes:&[u8])->Option<Value> {
    if bytes.is_empty() || bytes.len()>4096 {return None;}
    let value:Value=serde_json::from_slice(bytes).ok()?;
    if value.as_object()?.len()!=1 || !matches!(value["op"].as_str(),Some("ui.chat.open"|"ui.settings.open"|"ui.wish.open"|"ui.music.open")) {return None;}
    Some(value)
}
/// Trusted native UI navigation only; this is not a general command endpoint.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gmgn_gpui_ui_command(bytes:*const u8,len:usize)->i32 {
    if unsafe {pthread_main_np()}==0 || bytes.is_null() || MOUNTED.with(|v|v.borrow().is_null()) || len>4096 {return -1;}
    let Some(value)=navigation_command(unsafe {std::slice::from_raw_parts(bytes,len)}) else {return -1;};
    if COMMANDS.with(|q|enqueue_ui_command(q,value)) {unsafe {probe_native_wake_frames();} 0} else {-2}
}

/// UI command transport only. Negative return is required capacity, no dequeue.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gmgn_gpui_chat_take_command(out:*mut u8,capacity:usize)->isize {
    if unsafe {pthread_main_np()}==0 {return -1;}
    let snapshot=SNAPSHOT.with(|v|v.borrow().clone());
    with_chat(|pane,window,cx| {
        for command in pane.take_commands() {
            let Some(value)=translate_command(command,&snapshot) else {continue};
            let enqueued=COMMANDS.with(|v| {let mut q=v.borrow_mut();if q.len()>=32 {false} else {q.push_back(value.clone());true}});
            if enqueued && value["op"]=="chat.send" {PENDING_REQUEST.with(|v|*v.borrow_mut()=value["requestID"].as_u64());}
            if !enqueued {if let Some(id)=value["requestID"].as_u64() {pane.failed(id,"发送队列已满，文字已保留。".into(),window,cx);}}
        }
    });
    APPLICATION.with(|app|DONOR.with(|donor| {
        if let (Some(app),Some(donor))=(app.borrow().as_ref(),*donor.borrow()) {
            app.update(|cx| {let _=donor.update(cx,|_,window,cx| {
                if reconcile_host_geometry(window,cx) {unsafe {probe_native_wake_frames();}}
                report_kit_text_input(window,cx);
            });});
        }
    }));
    // These requests are local GPUI navigation, never unsupported host tools.
    // Release the queue borrow before entering GPUI; opening emits the real
    // native viewport intent through the same bounded transport.
    loop {
        let navigation=COMMANDS.with(|q| {
            let mut q=q.borrow_mut();
            if q.front().is_some_and(|v|matches!(v["op"].as_str(),Some("ui.chat.open"|"ui.settings.open"|"ui.wish.open"|"ui.music.open"))) {q.pop_front()} else {None}
        });
        let Some(navigation)=navigation else {break;};
        if navigation["op"]=="ui.settings.open" {
            APPLICATION.with(|app|if let Some(app)=app.borrow().as_ref() {app.update(open_settings_window);});
            continue;
        }
        let label=match navigation["op"].as_str() {Some("ui.settings.open")=>"设置",Some("ui.wish.open"|"ui.music.open")=>"音乐与空间",_=>"聊天"};
        APPLICATION.with(|app|DONOR.with(|donor|SHELL.with(|shell| {
            let runtime=app.borrow();
            if let (Some(app),Some(donor),Some(shell))=(runtime.as_ref(),*donor.borrow(),shell.borrow().as_ref()) {
                app.update(|cx|{let _=donor.update(cx,|_,window,cx| {
                    if let Some(section)=match navigation["op"].as_str() {Some("ui.wish.open")=>Some("wish"),Some("ui.music.open")=>Some("library"),_=>None} {
                        MEDIA.with(|v|if let Some(media)=v.borrow().as_ref() {media.update(cx,|v,cx|v.select_section(section,cx));});
                    }
                    shell.update(cx,|v,cx|v.open_panel(label,window,cx));
                });});
            }
        })));
    }
    COMMANDS.with(|v| {
        let mut q=v.borrow_mut();let Some(value)=q.front() else {return 0};
        let Ok(bytes)=serde_json::to_vec(value) else {return -1};
        if out.is_null() || capacity<bytes.len() {return -(bytes.len() as isize);}
        unsafe {std::ptr::copy_nonoverlapping(bytes.as_ptr(),out,bytes.len());}
        q.pop_front(); bytes.len() as isize
    })
}

#[cfg(test)]
mod chat_transport_tests {
    use super::*;
    use core::prelude::v1::test;
    #[test]
    fn native_asr_failure_projects_safe_code_and_new_attempt_clears_it() {
        let host=json!({"chat":{"state":{"contextID":"a"}},"voice":{"state":"error","errorCode":"asr_timeout"}});
        let error=normalize_chat(&host);
        assert_eq!(error["voiceState"],"error");
        assert_eq!(error["voiceErrorCode"],"asr_timeout");
        assert_eq!(error["voiceActive"],false);
        let mut next=host.clone();next["voice"]["state"]=json!("connecting");
        assert!(normalize_chat(&next)["voiceErrorCode"].is_null());
        next["voice"]["state"]=json!("idle");
        assert!(normalize_chat(&next)["voiceErrorCode"].is_null());
        next["voice"]["state"]=json!("error");
        next["voice"]["errorCode"]=json!("private token=secret");
        assert_eq!(normalize_chat(&next)["voiceErrorCode"],"asr_failed");
    }
    #[test]
    fn native_navigation_cannot_inject_business_commands() {
        assert_eq!(navigation_command(br#"{"op":"ui.chat.open"}"#),Some(json!({"op":"ui.chat.open"})));
        assert!(navigation_command(br#"{"op":"ui.settings.open"}"#).is_some());
        assert!(navigation_command(br#"{"op":"ui.wish.open"}"#).is_some());
        assert!(navigation_command(br#"{"op":"ui.music.open"}"#).is_some());
        assert!(navigation_command(br#"{"op":"chat.send","text":"injected"}"#).is_none());
        assert!(navigation_command(br#"{"op":"ui.chat.open","command":{}}"#).is_none());
        assert!(navigation_command(&[b' ';4097]).is_none());
        assert!(navigation_command(&[0xff]).is_none());
    }
    #[test]
    fn panel_escape_fact_is_consumed_once_not_a_fixed_gate() {
        let mut event=ConsumedEscape::default();
        assert!(!event.take());
        event.record();
        assert!(event.take());
        assert!(!event.take());
        event.record();
        assert!(event.take());
        assert!(!event.take());
    }
    #[test]
    fn voice_revision_is_once_per_context_and_mount_baseline() {
        let mut cursor=VoiceCursor::default();
        let voice=|revision,text|json!({"transcriptRevision":revision,"transcript":text});
        assert_eq!(cursor.observe(&json!("a"),&voice(4,"旧文本")),None);
        assert_eq!(cursor.observe(&json!("a"),&voice(5,"新文本")),Some("新文本".into()));
        assert_eq!(cursor.observe(&json!("a"),&voice(5,"新文本")),None);
        assert_eq!(cursor.observe(&json!("a"),&voice(3,"迟到")),None);
        assert_eq!(cursor.observe(&json!("b"),&voice(5,"新文本")),None);
        assert_eq!(cursor.observe(&json!("b"),&voice(6,"  ")),None);
        assert_eq!(cursor.observe(&json!("b"),&voice(7,"第二句")),Some("第二句".into()));
        let mut remounted=VoiceCursor::default();
        assert_eq!(remounted.observe(&json!("b"),&voice(7,"第二句")),None);
    }
    #[test]
    fn visual_progress_wakes_but_audio_and_scene_frames_do_not() {
        let original=json!({"music":{"position":1.1,"duration":60,"features":[0.1]},
            "screenVideo":{"screens":[{"objectID":"tv","name":"电视","state":"playing","audioFeatures":[1]}]},
            "pointCloud":[1],"lines":[1]});
        let mut next=original.clone();
        next["music"]["features"]=json!([0.8]);
        next["screenVideo"]["screens"][0]["audioFeatures"]=json!([2]);
        next["pointCloud"]=json!([2]);next["lines"]=json!([2]);
        next["music"]["position"]=json!(1.8);
        assert_eq!(visual_projection(&original),visual_projection(&next));
        next["music"]["position"]=json!(2.0);
        assert_ne!(visual_projection(&original),visual_projection(&next));
        next=original.clone();next["settings"]=json!({"settings":{"saveRevision":2}});
        assert_ne!(visual_projection(&original),visual_projection(&next));
        let mut diagnostics=original.clone();
        diagnostics["settings"]=json!({"runtimeDiagnostics":{"frame":999}});
        assert_eq!(visual_projection(&original),visual_projection(&diagnostics));
        // Real envelope nesting: the stage lives inside the settings dictionary
        // the host publishes as `settings` (`settings.settings.stage`).
        diagnostics["settings"]=json!({"settings":{"stage":{"player":{"lyricID":"dots"}}}});
        assert_ne!(visual_projection(&original),visual_projection(&diagnostics));
        diagnostics["settings"]=json!({"supportedCommands":["tts.stop"]});
        assert_ne!(visual_projection(&original),visual_projection(&diagnostics));
    }
    #[test]
    fn attachment_thumbnail_mapping_keeps_native_id_and_inline_bytes() {
        let state=normalize_chat(&json!({"chat":{"state":{}},"chatAttachments":{"attachments":[
            {"id":"native-id","name":"图片.png","thumbnailPNG":"native-inline-png"}]}}));
        assert_eq!(state["attachments"][0]["id"],"native-id");
        assert_eq!(state["attachments"][0]["thumbnailPNG"],"native-inline-png");
        assert!(state["attachments"][0]["previewPath"].is_null());
    }
    #[test]
    fn raw_host_projection_preserves_history_and_attachment_generation() {
        let raw=json!({"chat":{"state":{"contextID":"world-a","transcript":[{"role":"agent","text":"真实历史"}],"isThinking":true}},
            "chatAttachments":{"generation":19,"attachments":[{"id":"native-image","name":"照片"}],"isPreparing":true},
            "voice":{"state":"listening"},"replySpeech":{"isPlaying":true}});
        let state=normalize_chat(&raw);
        assert_eq!(state["transcript"],raw["chat"]["state"]["transcript"]);
        assert_eq!(state["attachments"][0]["fileName"],"照片");
        assert_eq!(state["attachmentsPreparing"],true);
        assert_eq!(state["voiceActive"],true);
        assert_eq!(state["isSpeaking"],true);
        let cmd=translate_command(ChatCommand::Send{request_id:4,text:"消息".into(),attachment_ids:vec!["native-image".into()]},&raw).unwrap();
        assert_eq!(cmd["requestID"],4);
        assert_eq!(cmd["attachmentGeneration"],19);
    }
    #[test]
    fn text_only_send_does_not_claim_an_image_generation() {
        let cmd=translate_command(ChatCommand::Send{request_id:2,text:"text".into(),attachment_ids:vec![]},&Value::Null).unwrap();
        assert!(cmd.get("attachmentIDs").is_none());
        assert!(cmd.get("attachmentGeneration").is_none());
        // Real external drops use the measured native NSDragging destination.
        // Paths alone never constitute a user-drag authorization.
        assert!(translate_command(ChatCommand::ImportAttachments{paths:vec!["/arbitrary".into()]},&Value::Null).is_none());
    }
    #[test]
    fn host_viewport_is_reasserted_from_the_poll_and_stays_change_gated() {
        // Real defect: after a fullscreen toggle the native viewport was
        // already 2048×1152 while gpui's window still reported 720×450, so the
        // floating shell stayed at the old bottom-right corner. The native
        // resize notification alone is not enough, so the host poll has to
        // re-assert the size into gpui's window state — and only on a change.
        let host=include_str!("../host/OverlayHost.m");
        let sync=host.split("int32_t probe_native_sync_geometry(void) {").nth(1)
            .expect("host viewport sync entry point");
        let sync=sync.split("\nint32_t probe_native_set_panel_expanded").next().unwrap();
        for applied in ["container.frame.size","donorWindow.contentView.frame.size","mountedView.frame.size"] {
            assert!(sync.contains(&format!("NSEqualSizes(host, {applied})")),
                "sync must leave every applied view alone when it already matches ({applied})");
        }
        assert_eq!(sync.matches("updateGeometry();").count(),1,
            "sync must resize only when something actually differs");

        let lib=include_str!("lib.rs");
        // Cut the test module off: this test's own source must never satisfy it.
        let code=lib.split("\n#[cfg(test)]").next().expect("library source before tests");
        let reconcile=code.split("fn reconcile_host_geometry(").nth(1)
            .expect("viewport reconcile");
        let reconcile=reconcile.split("\npub(crate) fn select_media_section").next().unwrap();
        assert!(reconcile.contains("if window.viewport_size()==host {return native_changed;}"),
            "a steady viewport must not be pushed again");
        assert!(reconcile.contains("window.bounds_changed(cx);"),
            "gpui's cached viewport must be updated from the real host size");
        assert!(reconcile.contains("window.refresh();"),
            "the window must be marked dirty so the shell re-lays out");
        let poll=code.split("pub unsafe extern \"C\" fn gmgn_gpui_chat_take_command").nth(1)
            .expect("per frame host poll");
        assert!(poll.contains("if reconcile_host_geometry(window,cx) {unsafe {probe_native_wake_frames();}}"),
            "the host poll must reconcile the viewport every frame it is called");
    }
    #[test]
    fn platform_never_delegates_application_credentials_to_keychain() {
        let source=include_str!("lib.rs");
        let delegation=source.split("forward! {").nth(1).unwrap().split("fn write_credentials").next().unwrap();
        for name in ["write_credentials","read_credentials","delete_credentials"] {
            assert!(!delegation.contains(name),"credential hook must not enter platform delegation");
            assert!(!source.contains(&format!("self.0.{name}(")),"direct Mac credential call forbidden");
        }
        assert_eq!(source.matches("Task::ready(Err(anyhow::anyhow!(\"platform_credentials_disabled\")))").count(),3);
    }
    #[test]
    fn one_poll_derives_the_state_and_the_visual_projection_exactly_once() {
        let previous=json!({"chat":{"state":{"contextID":"world-a","transcript":[{"role":"user","text":"旧"}]}}});
        let value=json!({"chat":{"state":{"contextID":"world-a","transcript":[{"role":"user","text":"新"}]}},
            "chatAttachments":{"attachments":[]},"voice":{"state":"idle"},"replySpeech":{"isPlaying":false},
            "music":{"position":3,"queue":[]},"screenVideo":{"screens":[]},"settings":{},
            "world":{"worldID":"world-a"},"unityWorldAuthority":{"state":{"worldID":"world-a"}}});
        let previous_state=normalize_chat(&previous);
        let previous_visual=visual_projection(&previous);
        let normal_before=NORMALIZE_CALLS.with(Cell::get);
        let visual_before=VISUAL_CALLS.with(Cell::get);
        let step=snapshot_step(&previous_state,&previous_visual,&value).expect("an object chat state");
        assert_eq!(NORMALIZE_CALLS.with(Cell::get)-normal_before,1,
            "one poll must normalize the chat state once, not once per comparison");
        assert_eq!(VISUAL_CALLS.with(Cell::get)-visual_before,1,
            "one poll must build the visual projection once, not once per side");
        assert!(step.changed,"a changed transcript is a changed snapshot");
        assert_eq!(step.old_context,"world-a","the comparison still reads the previous context");
        assert_eq!(step.state,normalize_chat(&value),"the step hands back the real state");
        assert_eq!(step.visual,visual_projection(&value),"the step hands back the real projection");
    }
    #[test]
    fn the_poll_never_rederives_or_reclones_the_previous_envelope() {
        let lib=include_str!("lib.rs");
        // Cut the test module off: this test's own source must never satisfy it.
        let code=lib.split("\n#[cfg(test)]").next().expect("library source before tests");
        let poll=code.split("pub unsafe extern \"C\" fn gmgn_gpui_chat_snapshot").nth(1)
            .expect("per poll host snapshot");
        let poll=poll.split("\nfn navigation_command").next().unwrap();
        assert!(!poll.contains("normalize_chat("),
            "the poll must take the state from snapshot_step, never re-derive it");
        assert!(!poll.contains("visual_projection("),
            "the poll must take the visual projection from snapshot_step, never re-derive it");
        assert!(poll.contains("snapshot_step("),"the poll derives through the one-step helper");
        assert_eq!(poll.matches("previous_derivations(").count(),1,
            "the previous envelope's derivations are read once, from the cache");
        let step=code.split("pub(crate) fn snapshot_step").nth(1).expect("snapshot step");
        let step=step.split("\n}").next().unwrap();
        assert_eq!(step.matches("normalize_chat(").count(),1,"one state derivation per step");
        assert_eq!(step.matches("visual_projection(").count(),1,"one visual derivation per step");
        assert!(poll.contains("retained_envelope("),
            "the poll keeps the parsed envelope and drops the rest");
        assert!(!poll.contains("value.clone()"),
            "retained keys must move out of the parsed envelope, never be cloned");
        let retain=code.split("pub(crate) fn retained_envelope").nth(1).expect("retained envelope");
        let retain=retain.split("\n}").next().unwrap();
        assert!(retain.contains("retained.retain(|key,_|RETAINED_KEYS.contains(&key.as_str()))"),
            "the retained envelope moves the parsed map and drops the rest");
        assert!(!retain.contains("value.clone()"),
            "the retained envelope must move the parsed map, never clone its values");
    }
    #[test]
    fn retained_envelope_keeps_the_ui_keys_and_drops_the_rest() {
        let raw=json!({"chat":{"state":{"contextID":"w"}},"music":{"title":"x"},
            "settings":{"settings":{}},"builtinDevices":{"templates":[]},
            "world":{"triangles":[[[0,0,0]]],"generation":9},
            "runtimeDiagnostics":{"frame":1},"heldAvatarBindingNotice":"x"});
        // The pre-fix shape: a fresh map that cloned every retained value.
        let mut reference=serde_json::Map::new();
        for key in RETAINED_KEYS {
            if let Some(value)=raw.get(key) {reference.insert(key.into(),value.clone());}
        }
        assert_eq!(retained_envelope(raw.clone()),Some(Value::Object(reference)),
            "the retained envelope is exactly the old key list, value for value");
        let got=retained_envelope(raw).expect("an object envelope");
        assert!(got.get("runtimeDiagnostics").is_none(),"host diagnostics are not a UI projection");
        assert!(got.get("heldAvatarBindingNotice").is_none(),"world services are not a UI projection");
        assert!(got.get("world").is_none(),
            "the host's full world/grid blob is dropped, never copied; the poll rebuilds a \
             one-key world from unityWorldAuthority.state.worldID instead");
        assert_eq!(retained_envelope(json!([1,2])),None,"a non-object envelope is refused");
    }
}
