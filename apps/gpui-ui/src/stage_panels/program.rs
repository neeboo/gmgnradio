use crate::ui_tokens::program as m;
use super::scene_variant;
use crate::projective_card::{
    CardEffects, CardShadow, CardTransform, ProjectedCard, RailMask, RgbaTexture, ScrollTransition,
};
use crate::ui_tokens as doc;
use crate::ui_tokens::scene as s;

fn scroll_phase(card_top: f64, card_height: f64, viewport_top: f64, viewport_height: f64) -> f64 {
    if card_height <= 0. || viewport_height <= 0. {
        return 0.;
    }
    if card_top < viewport_top {
        ((card_top - viewport_top) / card_height).clamp(-1., 0.)
    } else {
        ((card_top + card_height - viewport_top - viewport_height) / card_height).clamp(0., 1.)
    }
}
fn card_effects(card: &Value, catalog: bool) -> CardEffects {
    if card["isEmpty"].as_bool() == Some(true) {
        return CardEffects {
            blur_radius: 0.,
            shadow: Some(CardShadow {
                radius: 24.,
                offset: [0., 0.],
                rgba: [0, 255, 255, 36],
            }),
        };
    }
    let current = card["isCurrent"].as_bool() == Some(true);
    let focused = card["isFocused"].as_bool().unwrap_or(current);
    CardEffects {
        blur_radius: if catalog || focused {
            0.
        } else {
            card["relativeIndex"]
                .as_i64()
                .unwrap_or(0)
                .unsigned_abs()
                .min(2) as f64
                * 0.16
        },
        shadow: Some(CardShadow {
            radius: if !catalog && current { 24. } else { 13. },
            offset: [0., 7.],
            rgba: if catalog {
                [0, 0, 0, 97]
            } else if current {
                [0, 255, 255, 51]
            } else {
                [0, 0, 0, 107]
            },
        }),
    }
}
fn icon_svg(icon: gpui_kit::assets::IconName, x: f64, y: f64, size: f64, color: &str) -> String {
    let Ok(Some(bytes)) = gpui_kit::assets::AllAssets.load(&icon.path()) else {
        return String::new();
    };
    let Ok(svg) = std::str::from_utf8(&bytes) else {
        return String::new();
    };
    let Some(start) = svg.find('>') else {
        return String::new();
    };
    let Some(end) = svg.rfind("</svg>") else {
        return String::new();
    };
    format!(
        r#"<g transform="translate({x} {y}) scale({})" fill="none" stroke="{color}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">{}</g>"#,
        size / 24.,
        svg[start + 1..end].replace("currentColor", color)
    )
}
use base64::Engine as _;
use gpui_kit::assets::IconName as AssetIcon;
use gpui_kit::base::Disableable;
use gpui_kit::component::button::*;
use gpui_kit::component::spinner::Spinner;
use gpui_kit::component::Sizable as _;
use gpui_kit::prelude::InteractiveElement as _;
use gpui_kit::*;
use serde_json::{Value, json};
use std::{
    cell::{Cell, RefCell},
    collections::HashMap,
    rc::Rc,
    sync::Arc,
};
use std::{
    collections::VecDeque,
    sync::{Condvar, Mutex},
};

#[derive(Clone)]
struct CardPrepareJob {
    id: String,
    key: String,
    source_key: String,
    generation: u64,
    renderer: SvgRenderer,
    card: Value,
    audio: Value,
    artwork: Option<Arc<RenderImage>>,
    catalog: bool,
    playlist: bool,
    material: bool,
    transform: CardTransform,
    origin: [f64; 2],
    viewport: [f64; 2],
    ppp: f64,
    opacity: f64,
    mask: Option<RailMask>,
    transition: Option<ScrollTransition>,
    effects: CardEffects,
}
struct CardReady {
    key: String,
    source_key: String,
    origin: [f64; 2],
    opacity: f64,
    projected: Arc<ProjectedCard>,
    image: Arc<RenderImage>,
    foreground: Option<Arc<RenderImage>>,
    source: Arc<RgbaTexture>,
    material_source: Option<Arc<RgbaTexture>>,
}
struct CardPrepareQueue {
    generation: u64,
    pending: HashMap<String, CardPrepareJob>,
    order: VecDeque<String>,
    ready: HashMap<String, Arc<CardReady>>,
    inflight: Option<(String, String)>,
    closed: bool,
}
struct CardPrepareWorker {
    shared: Arc<(Mutex<CardPrepareQueue>, Condvar)>,
}
impl CardPrepareWorker {
    fn new() -> Arc<Self> {
        let shared = Arc::new((
            Mutex::new(CardPrepareQueue {
                generation: 0,
                pending: HashMap::new(),
                order: VecDeque::new(),
                ready: HashMap::new(),
                inflight: None,
                closed: false,
            }),
            Condvar::new(),
        ));
        let state = shared.clone();
        std::thread::Builder::new()
            .name("stage-program-card-prepare".into())
            .spawn(move || {
                let mut sources: HashMap<
                    String,
                    (String, Arc<RgbaTexture>, Option<Arc<RgbaTexture>>),
                > = HashMap::new();
                loop {
                    let job = {
                        let mut q = state.0.lock().unwrap();
                        while q.order.is_empty() && !q.closed {
                            q = state.1.wait(q).unwrap();
                        }
                        if q.closed {
                            break;
                        }
                        let id = q.order.pop_front().unwrap();
                        let Some(job) = q.pending.remove(&id) else {
                            continue;
                        };
                        q.inflight = Some((id, job.key.clone()));
                        job
                    };
                    let result = prepare_card_job(&job, &mut sources);
                    // Single consumer + at most twelve latest pending visible rows.
                    // Publish same-generation completions even under continuous
                    // animation; discarding each superseded frame would starve.
                    let mut q = state.0.lock().unwrap();
                    q.inflight = None;
                    if !q.closed && q.generation == job.generation {
                        if let Some(result) = result {
                            q.ready.insert(job.id.clone(), Arc::new(result));
                        }
                        if q.ready.len() > 24 {
                            q.ready.retain(|id, _| id == &job.id);
                        }
                    }
                    if sources.len() > 24 {
                        sources.retain(|id, _| id == &job.id);
                    }
                }
            })
            .expect("program preparation worker");
        Arc::new(Self { shared })
    }
    fn reset(&self, generation: u64) {
        let mut q = self.shared.0.lock().unwrap();
        q.generation = generation;
        q.pending.clear();
        q.order.clear();
        q.ready.clear();
    }
    fn submit(&self, job: CardPrepareJob) {
        let mut q = self.shared.0.lock().unwrap();
        if q.closed
            || q.generation != job.generation
            || q.ready.get(&job.id).is_some_and(|r| r.key == job.key)
            || q.inflight
                .as_ref()
                .is_some_and(|(id, key)| id == &job.id && key == &job.key)
            || q.pending.get(&job.id).is_some_and(|p| p.key == job.key)
        {
            return;
        }
        if !q.pending.contains_key(&job.id) {
            if q.pending.len() >= 12 {
                return;
            }
            q.order.push_back(job.id.clone());
        }
        q.pending.insert(job.id.clone(), job);
        self.shared.1.notify_one();
    }
    fn ready(&self, id: &str, generation: u64) -> Option<Arc<CardReady>> {
        let q = self.shared.0.lock().unwrap();
        (q.generation == generation)
            .then(|| q.ready.get(id).cloned())
            .flatten()
    }
    fn busy(&self) -> bool {
        let q = self.shared.0.lock().unwrap();
        q.inflight.is_some() || !q.pending.is_empty()
    }
}
impl Drop for CardPrepareWorker {
    fn drop(&mut self) {
        let mut q = self.shared.0.lock().unwrap();
        q.closed = true;
        q.pending.clear();
        q.order.clear();
        self.shared.1.notify_one();
    }
}

fn prepare_card_job(
    job: &CardPrepareJob,
    sources: &mut HashMap<String, (String, Arc<RgbaTexture>, Option<Arc<RgbaTexture>>)>,
) -> Option<CardReady> {
    #[cfg(target_os = "macos")]
    unsafe extern "C" {
        fn objc_autoreleasePoolPush() -> *mut std::ffi::c_void;
        fn objc_autoreleasePoolPop(pool: *mut std::ffi::c_void);
    }
    #[cfg(target_os = "macos")]
    struct Pool(*mut std::ffi::c_void);
    #[cfg(target_os = "macos")]
    impl Drop for Pool {
        fn drop(&mut self) {
            unsafe { objc_autoreleasePoolPop(self.0) }
        }
    }
    #[cfg(target_os = "macos")]
    let _pool = Pool(unsafe { objc_autoreleasePoolPush() });
    let cached = sources
        .get(&job.id)
        .filter(|(key, _, mat)| key == &job.source_key && (!job.material || mat.is_some()))
        .cloned();
    let (_, source, material_source) = match cached {
        Some(c) => c,
        None => {
            let source = raster_card_source(
                &job.renderer,
                &job.card,
                &job.audio,
                job.catalog,
                job.playlist,
                job.artwork.as_ref(),
                false,
            )?;
            let material = if job.material {
                raster_card_source(
                    &job.renderer,
                    &job.card,
                    &job.audio,
                    job.catalog,
                    job.playlist,
                    job.artwork.as_ref(),
                    true,
                )
            } else {
                None
            };
            let c = (job.source_key.clone(), source, material);
            sources.insert(job.id.clone(), c.clone());
            c
        }
    };
    let render = |source: &RgbaTexture| {
        ProjectedCard::render_with_effects(
            source,
            job.transform,
            job.origin,
            job.viewport,
            job.ppp,
            job.opacity,
            job.mask,
            job.transition,
            job.effects,
        )
        .ok()
    };
    let projected = Arc::new(render(&source)?);
    let image = projected.render_image();
    let foreground = material_source
        .as_ref()
        .and_then(|source| render(source))
        .map(|p| p.render_image());
    Some(CardReady {
        key: job.key.clone(),
        source_key: job.source_key.clone(),
        origin: job.origin,
        opacity: job.opacity,
        projected,
        image,
        foreground,
        source,
        material_source,
    })
}

#[derive(Clone, Debug, Default)]
pub struct ProgramMaterialFrame {
    pub viewport: [f64; 4],
    pub scale: f64,
    pub revision: u64,
    pub fade_fraction: f64,
    pub cards: Vec<ProgramMaterialCard>,
}
#[derive(Clone, Debug)]
pub struct ProgramMaterialCard {
    pub id: String,
    pub width: f64,
    pub height: f64,
    pub radius: f64,
    pub opacity: f64,
    pub priority: f64,
    pub matrix: [f64; 9],
}
type MaterialRenderer = Rc<dyn Fn(&ProgramMaterialFrame) -> bool>;
type CardSourceCache = Rc<RefCell<HashMap<String, (String, Arc<RgbaTexture>)>>>;

fn raster_card_source(
    renderer: &SvgRenderer,
    card: &Value,
    audio: &Value,
    catalog: bool,
    playlist: bool,
    artwork: Option<&Arc<RenderImage>>,
    material: bool,
) -> Option<Arc<RgbaTexture>> {
    let svg = card_svg_content(card, audio, catalog, playlist, artwork.is_some());
    let svg = if material {
        material_foreground_svg(svg)
    } else {
        svg
    };
    let image = renderer.render_single_frame(svg.as_bytes(), 1.).ok()?;
    let dimensions = image.size(0);
    let mut pixels = image.as_bytes(0)?.to_vec();
    for p in pixels.chunks_exact_mut(4) {
        p.swap(0, 2);
    }
    let mut texture = RgbaTexture {
        width: dimensions.width.0 as u32,
        height: dimensions.height.0 as u32,
        pixels,
    };
    if let Some(artwork) = artwork {
        composite_artwork(&mut texture, artwork);
    }
    Some(Arc::new(texture))
}

fn material_foreground_svg(svg: String) -> String {
    svg.replace("fill=\"#1c252d\"", "fill=\"#1c252d\" fill-opacity=\"0\"")
        .replace("fill=\"#263641\"", "fill=\"#263641\" fill-opacity=\"0\"")
}
fn empty_card_width(card: &Value) -> f64 {
    let text = card["title"].as_str().unwrap_or("暂无节目");
    let text_width = card["emptySymbol"]["labelWidth"]
        .as_f64()
        .unwrap_or_else(|| {
            crate::lyrics::shaped_text_svg(text, 16., 600, 0.)
                .map_or(text.chars().count() as f64 * 16., |line| line.width)
        });
    // Original horizontal padding 20, spacing 12 and the SF `waveform.path`
    // intrinsic width 26 at font 18 medium (actual AppKit
    // SymbolConfiguration readback), from `emptyState` (:4030-4048).
    2. * m::EMPTY_H_PADDING
        + m::EMPTY_GAP
        + card["emptySymbol"]["logicalWidth"]
            .as_f64()
            .unwrap_or(m::EMPTY_SYMBOL_WIDTH)
        + text_width
}

