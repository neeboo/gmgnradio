//! Viewport-scaled raster budget for the native GPU lyric layer.
//!
//! The native compositor clamps its own render targets to a fixed pixel budget
//! (`tools/gpui-lyrics-metal-probe/lyrics_layer.m`):
//!
//! ```text
//! targetCount = 5 + maxdepth
//! budget      = MIN(4194304, floor(256*1024*1024/(4*targetCount)))   // = 2048x2048
//! w,h         = ceil(logical*scale)
//! if (w*h > budget) { effectiveScale = sqrt(budget/(logicalW*logicalH)); ... }
//! ```
//!
//! so a 4096x2304 fullscreen viewport is *downsampled* to that budget instead of
//! being rejected. The Rust atlas side has no equivalent: every glyph is
//! rasterized at the device `scale` alone, while the lyric layout size follows
//! the viewport width (`font_size(text, self.width)`), so the rasterized atlas
//! area grows with the viewport squared. `AtlasCache::pack` then refuses the
//! frame once it needs more than 16 pages or 64 MiB (`gpu_atlas_frame_budget_exceeded`),
//! which removes the lyric layer at exactly the resolution the user reported.
//!
//! These tests pin the budget to the viewport: the raster scale must follow the
//! same fixed pixel budget the native layer uses, and the frame must stay inside
//! the published page/byte limits at every viewport.
use super::gpu_scene::AtlasCache;
use super::{Scene, SvgRenderer};
use serde_json::json;
use std::sync::Arc;
use std::time::Instant;

/// The native layer's fixed target budget: `MIN(4194304, 256MiB/(4*(5+depth)))`.
const NATIVE_TARGET_BUDGET: f64 = 4_194_304.;
/// `GpuLyricsFrame::diagnostics` and the native renderer both cap pages at 16.
const MAX_ATLAS_PAGES: usize = 16;
/// `AtlasCache::pack` refuses a frame above 64 MiB of page bytes.
const MAX_ATLAS_BYTES: usize = 64 * 1024 * 1024;

fn long_context(mode: &str) -> serde_json::Value {
    let text = "在很长的歌词里保留真正的文字轮廓与完整光影".repeat(5);
    let glyphs: Vec<_> = "真正的逐字辉光过渡"
        .chars()
        .enumerate()
        .map(|(i, c)| json!({"id":format!("g{i}"),"text":c.to_string(),"phase":"active","progress":0.5}))
        .collect();
    json!({"mode":mode,"animationTime":10.2,"playbackTime":5.,
        "flow":{"activeLine":{"id":"new","text":"真正的逐字辉光过渡"},"previousLine":{"text":text},"nextLine":{"text":text},"translation":text,"glyphs":glyphs},
        "monet":{"entries":[{"line":{"text":text,"translation":text},"offset":-1,"status":"passed"},{"line":{"text":text},"offset":0,"status":"active"},{"line":{"text":text},"offset":1,"status":"upcoming"}]}})
}

/// The product's two real viewports, in *points*, at the Retina device scale:
/// a 720x450 window (1440x900 px) and a 2048x1152 fullscreen window
/// (4096x2304 px) — 7.28x the pixel area.
const WINDOWED: (f64, f64, f32) = (720., 450., 2.);
const FULLSCREEN: (f64, f64, f32) = (2048., 1152., 2.);

struct Cost {
    pages: usize,
    bytes: usize,
    glyphs: usize,
    batches: usize,
    millis: f64,
    warm_millis: f64,
    raster_scale: f32,
}

/// Cold frame (first submit for this scene) and warm frame (same scene, atlas
/// cache hot) of the real production scene.
fn cost(mode: &str, width: f64, height: f64, scale: f32) -> Result<Cost, String> {
    let renderer = SvgRenderer::new(Arc::new(()));
    let mut cache = AtlasCache::default();
    let snapshot = long_context(mode);
    let started = Instant::now();
    let (svg, primitives) = Scene::new(&snapshot, width, height).finish_gpu();
    cache.frame(&renderer, &svg, &primitives, width, height, scale, 1)?;
    let millis = started.elapsed().as_secs_f64() * 1000.;
    let warm = Instant::now();
    let (svg, primitives) = Scene::new(&snapshot, width, height).finish_gpu();
    let frame = cache.frame(&renderer, &svg, &primitives, width, height, scale, 2)?;
    let warm_millis = warm.elapsed().as_secs_f64() * 1000.;
    Ok(Cost {
        pages: frame.atlases.len(),
        bytes: frame.atlases.iter().map(|a| a.rgba.len()).sum(),
        glyphs: frame.batches.iter().map(|b| b.glyphs.len()).sum(),
        batches: frame.batches.len(),
        millis,
        warm_millis,
        raster_scale: frame.raster_scale(),
    })
}

