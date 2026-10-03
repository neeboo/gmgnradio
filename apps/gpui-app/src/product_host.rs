use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::path::PathBuf;

type Create = unsafe extern "C" fn() -> *mut c_void;
type Lifecycle = unsafe extern "C" fn(*mut c_void) -> c_int;
type Action = unsafe extern "C" fn(*mut c_void, *const c_char) -> c_int;
type Cancel = unsafe extern "C" fn(*mut c_void, u64) -> c_int;
type Poll = unsafe extern "C" fn(*mut c_void) -> *mut c_char;
type Free = unsafe extern "C" fn(*mut c_char);
type Attach = unsafe extern "C" fn(*mut c_void, *mut c_void, c_int) -> c_int;
type Visibility = unsafe extern "C" fn(*mut c_void, c_int, c_int) -> c_int;
type Reopen = unsafe extern "C" fn(*mut c_void, c_int) -> c_int;

unsafe extern "C" {
    fn dlopen(path: *const c_char, flags: c_int) -> *mut c_void;
    fn dlsym(handle: *mut c_void, name: *const c_char) -> *mut c_void;
    fn gmgn_gpui_surface_container(view: *mut c_void, compact: c_int) -> *mut c_void;
    fn gmgn_gpui_window_visible(view: *mut c_void) -> c_int;
    fn gmgn_gpui_has_visible_windows() -> c_int;
    fn gmgn_gpui_hit_regions(view:*mut c_void,regions:*const f64,count:usize);
    fn gmgn_gpui_set_outer_size(view:*mut c_void,width:f64,height:f64,min_width:f64,min_height:f64)->c_int;
}

pub fn set_window_outer_size(view:*mut c_void,width:f64,height:f64,min_width:f64,min_height:f64)->bool {
    unsafe {gmgn_gpui_set_outer_size(view,width,height,min_width,min_height)!=0}
}

/// Lives only on the GPUI/AppKit main thread. The dylib stays loaded until
/// process exit so asynchronous Swift cleanup can finish after shutdown.
pub struct ProductHost {
    handle: *mut c_void,
    shutdown: Lifecycle,
    destroy: Lifecycle,
    action: Action,
    settings_command: Action,
    cancel: Cancel,
    poll: Poll,
    free: Free,
    attach: Attach,
    visibility: Visibility,
    reopen: Reopen,
    view: *mut c_void,
}

impl ProductHost {
    pub fn load() -> Result<Self, String> {
        let executable = std::env::current_exe().map_err(|_| "无法定位应用目录")?;
        let contents = executable.parent().and_then(|p| p.parent()).ok_or("应用目录不完整")?;
        let path: PathBuf = contents.join("Frameworks/GPUIProductHost.dylib");
        let path = CString::new(path.to_string_lossy().as_bytes()).map_err(|_| "应用路径无效")?;
        unsafe {
            let library = dlopen(path.as_ptr(), 2);
            if library.is_null() { return Err("真实应用核心未能加载，请检查产品构建。".into()); }
            macro_rules! symbol {
                ($name:literal, $type:ty) => {{
                    let pointer = dlsym(library, concat!($name, "\0").as_ptr().cast());
                    if pointer.is_null() { return Err(concat!("应用核心缺少接口：", $name).into()); }
                    std::mem::transmute::<*mut c_void, $type>(pointer)
                }};
            }
            let create = symbol!("gmgn_product_host_create", Create);
            let start = symbol!("gmgn_product_host_start", Lifecycle);
            let mut host = Self {
                handle: std::ptr::null_mut(),
                shutdown: symbol!("gmgn_product_host_shutdown", Lifecycle),
                destroy: symbol!("gmgn_product_host_destroy", Lifecycle),
                action: symbol!("gmgn_product_host_action", Action),
                settings_command: symbol!("gmgn_product_host_settings_command", Action),
                cancel: symbol!("gmgn_product_host_chat_cancel", Cancel),
                poll: symbol!("gmgn_product_host_chat_poll", Poll),
                free: symbol!("gmgn_product_host_string_free", Free),
                attach: symbol!("gmgn_product_host_attach_surface", Attach),
                visibility: symbol!("gmgn_product_host_surface_visibility", Visibility),
                reopen: symbol!("gmgn_product_host_reopen", Reopen),
                view: std::ptr::null_mut(),
            };
            host.handle = create();
            if host.handle.is_null() { return Err("真实应用核心初始化失败。".into()); }
            if start(host.handle) == 0 { host.close(); return Err("真实应用启动未完成。".into()); }
            Ok(host)
        }
    }
    pub fn cancel(&self, id: u64) -> bool { unsafe { (self.cancel)(self.handle, id) != 0 } }
    pub fn action(&self, action: &str) -> bool {
        CString::new(action).is_ok_and(|action| unsafe { (self.action)(self.handle, action.as_ptr()) != 0 })
    }
    pub fn poll(&self) -> Result<Vec<u8>, ()> {
        unsafe {
            let pointer = (self.poll)(self.handle);
            if pointer.is_null() { return Err(()); }
            let bytes = CStr::from_ptr(pointer).to_bytes().to_vec();
            (self.free)(pointer);
            Ok(bytes)
        }
    }
    pub fn settings_command(&self, value: &serde_json::Value) -> bool {
        CString::new(value.to_string()).is_ok_and(|command| unsafe { (self.settings_command)(self.handle, command.as_ptr()) != 0 })
    }
    pub fn mount(&mut self, view: *mut c_void, compact: bool) -> bool {
        unsafe {
            let container = gmgn_gpui_surface_container(view, compact as c_int);
            if container.is_null() { return false; }
            self.view = view;
            (self.attach)(self.handle, container, (!compact) as c_int) != 0
        }
    }
    pub fn update_visibility(&self) {
        if !self.view.is_null() { unsafe { (self.visibility)(self.handle, gmgn_gpui_window_visible(self.view), 0); } }
    }
    pub fn clear_window_reference(&mut self) {
        // The real renderer remains owned by Swift until the next window-ready
        // attach. Never send hit regions to the old, released GPUI NSView.
        self.view=std::ptr::null_mut();
    }
    pub fn hit_regions(&self,regions:&[[f32;4]]) {
        let values:Vec<f64>=regions.iter().flatten().map(|n|*n as f64).collect();
        if !self.view.is_null() {unsafe{gmgn_gpui_hit_regions(self.view,values.as_ptr(),regions.len());}}
    }
    pub fn reopen(&self) { unsafe { (self.reopen)(self.handle, gmgn_gpui_has_visible_windows()); } }
    pub fn close(&mut self) {
        if self.handle.is_null() { return; }
        unsafe { (self.shutdown)(self.handle); (self.destroy)(self.handle); }
        self.handle = std::ptr::null_mut();
        self.view = std::ptr::null_mut();
    }
}
impl Drop for ProductHost { fn drop(&mut self) { self.close(); } }
