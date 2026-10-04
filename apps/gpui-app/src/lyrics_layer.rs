//! Main-thread-only passive Metal lyric surface; no lyric clock or scene state.
use std::{ffi::c_void, marker::PhantomData, rc::Rc};
use gmgn_gpui_ui::lyrics::GpuLyricsFrame;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Glyph {
    pub atlas_id: u64,
    pub width: f64,
    pub height: f64,
    pub matrix: [f64; 9],
    pub uv: [f64; 4],
    pub rgba: [f64; 4],
}
#[repr(C)]
struct Batch {
    glyphs: *const Glyph,
    count: usize,
    sigma: f64,
    blur_mix: f64,
    glow: [f64; 4],
    opacity: f64,
    parent_index: i64,
}

unsafe extern "C" {
    fn gmgn_lyrics_layer_create(view: *mut c_void) -> *mut c_void;
    fn gmgn_lyrics_layer_atlas(context: *mut c_void, id: u64, width: u32, height: u32, rgba: *const u8, bytes: usize) -> i32;
    fn gmgn_lyrics_layer_has_atlas(context: *mut c_void, id: u64, width: u32, height: u32) -> i32;
    fn gmgn_lyrics_layer_render_frame(context: *mut c_void, batches: *const Batch, count: usize, scale: f64) -> i32;
    fn gmgn_lyrics_layer_clear(context: *mut c_void) -> i32;
    fn gmgn_lyrics_layer_destroy(context: *mut c_void) -> i32;
}

pub struct LyricsLayer {
    context: *mut c_void,
    submission_failed: bool,
    _main_thread: PhantomData<Rc<()>>,
}
impl LyricsLayer {
    /// Borrowed view must be a live GPUI NSView on the main thread.
    pub unsafe fn new(view: *mut c_void) -> Option<Self> {
        let context = unsafe { gmgn_lyrics_layer_create(view) };
        (!context.is_null()).then_some(Self { context, submission_failed: false, _main_thread: PhantomData })
    }
    pub fn atlas(&mut self, id: u64, width: u32, height: u32, rgba: &[u8]) -> bool {
        let expected = (width as usize).checked_mul(height as usize).and_then(|n| n.checked_mul(4));
        if expected != Some(rgba.len()) || width == 0 || height == 0 { return false; }
        unsafe { gmgn_lyrics_layer_has_atlas(self.context,id,width,height) != 0 || gmgn_lyrics_layer_atlas(self.context,id,width,height,rgba.as_ptr(),rgba.len()) != 0 }
    }
    pub fn apply(&mut self, frame: &GpuLyricsFrame) -> bool {
        let accepted = self.apply_inner(frame);
        if !accepted && !self.submission_failed {
            eprintln!("GMGN_LYRICS_GPU_REJECT generation={} width={} height={} scale={} batches={} atlases={}",frame.generation,frame.width,frame.height,frame.scale,frame.batches.len(),frame.atlases.len());
        }
        self.submission_failed = !accepted;
        accepted
    }
    fn apply_inner(&mut self, frame: &GpuLyricsFrame) -> bool {
        if frame.batches.is_empty() { return self.clear(); }
        for atlas in &frame.atlases {
            if !self.atlas(atlas.id,atlas.width,atlas.height,&atlas.rgba) { return false; }
        }
        let glyphs = frame.batches.iter().map(|batch| batch.glyphs.iter().map(|g| Glyph {
            atlas_id:g.atlas_id,width:g.width,height:g.height,matrix:g.matrix,uv:g.uv,rgba:g.rgba,
        }).collect::<Vec<_>>()).collect::<Vec<_>>();
        let batches = frame.batches.iter().zip(&glyphs).map(|(b,g)| Batch {
            glyphs:g.as_ptr(),count:g.len(),sigma:b.sigma,blur_mix:b.blur_mix,glow:b.glow,opacity:b.opacity,
            parent_index:b.parent.map_or(-1, |index| i64::try_from(index).unwrap_or(i64::MAX)),
        }).collect::<Vec<_>>();
        unsafe { gmgn_lyrics_layer_render_frame(self.context,batches.as_ptr(),batches.len(),f64::from(frame.scale)) != 0 }
    }
    pub fn clear(&mut self) -> bool {
        unsafe { gmgn_lyrics_layer_clear(self.context) != 0 }
    }
}
impl Drop for LyricsLayer {
    fn drop(&mut self) { unsafe { gmgn_lyrics_layer_destroy(self.context); } }
}

#[cfg(test)]
mod tests {
    #[test]
    fn glyph_abi_matches_native_header() {
        assert_eq!(std::mem::size_of::<super::Glyph>(), 20 * 8);
        assert_eq!(std::mem::offset_of!(super::Glyph, matrix), 3 * 8);
        assert_eq!(std::mem::offset_of!(super::Glyph, uv), 12 * 8);
        assert_eq!(std::mem::offset_of!(super::Glyph, rgba), 16 * 8);
        assert_eq!(std::mem::size_of::<super::Batch>(), 10 * 8);
        assert_eq!(std::mem::offset_of!(super::Batch, parent_index), 9 * 8);
    }
}
