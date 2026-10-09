//! GPU transport for the production Scene primitives. No independent layout.
use super::{RenderImage, SvgRenderer, outline};
use std::collections::HashMap;
use std::hash::{Hash, Hasher};
use std::sync::Arc;

#[derive(Clone, Debug)]
pub struct GpuLyricsAtlas {
    pub id: u64,
    pub width: u32,
    pub height: u32,
    pub rgba: Arc<Vec<u8>>,
}
#[derive(Clone, Debug)]
pub struct GpuLyricsGlyph {
    pub atlas_id: u64,
    pub width: f64,
    pub height: f64,
    pub matrix: [f64; 9],
    pub uv: [f64; 4],
    pub rgba: [f64; 4],
}
#[derive(Clone, Debug)]
pub struct GpuLyricsBatch {
    /// Parent compositing group; children are composited before its effects.
    pub parent: Option<usize>,
    pub glyphs: Vec<GpuLyricsGlyph>,
    pub sigma: f64,
    pub glow: [f64; 4],
    pub blur_mix: f64,
    pub opacity: f64,
}
#[derive(Clone, Debug)]
pub struct GpuLyricsFrame {
    pub width: f64,
    pub height: f64,
    pub scale: f32,
    pub generation: u64,
    /// All pages referenced by this frame, including cached pages. The native
    /// renderer checks residency before uploading and can recover after eviction.
    pub atlases: Vec<GpuLyricsAtlas>,
    pub batches: Vec<GpuLyricsBatch>,
}
/// Native-compositor pixel budget for one lyric render target.
///
/// `tools/gpui-lyrics-metal-probe/lyrics_layer.m` clamps every intermediate and
/// presentation target it allocates to `MIN(4194304, 256MiB/(4*(5+maxdepth)))`
/// pixels (2048x2048) and recomputes its blur sigma from that effective scale.
/// The atlas rasters below are the Rust half of the same intermediate layer, so
/// they follow the same budget: with a fixed device scale the atlas area grows
/// with the viewport, and `pack` then rejects the whole frame with
/// `gpu_atlas_frame_budget_exceeded` exactly when the window goes fullscreen.
const NATIVE_TARGET_PIXEL_BUDGET: f64 = 4_194_304.;