#[allow(dead_code)] // System-symbol migration is explicitly paused during perf repair.
fn composite_empty_symbol(texture: &mut RgbaTexture, card: &Value) -> bool {
    let symbol = &card["emptySymbol"];
    let Some(width) = symbol["pixelWidth"]
        .as_u64()
        .and_then(|v| u32::try_from(v).ok())
    else {
        return false;
    };
    let Some(height) = symbol["pixelHeight"]
        .as_u64()
        .and_then(|v| u32::try_from(v).ok())
    else {
        return false;
    };
    let (Some(logical_width), Some(logical_height), Some(encoded)) = (
        symbol["logicalWidth"].as_f64(),
        symbol["logicalHeight"].as_f64(),
        symbol["rgbaBase64"].as_str(),
    ) else {
        return false;
    };
    if width == 0
        || height == 0
        || width as u64 * height as u64 > 262144
        || !logical_width.is_finite()
        || !logical_height.is_finite()
        || logical_width <= 0.
        || logical_height <= 0.
    {
        return false;
    }
    let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(encoded) else {
        return false;
    };
    let Some(source) = image::RgbaImage::from_raw(width, height, bytes) else {
        return false;
    };
    let scale = texture.width as f64 / empty_card_width(card);
    let target_width = (logical_width * scale).round().max(1.) as u32;
    let target_height = (logical_height * scale).round().max(1.) as u32;
    let source = image::imageops::resize(
        &source,
        target_width,
        target_height,
        image::imageops::FilterType::Triangle,
    );
    let x = (20. * scale).round() as u32;
    let y = ((64. - logical_height) / 2. * scale).round().max(0.) as u32;
    for (sx, sy, pixel) in source.enumerate_pixels() {
        let (dx, dy) = (x + sx, y + sy);
        if dx >= texture.width || dy >= texture.height {
            continue;
        }
        let i = ((dy * texture.width + dx) * 4) as usize;
        let a = pixel[3] as f64 / 255.;
        let old_a = texture.pixels[i + 3] as f64 / 255.;
        let output = a + old_a * (1. - a);
        if output > 0. {
            for c in 0..3 {
                texture.pixels[i + c] = ((pixel[c] as f64 * a
                    + texture.pixels[i + c] as f64 * old_a * (1. - a))
                    / output)
                    .round() as u8;
            }
            texture.pixels[i + 3] = (output * 255.).round() as u8;
        }
    }
    true
}

fn video_material_card(card: &ProgramMaterialCard) -> ProgramMaterialCard {
    // Original trailing 26pt button: 294 - 26 - 9 = 259; top offset 8.
    // Compose local translation BEFORE the same final projective matrix.
    let mut matrix = card.matrix;
    matrix[2] += matrix[0] * 259. + matrix[1] * 8.;
    matrix[5] += matrix[3] * 259. + matrix[4] * 8.;
    matrix[8] += matrix[6] * 259. + matrix[7] * 8.;
    ProgramMaterialCard {
        id: format!("{}-video", card.id),
        width: 26.,
        height: 26.,
        radius: 13.,
        opacity: card.opacity,
        priority: card.priority + 0.25,
        matrix,
    }
}
type ProjectionCache = Rc<RefCell<HashMap<String, (String, Arc<ProjectedCard>, Arc<RenderImage>)>>>;

// Match AsyncImage: centered scaledToFill, 42pt square, 12pt rounded clip.
fn composite_artwork(card: &mut RgbaTexture, artwork: &RenderImage) {
    let dimensions = artwork.size(0);
    let Some(bytes) = artwork.as_bytes(0) else {
        return;
    };
    let mut pixels = bytes.to_vec();
    for pixel in pixels.chunks_exact_mut(4) {
        pixel.swap(0, 2);
    }
    let Some(source) = image::RgbaImage::from_raw(
        dimensions.width.0 as u32,
        dimensions.height.0 as u32,
        pixels,
    ) else {
        return;
    };
    let edge = source.width().min(source.height());
    if edge == 0 {
        return;
    }
    let crop = image::imageops::crop_imm(
        &source,
        (source.width() - edge) / 2,
        (source.height() - edge) / 2,
        edge,
        edge,
    );
    let factor = card.width as f64 / 306.;
    let side = (42. * factor).round() as u32;
    let cover = image::imageops::resize(
        &crop.to_image(),
        side,
        side,
        image::imageops::FilterType::Triangle,
    );
    let (x0, y0) = ((14. * factor).round() as u32, (16. * factor).round() as u32);
    let radius = 12. * factor;
    for y in 0..side {
        for x in 0..side {
            if x0 + x >= card.width || y0 + y >= card.height {
                continue;
            }
            let (dx, dy) = (x as f64 + 0.5, y as f64 + 0.5);
            let distance = ((dx - dx.clamp(radius, side as f64 - radius)).powi(2)
                + (dy - dy.clamp(radius, side as f64 - radius)).powi(2))
            .sqrt();
            let src = cover.get_pixel(x, y).0;
            let alpha = src[3] as f64 / 255. * (radius - distance + 0.5).clamp(0., 1.);
            let i = ((y + y0) as usize * card.width as usize + (x + x0) as usize) * 4;
            let destination = card.pixels[i + 3] as f64 / 255.;
            let out_alpha = alpha + destination * (1. - alpha);
            if out_alpha > 0. {
                for c in 0..3 {
                    card.pixels[i + c] = ((src[c] as f64 * alpha
                        + card.pixels[i + c] as f64 * destination * (1. - alpha))
                        / out_alpha)
                        .round() as u8;
                }
            }
            card.pixels[i + 3] = (out_alpha * 255.).round() as u8;
        }
    }
}

fn svg_text(
    text: &str,
    x: f64,
    baseline: f64,
    size: f64,
    weight: u16,
    color: &str,
    max_width: f64,
) -> String {
    let mut display = text.to_owned();
    if let Some(line) = crate::lyrics::shaped_text_svg(text, size, weight, 0.) {
        if line.width > max_width {
            let mut chars: Vec<char> = text.chars().collect();
            while !chars.is_empty() {
                chars.pop();
                display = format!("{}…", chars.iter().collect::<String>());
                if crate::lyrics::shaped_text_svg(&display, size, weight, 0.)
                    .is_some_and(|line| line.width <= max_width)
                {
                    break;
                }
            }
        }
    }
    if let Some(line) = crate::lyrics::shaped_text_svg(&display, size, weight, 0.) {
        format!(
            r#"<path fill="{color}" transform="translate({x} {baseline})" d="{}"/>"#,
            line.path
        )
    } else {
        let escaped = display
            .replace('&', "&amp;")
            .replace('<', "&lt;")
            .replace('>', "&gt;")
            .replace('"', "&quot;");
        format!(
            r#"<text x="{x}" y="{baseline}" font-family="sans-serif" font-size="{size}" font-weight="{weight}" fill="{color}">{escaped}</text>"#
        )
    }
}

#[cfg(test)]
fn card_svg(card: &Value, audio: &Value, catalog: bool, playlist: bool) -> String {
    card_svg_content(card, audio, catalog, playlist, false)
}
fn card_svg_content(
    card: &Value,
    audio: &Value,
    catalog: bool,
    playlist: bool,
    has_artwork: bool,
) -> String {
    if card["isEmpty"].as_bool() == Some(true) {
        let width = empty_card_width(card);
        let inner_width = width - 1.;
        let symbol_width = card["emptySymbol"]["logicalWidth"]
            .as_f64()
            .unwrap_or(m::EMPTY_SYMBOL_WIDTH);
        let label = svg_text(
            card["title"].as_str().unwrap_or("暂无节目"),
            // `HStack(spacing: 12)` + `.padding(.horizontal, 20)`: 20 + 12 + the
            // symbol's own width.
            m::EMPTY_H_PADDING + m::EMPTY_GAP + symbol_width,
            card["emptySymbol"]["labelBaseline"].as_f64().unwrap_or(38.),
            m::EMPTY_TEXT_SIZE,
            600,
            m::EMPTY_TEXT,
            width - 52. - symbol_width,
        );
        return format!(
            r##"<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{}" viewBox="0 0 {width} {}"><rect x=".5" y=".5" width="{inner_width}" height="{}" rx="{}" fill="#1c252d"/><rect x=".5" y=".5" width="{inner_width}" height="{}" rx="{}" fill="none" stroke="{}" stroke-opacity="{}"/><path d="M20 32h3l2-6 3 12 3-18 3 20 2-8h2" transform="translate(-8.8889 0) scale(1.444444 1)" fill="none" stroke="{}" stroke-opacity=".9" stroke-width="1.5"/>{label}</svg>"##,
            m::EMPTY_HEIGHT,
            m::EMPTY_HEIGHT,
            m::EMPTY_HEIGHT - 1.,
            m::EMPTY_RADIUS,
            m::EMPTY_HEIGHT - 1.,
            m::EMPTY_RADIUS,
            m::EMPTY_STROKE,
            m::EMPTY_STROKE_OPACITY,
            m::EMPTY_STROKE,
        );
    }
    let geometry = card_geometry(catalog);
    let (w, h, r) = (geometry.width, geometry.height, geometry.radius);
    let current = card["isCurrent"].as_bool() == Some(true);
    let border = if current { "#68d6e8" } else { "#ffffff" };
    let border_alpha = if current { 0.52 } else { 0.12 };
    let mut body = format!(
        r##"<defs><linearGradient id="surface" x2="1" y2="1"><stop stop-color="#028ce0" stop-opacity="{}"/><stop offset="1" stop-color="#000000" stop-opacity=".12"/></linearGradient></defs><rect x=".6" y=".6" width="{}" height="{}" rx="{r}" fill="#1c252d"/><rect x=".6" y=".6" width="{}" height="{}" rx="{r}" fill="url(#surface)" stroke="{border}" stroke-opacity="{border_alpha}" stroke-width="{}"/>"##,
        if current { 0.19 } else { 0.06 },
        w - 1.2,
        h - 1.2,
        w - 1.2,
        h - 1.2,
        if current { 1.2 } else { 0.8 }
    );
    let circle = if playlist { "#ff5151" } else { "#7af2ff" };
    let icon_edge = if catalog {
        m::CARD_PLATE_CATALOG
    } else {
        m::CARD_PLATE_TRACK
    };
    body.push_str(&format!(r#"<rect x="14" y="16" width="{icon_edge}" height="{icon_edge}" rx="{}" fill="{circle}" fill-opacity="{}"/>"#,if playlist {12}else{22},if playlist {0.1}else{0.12}));
    if current && !catalog {
        for i in 0..5 {
            let sample = audio["waveform"][i].as_f64().unwrap_or(0.).abs();
            let band = audio[if i < 2 {
                "low"
            } else if i == 2 {
                "mid"
            } else {
                "high"
            }]
            .as_f64()
            .unwrap_or(0.);
            let amplitude = audio["amplitude"].as_f64().unwrap_or(0.);
            let height = 5. + 18. * sample.max(band * 0.72).max(amplitude * 0.56);
            body.push_str(&format!(
                r##"<rect x="{}" y="{}" width="2.4" height="{height}" rx="1.2" fill="#7af2ff"/>"##,
                25. + i as f64 * 4.4,
                38. - height / 2.
            ));
        }
    } else if !has_artwork {
        let icon = if catalog && !playlist {
            gpui_kit::assets::IconName::Radio
        } else if playlist {
            gpui_kit::assets::IconName::ListMusic
        } else {
            gpui_kit::assets::IconName::Music
        };
        body.push_str(&icon_svg(
            icon,
            if catalog { 26.5 } else { 25. },
            if catalog { 28.5 } else { 27. },
            if catalog { 17. } else { 22. },
            circle,
        ));
    }
    let title_size = if current && !catalog {
        m::CARD_TITLE_CURRENT_SIZE
    } else {
        m::CARD_TITLE_SIZE
    };
    // The original `HStack(spacing: 13)` starts its text column after the
    // 14 pt leading inset and the 42/44 pt artwork plate.
    body.push_str(&svg_text(
        card["title"].as_str().unwrap_or(""),
        m::CARD_H_PADDING as f64 + icon_edge + m::CARD_GAP as f64,
        33.,
        title_size,
        600,
        m::CARD_TITLE_COLOR,
        if catalog { 207. } else { 209. },
    ));
    body.push_str(&svg_text(
        card[if catalog { "subtitle" } else { "artist" }]
            .as_str()
            .unwrap_or(""),
        m::CARD_H_PADDING as f64 + icon_edge + m::CARD_GAP as f64,
        54.,
        if catalog {
            m::CARD_SUBTITLE_SIZE
        } else {
            m::CARD_ARTIST_SIZE
        },
        500,
        m::CARD_SUBTITLE_COLOR,
        if catalog { 207. } else { 164. },
    ));
    if catalog {
        if card["isPending"].as_bool() == Some(true) {
            body.push_str(r##"<path d="M286 29l2 7 7 2-7 2-2 7-2-7-7-2 7-2z" fill="#7af2ff"/>"##);
        } else {
            body.push_str(r##"<path d="M284 32l5 6-5 6" fill="none" stroke="#ffffff" stroke-opacity=".34" stroke-width="1.8"/>"##);
        }
    } else {
        for i in 0..m::ENERGY_BARS {
            let height = energy_height(card["energy"].as_f64().unwrap_or(0.) as f32, i);
            body.push_str(&format!(
                r##"<rect x="{}" y="{}" width="{}" height="{height}" rx="1" fill="#00ffff" fill-opacity=".42"/>"##,
                252. + i as f64 * 4.,
                49. - height / 2.,
                m::ENERGY_BAR_WIDTH,
            ));
        }
        if current && card["hasBoundVideo"].as_bool() == Some(true) {
            body.push_str(r##"<circle cx="272" cy="21" r="13" fill="#263641"/><path d="M265 17h10v8h-10z M275 19l5-2v8l-5-2z" fill="#a3b3bb"/>"##);
        }
    }
    format!(
        r#"<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">{body}</svg>"#
    )
}

fn card_transform(card: &Value, catalog: bool) -> CardTransform {
    if card["isEmpty"].as_bool() == Some(true) {
        return CardTransform {
            width: empty_card_width(card),
            height: m::EMPTY_HEIGHT,
            scale: 1.,
            y_degrees: 0.,
            perspective: m::PERSPECTIVE,
        };
    }
    let focused = card["isFocused"]
        .as_bool()
        .unwrap_or(card["isCurrent"].as_bool() == Some(true));
    let geometry = card_geometry(catalog);
    CardTransform {
        width: geometry.width,
        height: geometry.height,
        scale: if catalog {
            1.
        } else {
            card["scale"].as_f64().unwrap_or(1.)
                + if focused { m::FOCUS_SCALE_BUMP } else { 0. }
        },
        y_degrees: if catalog {
            m::CATALOG_ROTATION
        } else if focused {
            m::TRACK_ROTATION_FOCUSED
        } else {
            m::TRACK_ROTATION_BASE
                - card["relativeIndex"].as_i64().unwrap_or(0).clamp(-2, 2) as f64
                    * m::TRACK_ROTATION_STEP
        },
        perspective: m::PERSPECTIVE,
    }
}
fn energy_height(energy: f32, index: usize) -> f32 {
    m::ENERGY_BASE
        + m::ENERGY_SWING
            * energy
            * (m::ENERGY_WAVE_BASE + ((index + 1) as f32 * 1.7).sin().abs() * m::ENERGY_WAVE_SWING)
}

/// Card geometry, transcribed from `StageProgramRailView` (`:3724`, `:3942`,
/// `:4122`): a catalog card is 306×74 r22, a track card is 294×76 r23. The two
/// are **constant** — depth, focus and audio never resize a card.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CardGeometry {
    pub width: f64,
    pub height: f64,
    pub radius: f64,
}

pub fn card_geometry(catalog: bool) -> CardGeometry {
    if catalog {
        CardGeometry {
            width: m::CATALOG_CARD_WIDTH as f64,
            height: m::CATALOG_CARD_HEIGHT as f64,
            radius: m::CATALOG_CARD_RADIUS as f64,
        }
    } else {
        CardGeometry {
            width: m::TRACK_CARD_WIDTH as f64,
            height: m::TRACK_CARD_HEIGHT as f64,
            radius: m::TRACK_CARD_RADIUS as f64,
        }
    }
}

/// `StageProgramRailCardLayout.horizontalOffset(relativeIndex:isFocused:)`
/// (`:3370-3380`): the focused card sits 30 pt left, every other card is pushed
/// out by `min(2, |relativeIndex|) * 9`. The host may project its own
/// `horizontalOffset`; this is the original's rule and the fallback.
pub fn card_horizontal_offset(relative_index: i64, focused: bool) -> f64 {
    if focused {
        m::CARD_OFFSET_FOCUSED
    } else {
        relative_index
            .unsigned_abs()
            .min(m::CARD_OFFSET_LIMIT as u64) as f64
            * m::CARD_OFFSET_STEP
    }
}

const TRACK_HEIGHT: f32 = m::TRACK_CARD_HEIGHT;
const TRACK_SPACING: f32 = m::TRACK_SPACING;
fn pagination_key(
    state: &Value,
    viewport: f32,
    offset: f32,
    requested: Option<&(String, usize)>,
) -> Option<(String, usize)> {
    let count = state["tracks"].as_array().map_or(0, Vec::len);
    let key = (state["playlistID"].as_str()?.to_owned(), count);
    let last_four_top = 18. + count.saturating_sub(4) as f32 * (TRACK_HEIGHT + TRACK_SPACING);
    (state["isPlaylist"].as_bool() == Some(true)
        && !key.0.is_empty()
        && (count == 0 || last_four_top < -offset + viewport)
        && (count == 0 || state["hasMore"].as_bool() == Some(true))
        && state["playlistLoading"].as_bool() != Some(true)
        && requested != Some(&key))
    .then_some(key)
}
const PROGRAM_SPACING: f32 = m::CATALOG_SPACING;

/// The bound-video glyph's touch target: `ZStack(alignment: .topTrailing)` with
/// the control `.frame(width: 26, height: 26).offset(x: -9, y: 8)` inside the
/// 294 pt track card (`:4159-4187`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct VideoHitBox {
    pub x: f64,
    pub y: f64,
    pub size: f64,
}

pub fn video_hit_box() -> VideoHitBox {
    VideoHitBox {
        x: m::TRACK_CARD_WIDTH as f64 - m::VIDEO_BUTTON as f64 - m::VIDEO_OFFSET_RIGHT as f64,
        y: m::VIDEO_OFFSET_TOP as f64,
        size: m::VIDEO_BUTTON as f64,
    }
}

/// Whether a point inside the card's own (unprojected) coordinates lands on the
/// bound-video control. The same test is used for press and release, so a press
/// that drifts off the control cannot still fire it.
pub fn video_hit_test(local: [f64; 2]) -> bool {
    let hit = video_hit_box();
    local[0] >= hit.x && local[0] <= hit.x + hit.size && local[1] >= hit.y && local[1] <= hit.y + hit.size
}

/// `StageProgramRailRoute` (`:3468-3473`): which of the three lists is on screen.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RailRoute {
    Programs,
    Tracks,
    PlaylistTracks,
}

pub fn rail_route(snapshot: &Value) -> RailRoute {
    match snapshot["route"].as_str() {
        Some("programs") | None => RailRoute::Programs,
        Some(_) if snapshot["isPlaylist"].as_bool() == Some(true) => RailRoute::PlaylistTracks,
        Some(_) => RailRoute::Tracks,
    }
}

/// What the rail shows when it has no cards (`:3646-3660`, `:3759-3782`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RailEmpty {
    /// The 142×64 `emptyState` card, `.padding(.top, 96)`, no header.
    Card,
    /// `ProgressView` + 「正在加载歌曲…」 for a playlist with no tracks yet.
    LoadingPlaylist,
}

/// The original's own empty decision: a catalog with no programs **and** no
/// playlists, or a track list with no cards at all, is an empty state — never a
/// header over an empty scroll.
pub fn rail_empty(route: RailRoute, catalog_items: usize, track_count: usize) -> Option<RailEmpty> {
    match route {
        RailRoute::Programs => (catalog_items == 0).then_some(RailEmpty::Card),
        RailRoute::Tracks => (track_count == 0).then_some(RailEmpty::Card),
        RailRoute::PlaylistTracks => (track_count == 0).then_some(RailEmpty::LoadingPlaylist),
    }
}

/// `Text(programStore.status == .planning ? "DJ 正在排歌" : "暂无节目")` (`:4036`).
pub fn rail_empty_title(planning: bool) -> &'static str {
    if planning {
        "DJ 正在排歌"
    } else {
        "暂无节目"
    }
}

