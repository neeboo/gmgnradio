//! Main-thread-only, passive native background material. GPUI owns all UI and hit tests.
use std::{ffi::c_void, marker::PhantomData, rc::Rc};

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct BackdropCard {
    pub width: f64,
    pub height: f64,
    pub radius: f64,
    pub opacity: f64,
    pub priority: f64,
    /// Row-major source-local -> window top-left projective transform.
    pub matrix: [f64; 9],
}
unsafe extern "C" {
    fn gmgn_gpui_program_backdrop_create(view: *mut c_void) -> *mut c_void;
    fn gmgn_gpui_program_backdrop_apply(
        context: *mut c_void,
        cards: *const BackdropCard,
        count: usize,
        viewport: *const f64,
    ) -> i32;
    fn gmgn_gpui_program_backdrop_clear(context: *mut c_void) -> i32;
    fn gmgn_gpui_program_backdrop_destroy(context: *mut c_void) -> i32;
    fn gmgn_gpui_program_backdrop_diagnostics(context: *mut c_void, values: *mut f64) -> i32;
}
pub struct ProgramBackdrop {
    context: *mut c_void,
    _main_thread: PhantomData<Rc<()>>,
}
impl ProgramBackdrop {
    /// Caller supplies a live borrowed GPUI NSView on the macOS main thread.
    pub unsafe fn new(view: *mut c_void) -> Option<Self> {
        let context = unsafe { gmgn_gpui_program_backdrop_create(view) };
        (!context.is_null()).then_some(Self {
            context,
            _main_thread: PhantomData,
        })
    }
    /// All coordinates are logical points relative to the GPUI view's top-left.
    pub fn apply(&mut self, cards: &[BackdropCard], viewport: [f64; 4]) -> bool {
        unsafe {
            gmgn_gpui_program_backdrop_apply(
                self.context,
                cards.as_ptr(),
                cards.len(),
                viewport.as_ptr(),
            ) != 0
        }
    }
    pub fn clear(&mut self) -> bool {
        unsafe { gmgn_gpui_program_backdrop_clear(self.context) != 0 }
    }
    pub fn diagnostics(&self) -> Option<[f64; 6]> {
        let mut values = [0.; 6];
        (unsafe { gmgn_gpui_program_backdrop_diagnostics(self.context, values.as_mut_ptr()) } != 0)
            .then_some(values)
    }
}
impl Drop for ProgramBackdrop {
    fn drop(&mut self) {
        unsafe {
            gmgn_gpui_program_backdrop_destroy(self.context);
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn c_card_layout_has_fourteen_contiguous_doubles() {
        assert_eq!(std::mem::size_of::<super::BackdropCard>(), 14 * 8);
        assert_eq!(std::mem::offset_of!(super::BackdropCard, matrix), 5 * 8);
    }
}