/// Windowed (1440x900 px) and fullscreen (4096x2304 px) cost of the real scene.
#[cfg(target_os = "macos")]
#[test]
fn viewport_measurement_is_stable_and_inside_the_frame_budget() {
    for mode in ["luminous", "monet_poster", "diorama"] {
        let windowed = cost(mode, WINDOWED.0, WINDOWED.1, WINDOWED.2)
            .unwrap_or_else(|e| panic!("{mode} windowed: {e}"));
        let fullscreen = cost(mode, FULLSCREEN.0, FULLSCREEN.1, FULLSCREEN.2)
            .unwrap_or_else(|e| panic!("{mode} fullscreen: {e}"));
        eprintln!(
            "lyrics viewport cost {mode}: windowed pages={} bytes={} glyphs={} batches={} coldMs={:.1} warmMs={:.1} raster={:.3} | fullscreen pages={} bytes={} glyphs={} batches={} coldMs={:.1} warmMs={:.1} raster={:.3}",
            windowed.pages, windowed.bytes, windowed.glyphs, windowed.batches, windowed.millis, windowed.warm_millis, windowed.raster_scale,
            fullscreen.pages, fullscreen.bytes, fullscreen.glyphs, fullscreen.batches, fullscreen.millis, fullscreen.warm_millis, fullscreen.raster_scale,
        );
        for (label, measured) in [("windowed", &windowed), ("fullscreen", &fullscreen)] {
            assert!(
                measured.pages <= MAX_ATLAS_PAGES,
                "{mode} {label}: {} atlas pages exceeds the {MAX_ATLAS_PAGES}-page frame budget",
                measured.pages
            );
            assert!(
                measured.bytes <= MAX_ATLAS_BYTES,
                "{mode} {label}: {} atlas bytes exceeds the 64 MiB frame budget",
                measured.bytes
            );
        }
        // The atlas is the intermediate layer the compositor downsamples to its
        // own fixed pixel budget, so the fullscreen raster must be the bounded
        // scale — not the raw device scale the window rendered at.
        assert!(
            fullscreen.raster_scale < FULLSCREEN.2,
            "{mode}: fullscreen raster scale {} did not follow the viewport pixel budget (device scale {})",
            fullscreen.raster_scale,
            FULLSCREEN.2
        );
        // A steady-state lyric frame reuses the packed atlases instead of
        // re-rasterizing them every animation frame.
        assert!(
            fullscreen.warm_millis < fullscreen.millis,
            "{mode}: warm frame {:.1}ms did not beat the cold frame {:.1}ms, so atlases are rebuilt per frame",
            fullscreen.warm_millis,
            fullscreen.millis
        );
    }
}

/// The published native limit is a *pixel* budget, not a scale: at the 2048x2048
/// cap the effective device scale must be `sqrt(budget/area)`, exactly like
/// `lyrics_layer.m` computes it for its own targets. A 720x450 window at scale 2
/// (1.296M px) keeps its full scale, so the windowed rendering path is unchanged.
#[cfg(target_os = "macos")]
#[test]
fn raster_scale_follows_the_native_pixel_budget() {
    for (width, height, scale) in [
        (720., 450., 2f32),
        (1024., 576., 2.),
        (2048., 1152., 2.),
        (720., 450., 1.),
    ] {
        let measured = cost("luminous", width, height, scale).unwrap_or_else(|e| panic!("{width}x{height}: {e}"));
        let expected = (NATIVE_TARGET_BUDGET / (width * height)).sqrt().min(f64::from(scale));
        assert!(
            (f64::from(measured.raster_scale) - expected).abs() < 1e-3,
            "{width}x{height}@{scale}: raster scale {} must be min(scale, sqrt({NATIVE_TARGET_BUDGET}/{})) = {expected}",
            measured.raster_scale,
            width * height
        );
    }
}