fn card_priority(card: &Value, distance_bias: usize) -> usize {
    if card["isFocused"]
        .as_bool()
        .unwrap_or(card["isCurrent"].as_bool() == Some(true))
        || card["isCurrent"].as_bool() == Some(true)
    {
        20 + distance_bias
    } else {
        (10 + distance_bias)
            .saturating_sub(card["relativeIndex"].as_i64().unwrap_or(0).unsigned_abs() as usize)
    }
}

// Restore view-aligned settling with the original 18pt inset. Swift's
// `.always` velocity-dependent view limit is distinct from `.alwaysByOne`;
// GPUI does not expose that native target calculation, so do not invent a
// one-card restriction that would prevent browsing the real library.
fn snap_offset(offset: f32, maximum: f32) -> f32 {
    let stride = TRACK_HEIGHT + TRACK_SPACING;
    if -offset >= maximum {
        return -maximum;
    }
    let target = (-offset / stride).round();
    -(target * stride).clamp(0., maximum)
}

// GPUI macOS forwards finger Started/Ended but not momentumPhase; ordinary
// wheel and momentum updates both arrive as Moved. Never settle a live finger
// gesture simply because the user pauses. Once released, debounce all Moved
// updates so momentum cannot be interrupted by a premature alignment.
fn schedule_scroll_settle(finger_active: &mut bool, phase: TouchPhase) -> bool {
    match phase {
        TouchPhase::Started => {
            *finger_active = true;
            false
        }
        TouchPhase::Ended => {
            *finger_active = false;
            true
        }
        TouchPhase::Cancelled => {
            *finger_active = false;
            false
        }
        TouchPhase::Moved => !*finger_active,
    }
}

