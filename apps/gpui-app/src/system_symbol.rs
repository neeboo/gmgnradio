use gpui_kit::RenderImage;
use std::{
    collections::HashMap,
    ffi::{CString, c_char, c_void},
    sync::{Arc, Mutex, OnceLock},
};
unsafe extern "C" {
    fn gmgn_system_symbol_rgba(
        name: *const c_char,
        tint: i32,
        width: *mut i32,
        height: *mut i32,
    ) -> *mut u8;
    fn gmgn_system_color_rgba(color: i32) -> u32;
    fn gmgn_system_symbol_free(data: *mut c_void);
}
pub fn image(name: &str) -> Option<Arc<RenderImage>> {
    tinted_image(name, 0)
}
pub fn system_blue_background() -> u32 {
    unsafe { (gmgn_system_color_rgba(2) & 0xffffff00) | 71 }
}
pub fn tinted_image(name: &str, tint: i32) -> Option<Arc<RenderImage>> {
    static CACHE: OnceLock<Mutex<HashMap<String, Arc<RenderImage>>>> = OnceLock::new();
    let mut cache = CACHE.get_or_init(Default::default).lock().unwrap();
    let key = format!("{name}:{tint}");
    if let Some(image) = cache.get(&key) {
        return Some(image.clone());
    }
    let result = (|| {
        let name = CString::new(name).ok()?;
        let (mut width, mut height) = (0, 0);
        let data = unsafe { gmgn_system_symbol_rgba(name.as_ptr(), tint, &mut width, &mut height) };
        if data.is_null() {
            return None;
        }
        if width <= 0 || height <= 0 {
            unsafe { gmgn_system_symbol_free(data.cast()) };
            return None;
        }
        let bytes =
            unsafe { std::slice::from_raw_parts(data, (width * height * 4) as usize) }.to_vec();
        unsafe { gmgn_system_symbol_free(data.cast()) };
        render_image(width as u32, height as u32, bytes)
    })()?;
    cache.insert(key, result.clone());
    Some(result)
}

fn render_image(width: u32, height: u32, mut bytes: Vec<u8>) -> Option<Arc<RenderImage>> {
    if !bytes.chunks_exact(4).any(|pixel| pixel[3] > 0) {
        return None;
    }
    // GPUI's decoded image path uploads BGRA (see elements/img.rs), including RenderImage.
    for pixel in bytes.chunks_exact_mut(4) {
        pixel.swap(0, 2);
    }
    let buffer = image::RgbaImage::from_raw(width, height, bytes)?;
    Some(Arc::new(RenderImage::new(vec![image::Frame::new(buffer)])))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn visible_rgba_is_uploaded_as_bgra() {
        let image = render_image(1, 1, vec![0x7a, 0xf2, 0xff, 255]).unwrap();
        assert_eq!(image.as_bytes(0).unwrap(), &[0xff, 0xf2, 0x7a, 255]);
    }
    #[test]
    fn transparent_or_malformed_image_is_not_cached_as_renderable() {
        assert!(render_image(1, 1, vec![122, 242, 255, 0]).is_none());
        assert!(render_image(2, 1, vec![122, 242, 255, 255]).is_none());
    }
}