/// Device scale bounded by the native target budget.
///
/// A 720x450-point window at scale 2 (1440x900 px, 1.30M px) fits the budget and
/// keeps its full scale, so the windowed rendering path is unchanged. A
/// 2048x1152-point fullscreen window (4096x2304 px, 7.28x the pixels) is
/// rasterized at `sqrt(budget/area)` = 1.333 instead — exactly the scale the
/// native compositor already downsamples its own targets to, so nothing that is
/// visible is lost while the atlas area drops by `(2/1.333)^2` = 2.25x. Glyph
/// transforms, per-glyph progress, blur and glow stay exact: only the
/// intermediate raster resolution follows the viewport.
fn bounded_scale(width: f64, height: f64, scale: f32) -> f32 {
    let area = (width * height).max(1.);
    let bounded = (NATIVE_TARGET_PIXEL_BUDGET / area).sqrt().min(f64::from(scale));
    bounded.clamp(0.05, f64::from(scale)) as f32
}
impl GpuLyricsFrame {
    /// Raster scale this frame's atlases were actually rendered at.
    pub fn raster_scale(&self) -> f32 {
        self.scale
    }
    pub fn diagnostics(&self) -> String {
        let glyphs = self.batches.iter().map(|b| b.glyphs.len()).sum::<usize>();
        let depth = self
            .batches
            .iter()
            .map(|b| {
                let mut n = 1;
                let mut parent = b.parent;
                while let Some(i) = parent {
                    n += 1;
                    if n > self.batches.len() + 1 {
                        return n;
                    }
                    parent = self.batches.get(i).and_then(|b| b.parent);
                }
                n
            })
            .max()
            .unwrap_or(0);
        format!(
            "generation={} viewport={}x{} scale={} pages={} depth={} glyph_limit_exceeded={} batch_limit_exceeded={}",
            self.generation,
            self.width,
            self.height,
            self.scale,
            self.atlases.len(),
            depth,
            glyphs > 4096,
            self.batches.len() > 256
        )
    }
}
pub(super) struct Primitive {
    pub path: String,
    pub width: f64,
    pub height: f64,
    pub matrix: [f64; 9],
    pub fill: String,
    pub stroke: String,
    pub stroke_width: f64,
    pub opacity: f64,
    pub filter: String,
}
pub(super) fn identity() -> [f64; 9] {
    [1., 0., 0., 0., 1., 0., 0., 0., 1.]
}
pub(super) fn multiply(a: [f64; 9], b: [f64; 9]) -> [f64; 9] {
    let mut result = [0.; 9];
    for row in 0..3 {
        for col in 0..3 {
            for k in 0..3 {
                result[row * 3 + col] += a[row * 3 + k] * b[k * 3 + col];
            }
        }
    }
    result
}
/// Exact planar projective matrix recovered from four mapped corners.
pub(super) fn homography(
    width: f64,
    height: f64,
    map: impl Fn(outline::Point) -> outline::Point,
) -> [f64; 9] {
    let source = [(0., 0.), (width, 0.), (width, height), (0., height)];
    let mut equations = [[0.; 9]; 8];
    for (i, (x, y)) in source.into_iter().enumerate() {
        let p = map(outline::Point { x, y });
        equations[i * 2] = [x, y, 1., 0., 0., 0., -p.x * x, -p.x * y, p.x];
        equations[i * 2 + 1] = [0., 0., 0., x, y, 1., -p.y * x, -p.y * y, p.y];
    }
    for col in 0..8 {
        let pivot = (col..8)
            .max_by(|&a, &b| equations[a][col].abs().total_cmp(&equations[b][col].abs()))
            .unwrap();
        equations.swap(col, pivot);
        let divisor = equations[col][col];
        if divisor.abs() < 1e-12 {
            return identity();
        }
        for k in col..9 {
            equations[col][k] /= divisor;
        }
        for row in 0..8 {
            if row != col {
                let ratio = equations[row][col];
                for k in col..9 {
                    equations[row][k] -= ratio * equations[col][k];
                }
            }
        }
    }
    let mut result = [0.; 9];
    for i in 0..8 {
        result[i] = equations[i][8];
    }
    result[8] = 1.;
    result
}
fn attributes(tag: &str) -> HashMap<String, String> {
    let mut result = HashMap::new();
    let mut remaining = tag;
    while let Some(eq) = remaining.find('=') {
        let name = remaining[..eq].split_whitespace().last().unwrap_or("");
        remaining = &remaining[eq + 1..];
        let Some(quote) = remaining.chars().next().filter(|c| *c == '"' || *c == '\'') else {
            break;
        };
        remaining = &remaining[1..];
        let Some(end) = remaining.find(quote) else {
            break;
        };
        result.insert(name.to_owned(), remaining[..end].to_owned());
        remaining = &remaining[end + 1..];
    }
    result
}
fn number(attrs: &HashMap<String, String>, key: &str, default: f64) -> f64 {
    attrs
        .get(key)
        .and_then(|s| s.parse().ok())
        .unwrap_or(default)
}
fn rgba(color: &str, opacity: f64) -> [f64; 4] {
    let hex = match color {
        "black" => "000000",
        "white" => "ffffff",
        _ => color.strip_prefix('#').unwrap_or("ffffff"),
    };
    let v = u32::from_str_radix(hex, 16).unwrap_or(0xffffff);
    [
        ((v >> 16) & 255) as f64 / 255.,
        ((v >> 8) & 255) as f64 / 255.,
        (v & 255) as f64 / 255.,
        opacity.clamp(0., 1.),
    ]
}
fn transform(value: &str) -> Result<[f64; 9], String> {
    let mut result = identity();
    let mut value = value.trim();
    while !value.is_empty() {
        let open = value.find('(').ok_or("gpu_transform_parse")?;
        let close = value.find(')').ok_or("gpu_transform_parse")?;
        let args: Vec<f64> = value[open + 1..close]
            .split(|c: char| c.is_whitespace() || c == ',')
            .filter(|s| !s.is_empty())
            .map(str::parse)
            .collect::<Result<_, _>>()
            .map_err(|_| "gpu_transform_parse")?;
        let matrix = match (&value[..open], args.as_slice()) {
            ("translate", [x, y]) => [1., 0., *x, 0., 1., *y, 0., 0., 1.],
            ("translate", [x]) => [1., 0., *x, 0., 1., 0., 0., 0., 1.],
            ("scale", [x, y]) => [*x, 0., 0., 0., *y, 0., 0., 0., 1.],
            ("scale", [x]) => [*x, 0., 0., 0., *x, 0., 0., 0., 1.],
            ("rotate", [angle]) => {
                let (s, c) = angle.to_radians().sin_cos();
                [c, -s, 0., s, c, 0., 0., 0., 1.]
            }
            ("rotate", [angle, x, y]) => {
                let (s, c) = angle.to_radians().sin_cos();
                [
                    c,
                    -s,
                    x - x * c + y * s,
                    s,
                    c,
                    y - x * s - y * c,
                    0.,
                    0.,
                    1.,
                ]
            }
            ("matrix", [a, b, c, d, e, f]) => [*a, *c, *e, *b, *d, *f, 0., 0., 1.],
            _ => return Err("gpu_transform_unsupported".into()),
        };
        result = multiply(result, matrix);
        value = value[close + 1..].trim();
    }
    Ok(result)
}
#[derive(Default)]
pub(super) struct AtlasCache {
    entries: HashMap<String, GpuLyricsAtlas>,
    pages: HashMap<Vec<u64>, Vec<GpuLyricsAtlas>>,
    placements: HashMap<Vec<u64>, HashMap<u64, Vec<Placement>>>,
    entry_use: HashMap<String, u64>,
    page_use: HashMap<Vec<u64>, u64>,
    clock: u64,
}
#[derive(Clone)]
struct Placement {
    id: u64,
    uv: [f64; 4],
    offset: [f64; 2],
    extent: [f64; 2],
}
fn stable_id(key: impl Hash) -> u64 {
    let mut h = std::collections::hash_map::DefaultHasher::new();
    key.hash(&mut h);
    h.finish()
}
impl AtlasCache {
    fn atlas(
        &mut self,
        renderer: &SvgRenderer,
        primitive: &Primitive,
        gradients: &str,
        scale: f32,
    ) -> Result<(GpuLyricsAtlas, bool), String> {
        let fill = if primitive.fill.starts_with("url(") {
            primitive.fill.as_str()
        } else if primitive.fill == "none" {
            "none"
        } else {
            "white"
        };
        let stroke = if primitive.stroke == "none" {
            "none"
        } else if primitive.stroke.starts_with("url(") {
            primitive.stroke.as_str()
        } else {
            "white"
        };
        let gradients = if fill.starts_with("url(") || stroke.starts_with("url(") {
            gradients
        } else {
            ""
        };
        let svg = format!(
            r#"<svg xmlns="http://www.w3.org/2000/svg" width="{}" height="{}"><defs>{gradients}</defs><path d="{}" fill="{fill}" stroke="{stroke}" stroke-width="{}"/></svg>"#,
            primitive.width, primitive.height, primitive.path, primitive.stroke_width
        );
        let key = format!("{scale}:{svg}");
        self.clock += 1;
        if let Some(atlas) = self.entries.get(&key) {
            self.entry_use.insert(key.clone(), self.clock);
            return Ok((atlas.clone(), false));
        }
        let image: Arc<RenderImage> = renderer
            .render_single_frame(svg.as_bytes(), scale)
            .map_err(|_| "gpu_atlas_raster_failed")?;
        let size = image.size(0);
        let mut bytes = image
            .as_bytes(0)
            .ok_or("gpu_atlas_pixels_missing")?
            .to_vec();
        for pixel in bytes.chunks_exact_mut(4) {
            pixel.swap(0, 2);
            if pixel[3] > 0 {
                let alpha = pixel[3] as f64 / 255.;
                for channel in &mut pixel[..3] {
                    *channel = (*channel as f64 / alpha).round().min(255.) as u8;
                }
            }
        }
        while !self.entries.is_empty()
            && self.entries.values().map(|a| a.rgba.len()).sum::<usize>() + bytes.len()
                > 64 * 1024 * 1024
        {
            let oldest = self
                .entry_use
                .iter()
                .min_by_key(|(_, t)| *t)
                .map(|(k, _)| k.clone())
                .unwrap();
            self.entries.remove(&oldest);
            self.entry_use.remove(&oldest);
        }
        let atlas = GpuLyricsAtlas {
            id: stable_id(&key),
            width: size.width.0 as u32,
            height: size.height.0 as u32,
            rgba: Arc::new(bytes),
        };
        self.entries.insert(key, atlas.clone());
        self.entry_use.insert(format!("{scale}:{svg}"), self.clock);
        Ok((atlas, true))
    }
    pub(super) fn frame(
        &mut self,
        renderer: &SvgRenderer,
        svg: &str,
        primitives: &[Primitive],
        width: f64,
        height: f64,
        scale: f32,
        generation: u64,
    ) -> Result<GpuLyricsFrame, String> {
        // The frame's reported scale is the raster scale, and the native layer
        // sizes its targets from it, so both halves of the intermediate layer
        // share one viewport-derived pixel budget.
        let scale = bounded_scale(width, height, scale);
        let mut gradients = String::new();
        let mut filters: HashMap<String, Vec<(f64, [f64; 4], f64)>> = HashMap::new();
        let mut gradient_start = None;
        let mut current_filter = None;
        let mut in_defs = 0;
        let mut scan = 0;
        while let Some(relative) = svg[scan..].find('<') {
            let start = scan + relative;
            let end = start + svg[start..].find('>').ok_or("gpu_svg_parse")? + 1;
            let tag = &svg[start + 1..end - 1];
            let attrs = attributes(tag);
            if tag.starts_with("linearGradient ") {
                gradient_start = Some(start);
            }
            if tag.starts_with("/linearGradient") {
                if let Some(begin) = gradient_start.take() {
                    gradients.push_str(&svg[begin..end]);
                }
            }
            if tag.starts_with("filter ") {
                current_filter = attrs.get("id").cloned();
                if let Some(id) = &current_filter {
                    filters.insert(id.clone(), vec![]);
                }
            }
            if tag.starts_with("/filter") {
                current_filter = None;
            }
            if let Some(id) = &current_filter {
                if tag.starts_with("feGaussianBlur ") {
                    filters.entry(id.clone()).or_default().push((
                        number(&attrs, "stdDeviation", 0.),
                        [0.; 4],
                        1.,
                    ));
                }
                if tag.starts_with("feDropShadow ") {
                    filters.entry(id.clone()).or_default().push((
                        number(&attrs, "stdDeviation", 0.),
                        rgba(
                            attrs
                                .get("flood-color")
                                .map(String::as_str)
                                .unwrap_or("black"),
                            number(&attrs, "flood-opacity", 1.),
                        ),
                        0.,
                    ));
                }
            }
            scan = end;
        }
        let mut frame = GpuLyricsFrame {
            width,
            height,
            scale,
            generation,
            atlases: vec![],
            batches: vec![],
        };
        let mut referenced = HashMap::new();
        let mut stack: Vec<(usize, [f64; 9])> = vec![];
        scan = 0;
        while let Some(relative) = svg[scan..].find('<') {
            let start = scan + relative;
            let end = start + svg[start..].find('>').ok_or("gpu_svg_parse")? + 1;
            let tag = &svg[start + 1..end - 1];
            let attrs = attributes(tag);
            if tag.starts_with("defs") {
                in_defs += 1;
            }
            if tag.starts_with("/defs") {
                in_defs -= 1;
                scan = end;
                continue;
            }
            if in_defs > 0 {
                scan = end;
                continue;
            }
            if tag.starts_with("g ") || tag == "g" {
                let matrix = multiply(
                    stack.last().map(|v| v.1).unwrap_or(identity()),
                    transform(attrs.get("transform").map(String::as_str).unwrap_or(""))?,
                );
                let node = add_group(
                    &mut frame.batches,
                    stack.last().map(|v| v.0),
                    number(&attrs, "opacity", 1.),
                    attrs.get("filter").map(String::as_str).unwrap_or("none"),
                    &filters,
                );
                stack.push((node, matrix));
            } else if tag == "/g" {
                stack.pop().ok_or("gpu_group_unbalanced")?;
            } else if tag.starts_with("path ") {
                let arc;
                let primitive = if let Some(index) = attrs.get("data-gpu") {
                    let index: usize = index.parse().map_err(|_| "gpu_primitive_index")?;
                    primitives.get(index).ok_or("gpu_primitive_index")?
                } else {
                    arc = half_arc(&attrs)?;
                    &arc
                };
                let node = add_group(
                    &mut frame.batches,
                    stack.last().map(|v| v.0),
                    primitive.opacity,
                    &primitive.filter,
                    &filters,
                );
                let (atlas, updated) = self.atlas(renderer, primitive, &gradients, scale)?;
                let tint_source = if primitive.fill == "none" {
                    &primitive.stroke
                } else {
                    &primitive.fill
                };
                let tint = if tint_source.starts_with("url(") {
                    [1., 1., 1., 1.]
                } else {
                    rgba(tint_source, 1.)
                };
                frame.batches[node].glyphs.push(GpuLyricsGlyph {
                    atlas_id: atlas.id,
                    width: primitive.width,
                    height: primitive.height,
                    matrix: multiply(
                        stack.last().map(|v| v.1).unwrap_or(identity()),
                        primitive.matrix,
                    ),
                    uv: [0., 0., 1., 1.],
                    rgba: tint,
                });
                let _ = updated;
                referenced.insert(atlas.id, atlas);
            } else if tag.starts_with("circle ") {
                let radius = number(&attrs, "r", 0.);
                let x = number(&attrs, "cx", 0.);
                let y = number(&attrs, "cy", 0.);
                let primitive = Primitive {
                    path: "M64 0 A64 64 0 1 1 64 128 A64 64 0 1 1 64 0Z".into(),
                    width: 128.,
                    height: 128.,
                    matrix: [
                        radius / 64.,
                        0.,
                        x - radius,
                        0.,
                        radius / 64.,
                        y - radius,
                        0.,
                        0.,
                        1.,
                    ],
                    fill: attrs.get("fill").cloned().unwrap_or("black".into()),
                    stroke: "none".into(),
                    stroke_width: 0.,
                    opacity: number(&attrs, "opacity", 1.),
                    filter: attrs.get("filter").cloned().unwrap_or("none".into()),
                };
                let parent = stack.last().map(|v| v.0);
                let plain = primitive.filter == "none";
                let node = if plain
                    && frame.batches.last().is_some_and(|batch| {
                        batch.parent == parent
                            && batch.sigma == 0.
                            && batch.opacity == 1.
                            && !batch.glyphs.is_empty()
                    }) {
                    frame.batches.len() - 1
                } else {
                    add_group(
                        &mut frame.batches,
                        parent,
                        if plain { 1. } else { primitive.opacity },
                        &primitive.filter,
                        &filters,
                    )
                };
                let (atlas, _) = self.atlas(renderer, &primitive, &gradients, scale)?;
                frame.batches[node].glyphs.push(GpuLyricsGlyph {
                    atlas_id: atlas.id,
                    width: 128.,
                    height: 128.,
                    matrix: multiply(
                        stack.last().map(|v| v.1).unwrap_or(identity()),
                        primitive.matrix,
                    ),
                    uv: [0., 0., 1., 1.],
                    rgba: rgba(&primitive.fill, if plain { primitive.opacity } else { 1. }),
                });
                referenced.insert(atlas.id, atlas);
            } else if tag.starts_with("rect ")
                || tag.starts_with("ellipse ")
                || tag.starts_with("text ")
            {
                return Err("gpu_unrecorded_shape".into());
            }
            scan = end;
        }
        self.pack(&mut frame, referenced)?;
        compact_groups(&mut frame.batches);
        for batch in &mut frame.batches {
            batch.sigma *= scale as f64;
        }
        Ok(frame)
    }
    fn pack(
        &mut self,
        frame: &mut GpuLyricsFrame,
        referenced: HashMap<u64, GpuLyricsAtlas>,
    ) -> Result<(), String> {
        let mut key: Vec<u64> = referenced.keys().copied().collect();
        key.sort_unstable();
        self.clock += 1;
        if !self.pages.contains_key(&key) {
            let mut source_tiles = vec![];
            let mut metadata = HashMap::new();
            for source_id in &key {
                let source = &referenced[source_id];
                for draw_y in (0..source.height).step_by(2046) {
                    for draw_x in (0..source.width).step_by(2046) {
                        let dw = (source.width - draw_x).min(2046);
                        let dh = (source.height - draw_y).min(2046);
                        let cx = draw_x.saturating_sub(1);
                        let cy = draw_y.saturating_sub(1);
                        let cw = (draw_x + dw + 1).min(source.width) - cx;
                        let ch = (draw_y + dh + 1).min(source.height) - cy;
                        let id = stable_id((*source_id, cx, cy, cw, ch));
                        let pixels =
                            if cx == 0 && cy == 0 && cw == source.width && ch == source.height {
                                source.rgba.clone()
                            } else {
                                let mut pixels = vec![0; (cw * ch * 4) as usize];
                                for row in 0..ch {
                                    let start = ((cy + row) * source.width * 4 + cx * 4) as usize;
                                    let dest = (row * cw * 4) as usize;
                                    pixels[dest..dest + (cw * 4) as usize].copy_from_slice(
                                        &source.rgba[start..start + (cw * 4) as usize],
                                    );
                                }
                                Arc::new(pixels)
                            };
                        metadata.insert(
                            id,
                            (
                                *source_id,
                                [
                                    (draw_x - cx) as f64 / cw as f64,
                                    (draw_y - cy) as f64 / ch as f64,
                                    dw as f64 / cw as f64,
                                    dh as f64 / ch as f64,
                                ],
                                [
                                    draw_x as f64 / source.width as f64,
                                    draw_y as f64 / source.height as f64,
                                ],
                                [
                                    dw as f64 / source.width as f64,
                                    dh as f64 / source.height as f64,
                                ],
                            ),
                        );
                        source_tiles.push(GpuLyricsAtlas {
                            id,
                            width: cw,
                            height: ch,
                            rgba: pixels,
                        });
                    }
                }
            }
            let mut pages = vec![];
            let mut locations = HashMap::new();
            let mut current: Vec<(GpuLyricsAtlas, u32, u32)> = vec![];
            let (mut x, mut y, mut row_height) = (0, 0, 0);
            let publish = |tiles: &mut Vec<(GpuLyricsAtlas, u32, u32)>,
                           pages: &mut Vec<GpuLyricsAtlas>,
                           locations: &mut HashMap<u64, Vec<Placement>>| {
                if tiles.is_empty() {
                    return;
                }
                let w = tiles.iter().map(|(a, x, _)| x + a.width).max().unwrap();
                let h = tiles.iter().map(|(a, _, y)| y + a.height).max().unwrap();
                let id = stable_id(
                    tiles
                        .iter()
                        .map(|(a, x, y)| (a.id, *x, *y))
                        .collect::<Vec<_>>(),
                );
                let mut bytes = vec![0; (w * h * 4) as usize];
                for (atlas, x, y) in tiles.drain(..) {
                    for row in 0..atlas.height {
                        let source = (row * atlas.width * 4) as usize;
                        let destination = ((y + row) * w * 4 + x * 4) as usize;
                        bytes[destination..destination + (atlas.width * 4) as usize]
                            .copy_from_slice(
                                &atlas.rgba[source..source + (atlas.width * 4) as usize],
                            );
                    }
                    let (source, uv, offset, extent) = metadata[&atlas.id];
                    locations.entry(source).or_default().push(Placement {
                        id,
                        uv: [
                            (x as f64 + uv[0] * atlas.width as f64) / w as f64,
                            (y as f64 + uv[1] * atlas.height as f64) / h as f64,
                            uv[2] * atlas.width as f64 / w as f64,
                            uv[3] * atlas.height as f64 / h as f64,
                        ],
                        offset,
                        extent,
                    });
                }
                pages.push(GpuLyricsAtlas {
                    id,
                    width: w,
                    height: h,
                    rgba: Arc::new(bytes),
                });
            };
            for atlas in source_tiles {
                if x + atlas.width > 2048 {
                    x = 0;
                    y += row_height;
                    row_height = 0;
                }
                if y + atlas.height > 2048 {
                    publish(&mut current, &mut pages, &mut locations);
                    x = 0;
                    y = 0;
                    row_height = 0;
                }
                current.push((atlas.clone(), x, y));
                x += atlas.width;
                row_height = row_height.max(atlas.height);
            }
            publish(&mut current, &mut pages, &mut locations);
            if pages.len() > 16
                || pages.iter().map(|a| a.rgba.len()).sum::<usize>() > 64 * 1024 * 1024
            {
                return Err("gpu_atlas_frame_budget_exceeded".into());
            }
            while !self.pages.is_empty()
                && (self.pages.len() >= 16
                    || self
                        .pages
                        .values()
                        .flatten()
                        .map(|a| a.rgba.len())
                        .sum::<usize>()
                        + pages.iter().map(|a| a.rgba.len()).sum::<usize>()
                        > 64 * 1024 * 1024)
            {
                let oldest = self
                    .page_use
                    .iter()
                    .min_by_key(|(_, t)| *t)
                    .map(|(k, _)| k.clone())
                    .unwrap();
                self.pages.remove(&oldest);
                self.placements.remove(&oldest);
                self.page_use.remove(&oldest);
            }
            self.pages.insert(key.clone(), pages);
            self.placements.insert(key.clone(), locations);
        }
        self.page_use.insert(key.clone(), self.clock);
        let locations = &self.placements[&key];
        for batch in &mut frame.batches {
            batch.glyphs = std::mem::take(&mut batch.glyphs)
                .into_iter()
                .flat_map(|glyph| {
                    locations[&glyph.atlas_id]
                        .iter()
                        .map(move |tile| GpuLyricsGlyph {
                            atlas_id: tile.id,
                            width: glyph.width * tile.extent[0],
                            height: glyph.height * tile.extent[1],
                            matrix: multiply(
                                glyph.matrix,
                                [
                                    1.,
                                    0.,
                                    glyph.width * tile.offset[0],
                                    0.,
                                    1.,
                                    glyph.height * tile.offset[1],
                                    0.,
                                    0.,
                                    1.,
                                ],
                            ),
                            uv: tile.uv,
                            rgba: glyph.rgba,
                        })
                })
                .collect();
        }
        frame.atlases = self.pages[&key].clone();
        Ok(())
    }
}
fn compact_groups(batches: &mut Vec<GpuLyricsBatch>) {
    let original = std::mem::take(batches);
    let mut indices = vec![None; original.len()];
    for (index, batch) in original.iter().enumerate() {
        if batch.glyphs.is_empty()
            && batch.opacity == 1.
            && batch.sigma == 0.
            && batch.glow[3] == 0.
            && batch.blur_mix == 0.
        {
            continue;
        }
        indices[index] = Some(batches.len());
        batches.push(batch.clone());
    }
    for (old, index) in indices.iter().enumerate() {
        if let Some(index) = index {
            let mut parent = original[old].parent;
            while let Some(p) = parent {
                if indices[p].is_some() {
                    break;
                }
                parent = original[p].parent;
            }
            batches[*index].parent = parent.and_then(|p| indices[p]);
        }
    }
}
fn half_arc(attrs: &HashMap<String, String>) -> Result<Primitive, String> {
    let path = attrs.get("d").ok_or("gpu_unrecorded_path")?;
    let parts: Vec<_> = path.split_whitespace().collect();
    if parts.len() != 11 || parts[0] != "M" || parts[3] != "A" || parts[6..9] != ["0", "0", "1"] {
        return Err("gpu_unrecorded_path".into());
    }
    let parse = |i: usize| {
        parts[i]
            .parse::<f64>()
            .map_err(|_| "gpu_arc_parse".to_string())
    };
    let x = parse(1)?;
    let top = parse(2)?;
    let radius = parse(4)?;
    if radius <= 0.
        || (parse(5)? - radius).abs() > 1e-6
        || (parse(9)? - x).abs() > 1e-6
        || (parse(10)? - top - radius * 2.).abs() > 1e-6
    {
        return Err("gpu_arc_unsupported".into());
    }
    let source_radius = 256.;
    let padding = 8.;
    let ratio = radius / source_radius;
    // Only the bounded stroke-style source changes; radius/position/alpha stay
    // GPU transforms. <=1/64 source-pixel stroke error, no polygon approximation.
    let stroke = (number(attrs, "stroke-width", 1.) / ratio * 32.).round() / 32.;
    Ok(Primitive {
        path: "M264 8 A256 256 0 0 1 264 520".into(),
        width: 528.,
        height: 528.,
        matrix: [
            ratio,
            0.,
            x - radius - padding * ratio,
            0.,
            ratio,
            top - padding * ratio,
            0.,
            0.,
            1.,
        ],
        fill: "none".into(),
        stroke: attrs.get("stroke").cloned().unwrap_or("black".into()),
        stroke_width: stroke,
        opacity: number(attrs, "stroke-opacity", 1.) * number(attrs, "opacity", 1.),
        filter: "none".into(),
    })
}
fn add_group(
    batches: &mut Vec<GpuLyricsBatch>,
    parent: Option<usize>,
    opacity: f64,
    filter: &str,
    filters: &HashMap<String, Vec<(f64, [f64; 4], f64)>>,
) -> usize {
    let opacity = opacity.clamp(0., 1.);
    let effects = filter
        .strip_prefix("url(#")
        .and_then(|v| v.strip_suffix(')'))
        .and_then(|id| filters.get(id));
    let mut parent = parent;
    if let Some(effects) = effects {
        for (index, &(sigma, glow, blur_mix)) in effects.iter().rev().enumerate() {
            let id = batches.len();
            batches.push(GpuLyricsBatch {
                parent,
                glyphs: vec![],
                sigma,
                glow,
                blur_mix,
                opacity: if index == 0 { opacity } else { 1. },
            });
            parent = Some(id);
        }
    }
    let id = batches.len();
    batches.push(GpuLyricsBatch {
        parent,
        glyphs: vec![],
        sigma: 0.,
        glow: [0.; 4],
        blur_mix: 0.,
        opacity: if effects.is_none() { opacity } else { 1. },
    });
    id
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn oversized_text_tiles_preserve_extent_and_reuse_packed_pixels() {
        let source = GpuLyricsAtlas {
            id: 42,
            width: 4300,
            height: 40,
            rgba: Arc::new(vec![255; 4300 * 40 * 4]),
        };
        let mut cache = AtlasCache::default();
        let make = || {
            let mut result = frame();
            result.batches.push(GpuLyricsBatch {
                parent: None,
                glyphs: vec![GpuLyricsGlyph {
                    atlas_id: 42,
                    width: 2150.,
                    height: 20.,
                    matrix: identity(),
                    uv: [0., 0., 1., 1.],
                    rgba: [1.; 4],
                }],
                sigma: 0.,
                blur_mix: 0.,
                glow: [0.; 4],
                opacity: 1.,
            });
            result
        };
        let mut first = make();
        cache
            .pack(&mut first, HashMap::from([(42, source.clone())]))
            .unwrap();
        let glyphs = &first.batches[0].glyphs;
        assert_eq!(glyphs.len(), 3);
        assert!((glyphs.iter().map(|g| g.width).sum::<f64>() - 2150.).abs() < 1e-9);
        let mut edge = 0.;
        for glyph in glyphs {
            assert!((glyph.matrix[2] - edge).abs() < 1e-9);
            assert_eq!(glyph.height, 20.);
            edge += glyph.width;
            assert!(first.atlases.iter().any(|page| page.id == glyph.atlas_id));
        }
        assert!(
            first
                .atlases
                .iter()
                .all(|p| p.width <= 2048 && p.height <= 2048)
        );
        let mut second = make();
        cache
            .pack(&mut second, HashMap::from([(42, source)]))
            .unwrap();
        for (a, b) in first.atlases.iter().zip(&second.atlases) {
            assert!(Arc::ptr_eq(&a.rgba, &b.rgba));
        }
    }
    fn frame() -> GpuLyricsFrame {
        GpuLyricsFrame {
            width: 10.,
            height: 10.,
            scale: 1.,
            generation: 1,
            atlases: vec![],
            batches: vec![],
        }
    }
    #[test]
    fn mode_page_cache_keeps_hot_style_after_more_than_four_switches() {
        let mut cache = AtlasCache::default();
        let source = |id| {
            HashMap::from([(
                id,
                GpuLyricsAtlas {
                    id,
                    width: 4,
                    height: 4,
                    rgba: Arc::new(vec![255; 64]),
                },
            )])
        };
        let mut first = frame();
        cache.pack(&mut first, source(1)).unwrap();
        for id in 2..22 {
            let mut other = frame();
            cache.pack(&mut other, source(id)).unwrap();
            let mut hot = frame();
            cache.pack(&mut hot, source(1)).unwrap();
            assert!(
                Arc::ptr_eq(&first.atlases[0].rgba, &hot.atlases[0].rgba),
                "switching must not evict a recently used style and repack its bytes"
            );
        }
        assert!(cache.pages.len() <= 16);
        assert_eq!(cache.pages.len(), cache.placements.len());
        assert_eq!(cache.pages.len(), cache.page_use.len());
    }
    #[test]
    fn svg_opacity_normalization_does_not_reject_long_monet_context() {
        let mut batches = vec![];
        let node = add_group(&mut batches, None, -0.08, "none", &HashMap::new());
        assert_eq!(batches[node].opacity, 0.);
        assert_eq!(rgba("black", 2.)[3], 1.);
    }
}