pub struct StageProgramRailPane {
    snapshot: Value,
    commands: Vec<Value>,
    scroll: ScrollHandle,
    center_active: bool,
    animate_center: bool,
    center_task: Option<Task<()>>,
    center_generation: u64,
    scroll_start: Option<f32>,
    scroll_finger_active: bool,
    snap_task: Option<Task<()>>,
    renderer: SvgRenderer,
    card_cache: CardSourceCache,
    pressed_card: Option<(String, bool)>,
    projection_cache: ProjectionCache,
    focus_handles: HashMap<String, FocusHandle>,
    pagination_request: Option<(String, usize)>,
    material_renderer: Option<MaterialRenderer>,
    material_frame: Rc<RefCell<ProgramMaterialFrame>>,
    material_applied: Rc<Cell<bool>>,
    material_ready: Rc<Cell<bool>>,
    material_sources: CardSourceCache,
    material_projections: Rc<RefCell<HashMap<String, (String, Arc<RenderImage>)>>>,
    prepare_worker: Arc<CardPrepareWorker>,
    prepare_generation: u64,
}
impl StageProgramRailPane {
    pub fn new(_window: &mut Window, _cx: &mut Context<Self>) -> Self {
        Self {
            snapshot: Value::Null,
            commands: vec![json!({"op":"stage.program.load"})],
            scroll: ScrollHandle::new(),
            center_active: true,
            animate_center: false,
            center_task: None,
            center_generation: 0,
            scroll_start: None,
            scroll_finger_active: false,
            snap_task: None,
            renderer: SvgRenderer::new(Arc::new(())),
            card_cache: Rc::new(RefCell::new(HashMap::new())),
            pressed_card: None,
            projection_cache: Rc::new(RefCell::new(HashMap::new())),
            focus_handles: HashMap::new(),
            pagination_request: None,
            material_renderer: None,
            material_frame: Rc::new(RefCell::new(ProgramMaterialFrame::default())),
            material_applied: Rc::new(Cell::new(false)),
            material_ready: Rc::new(Cell::new(true)),
            material_sources: Rc::new(RefCell::new(HashMap::new())),
            material_projections: Rc::new(RefCell::new(HashMap::new())),
            prepare_worker: CardPrepareWorker::new(),
            prepare_generation: 0,
        }
    }
    pub fn update_snapshot(
        &mut self,
        snapshot: Value,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.snapshot != snapshot {
            let active = |state: &Value| {
                state["tracks"]
                    .as_array()
                    .and_then(|cards| {
                        cards
                            .iter()
                            .find(|card| card["isCurrent"].as_bool() == Some(true))
                    })
                    .map(|card| card["slotIndex"].clone())
            };
            if self.snapshot["route"] != snapshot["route"]
                || active(&self.snapshot) != active(&snapshot)
            {
                self.center_active = true;
                self.animate_center = self.snapshot["route"] == snapshot["route"]
                    && active(&self.snapshot) != active(&snapshot)
                    && snapshot["reduceMotion"].as_bool() != Some(true);
                self.center_task = None;
                self.center_generation = self.center_generation.wrapping_add(1);
                self.snap_task = None;
                self.scroll_start = None;
                self.scroll_finger_active = false;
            }
            if self.snapshot["route"] != snapshot["route"] {
                self.prepare_generation = self.prepare_generation.wrapping_add(1);
                self.prepare_worker.reset(self.prepare_generation);
                self.pagination_request = None;
                self.card_cache.borrow_mut().clear();
                self.pressed_card = None;
                self.projection_cache.borrow_mut().clear();
                self.focus_handles.clear();
            }
            if snapshot["reduceMotion"].as_bool() == Some(true)
                && self.snapshot["reduceMotion"].as_bool() != Some(true)
            {
                self.center_task = None;
                self.center_generation = self.center_generation.wrapping_add(1);
                self.animate_center = false;
            }
            self.snapshot = snapshot;
            cx.notify();
        }
    }
    pub fn take_commands(&mut self) -> Vec<Value> {
        std::mem::take(&mut self.commands)
    }
    pub fn set_native_material_renderer(
        &mut self,
        renderer: Option<MaterialRenderer>,
        cx: &mut Context<Self>,
    ) {
        if let Some(old) = self.material_renderer.take() {
            let _ = old(&ProgramMaterialFrame::default());
        }
        self.material_renderer = renderer;
        self.prepare_generation = self.prepare_generation.wrapping_add(1);
        self.prepare_worker.reset(self.prepare_generation);
        self.material_applied.set(false);
        self.material_sources.borrow_mut().clear();
        self.material_projections.borrow_mut().clear();
        cx.notify();
    }
    pub fn native_material_frame(&self) -> ProgramMaterialFrame {
        self.material_frame.borrow().clone()
    }
    fn material_publisher(&self, cx: &mut Context<Self>) -> AnyElement {
        let renderer = self.material_renderer.clone();
        let frame = self.material_frame.clone();
        let ready = self.material_ready.clone();
        let applied = self.material_applied.clone();
        let worker = self.prepare_worker.clone();
        let view = cx.weak_entity();
        // Card rows are deferred. This publisher must be deferred after ALL
        // their prepaints, while still preceding every foreground paint.
        deferred(
            canvas(
                move |_, window, _| {
                    let success = renderer.as_ref().is_some_and(|renderer| {
                        if ready.get() {
                            renderer(&frame.borrow())
                        } else {
                            let _ = renderer(&ProgramMaterialFrame::default());
                            false
                        }
                    });
                    applied.set(success);
                    if worker.busy() {
                        let view = view.clone();
                        window.on_next_frame(move |_, cx| {
                            let _ = view.update(cx, |_, cx| cx.notify());
                        });
                    }
                },
                |_, _, _, _| {},
            )
            .absolute()
            .top(px(0.))
            .left(px(0.))
            .w(px(1.))
            .h(px(1.)),
        )
        .with_priority(usize::MAX)
        .into_any_element()
    }
    fn projected_card(
        &mut self,
        card: &Value,
        catalog: bool,
        playlist: bool,
        op: &'static str,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let empty = card["isEmpty"].as_bool() == Some(true);
        let id = if catalog {
            format!("{op}-{}", card["id"].as_str().unwrap_or(""))
        } else {
            format!("track-{}", card["slotIndex"])
        };
        let audio = if !catalog && card["isCurrent"].as_bool() == Some(true) {
            self.snapshot["audioFeatures"].clone()
        } else {
            Value::Null
        };
        // Keep every row's original layout, AX label and keyboard action, but
        // defer HTTP/decode and CoreText/SVG work until its measured viewport
        // intersection is known. Swift's original LazyVStack does this too.
        let source_card = card.clone();
        let renderer = self.renderer.clone();
        let sources = self.card_cache.clone();
        let material_sources = self.material_sources.clone();
        let source_id = id.clone();
        let prepare_worker = self.prepare_worker.clone();
        let prepare_generation = self.prepare_generation;
        let focused = card["isFocused"]
            .as_bool()
            .unwrap_or(card["isCurrent"].as_bool() == Some(true));
        let transform = card_transform(card, catalog);
        let opacity = if focused || catalog {
            1.
        } else {
            card["opacity"].as_f64().unwrap_or(1.)
        };
        let offset = if catalog {
            0.
        } else {
            card["horizontalOffset"]
                .as_f64()
                .unwrap_or_else(|| card_horizontal_offset(card["relativeIndex"].as_i64().unwrap_or(0), focused))
        };
        let video = !catalog
            && card["isCurrent"].as_bool() == Some(true)
            && card["hasBoundVideo"].as_bool() == Some(true);
        let play = if catalog {
            json!({"op":op,"id":card["id"]})
        } else {
            json!({"op":"stage.program.play","slotIndex":card["slotIndex"]})
        };
        let video_command = json!({"op":"stage.program.video","trackID":card["trackID"]});
        let effects = card_effects(card, catalog);
        let scroll = self.scroll.clone();
        let view = cx.weak_entity();
        let width = transform.width as f32;
        let height = transform.height as f32;
        let cache = self.projection_cache.clone();
        let cache_id = id.clone();
        let material_frame = self.material_frame.clone();
        let material_ready = self.material_ready.clone();
        let material_applied = self.material_applied.clone();
        let material_cache = self.material_projections.clone();
        let material_id = id.clone();
        let material_enabled = self.material_renderer.is_some();
        let distance_bias = self.snapshot["tracks"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|c| c["relativeIndex"].as_i64().unwrap_or(0).unsigned_abs() as usize)
            .max()
            .unwrap_or(0);
        let material_priority = if catalog {
            0
        } else {
            card_priority(card, distance_bias)
        };
        let focus = self
            .focus_handles
            .entry(id.clone())
            .or_insert_with(|| cx.focus_handle())
            .clone();
        let mouse_focus = focus.clone();
        let keyboard_play = play.clone();
        let accessibility_id = id.clone();
        let canvas = canvas(
            move |bounds, window, cx| {
                let viewport = if empty { Bounds::new(point(px(0.),px(0.)),window.viewport_size()) } else {scroll.bounds()};
                let origin = [
                    f64::from(f32::from(bounds.origin.x)),
                    f64::from(f32::from(bounds.origin.y)),
                ];
                let mask = RailMask {
                    top: f64::from(f32::from(viewport.origin.y)),
                    height: f64::from(f32::from(viewport.size.height)),
                };
                let projection_mask = if empty { None } else {Some(mask)};
                let phase=if catalog {0.}else{scroll_phase(f64::from(f32::from(bounds.origin.y)),transform.height,mask.top,mask.height)};
                let amount=phase.abs();
                let transition=if catalog {None}else{Some(ScrollTransition{scale:1.-0.1*amount,degrees:phase*-13.,axis:[1.,0.16,0.],perspective:0.72,offset_before:[offset,0.]})};
                let opacity=opacity*(1.-0.44*amount);
                let corners = [
                    [0., 0.],
                    [transform.width, 0.],
                    [0., transform.height],
                    [transform.width, transform.height],
                ]
                .map(|p| transform.project_point(p));
                let top = corners
                    .iter()
                    .map(|p| p[1] + origin[1])
                    .fold(f64::INFINITY, f64::min);
                let bottom = corners
                    .iter()
                    .map(|p| p[1] + origin[1])
                    .fold(f64::NEG_INFINITY, f64::max);
                let padding=(effects.shadow.as_ref().map_or(0.,|shadow|shadow.radius*3.+shadow.offset[1].abs())+effects.blur_radius*3.)*transform.scale;
                if bottom+padding <= mask.top || top-padding >= mask.top + mask.height {
                    cache.borrow_mut().remove(&cache_id);
                    material_cache.borrow_mut().remove(&material_id);
                    return None;
                }
                let artwork = if playlist {
                    source_card["artworkURL"].as_str().filter(|u|u.starts_with("https://")||u.starts_with("http://"))
                        .and_then(|u|window.use_asset::<ImageAssetLoader>(&Resource::Uri(u.to_owned().into()),cx)).and_then(Result::ok)
                } else {None};
                let source_key=format!("{}/{audio}/{catalog}/{playlist}/{:?}",json!({"title":source_card["title"],"artist":source_card["artist"],"subtitle":source_card["subtitle"],"isCurrent":source_card["isCurrent"],"hasBoundVideo":source_card["hasBoundVideo"],"isPending":source_card["isPending"],"energy":source_card["energy"]}),artwork.as_ref().map(|a|a.id));
                let window_size = [
                    f64::from(f32::from(window.viewport_size().width)),
                    f64::from(f32::from(window.viewport_size().height)),
                ];
                let cache_key=format!("{source_key}/{transform:?}/{origin:?}/{window_size:?}/{}/{opacity}/{mask:?}/{transition:?}/{effects:?}/{material_enabled}",window.scale_factor());
                prepare_worker.submit(CardPrepareJob{id:source_id.clone(),key:cache_key,source_key,generation:prepare_generation,
                    renderer:renderer.clone(),card:source_card.clone(),audio:audio.clone(),artwork,catalog,playlist,material:material_enabled,
                    transform,origin,viewport:window_size,ppp:window.scale_factor() as f64,opacity,mask:projection_mask,transition,effects});
                let ready=prepare_worker.ready(&source_id,prepare_generation)?;
                let delta=[origin[0]-ready.origin[0],origin[1]-ready.origin[1]];
                let projected=ready.projected.clone();
                let image=ready.image.clone();
                let foreground=ready.foreground.clone();
                sources.borrow_mut().insert(source_id.clone(),(ready.source_key.clone(),ready.source.clone()));
                if let Some(source)=&ready.material_source {material_sources.borrow_mut().insert(source_id.clone(),(ready.source_key.clone(),source.clone()));}
                cache.borrow_mut().insert(cache_id,(ready.key.clone(),projected.clone(),image.clone()));
                if material_enabled {
                    if let Some(image)=&foreground {material_cache.borrow_mut().insert(material_id.clone(),(ready.key.clone(),image.clone()));}
                    if foreground.is_none() { material_ready.set(false); }
                    let mut frame = material_frame.borrow_mut();
                    frame.viewport = [f64::from(f32::from(viewport.origin.x)), mask.top, f64::from(f32::from(viewport.size.width)), mask.height];
                    frame.scale = window.scale_factor() as f64;
                    let material_card = ProgramMaterialCard { id: material_id, width: transform.width, height: transform.height, radius: if catalog {22.}else{23.}, opacity: ready.opacity, priority: material_priority as f64, matrix: projected.shifted_source_to_world_matrix(delta) };
                    if video { frame.cards.push(video_material_card(&material_card)); }
                    frame.cards.push(material_card);
                }
                Some((projected, image, foreground,delta))
            },
            move |_, projected, window, _| {
                let Some((projected, fallback, foreground,delta)) = projected else {
                    return;
                };
                let image = if material_applied.get() { foreground.unwrap_or(fallback) } else { fallback };
                let b = projected.bounds;
                let bounds = Bounds::new(
                    point(px((b[0]+delta[0]) as f32), px((b[1]+delta[1]) as f32)),
                    size(px(b[2] as f32), px(b[3] as f32)),
                );
                let _ = window.paint_image(bounds, bounds, Corners::default(), image, 0, false);
                if empty { return; }
                let down_projected = projected.clone();
                let down_view = view.clone();
                let down_id = id.clone();
                window.on_mouse_event(move |event: &MouseDownEvent, phase, window, cx| {
                    if phase != DispatchPhase::Bubble || event.button != MouseButton::Left {
                        return;
                    }
                    let point = [
                        f64::from(f32::from(event.position.x)),
                        f64::from(f32::from(event.position.y)),
                    ];
                    if let Some(local) = down_projected.inverse_hit_shifted(point,delta) {
                        window.focus(&mouse_focus, cx);
                        let video_hit = video && video_hit_test(local);
                        _ = down_view.update(cx, |this, _| {
                            this.pressed_card = Some((down_id.clone(), video_hit))
                        });
                        cx.stop_propagation();
                    }
                });
                window.on_mouse_event(move |event: &MouseUpEvent, phase, _, cx| {
                    if phase != DispatchPhase::Bubble || event.button != MouseButton::Left {
                        return;
                    }
                    let point = [
                        f64::from(f32::from(event.position.x)),
                        f64::from(f32::from(event.position.y)),
                    ];
                    if let Some(local) = projected.inverse_hit_shifted(point,delta) {
                        let video_hit = video && video_hit_test(local);
                        _ = view.update(cx, |this, cx| {
                            if this.pressed_card.take() == Some((id.clone(), video_hit)) {
                                this.commands.push(if video_hit {
                                    video_command.clone()
                                } else {
                                    play.clone()
                                });
                                cx.notify();
                            }
                        });
                        cx.stop_propagation();
                    }
                });
            },
        )
        .w(px(width))
        .h(px(height))
        .flex_shrink_0();
        if empty {
            return div()
                .id("empty-program-state")
                .role(Role::Label)
                .aria_label(card["title"].as_str().unwrap_or("暂无节目").to_owned())
                .child(canvas)
                .into_any_element();
        }
        let label = if catalog {
            card["title"].as_str().unwrap_or("").to_owned()
        } else {
            format!(
                "{}，{}，{}",
                if card["isCurrent"].as_bool() == Some(true) {
                    "正在播放"
                } else {
                    "选择"
                },
                card["title"].as_str().unwrap_or(""),
                card["artist"].as_str().unwrap_or("")
            )
        };
        let mut wrapper = div()
            .id(accessibility_id)
            .relative()
            .w(px(width))
            .h(px(height))
            .flex_shrink_0()
            .role(Role::Button)
            .aria_label(label)
            .track_focus(&focus)
            .on_key_down(cx.listener(move |this, event: &KeyDownEvent, _, cx| {
                if !event.keystroke.modifiers.modified()
                    && matches!(event.keystroke.key.as_str(), "enter" | "space")
                {
                    this.commands.push(keyboard_play.clone());
                    cx.stop_propagation();
                    cx.notify();
                }
            }))
            .child(canvas);
        if video {
            let command = json!({"op":"stage.program.video","trackID":card["trackID"]});
            wrapper = wrapper.child(
                Button::new(format!("video-{}", card["trackID"]))
                    .custom(scene_variant(
                        cx,
                        0xffffff26,
                        m::REPLAN_FILL,
                        s::ICON_ACTIVE,
                    ))
                    .absolute()
                    .right(px(m::VIDEO_OFFSET_RIGHT))
                    .top(px(m::VIDEO_OFFSET_TOP))
                    .w(px(m::VIDEO_BUTTON))
                    .h(px(m::VIDEO_BUTTON))
                    .rounded(px(m::VIDEO_BUTTON / 2.))
                    .text_color(rgba(s::ICON_ACTIVE))
                    .icon(AssetIcon::Video)
                    .tooltip("播放这首歌绑定的视频")
                    .accessibility_label("播放绑定视频")
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.commands.push(command.clone());
                        cx.notify();
                    })),
            );
        }
        wrapper.into_any_element()
    }
    /// The rail header's round controls: the 28 pt replan/planning button
    /// (`:3975-4001`) and the plain 12 pt back chevron (`:3785-3793`).
    fn icon_button(
        &self,
        id: impl Into<ElementId>,
        icon: AssetIcon,
        tooltip: &'static str,
        command: Value,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let replan = command["op"].as_str() == Some("stage.program.replan");
        let planning = replan && self.snapshot["planning"].as_bool() == Some(true);
        let back = command["op"].as_str() == Some("stage.program.back");
        let size = if back {
            m::BACK_ICON
        } else {
            m::REPLAN_BUTTON
        };
        let text = if planning { s::WARNING } else { s::ICON_ACTIVE };
        Button::new(id)
            .custom(scene_variant(
                cx,
                if back { 0x00000000 } else { m::REPLAN_FILL },
                m::REPLAN_FILL,
                if back { s::ICON_ACTIVE } else { text },
            ))
            .w(px(size))
            .h(px(size))
            .rounded(px(size / 2.))
            .text_color(if back {
                rgba(s::ICON_ACTIVE)
            } else {
                rgba(text)
            })
            .icon(if planning {
                AssetIcon::Hourglass
            } else {
                icon
            })
            .disabled(planning)
            .tooltip(if replan {
                if planning {
                    "DJ 正在重新编排"
                } else {
                    "让 DJ 重新编排后续歌曲"
                }
            } else {
                tooltip
            })
            .accessibility_label(if replan {
                if planning {
                    "DJ 正在重新编排"
                } else {
                    m::REPLAN_LABEL
                }
            } else {
                tooltip
            })
            .on_click(cx.listener(move |this, _, _, cx| {
                this.commands.push(command.clone());
                cx.notify();
            }))
            .into_any_element()
    }
}
impl Render for StageProgramRailPane {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        {
            let mut frame = self.material_frame.borrow_mut();
            let revision = frame.revision.wrapping_add(1);
            *frame = ProgramMaterialFrame {
                revision,
                fade_fraction: 0.08,
                ..Default::default()
            };
        }
        self.material_ready.set(true);
        self.material_applied.set(false);
        let route = rail_route(&self.snapshot);
        let tracks = route != RailRoute::Programs;
        let track_count = self.snapshot["tracks"].as_array().map_or(0, Vec::len);
        let catalog_items = self.snapshot["programs"]
            .as_array()
            .map_or(0, Vec::len)
            + self.snapshot["playlists"].as_array().map_or(0, Vec::len);
        let empty = rail_empty(route, catalog_items, track_count);
        if tracks && self.snapshot["isPlaylist"].as_bool() == Some(true) {
            let view = cx.entity().downgrade();
            window.on_next_frame(move |window, cx| {
                _ = view.update(cx, |this, cx| {
                    let viewport: f32 = this.scroll.bounds().size.height.into();
                    let offset: f32 = this.scroll.offset().y.into();
                    if let Some(key) = pagination_key(
                        &this.snapshot,
                        viewport,
                        offset,
                        this.pagination_request.as_ref(),
                    ) {
                        this.pagination_request = Some(key);
                        this.commands.push(json!({"op":"stage.program.more"}));
                        cx.notify();
                    }
                });
                let _ = window;
            });
        }
        if let Some(empty) = empty {
            // The empty state replaces the whole rail: no header, no refresh
            // control, no content margins, and no scroll rail mask — only the
            // waveform card (or the playlist spinner), 96 pt below the top inset.
            self.material_frame.borrow_mut().fade_fraction = 0.;
            let state: AnyElement = match empty {
                RailEmpty::LoadingPlaylist => div()
                    .flex()
                    .flex_col()
                    .items_center()
                    .gap(px(m::LOADING_GAP))
                    .text_size(px(m::LOADING_SIZE))
                    .text_color(rgba(m::LOADING_TEXT))
                    .child(Spinner::new().small())
                    .child("正在加载歌曲…")
                    .into_any_element(),
                RailEmpty::Card => {
                    let card = json!({
                        "id": "empty-state",
                        "isEmpty": true,
                        "title": rail_empty_title(self.snapshot["planning"].as_bool() == Some(true)),
                    });
                    self.projected_card(&card, true, false, "", window, cx)
                }
            };
            return div()
                .id("stage-program-rail")
                .capture_any_mouse_down(cx.listener(|this, _, _, _| this.pressed_card = None))
                .w_full()
                .h_full()
                .max_w(px(m::RAIL_WIDTH))
                .max_h(px(m::RAIL_HEIGHT))
                .pt(px(m::RAIL_TOP))
                .pr(px(m::RAIL_TRAILING))
                .flex()
                .flex_col()
                .items_end()
                .font_family(doc::FONT_FAMILY)
                .text_color(rgba(s::TEXT))
                .child(div().mt(px(m::EMPTY_TOP_PADDING)).child(state))
                .child(self.material_publisher(cx));
        }
        let mut content = div()
            .flex()
            .flex_col()
            .items_end()
            .gap(px(if tracks {
                TRACK_SPACING
            } else {
                PROGRAM_SPACING
            }))
            .py(px(m::CONTENT_MARGIN));
        // The original header hugs the trailing edge (the rail is a trailing
        // `VStack`): it is sized by its content, never stretched across the rail,
        // so the back control sits next to the title instead of at the far left.
        let mut header = div()
            .flex()
            .items_center()
            .gap(px(if tracks {
                m::HEADER_TRACK_GAP
            } else {
                m::HEADER_CATALOG_GAP
            }))
            .px(px(m::HEADER_H_PADDING))
            .text_size(px(m::HEADER_SIZE))
            .font_weight(FontWeight::SEMIBOLD)
            .text_color(rgba(m::HEADER_TEXT))
            .self_end();
        if tracks {
            // Preserve negative Swift zIndex values by shifting every priority
            // equally, rather than collapsing all distant cards to zero.
            let distance_bias = self.snapshot["tracks"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|card| card["relativeIndex"].as_i64().unwrap_or(0).unsigned_abs() as usize)
                .max()
                .unwrap_or(0);
            header = header
                .child(self.icon_button(
                    "program-back",
                    AssetIcon::ChevronLeft,
                    m::BACK_LABEL,
                    json!({"op":"stage.program.back"}),
                    cx,
                ))
                .child(div().flex_1())
                .child(self.snapshot["title"].as_str().unwrap_or("").to_uppercase());
            header = header.child(if self.snapshot["isPlaylist"].as_bool() == Some(true) {
                format!(
                    "· {} / {}",
                    self.snapshot["loadedTrackCount"]
                        .as_u64()
                        .unwrap_or(track_count as u64),
                    self.snapshot["totalTrackCount"]
                        .as_u64()
                        .unwrap_or(track_count as u64)
                )
            } else {
                format!("· {track_count}")
            });
            if self.snapshot["isPlaylist"].as_bool() != Some(true) {
                header = header.child(self.icon_button(
                    "program-replan",
                    AssetIcon::RefreshCw,
                    "重新编排",
                    json!({"op":"stage.program.replan"}),
                    cx,
                ));
            }
            if self.center_active {
                if let Some(index) = self.snapshot["tracks"].as_array().and_then(|cards| {
                    cards
                        .iter()
                        .position(|card| card["isCurrent"].as_bool() == Some(true))
                }) {
                    let view = cx.entity().downgrade();
                    let generation = self.center_generation;
                    window.on_next_frame(move |window, cx| {
                        _ = view.update(cx, |this, cx| {
                            if generation != this.center_generation {
                                return;
                            }
                            let viewport: f32 = this.scroll.bounds().size.height.into();
                            let maximum: f32 = this.scroll.max_offset().y.into();
                            let target = active_center_offset(index, viewport, maximum.abs());
                            let start: f32 = this.scroll.offset().y.into();
                            if !this.animate_center || (target - start).abs() < 0.01 {
                                this.scroll.set_offset(point(px(0.), px(target)));
                                window.refresh();
                                return;
                            }
                            this.center_task = Some(cx.spawn_in(window, async move |view, cx| {
                                let began = std::time::Instant::now();
                                loop {
                                    cx.background_executor()
                                        .timer(std::time::Duration::from_millis(16))
                                        .await;
                                    let progress = (began.elapsed().as_secs_f64() / 0.24).min(1.);
                                    let offset = start
                                        + (target - start) * ease_out_progress(progress) as f32;
                                    let keep = view
                                        .update_in(cx, |this, window, cx| {
                                            if this.center_generation != generation {
                                                return false;
                                            }
                                            this.scroll.set_offset(point(px(0.), px(offset)));
                                            window.refresh();
                                            cx.notify();
                                            true
                                        })
                                        .unwrap_or(false);
                                    if !keep || progress >= 1. {
                                        break;
                                    }
                                }
                            }));
                        });
                    });
                }
                self.center_active = false;
            }
            let track_cards = self.snapshot["tracks"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            for card in &track_cards {
                let row = self.projected_card(card, false, false, "stage.program.play", window, cx);
                // GPUI deferred paint preserves measured order/positions and
                // provides the original card zIndex without reordering tracks.
                content =
                    content.child(deferred(row).with_priority(card_priority(card, distance_bias)));
            }
            if track_count > 0 && self.snapshot["hasMore"].as_bool() == Some(true) {
                content = content.child(
                    div()
                        .w(px(m::PAGING_WIDTH))
                        .h(px(m::PAGING_HEIGHT))
                        .flex()
                        .items_center()
                        .justify_center()
                        .child(Spinner::new().small()),
                );
            }
        } else {
            header = header
                .child(self.icon_button(
                    "program-replan",
                    AssetIcon::RefreshCw,
                    "重新编排",
                    json!({"op":"stage.program.replan"}),
                    cx,
                ))
                .child(div().w(px(doc::SPACING_4)))
                .child(format!(
                    "歌单 · {}",
                    self.snapshot["programs"].as_array().map_or(0, Vec::len)
                        + self.snapshot["playlists"].as_array().map_or(0, Vec::len)
                ));
            for (key, op) in [
                ("programs", "stage.program.open"),
                ("playlists", "stage.playlist.open"),
            ] {
                let items = self.snapshot[key].as_array().cloned().unwrap_or_default();
                for item in &items {
                    let row = self.projected_card(item, true, key == "playlists", op, window, cx);
                    content = content.child(row);
                }
            }
        }
        div()
            .id("stage-program-rail")
            .capture_any_mouse_down(cx.listener(|this, _, _, _| this.pressed_card = None))
            .w_full()
            .h_full()
            .max_w(px(m::RAIL_WIDTH))
            .max_h(px(m::RAIL_HEIGHT))
            .pt(px(m::RAIL_TOP))
            .pr(px(m::RAIL_TRAILING))
            .flex()
            .flex_col()
            .items_end()
            .gap(px(m::RAIL_GAP))
            .font_family(doc::FONT_FAMILY)
            .text_color(rgba(s::TEXT))
            .child(header)
            .child(
                div()
                    .id("stage-program-scroll")
                    .w_full()
                    .flex_1()
                    .min_h(px(0.))
                    .overflow_y_scroll()
                    .track_scroll(&self.scroll)
                    .on_scroll_wheel(cx.listener(
                        move |this, event: &ScrollWheelEvent, window, cx| {
                            if !tracks {
                                return;
                            }
                            this.center_task = None;
                            this.center_generation = this.center_generation.wrapping_add(1);
                            this.center_active = false;
                            if this.scroll_start.is_none()
                                || event.touch_phase == TouchPhase::Started
                            {
                                this.scroll_start = Some(this.scroll.offset().y.into());
                            }
                            if event.touch_phase == TouchPhase::Cancelled {
                                this.snap_task = None;
                                this.scroll_start = None;
                                this.scroll_finger_active = false;
                                return;
                            }
                            this.snap_task = None;
                            if !schedule_scroll_settle(
                                &mut this.scroll_finger_active,
                                event.touch_phase,
                            ) {
                                return;
                            }
                            // macOS GPUI does not expose momentumPhase. Wait for
                            // wheel activity to cease, including momentum events.
                            this.snap_task = Some(cx.spawn_in(window, async move |view, cx| {
                                cx.background_executor()
                                    .timer(std::time::Duration::from_millis(140))
                                    .await;
                                _ = view.update_in(cx, |this, _, cx| {
                                    if this.scroll_start.take().is_some() {
                                        let offset: f32 = this.scroll.offset().y.into();
                                        let maximum: f32 = this.scroll.max_offset().y.into();
                                        this.scroll.set_offset(point(
                                            px(0.),
                                            px(snap_offset(offset, maximum.abs())),
                                        ));
                                        cx.notify();
                                    }
                                });
                            }));
                        },
                    ))
                    .child(content),
            )
            // Every card's prepaint has published its actual homography before
            // this final prepaint runs. Apply all native layers atomically, then
            // foreground paint selects transparent or opaque images in THIS
            // frame. No 100ms polling, deferred geometry, or failure blank frame.
            .child(self.material_publisher(cx))
    }
}

fn active_center_offset(index: usize, viewport: f32, maximum: f32) -> f32 {
    -(m::CONTENT_MARGIN
        + index as f32 * (TRACK_HEIGHT + TRACK_SPACING)
        + TRACK_HEIGHT / 2.
        - viewport / 2.)
        .clamp(0., maximum)
}
// SwiftUI's easeOut timing curve: cubic Bezier (0, 0, 0.58, 1).
// Solve time (x) first; applying the y polynomial directly would change timing.
fn ease_out_progress(time: f64) -> f64 {
    let time = time.clamp(0., 1.);
    if time == 0. || time == 1. {
        return time;
    }
    let (mut lo, mut hi) = (0., 1.);
    for _ in 0..32 {
        let t = (lo + hi) / 2.;
        let x = 3. * (1. - t) * t * t * 0.58 + t * t * t;
        if x < time {
            lo = t;
        } else {
            hi = t;
        }
    }
    let t = (lo + hi) / 2.;
    3. * (1. - t) * t * t + t * t * t
}

#[cfg(test)]
mod tests {
    use super::{
        PROGRAM_SPACING, TRACK_SPACING, active_center_offset, card_effects, card_geometry,
        card_horizontal_offset, card_priority, card_svg, card_transform, empty_card_width,
        RailEmpty, RailRoute, energy_height, pagination_key, rail_empty, rail_empty_title,
        rail_route, scroll_phase, snap_offset, video_hit_box, video_hit_test,
    };
    use super::m;
    use serde_json::json;

    /// The rail's own geometry, transcribed from `StageProgramRailView`: a
    /// catalog card is 306×74 r22, a track card 294×76 r23, and neither number
    /// depends on depth, focus or audio.
    #[test]
    fn card_geometry_is_constant_at_the_original_sizes() {
        let catalog = card_geometry(true);
        let track = card_geometry(false);
        assert_eq!(
            (catalog.width, catalog.height, catalog.radius),
            (306., 74., 22.)
        );
        assert_eq!((track.width, track.height, track.radius), (294., 76., 23.));
        assert_ne!(catalog.width, track.width);
        assert_ne!(catalog.height, track.height);
        for card in [
            json!({"isCurrent":true,"scale":1.4,"relativeIndex":0,"depth":-72}),
            json!({"isCurrent":false,"scale":0.78,"relativeIndex":-5,"depth":-144}),
        ] {
            assert_eq!(card_transform(&card, false).width, track.width);
            assert_eq!(card_transform(&card, false).height, track.height);
            assert_eq!(card_transform(&card, true).width, catalog.width);
            assert_eq!(card_transform(&card, true).height, catalog.height);
        }
    }

    /// The empty state is the original's measured ~142×64 card (`HStack(spacing:
    /// 12)` + `.padding(.horizontal, 20)` + the 26 pt symbol + the 16 pt label):
    /// it must never grow into a 306×64 catalog card.
    #[test]
    fn empty_state_is_the_original_intrinsic_card_not_a_catalog_card() {
        let empty = json!({"id":"empty-state","isEmpty":true,"title":"暂无节目"});
        let width = empty_card_width(&empty);
        assert!(
            (width - 142.).abs() < 1.,
            "the live measured empty width is ~142, got {width}"
        );
        assert_ne!(width, card_geometry(true).width);
        let transform = card_transform(&empty, true);
        assert_eq!(transform.width, width);
        assert_eq!(transform.height, 64.);
        assert_ne!(transform.height, card_geometry(true).height);
        let svg = card_svg(&empty, &serde_json::Value::Null, true, false);
        assert!(
            svg.starts_with(&format!(
                "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{width}\" height=\"64\""
            )),
            "the rasterized card must be the intrinsic empty size: {svg}"
        );
        assert!(
            svg.contains("scale(1.444444 1)"),
            "the empty card carries the original waveform glyph (18 pt source): {svg}"
        );
        // The label is shaped text (`lyrics::shaped_text_svg`), so it is the
        // second path in the card: the waveform glyph and the label, nothing else.
        assert!(svg.contains(m::EMPTY_TEXT));
        assert_eq!(
            svg.matches("<path").count(),
            2,
            "the empty card is the waveform plus one label: {svg}"
        );
        assert!(
            !svg.contains("fill-opacity=\".42\""),
            "the empty card has no energy trace"
        );
        assert!(!svg.contains("#028ce0"), "the empty card has no card gradient");
    }

    /// The header is the original's: the catalog header uses a 10 pt gap, the
    /// track header 8, both inset 14 pt, and the replan control is the original
    /// 28 pt circle — not the 26 pt video control.
    #[test]
    fn header_geometry_matches_the_original_rail_header() {
        assert_eq!(m::HEADER_CATALOG_GAP, 10.);
        assert_eq!(m::HEADER_TRACK_GAP, 8.);
        assert_ne!(m::HEADER_CATALOG_GAP, m::HEADER_TRACK_GAP);
        assert_eq!(m::HEADER_H_PADDING, 14.);
        assert_eq!(m::HEADER_SIZE, 14.);
        assert_eq!(m::REPLAN_BUTTON, 28.);
        assert_ne!(m::REPLAN_BUTTON, m::VIDEO_BUTTON);
        assert_eq!(m::RAIL_TOP, 42.);
        assert_eq!(m::RAIL_TRAILING, 10.);
        assert_eq!(m::CONTENT_MARGIN, 18.);
    }

    /// `rail_empty` is the original's own empty decision: a catalog is empty only
    /// when programs **and** playlists are; a playlist with no tracks shows the
    /// spinner instead of the waveform card.
    #[test]
    fn rail_empty_decision_matches_the_original_routes() {
        assert_eq!(rail_empty(RailRoute::Programs, 0, 0), Some(RailEmpty::Card));
        assert_eq!(rail_empty(RailRoute::Programs, 1, 0), None);
        assert_eq!(rail_empty(RailRoute::Tracks, 0, 0), Some(RailEmpty::Card));
        assert_eq!(rail_empty(RailRoute::Tracks, 0, 3), None);
        assert_eq!(
            rail_empty(RailRoute::PlaylistTracks, 0, 0),
            Some(RailEmpty::LoadingPlaylist)
        );
        assert_eq!(rail_empty(RailRoute::PlaylistTracks, 0, 3), None);
        assert_ne!(
            rail_empty(RailRoute::PlaylistTracks, 0, 0),
            rail_empty(RailRoute::Tracks, 0, 0)
        );
        assert_eq!(rail_empty_title(false), "暂无节目");
        assert_eq!(rail_empty_title(true), "DJ 正在排歌");
        assert_ne!(rail_empty_title(false), rail_empty_title(true));
    }

    #[test]
    fn rail_route_reads_the_host_route_and_never_invents_tracks() {
        assert_eq!(rail_route(&json!({"route":"programs"})), RailRoute::Programs);
        assert_eq!(rail_route(&json!({})), RailRoute::Programs);
        assert_eq!(rail_route(&json!({"route":"tracks"})), RailRoute::Tracks);
        assert_eq!(
            rail_route(&json!({"route":"tracks","isPlaylist":true})),
            RailRoute::PlaylistTracks
        );
        assert_ne!(
            rail_route(&json!({"route":"tracks","isPlaylist":false})),
            RailRoute::PlaylistTracks
        );
    }

    /// `StageProgramRailCardLayout.horizontalOffset`: the focused card sits
    /// 30 pt left, neighbours are pushed out by `min(2, |relativeIndex|) * 9`.
    #[test]
    fn card_horizontal_offset_matches_the_original_layout() {
        assert_eq!(card_horizontal_offset(0, true), -30.);
        assert_eq!(card_horizontal_offset(3, true), -30.);
        assert_eq!(card_horizontal_offset(0, false), 0.);
        assert_eq!(card_horizontal_offset(1, false), 9.);
        assert_eq!(card_horizontal_offset(2, false), 18.);
        assert_eq!(card_horizontal_offset(-5, false), 18.);
        assert_ne!(
            card_horizontal_offset(0, true),
            card_horizontal_offset(0, false)
        );
    }

    /// The bound-video control is the original's 26 pt glyph offset 9 pt from the
    /// card's trailing edge and 8 pt from its top — inside the track card.
    #[test]
    fn bound_video_hit_target_matches_the_original_offset_button() {
        let hit = video_hit_box();
        assert_eq!((hit.x, hit.y, hit.size), (259., 8., 26.));
        assert_eq!(hit.x + hit.size, 294. - 9.);
        assert!(video_hit_test([259., 8.]));
        assert!(video_hit_test([272., 21.]));
        assert!(video_hit_test([285., 34.]));
        assert!(!video_hit_test([258.9, 21.]));
        assert!(!video_hit_test([285.1, 21.]));
        assert!(!video_hit_test([272., 7.9]));
        assert!(!video_hit_test([272., 34.1]));
    }

    /// Scroll settling must honour both ends: never a negative offset at the top,
    /// never past `maximum` at the bottom, and a zero-length rail cannot move.
    #[test]
    fn snapping_honours_the_scroll_boundaries() {
        assert_eq!(snap_offset(0., 0.), 0.);
        assert_eq!(snap_offset(-300., 0.), 0.);
        assert_eq!(snap_offset(0., 900.), 0.);
        assert_eq!(snap_offset(-900., 900.), -900.);
        assert_eq!(snap_offset(-901., 900.), -900.);
        // Half a 69 pt stride rounds to the nearer card, at the top boundary.
        assert_eq!(snap_offset(-34., 900.), 0.);
        assert_eq!(snap_offset(-35., 900.), -69.);
        assert_ne!(snap_offset(-34., 900.), snap_offset(-35., 900.));
    }

    /// The active track centres with the original 18 pt content margin, and the
    /// centring clamps at both ends of the rail.
    #[test]
    fn active_card_centering_clamps_at_both_ends() {
        assert_eq!(active_center_offset(0, 300., 900.), 0.);
        assert_eq!(active_center_offset(0, 900., 900.), 0.);
        // A card whose centre is already at or above the viewport centre needs no
        // scroll; only once it is below does the offset become negative.
        assert_eq!(active_center_offset(1, 300., 900.), 0.);
        assert_eq!(active_center_offset(2, 300., 900.), -44.);
        assert_eq!(active_center_offset(30, 300., 900.), -900.);
        assert_ne!(
            active_center_offset(0, 300., 900.),
            active_center_offset(2, 300., 900.)
        );
    }

    /// The energy trace is the original's seven-bar waveform: a fixed 5 pt base
    /// plus `13 * energy * (0.36 + |sin((index + 1) * 1.7)| * 0.64)`, so two bars
    /// of the same track are never the same height.
    #[test]
    fn energy_trace_uses_the_original_wave_shape() {
        for index in 0..m::ENERGY_BARS {
            assert_eq!(energy_height(0., index), 5.);
            let expected = 5.
                + 13. * (0.36 + (((index + 1) as f32) * 1.7).sin().abs() * 0.64);
            assert!(
                (energy_height(1., index) - expected).abs() < 1e-5,
                "bar {index} must follow the original wave, got {}",
                energy_height(1., index)
            );
        }
        assert_ne!(energy_height(1., 0), energy_height(1., 1));
        assert_ne!(energy_height(1., 2), energy_height(1., 3));
        // Index 1 is the trough of the original wave (|sin(3.4)| ≈ 0.26), so it
        // must read below both of its neighbours.
        assert!(energy_height(1., 1) < energy_height(1., 0));
        assert!(energy_height(1., 1) < energy_height(1., 2));
        assert!(energy_height(0., 3) < energy_height(1., 3));
    }

    /// Paint priority never reorders the list: the current/focused card paints
    /// above every neighbour, and among neighbours a nearer card always paints
    /// above a farther one.
    #[test]
    fn paint_priority_keeps_the_original_order_and_raises_activations() {
        let current = card_priority(&json!({"isCurrent":true,"relativeIndex":0}), 4);
        for relative in [-4, -2, -1, 1, 2, 4] {
            assert!(
                current > card_priority(&json!({"relativeIndex":relative}), 4),
                "the current card must paint above relativeIndex {relative}"
            );
        }
        let near = card_priority(&json!({"relativeIndex":1}), 4);
        let far = card_priority(&json!({"relativeIndex":3}), 4);
        assert!(near > far);
        assert_ne!(near, far);
    }
    #[test]
    fn background_queue_bounds_replaces_latest_and_rejects_old_generation() {
        use super::*;
        let worker = CardPrepareWorker {
            shared: Arc::new((
                Mutex::new(CardPrepareQueue {
                    generation: 1,
                    pending: HashMap::new(),
                    order: VecDeque::new(),
                    ready: HashMap::new(),
                    inflight: None,
                    closed: false,
                }),
                Condvar::new(),
            )),
        };
        let job = |id: usize, key: &str, generation| CardPrepareJob {
            id: id.to_string(),
            key: key.into(),
            source_key: key.into(),
            generation,
            renderer: SvgRenderer::new(Arc::new(())),
            card: json!({}),
            audio: json!({}),
            artwork: None,
            catalog: true,
            playlist: false,
            material: false,
            transform: card_transform(&json!({}), true),
            origin: [0., 0.],
            viewport: [400., 400.],
            ppp: 1.,
            opacity: 1.,
            mask: None,
            transition: None,
            effects: CardEffects::default(),
        };
        for i in 0..50 {
            worker.submit(job(i, "initial", 1));
        }
        worker.submit(job(0, "newest", 1));
        worker.submit(job(1, "stale", 0));
        {
            let queue = worker.shared.0.lock().unwrap();
            assert_eq!(queue.pending.len(), 12);
            assert_eq!(queue.order.len(), 12);
            assert_eq!(queue.pending["0"].key, "newest");
            assert_eq!(queue.pending["1"].key, "initial");
        }
        worker.reset(2);
        worker.submit(job(0, "old route", 1));
        assert!(!worker.busy());
    }
    #[test]
    fn real_fifty_catalog_draw_bounds_source_work_to_visible_rows_and_reuses_textures() {
        use gpui_kit::{AppContext, TestAppContext, point, px};
        use std::{cell::RefCell, collections::HashMap, rc::Rc, sync::Arc};
        let mut cx = TestAppContext::single();
        cx.update(gpui_kit::init);
        let stored = Rc::new(RefCell::new(None));
        let entity = stored.clone();
        let cold = std::time::Instant::now();
        let handle=cx.add_window(move|window,cx|{
            let pane=cx.new(|cx|{
                let mut pane=super::StageProgramRailPane::new(window,cx);
                // Unit regression only: no provider/library writes or requests.
                pane.snapshot=json!({"route":"programs","programs":(0..50).map(|i|json!({"id":format!("perf-{i}"),"title":"回归布局字段","subtitle":"缓存工作量"})).collect::<Vec<_>>(),"playlists":[]});
                pane.set_native_material_renderer(Some(Rc::new(|_|true)),cx);
                pane
            });
            *entity.borrow_mut()=Some(pane.clone());
            gpui_kit::base::Root::new(pane,window,cx)
        });
        cx.update_window(handle.into(), |_, window, cx| { window.refresh(); window.draw(cx).clear(cx) })
            .unwrap();
        let cold_elapsed = cold.elapsed();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        loop {
            let busy = cx.update(|cx| {
                stored
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .read(cx)
                    .prepare_worker
                    .busy()
            });
            if !busy {
                break;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "bounded background prepare must complete"
            );
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        cx.update_window(handle.into(), |_, window, cx| { window.refresh(); window.draw(cx).clear(cx) })
            .unwrap();
        let initial = cx.update(|cx| {
            let pane = stored.borrow().as_ref().unwrap().read(cx);
            assert_eq!(
                pane.focus_handles.len(),
                50,
                "offscreen rows retain original keyboard/AX entries and layout"
            );
            let sources = pane.card_cache.borrow();
            assert!(!sources.is_empty());
            assert!(
                sources.len() <= 10,
                "never rasterize the entire fifty-row library on first draw"
            );
            assert_eq!(sources.len(), pane.material_sources.borrow().len());
            sources
                .iter()
                .map(|(id, (_, source))| (id.clone(), Arc::as_ptr(source)))
                .collect::<HashMap<_, _>>()
        });
        let warm = std::time::Instant::now();
        cx.update_window(handle.into(), |_, window, cx| { window.refresh(); window.draw(cx).clear(cx) })
            .unwrap();
        let warm_elapsed = warm.elapsed();
        cx.update(|cx| {
            let pane = stored.borrow().as_ref().unwrap().read(cx);
            let sources = pane.card_cache.borrow();
            assert_eq!(sources.len(), initial.len());
            for (id, pointer) in &initial {
                assert_eq!(
                    Arc::as_ptr(&sources[id].1),
                    *pointer,
                    "warm frame performs no text/SVG raster rebuild"
                );
            }
        });
        let scrolled = std::time::Instant::now();
        cx.update_window(handle.into(), |_, window, cx| {
            stored.borrow().as_ref().unwrap().update(cx, |pane, cx| {
                pane.scroll.set_offset(point(px(0.), px(-1200.)));
                cx.notify();
            });
            { window.refresh(); window.draw(cx).clear(cx) };
        })
        .unwrap();
        let scroll_elapsed = scrolled.elapsed();
        cx.update(|cx|{
            let pane=stored.borrow().as_ref().unwrap().read(cx);
            let count=pane.card_cache.borrow().len();
            assert!(count<=initial.len()+10,"far scroll prepares only newly visible rows, not remaining fifty");
            assert!(pane.native_material_frame().cards.len()<=10);
            eprintln!("50-row Window coldWithSetup={cold_elapsed:?} warm={warm_elapsed:?} farScroll={scroll_elapsed:?}; initialSources={} totalAfterFarScroll={count}",initial.len());
        });
    }
    #[test]
    fn real_material_frame_uses_foreground_geometry_and_same_frame_failure_fallback() {
        use gpui_kit::{AppContext, TestAppContext};
        let mut cx = TestAppContext::single();
        cx.update(gpui_kit::init);
        let result = std::rc::Rc::new(std::cell::Cell::new(false));
        let latest = std::rc::Rc::new(std::cell::RefCell::new(
            super::ProgramMaterialFrame::default(),
        ));
        let stored = std::rc::Rc::new(std::cell::RefCell::new(None));
        let (returned, frames, entity) = (result.clone(), latest.clone(), stored.clone());
        let handle = cx.add_window(move |window, cx| {
            let pane = cx.new(|cx| {
                let mut pane = super::StageProgramRailPane::new(window, cx);
                pane.snapshot = json!({"route":"programs","programs":[{"id":"material-geometry","title":"真实字段","subtitle":"内容"}],"playlists":[]});
                pane.set_native_material_renderer(Some(std::rc::Rc::new(move |frame| {
                    *frames.borrow_mut() = frame.clone();
                    returned.get()
                })), cx);
                pane
            });
            *entity.borrow_mut() = Some(pane.clone());
            gpui_kit::base::Root::new(pane, window, cx)
        });
        // Manual fixture frames must invalidate Fast's cached entity tree;
        // the production event loop does this through on_next_frame/notify.
        let draw = |cx: &mut TestAppContext| {
            cx.update_window(handle.into(), |_, window, cx| { window.refresh(); window.draw(cx).clear(cx) })
                .unwrap();
        };
        draw(&mut cx);
        draw(&mut cx);
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while latest.borrow().cards.is_empty() {
            assert!(
                std::time::Instant::now() < deadline,
                "actual material prepare must complete"
            );
            std::thread::sleep(std::time::Duration::from_millis(5));
            draw(&mut cx);
        }
        assert_eq!(
            latest.borrow().cards.len(),
            1,
            "callback publishes all actual measured cards"
        );
        assert!(latest.borrow().viewport[3] > 0.);
        let card = latest.borrow().cards[0].clone();
        assert_eq!((card.width, card.height, card.radius), (306., 74., 22.));
        cx.update(|cx| {
            let pane = stored.borrow().as_ref().unwrap().read(cx);
            assert!(
                !pane.material_applied.get(),
                "failed callback uses opaque foreground THIS paint"
            );
            let cache = pane.projection_cache.borrow();
            let projected = &cache.values().next().unwrap().1;
            assert_eq!(card.matrix, projected.source_to_world_matrix());
            let sources = pane.card_cache.borrow();
            let material_sources = pane.material_sources.borrow();
            let opaque = &sources.values().next().unwrap().1;
            let transparent = &material_sources.values().next().unwrap().1;
            let i = ((8 * opaque.width + 80) * 4 + 3) as usize;
            assert_eq!(opaque.pixels[i], 255);
            assert!(transparent.pixels[i] < opaque.pixels[i]);
        });
        result.set(true);
        draw(&mut cx);
        cx.update(|cx| {
            assert!(
                stored
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .read(cx)
                    .material_applied
                    .get()
            )
        });
        result.set(false);
        draw(&mut cx);
        cx.update(|cx| {
            assert!(
                !stored
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .read(cx)
                    .material_applied
                    .get()
            )
        });
        result.set(true);
        cx.update_window(handle.into(), |_, window, cx| {
            stored.borrow().as_ref().unwrap().update(cx, |pane,cx|pane.update_snapshot(json!({"route":"programs","programs":[],"playlists":[],"emptyMessage":"暂无节目"}),window,cx));
        }).unwrap();
        draw(&mut cx);
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while latest.borrow().cards.is_empty() {
            assert!(
                std::time::Instant::now() < deadline,
                "actual empty card preparation must complete"
            );
            std::thread::sleep(std::time::Duration::from_millis(5));
            draw(&mut cx);
        }
        let empty = latest.borrow().cards[0].clone();
        assert!(
            (empty.width - 142.).abs() < 1.,
            "intrinsic source text/symbol width matches original live ~142pt card"
        );
        assert_eq!((empty.height, empty.radius), (64., 22.));
        assert_eq!(
            latest.borrow().fade_fraction,
            0.,
            "original empty state has no scroll rail mask"
        );
        assert!(
            (empty.matrix[5] - 138.).abs() < 0.01,
            "original root top42 plus empty padding96, without header or contentMargins18"
        );
        assert_eq!(empty.matrix[0], 1.);
        assert_eq!(empty.matrix[4], 1.);
        assert_eq!(empty.matrix[6], 0.);
        assert_eq!(empty.matrix[7], 0.);
        assert_eq!(
            latest.borrow().cards.len(),
            1,
            "real empty state replaces, not retains, old catalog layers"
        );
        cx.update_window(handle.into(), |_,window,cx| {
            stored.borrow().as_ref().unwrap().update(cx, |pane,cx|pane.update_snapshot(json!({"route":"tracks","tracks":[{"slotIndex":0,"trackID":"video-material","title":"真实视频按钮字段","isCurrent":true,"hasBoundVideo":true,"scale":1.,"relativeIndex":0}]}),window,cx));
        }).unwrap();
        draw(&mut cx);
        draw(&mut cx);
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while latest.borrow().cards.len() != 2 {
            assert!(
                std::time::Instant::now() < deadline,
                "actual video material preparation must complete"
            );
            std::thread::sleep(std::time::Duration::from_millis(5));
            draw(&mut cx);
        }
        let frame = latest.borrow().clone();
        assert_eq!(
            frame.cards.len(),
            2,
            "bound video material is part of the same atomic native frame"
        );
        let video = frame
            .cards
            .iter()
            .find(|c| c.id.ends_with("-video"))
            .unwrap();
        let track = frame
            .cards
            .iter()
            .find(|c| !c.id.ends_with("-video"))
            .unwrap();
        assert_eq!((video.width, video.height, video.radius), (26., 26., 13.));
        assert_eq!(video.opacity, track.opacity);
        assert_eq!(video.priority, track.priority + 0.25);
        let project = |m: &[f64; 9], x: f64, y: f64| {
            let w = m[6] * x + m[7] * y + m[8];
            [
                (m[0] * x + m[1] * y + m[2]) / w,
                (m[3] * x + m[4] * y + m[5]) / w,
            ]
        };
        for local in [[0., 0.], [26., 0.], [0., 26.], [26., 26.], [13., 13.]] {
            let a = project(&video.matrix, local[0], local[1]);
            let b = project(&track.matrix, local[0] + 259., local[1] + 8.);
            assert!((a[0] - b[0]).abs() < 1e-8 && (a[1] - b[1]).abs() < 1e-8);
        }
        result.set(false);
        draw(&mut cx);
        cx.update(|cx| {
            let pane = stored.borrow().as_ref().unwrap().read(cx);
            assert!(!pane.material_applied.get());
            let sources = pane.card_cache.borrow();
            let material_sources = pane.material_sources.borrow();
            let opaque=&sources["track-0"].1;
            let transparent=&material_sources["track-0"].1;
            let i=((10*opaque.width+272)*4+3) as usize;
            assert_eq!(opaque.pixels[i],255, "failed callback retains original circle background");
            assert!(transparent.pixels[i]<opaque.pixels[i], "native-success variant removes only opaque circle/base, preserves overlay and glyph");
        });
        cx.update_window(handle.into(), |_, window, cx| {
            stored
                .borrow()
                .as_ref()
                .unwrap()
                .update(cx, |pane, cx| pane.set_native_material_renderer(None, cx));
            { window.refresh(); window.draw(cx).clear(cx) };
        })
        .unwrap();
        assert!(
            latest.borrow().cards.is_empty(),
            "renderer removal explicitly clears native cards"
        );
    }
    #[test]
    fn real_gpui_window_draw_empty_and_projected_catalog_obeys_paint_phase() {
        use gpui_kit::{AppContext, TestAppContext};
        let mut cx = TestAppContext::single();
        cx.update(gpui_kit::init);
        let handle = cx.add_window(|window, cx| {
            let pane = cx.new(|cx| super::StageProgramRailPane::new(window, cx));
            gpui_kit::base::Root::new(pane, window, cx)
        });
        cx.update_window(handle.into(), |_, window, _| {
            let rejected = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                window.on_mouse_event(|_: &gpui_kit::MouseDownEvent, _, _, _| {});
            }));
            assert!(
                rejected.is_err(),
                "test window must exercise GPUI's real paint-phase guard"
            );
        })
        .unwrap();
        cx.update_window(handle.into(), |_, window, cx| { window.refresh(); window.draw(cx).clear(cx) })
            .unwrap();
        // Real production pane/layout/paint paths, not an extracted math probe.
        let projected=cx.add_window(|window,cx|{
            let pane=cx.new(|cx|{
                let mut pane=super::StageProgramRailPane::new(window,cx);
                pane.snapshot=json!({"route":"programs","programs":[{"id":"phase-regression","title":"绘制阶段","subtitle":"真实字段","isCurrent":true}],"playlists":[]});
                pane
            });
            gpui_kit::base::Root::new(pane,window,cx)
        });
        cx.update_window(projected.into(), |_, window, cx| { window.refresh(); window.draw(cx).clear(cx) })
            .unwrap();
        let track_pane = std::rc::Rc::new(std::cell::RefCell::new(None));
        let stored = track_pane.clone();
        let tracks=cx.add_window(move|window,cx|{
            let pane=cx.new(|cx|{
                let mut pane=super::StageProgramRailPane::new(window,cx);
                pane.snapshot=json!({"route":"tracks","tracks":[{"slotIndex":0,"trackID":"phase-only","title":"整内容投影","artist":"字段","isCurrent":true,"hasBoundVideo":true,"scale":1.,"relativeIndex":0}],"audioFeatures":{"amplitude":0.5}});
                pane
            });
            *stored.borrow_mut()=Some(pane.clone());
            gpui_kit::base::Root::new(pane,window,cx)
        });
        cx.update_window(tracks.into(), |_, window, cx| { window.refresh(); window.draw(cx).clear(cx) })
            .unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        loop {
            let ready = cx.update(|cx| {
                !track_pane
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .read(cx)
                    .projection_cache
                    .borrow()
                    .is_empty()
            });
            if ready {
                break;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "real track background projection must complete"
            );
            std::thread::sleep(std::time::Duration::from_millis(5));
            cx.update_window(tracks.into(), |_, window, cx| { window.refresh(); window.draw(cx).clear(cx) })
                .unwrap();
        }
        cx.update_window(tracks.into(), |_, window, cx| { window.refresh(); window.draw(cx).clear(cx) })
            .unwrap();
        cx.update(|cx| {
            assert!(
                !track_pane
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .read(cx)
                    .projection_cache
                    .borrow()
                    .is_empty(),
                "real track draw must render the full projected image, not an empty canvas"
            )
        });
        cx.update_window(projected.into(), |_, window, cx| { window.refresh(); window.draw(cx).clear(cx) })
            .unwrap();
        cx.update_window(tracks.into(), |_, window, cx| {
            let pane = track_pane.borrow().as_ref().unwrap().clone();
            pane.update(cx, |pane, cx| {
                assert!(!pane.animate_center, "first appearance must remain immediate");
                let original_generation = pane.center_generation;
                pane.update_snapshot(json!({"route":"tracks","tracks":[{"slotIndex":1,"isCurrent":true}]}), window, cx);
                assert!(pane.animate_center, "active change uses the original .24s animation");
                assert!(pane.center_generation > original_generation);
                pane.update_snapshot(json!({"route":"tracks","reduceMotion":true,"tracks":[{"slotIndex":2,"isCurrent":true}]}), window, cx);
                assert!(!pane.animate_center);
                assert!(pane.center_task.is_none());
                let generation = pane.center_generation;
                pane.update_snapshot(json!({"route":"programs","tracks":[]}), window, cx);
                assert!(!pane.animate_center, "route appearance is not an active-change animation");
                assert!(pane.center_generation > generation);
                assert!(pane.center_task.is_none());
            });
        }).unwrap();
    }
    #[test]
    fn scrolling_waits_for_finger_release_and_accepts_wheel_and_momentum() {
        use gpui_kit::TouchPhase;
        let mut active = false;
        assert!(!super::schedule_scroll_settle(
            &mut active,
            TouchPhase::Started
        ));
        assert!(active);
        // A pause while fingers remain on the trackpad has no timer to fire.
        for _ in 0..10 {
            assert!(!super::schedule_scroll_settle(
                &mut active,
                TouchPhase::Moved
            ));
        }
        assert!(super::schedule_scroll_settle(
            &mut active,
            TouchPhase::Ended
        ));
        assert!(!active);
        // Subsequent momentum events reschedule settling, rather than snapping
        // at the finger's Ended event. Mouse wheels (no Started) use this too.
        assert!(super::schedule_scroll_settle(
            &mut active,
            TouchPhase::Moved
        ));
        assert!(!super::schedule_scroll_settle(
            &mut active,
            TouchPhase::Started
        ));
        assert!(!super::schedule_scroll_settle(
            &mut active,
            TouchPhase::Cancelled
        ));
        assert!(!active);
        assert!(super::schedule_scroll_settle(
            &mut active,
            TouchPhase::Moved
        ));
    }
    #[test]
    fn ease_out_matches_original_curve_and_240ms_endpoints() {
        assert_eq!(super::ease_out_progress(0.), 0.);
        assert_eq!(super::ease_out_progress(0.24 / 0.24), 1.);
        assert!((super::ease_out_progress(0.5) - 0.684643187).abs() < 1e-8);
        assert!(super::ease_out_progress(0.25) > 0.25);
        for i in 0..100 {
            assert!(
                super::ease_out_progress(i as f64 / 100.)
                    <= super::ease_out_progress((i + 1) as f64 / 100.)
            );
        }
    }
    #[test]
    fn playlist_pagination_uses_real_busy_and_last_four_visibility_without_repeating() {
        let mut state = json!({"playlistID":"actual-scope","isPlaylist":true,"hasMore":true,"playlistLoading":false,"tracks":vec![json!({});12]});
        assert!(pagination_key(&state, 300., 0., None).is_none());
        let first = pagination_key(&state, 300., -300., None).unwrap();
        assert!(pagination_key(&state, 300., -300., Some(&first)).is_none());
        state["playlistLoading"] = json!(true);
        assert!(pagination_key(&state, 300., -300., None).is_none());
        state["playlistLoading"] = json!(false);
        // Failed or unchanged snapshots cannot create an automatic request storm.
        assert!(pagination_key(&state, 300., -300., Some(&first)).is_none());
        state["tracks"] = json!([]);
        assert!(pagination_key(&state, 300., 0., Some(&first)).is_some());
        state["isPlaylist"] = json!(false);
        assert!(pagination_key(&state, 300., 0., None).is_none());
    }
    #[test]
    fn visual_depth_does_not_change_original_card_layout() {
        let current = card_transform(
            &json!({"isCurrent":true,"scale":1.,"depth":0,"opacity":1.}),
            false,
        );
        let distant = card_transform(
            &json!({"isCurrent":false,"scale":0.89,"depth":-144,"opacity":0.68,"relativeIndex":2}),
            false,
        );
        assert_eq!(distant.width, 294.);
        assert_eq!(current.width, 294.);
        assert_eq!(distant.height, 76.);
        assert_eq!(current.height, 76.);
        assert_eq!(distant.y_degrees, -15.);
        assert_eq!(current.y_degrees, -4.);
        assert_eq!(current.scale, 1.055);
        assert_eq!(distant.perspective, 0.72);
    }
    #[test]
    fn active_card_centers_using_original_overlap_and_margins() {
        assert_eq!(active_center_offset(0, 300., 900.), 0.);
        assert_eq!(active_center_offset(4, 300., 900.), -182.);
        assert_eq!(active_center_offset(30, 300., 900.), -900.);
    }
    #[test]
    fn catalog_and_track_spacing_match_swift() {
        assert_eq!(PROGRAM_SPACING, 4.);
        assert_eq!(TRACK_SPACING, -7.);
    }
    #[test]
    fn focused_and_current_cards_paint_above_neighbours_without_reordering() {
        assert_eq!(
            card_priority(&json!({"isFocused":true,"relativeIndex":2}), 0),
            20
        );
        assert_eq!(
            card_priority(
                &json!({"isFocused":false,"isCurrent":true,"relativeIndex":0}),
                0
            ),
            20
        );
        assert_eq!(card_priority(&json!({"relativeIndex":-2}), 0), 8);
        assert_eq!(card_priority(&json!({"relativeIndex":1}), 0), 9);
        assert!(
            card_priority(&json!({"relativeIndex":-20}), 30)
                > card_priority(&json!({"relativeIndex":30}), 30)
        );
    }
    #[test]
    fn snapping_aligns_card_preserves_browsing_and_reaches_end() {
        assert_eq!(snap_offset(-90., 900.), -69.);
        assert_eq!(snap_offset(-110., 900.), -138.);
        assert_eq!(snap_offset(-600., 900.), -621.);
        assert_eq!(snap_offset(40., 900.), 0.);
        assert_eq!(snap_offset(-1000., 970.), -970.);
    }
    #[test]
    fn focus_restores_visibility_without_mutating_host_card() {
        let card = json!({"isFocused":true,"scale":0.89,"depth":-144,"opacity":0.68});
        assert!((card_transform(&card, false).scale - 0.945).abs() < 1e-12);
        assert_eq!(card["opacity"], 0.68);
    }
    #[test]
    fn scroll_transition_phase_uses_real_viewport_overlap() {
        assert_eq!(scroll_phase(100., 76., 100., 300.), 0.);
        assert_eq!(scroll_phase(62., 76., 100., 300.), -0.5);
        assert_eq!(scroll_phase(362., 76., 100., 300.), 0.5);
        assert_eq!(scroll_phase(-100., 76., 100., 300.), -1.);
        assert_eq!(scroll_phase(500., 76., 100., 300.), 1.);
        let phase = scroll_phase(362., 76., 100., 300.);
        assert_eq!(phase * -13., -6.5);
        assert_eq!(1. - 0.1 * phase.abs(), 0.95);
        assert_eq!(1. - 0.44 * phase.abs(), 0.78);
    }
    #[test]
    fn original_shadow_and_outer_blur_parameters_remain_independent_of_layout() {
        let current = card_effects(&json!({"isCurrent":true}), false);
        assert_eq!(current.blur_radius, 0.);
        let shadow = current.shadow.unwrap();
        assert_eq!(
            (shadow.radius, shadow.offset, shadow.rgba),
            (24., [0., 7.], [0, 255, 255, 51])
        );
        assert_eq!(
            card_effects(&json!({"relativeIndex":-5}), false).blur_radius,
            0.32
        );
        assert_eq!(
            card_effects(&json!({"relativeIndex":2,"isFocused":true}), false).blur_radius,
            0.
        );
        let catalog = card_effects(&json!({}), true).shadow.unwrap();
        assert_eq!((catalog.radius, catalog.rgba), (13., [0, 0, 0, 97]));
    }
    #[test]
    fn complete_card_content_rasterizes_before_projecting() {
        let card = json!({"title":"实际字段 中文 A","artist":"Artist","isCurrent":true,"hasBoundVideo":true,"energy":0.6});
        let svg = card_svg(&card, &json!({"amplitude":0.5}), false, false);
        let renderer = gpui_kit::SvgRenderer::new(std::sync::Arc::new(()));
        let image = renderer
            .render_single_frame(svg.as_bytes(), 1.)
            .expect("full card SVG");
        assert!(image.as_bytes(0).unwrap().iter().any(|v| *v != 0));
        let dimensions = image.size(0);
        let mut pixels = image.as_bytes(0).unwrap().to_vec();
        for pixel in pixels.chunks_exact_mut(4) {
            pixel.swap(0, 2);
        }
        let texture = super::RgbaTexture {
            width: dimensions.width.0 as u32,
            height: dimensions.height.0 as u32,
            pixels,
        };
        let transform = card_transform(&card, false);
        let projected = super::ProjectedCard::render(
            &texture,
            transform,
            [30., 50.],
            [800., 600.],
            2.,
            1.,
            Some(super::RailMask {
                top: 0.,
                height: 600.,
            }),
        )
        .unwrap();
        let point = transform.project_point([272., 21.]);
        let hit = projected
            .inverse_hit([point[0] + 30., point[1] + 50.])
            .expect("same projected video content accepts inverse pointer");
        assert!((hit[0] - 272.).abs() < 1e-8 && (hit[1] - 21.).abs() < 1e-8);
        assert_ne!(projected.texture.pixels, texture.pixels);
        assert!(svg.matches("<path").count() > 2);
        let plain = card_svg(
            &json!({"title":"","artist":"","isCurrent":false}),
            &serde_json::Value::Null,
            false,
            false,
        );
        assert_ne!(svg, plain);
        let catalog = card_transform(&card, true);
        assert_eq!(
            (catalog.width, catalog.height, catalog.y_degrees),
            (306., 74., -7.)
        );
    }
    #[test]
    fn cover_composites_centered_scaled_fill_and_rounded_clip_before_projection() {
        // Pixel-only unit input, never inserted into the production music store.
        let buffer = image::RgbaImage::from_fn(120, 40, |x, _| {
            image::Rgba(if x < 40 {
                [0, 0, 255, 255]
            } else if x < 80 {
                [0, 255, 0, 255]
            } else {
                [255, 0, 0, 255]
            })
        });
        let cover = gpui_kit::RenderImage::new(vec![image::Frame::new(buffer)]);
        let mut card = super::RgbaTexture {
            width: 306,
            height: 74,
            pixels: vec![0; 306 * 74 * 4],
        };
        super::composite_artwork(&mut card, &cover);
        let sample =
            |x: usize, y: usize| card.pixels[(y * 306 + x) * 4..(y * 306 + x) * 4 + 4].to_vec();
        assert_eq!(
            sample(35, 37),
            vec![0, 255, 0, 255],
            "scaledToFill crops real image center, not letterboxing"
        );
        assert_eq!(
            sample(14, 16),
            vec![0, 0, 0, 0],
            "12pt corners remain truly transparent"
        );
        assert_eq!(
            sample(69, 37),
            vec![0, 0, 0, 0],
            "original 42pt cover does not cover title/other fields"
        );
        let transform = card_transform(&json!({}), true);
        let projected =
            super::ProjectedCard::render(&card, transform, [30., 50.], [800., 600.], 1., 1., None)
                .unwrap();
        let location = transform.project_point([35., 37.]);
        assert!(
            projected
                .inverse_hit([location[0] + 30., location[1] + 50.])
                .is_some(),
            "cover is inside the same whole-card projected image"
        );
    }
    #[test]
    fn energy_trace_uses_real_track_energy() {
        for i in 0..7 {
            assert_eq!(energy_height(0., i), 5.);
            assert!(energy_height(1., i) > 5.);
            assert!(energy_height(1., i) <= 18.);
        }
    }
}
