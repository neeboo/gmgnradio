//! Whole-content projective rasterization. No view, business state or clock is created here.
use gpui_kit::RenderImage;
use std::sync::Arc;

/// Straight-alpha RGBA8; source dimensions may be Retina-scaled.
#[derive(Clone, Debug)]
pub struct RgbaTexture {
    pub width: u32,
    pub height: u32,
    pub pixels: Vec<u8>,
}
impl RgbaTexture {
    fn valid(&self) -> bool {
        let count = self.width as u64 * self.height as u64;
        self.width > 0
            && self.height > 0
            && count <= 16_777_216
            && self.pixels.len() == count as usize * 4
    }
    /// Converts straight RGBA to the same straight BGRA used by GPUI SvgRenderer.
    pub fn into_render_image(mut self) -> Result<Arc<RenderImage>, &'static str> {
        if !self.valid() {
            return Err("invalid texture");
        }
        for pixel in self.pixels.chunks_exact_mut(4) {
            pixel.swap(0, 2);
        }
        let buffer = image::RgbaImage::from_raw(self.width, self.height, self.pixels)
            .ok_or("invalid texture")?;
        Ok(Arc::new(RenderImage::new(vec![image::Frame::new(buffer)])))
    }
}
#[derive(Clone, Copy, Debug)]
pub struct CardTransform {
    pub width: f64,
    pub height: f64,
    pub scale: f64,
    pub y_degrees: f64,
    pub perspective: f64,
}
impl CardTransform {
    fn valid(self) -> bool {
        [
            self.width,
            self.height,
            self.scale,
            self.y_degrees,
            self.perspective,
        ]
        .iter()
        .all(|n| n.is_finite())
            && self.width > 0.
            && self.height > 0.
            && self.scale > 0.
    }
    /// Matches scaleEffect then rotation3DEffect around the trailing-center anchor.
    pub fn project_point(self, p: [f64; 2]) -> [f64; 2] {
        let (s, c) = self.y_degrees.to_radians().sin_cos();
        let u = (p[0] - self.width) * self.scale;
        let v = (p[1] - self.height * 0.5) * self.scale;
        let d = 1. + self.perspective * s * u / self.width;
        [self.width + c * u / d, self.height * 0.5 + v / d]
    }
    pub fn inverse_point(self, p: [f64; 2]) -> Option<[f64; 2]> {
        let (s, c) = self.y_degrees.to_radians().sin_cos();
        let x = p[0] - self.width;
        let k = self.perspective * s / self.width;
        let denominator = c - k * x;
        if denominator.abs() < 1e-10 {
            return None;
        }
        let u = x / denominator;
        let d = 1. + k * u;
        if d <= 0. || !d.is_finite() {
            return None;
        }
        Some([
            u / self.scale + self.width,
            (p[1] - self.height * 0.5) * d / self.scale + self.height * 0.5,
        ])
    }
}
#[derive(Clone, Copy, Debug)]
pub struct RailMask {
    pub top: f64,
    pub height: f64,
}
impl RailMask {
    pub fn alpha(self, y: f64) -> f64 {
        if self.height <= 0. {
            return 0.;
        }
        let t = (y - self.top) / self.height;
        (t / 0.08).min((1. - t) / 0.08).clamp(0., 1.)
    }
}
/// The outer Swift scrollTransition, applied after the inner card transform.
#[derive(Clone, Copy, Debug)]
pub struct ScrollTransition {
    pub scale: f64,
    pub degrees: f64,
    pub axis: [f64; 3],
    pub perspective: f64,
    pub offset_before: [f64; 2],
}
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CardShadow {
    pub radius: f64,
    pub offset: [f64; 2],
    pub rgba: [u8; 4],
}
#[derive(Clone, Copy, Debug, Default)]
pub struct CardEffects {
    pub blur_radius: f64,
    pub shadow: Option<CardShadow>,
}
#[derive(Clone, Copy)]
struct Homography([[f64; 3]; 3]);
impl Homography {
    fn multiply(self, b: Self) -> Self {
        let mut m = [[0.; 3]; 3];
        for i in 0..3 {
            for j in 0..3 {
                for k in 0..3 {
                    m[i][j] += self.0[i][k] * b.0[k][j];
                }
            }
        }
        Self(m)
    }
    fn translate(x: f64, y: f64) -> Self {
        Self([[1., 0., x], [0., 1., y], [0., 0., 1.]])
    }
    fn apply(self, p: [f64; 2]) -> Option<[f64; 2]> {
        let m = self.0;
        let w = m[2][0] * p[0] + m[2][1] * p[1] + m[2][2];
        if w <= 1e-8 || !w.is_finite() {
            return None;
        }
        Some([
            (m[0][0] * p[0] + m[0][1] * p[1] + m[0][2]) / w,
            (m[1][0] * p[0] + m[1][1] * p[1] + m[1][2]) / w,
        ])
    }
    fn inverse(self) -> Option<Self> {
        let m = self.0;
        let mut c = [[0.; 3]; 3];
        for i in 0..3 {
            for j in 0..3 {
                let r = [(i + 1) % 3, (i + 2) % 3];
                let s = [(j + 1) % 3, (j + 2) % 3];
                c[i][j] = m[r[0]][s[0]] * m[r[1]][s[1]] - m[r[0]][s[1]] * m[r[1]][s[0]];
            }
        }
        let d = (0..3).map(|j| m[0][j] * c[0][j]).sum::<f64>();
        if d.abs() < 1e-10 {
            return None;
        }
        let mut inverse = [[0.; 3]; 3];
        for i in 0..3 {
            for j in 0..3 {
                inverse[i][j] = c[j][i] / d;
            }
        }
        Some(Self(inverse))
    }
    fn rotation(
        width: f64,
        height: f64,
        scale: f64,
        degrees: f64,
        axis: [f64; 3],
        perspective: f64,
    ) -> Option<Self> {
        let n = axis.iter().map(|a| a * a).sum::<f64>().sqrt();
        if n <= 0. || !n.is_finite() || scale <= 0. {
            return None;
        }
        let [x, y, z] = axis.map(|a| a / n);
        let (s, c) = degrees.to_radians().sin_cos();
        let a = 1. - c;
        let r00 = c + x * x * a;
        let r01 = x * y * a - z * s;
        let r10 = y * x * a + z * s;
        let r11 = c + y * y * a;
        let r20 = z * x * a - y * s;
        let r21 = z * y * a + x * s;
        let p = Self([
            [r00 * scale, r01 * scale, 0.],
            [r10 * scale, r11 * scale, 0.],
            [
                -perspective * r20 * scale / width,
                -perspective * r21 * scale / width,
                1.,
            ],
        ]);
        Some(
            Self::translate(width, height / 2.)
                .multiply(p)
                .multiply(Self::translate(-width, -height / 2.)),
        )
    }
}
pub struct ProjectedCard {
    pub texture: RgbaTexture,
    /// World logical coordinates; texture covers exactly this clipped rectangle.
    pub bounds: [f64; 4],
    transform: CardTransform,
    origin: [f64; 2],
    source: RgbaTexture,
    opacity: f64,
    mask: Option<RailMask>,
    mapping: Option<Homography>,
}
impl ProjectedCard {
    /// Repositions an already prepared frame without rerasterizing. Input,
    /// native material and hit testing all follow the exact displayed frame.
    pub fn shifted_source_to_world_matrix(&self, delta: [f64; 2]) -> [f64; 9] {
        let mut m = self.source_to_world_matrix();
        for c in 0..3 {
            m[c] += delta[0] * m[6 + c];
            m[3 + c] += delta[1] * m[6 + c];
        }
        m
    }
    pub fn inverse_hit_shifted(&self, world: [f64; 2], delta: [f64; 2]) -> Option<[f64; 2]> {
        self.inverse_hit([world[0] - delta[0], world[1] - delta[1]])
    }
    /// Exact foreground geometry, in logical points (not source raster pixels).
    /// Native materials use this same mapping, including final world origin.
    pub fn source_to_world_matrix(&self) -> [f64; 9] {
        let forward = if let Some(inverse) = self.mapping {
            inverse
                .inverse()
                .expect("validated projected-card homography")
        } else {
            Homography::rotation(
                self.transform.width,
                self.transform.height,
                self.transform.scale,
                self.transform.y_degrees,
                [0., 1., 0.],
                self.transform.perspective,
            )
            .expect("validated projected-card transform")
        };
        let m = Homography::translate(self.origin[0], self.origin[1])
            .multiply(forward)
            .0;
        [
            m[0][0], m[0][1], m[0][2], m[1][0], m[1][1], m[1][2], m[2][0], m[2][1], m[2][2],
        ]
    }
    pub fn render(
        source: &RgbaTexture,
        transform: CardTransform,
        origin: [f64; 2],
        viewport: [f64; 2],
        pixels_per_point: f64,
        opacity: f64,
        mask: Option<RailMask>,
    ) -> Result<Self, &'static str> {
        if !source.valid()
            || !transform.valid()
            || !pixels_per_point.is_finite()
            || pixels_per_point <= 0.
            || !opacity.is_finite()
            || origin.iter().chain(viewport.iter()).any(|n| !n.is_finite())
            || viewport.iter().any(|n| *n <= 0.)
            || mask.is_some_and(|m| !m.top.is_finite() || !m.height.is_finite() || m.height <= 0.)
        {
            return Err("invalid raster geometry");
        }
        let near =
            1. - transform.perspective * transform.y_degrees.to_radians().sin() * transform.scale;
        if near <= 1e-8 || transform.y_degrees.to_radians().cos().abs() < 1e-8 {
            return Err("singular projection");
        }
        let corners = [
            [0., 0.],
            [transform.width, 0.],
            [transform.width, transform.height],
            [0., transform.height],
        ]
        .map(|p| transform.project_point(p));
        if corners.iter().flatten().any(|v| !v.is_finite()) {
            return Err("singular projection");
        }
        let left = (corners.iter().map(|p| p[0]).fold(f64::INFINITY, f64::min) + origin[0]).max(0.);
        let top = (corners.iter().map(|p| p[1]).fold(f64::INFINITY, f64::min) + origin[1]).max(0.);
        let right = (corners
            .iter()
            .map(|p| p[0])
            .fold(f64::NEG_INFINITY, f64::max)
            + origin[0])
            .min(viewport[0]);
        let bottom = (corners
            .iter()
            .map(|p| p[1])
            .fold(f64::NEG_INFINITY, f64::max)
            + origin[1])
            .min(viewport[1]);
        if right <= left || bottom <= top {
            return Err("projection outside viewport");
        }
        let w = ((right - left) * pixels_per_point).ceil() as u32;
        let h = ((bottom - top) * pixels_per_point).ceil() as u32;
        if w == 0 || h == 0 || (w as u64) * (h as u64) > 16_777_216 {
            return Err("projection exceeds raster limit");
        }
        let bounds = [
            left,
            top,
            w as f64 / pixels_per_point,
            h as f64 / pixels_per_point,
        ];
        let mut pixels = vec![0; w as usize * h as usize * 4];
        for y in 0..h {
            for x in 0..w {
                let world = [
                    left + (x as f64 + 0.5) / pixels_per_point,
                    top + (y as f64 + 0.5) / pixels_per_point,
                ];
                let Some(local) =
                    transform.inverse_point([world[0] - origin[0], world[1] - origin[1]])
                else {
                    continue;
                };
                let sample = sample(source, local, transform);
                let a = opacity.clamp(0., 1.) * mask.map_or(1., |m| m.alpha(world[1]));
                let i = (y as usize * w as usize + x as usize) * 4;
                pixels[i..i + 3].copy_from_slice(&sample[..3]);
                pixels[i + 3] = (sample[3] as f64 * a).round() as u8;
            }
        }
        Ok(Self {
            texture: RgbaTexture {
                width: w,
                height: h,
                pixels,
            },
            bounds,
            transform,
            origin,
            source: source.clone(),
            opacity: opacity.clamp(0., 1.),
            mask,
            mapping: None,
        })
    }
    /// Shadow is inside the original card; blur follows inner scale/opacity and
    /// precedes Y rotation. The outer transition is composed, never added to Y.
    #[allow(clippy::too_many_arguments)]
    pub fn render_with_effects(
        source: &RgbaTexture,
        t: CardTransform,
        origin: [f64; 2],
        viewport: [f64; 2],
        ppp: f64,
        opacity: f64,
        mask: Option<RailMask>,
        transition: Option<ScrollTransition>,
        effects: CardEffects,
    ) -> Result<Self, &'static str> {
        if !source.valid()
            || !t.valid()
            || !ppp.is_finite()
            || ppp <= 0.
            || !opacity.is_finite()
            || origin.iter().chain(viewport.iter()).any(|v| !v.is_finite())
            || viewport.iter().any(|v| *v <= 0.)
            || mask.is_some_and(|m| !m.top.is_finite() || !m.height.is_finite() || m.height <= 0.)
        {
            return Err("invalid raster geometry");
        }
        let mut card = Self {
            texture: RgbaTexture {
                width: 0,
                height: 0,
                pixels: vec![],
            },
            bounds: [0.; 4],
            transform: t,
            origin,
            source: source.clone(),
            opacity: opacity.clamp(0., 1.),
            mask,
            mapping: None,
        };
        if !effects.blur_radius.is_finite() || effects.blur_radius < 0. {
            return Err("invalid blur");
        }
        let mut matrix = Homography::rotation(
            t.width,
            t.height,
            t.scale,
            t.y_degrees,
            [0., 1., 0.],
            t.perspective,
        )
        .ok_or("invalid rotation")?;
        if let Some(outer) = transition {
            if ![
                outer.scale,
                outer.degrees,
                outer.perspective,
                outer.offset_before[0],
                outer.offset_before[1],
            ]
            .iter()
            .all(|n| n.is_finite())
            {
                return Err("invalid transition");
            }
            matrix = Homography::rotation(
                t.width,
                t.height,
                outer.scale,
                outer.degrees,
                outer.axis,
                outer.perspective,
            )
            .ok_or("invalid transition")?
            .multiply(Homography::translate(
                outer.offset_before[0],
                outer.offset_before[1],
            ))
            .multiply(matrix);
        }
        let inverse = matrix.inverse().ok_or("singular projection")?;
        let density = source.width as f64 / t.width;
        let blur = effects.blur_radius / t.scale * density;
        let mut shadow = effects.shadow;
        if let Some(s) = shadow.as_mut() {
            if !s.radius.is_finite() || s.radius < 0. || s.offset.iter().any(|x| !x.is_finite()) {
                return Err("invalid shadow");
            }
            s.radius *= density;
            s.offset = s.offset.map(|x| x * density);
        }
        let padding_size = (blur * 3.
            + shadow.map_or(0., |s| {
                s.radius * 3. + s.offset[0].abs().max(s.offset[1].abs())
            }))
        .ceil();
        if padding_size > 2048. {
            return Err("effects exceed raster limit");
        }
        let padding = padding_size as u32 + 2;
        let raster = cached_effects_texture(source, blur, shadow, padding)?;
        let pad = padding as f64 / density;
        let corners = [
            [-pad, -pad],
            [t.width + pad, -pad],
            [t.width + pad, t.height + pad],
            [-pad, t.height + pad],
        ]
        .map(|p| matrix.apply(p));
        let corners = corners
            .into_iter()
            .collect::<Option<Vec<_>>>()
            .ok_or("projection crosses near plane")?;
        let left = (corners.iter().map(|p| p[0]).fold(f64::INFINITY, f64::min) + origin[0]).max(0.);
        let top = (corners.iter().map(|p| p[1]).fold(f64::INFINITY, f64::min) + origin[1]).max(0.);
        let right = (corners
            .iter()
            .map(|p| p[0])
            .fold(f64::NEG_INFINITY, f64::max)
            + origin[0])
            .min(viewport[0]);
        let bottom = (corners
            .iter()
            .map(|p| p[1])
            .fold(f64::NEG_INFINITY, f64::max)
            + origin[1])
            .min(viewport[1]);
        if right <= left || bottom <= top {
            return Err("projection outside viewport");
        }
        let w = ((right - left) * ppp).ceil() as u32;
        let h = ((bottom - top) * ppp).ceil() as u32;
        if w as u64 * h as u64 > 16_777_216 {
            return Err("projection exceeds raster limit");
        }
        let local_left = if left == 0. {
            -origin[0]
        } else {
            corners.iter().map(|p| p[0]).fold(f64::INFINITY, f64::min)
        };
        let local_top = if top == 0. {
            -origin[1]
        } else {
            corners.iter().map(|p| p[1]).fold(f64::INFINITY, f64::min)
        };
        let padded_t = CardTransform {
            width: raster.width as f64 / density,
            height: raster.height as f64 / density,
            ..t
        };
        let projected = cached_projection(
            &raster,
            inverse,
            [local_left, local_top],
            padded_t,
            pad,
            ppp,
            w,
            h,
        );
        let mut pixels = projected.pixels.clone();
        for y in 0..h {
            let alpha =
                opacity.clamp(0., 1.) * mask.map_or(1., |m| m.alpha(top + (y as f64 + 0.5) / ppp));
            for x in 0..w {
                let i = (y as usize * w as usize + x as usize) * 4;
                pixels[i + 3] = (pixels[i + 3] as f64 * alpha).round() as u8;
            }
        }
        card.texture = RgbaTexture {
            width: w,
            height: h,
            pixels,
        };
        card.bounds = [left, top, w as f64 / ppp, h as f64 / ppp];
        card.mapping = Some(inverse);
        Ok(card)
    }
    /// Inverse hit testing uses the same projection and true source/mask alpha as paint.
    pub fn inverse_hit(&self, world: [f64; 2]) -> Option<[f64; 2]> {
        if world.iter().any(|v| !v.is_finite())
            || world[0] < self.bounds[0]
            || world[1] < self.bounds[1]
            || world[0] >= self.bounds[0] + self.bounds[2]
            || world[1] >= self.bounds[1] + self.bounds[3]
        {
            return None;
        }
        let point = [world[0] - self.origin[0], world[1] - self.origin[1]];
        let local = if let Some(inverse) = self.mapping {
            inverse.apply(point)?
        } else {
            self.transform.inverse_point(point)?
        };
        let alpha = sample(&self.source, local, self.transform)[3] as f64
            * self.opacity
            * self.mask.map_or(1., |m| m.alpha(world[1]));
        (alpha >= 1.).then_some(local)
    }
    /// GPUI's image atlas expects BGRA bytes (straight alpha, like decoded images).
    pub fn render_image(&self) -> Arc<RenderImage> {
        self.texture
            .clone()
            .into_render_image()
            .expect("validated projected texture")
    }
}
struct ProjectionCacheEntry {
    source: Arc<RgbaTexture>,
    key: Vec<u64>,
    raster: Arc<RgbaTexture>,
}
thread_local! {static PROJECTION_CACHE:std::cell::RefCell<std::collections::VecDeque<ProjectionCacheEntry>>=const{std::cell::RefCell::new(std::collections::VecDeque::new())};}
#[allow(clippy::too_many_arguments)]
fn cached_projection(
    source: &Arc<RgbaTexture>,
    inverse: Homography,
    local_origin: [f64; 2],
    transform: CardTransform,
    pad: f64,
    ppp: f64,
    width: u32,
    height: u32,
) -> Arc<RgbaTexture> {
    let mut key: Vec<u64> = inverse
        .0
        .iter()
        .flatten()
        .chain(local_origin.iter())
        .map(|v| v.to_bits())
        .collect();
    key.extend([
        transform.width.to_bits(),
        transform.height.to_bits(),
        pad.to_bits(),
        ppp.to_bits(),
        width as u64,
        height as u64,
    ]);
    PROJECTION_CACHE.with(|cache| {
        let mut cache = cache.borrow_mut();
        if let Some(index) = cache
            .iter()
            .position(|entry| Arc::ptr_eq(&entry.source, source) && entry.key == key)
        {
            let entry = cache.remove(index).unwrap();
            let result = entry.raster.clone();
            cache.push_front(entry);
            return result;
        }
        let mut pixels = vec![0; width as usize * height as usize * 4];
        for y in 0..height {
            for x in 0..width {
                let point = [
                    local_origin[0] + (x as f64 + 0.5) / ppp,
                    local_origin[1] + (y as f64 + 0.5) / ppp,
                ];
                if let Some(local) = inverse.apply(point) {
                    let rgba = sample(source, [local[0] + pad, local[1] + pad], transform);
                    let index = (y as usize * width as usize + x as usize) * 4;
                    pixels[index..index + 4].copy_from_slice(&rgba);
                }
            }
        }
        let raster = Arc::new(RgbaTexture {
            width,
            height,
            pixels,
        });
        cache.push_front(ProjectionCacheEntry {
            source: source.clone(),
            key,
            raster: raster.clone(),
        });
        while cache.len() > 32
            || cache.iter().map(|e| e.raster.pixels.len()).sum::<usize>() > 64 * 1024 * 1024
        {
            cache.pop_back();
        }
        raster
    })
}
// Straight pixels enter/leave; all filtering and source-over use premultiplied RGBA.
struct EffectsCacheEntry {
    source: RgbaTexture,
    blur: f64,
    shadow: Option<CardShadow>,
    pad: u32,
    raster: Arc<RgbaTexture>,
}
thread_local! {static EFFECTS_CACHE:std::cell::RefCell<std::collections::VecDeque<EffectsCacheEntry>>=const{std::cell::RefCell::new(std::collections::VecDeque::new())};}
fn cached_effects_texture(
    source: &RgbaTexture,
    blur: f64,
    shadow: Option<CardShadow>,
    pad: u32,
) -> Result<Arc<RgbaTexture>, &'static str> {
    EFFECTS_CACHE.with(|cache| {
        let mut cache = cache.borrow_mut();
        if let Some(i) = cache.iter().position(|e| {
            e.blur == blur
                && e.shadow == shadow
                && e.pad == pad
                && e.source.width == source.width
                && e.source.height == source.height
                && e.source.pixels == source.pixels
        }) {
            let entry = cache.remove(i).unwrap();
            let result = entry.raster.clone();
            cache.push_front(entry);
            return Ok(result);
        }
        let raster = Arc::new(effects_texture(source, blur, shadow, pad)?);
        cache.push_front(EffectsCacheEntry {
            source: source.clone(),
            blur,
            shadow,
            pad,
            raster: raster.clone(),
        });
        // Geometry-only scrolling reuses prepared pixels; memory stays bounded
        // to sixteen cards and sixteen million prepared/source pixels per UI thread.
        while cache.len() > 16
            || cache
                .iter()
                .map(|e| e.raster.pixels.len() + e.source.pixels.len())
                .sum::<usize>()
                > 16_777_216 * 4
        {
            cache.pop_back();
        }
        Ok(raster)
    })
}
fn effects_texture(
    source: &RgbaTexture,
    blur: f64,
    shadow: Option<CardShadow>,
    pad: u32,
) -> Result<RgbaTexture, &'static str> {
    let w = source
        .width
        .checked_add(pad * 2)
        .ok_or("effects exceed raster limit")?;
    let h = source
        .height
        .checked_add(pad * 2)
        .ok_or("effects exceed raster limit")?;
    if w as u64 * h as u64 > 16_777_216 {
        return Err("effects exceed raster limit");
    }
    let mut layer = vec![[0_f32; 4]; w as usize * h as usize];
    for y in 0..source.height {
        for x in 0..source.width {
            let i = (y as usize * source.width as usize + x as usize) * 4;
            let a = source.pixels[i + 3] as f32 / 255.;
            let j = (y + pad) as usize * w as usize + (x + pad) as usize;
            layer[j] = [
                source.pixels[i] as f32 / 255. * a,
                source.pixels[i + 1] as f32 / 255. * a,
                source.pixels[i + 2] as f32 / 255. * a,
                a,
            ];
        }
    }
    if let Some(s) = shadow {
        let mut background = vec![[0.; 4]; layer.len()];
        // Keep fractional shadow offsets; interpolate the original alpha field.
        for y in 0..h {
            for x in 0..w {
                let px = x as f64 - pad as f64 - s.offset[0] + 0.5;
                let py = y as f64 - pad as f64 - s.offset[1] + 0.5;
                let t = CardTransform {
                    width: source.width as f64,
                    height: source.height as f64,
                    scale: 1.,
                    y_degrees: 0.,
                    perspective: 0.,
                };
                let a = sample(source, [px, py], t)[3] as f32 / 255. * s.rgba[3] as f32 / 255.;
                background[y as usize * w as usize + x as usize] = [
                    s.rgba[0] as f32 / 255. * a,
                    s.rgba[1] as f32 / 255. * a,
                    s.rgba[2] as f32 / 255. * a,
                    a,
                ];
            }
        }
        gaussian(&mut background, w, h, s.radius);
        for (front, back) in layer.iter_mut().zip(background) {
            let coverage = 1. - front[3];
            for c in 0..4 {
                front[c] += back[c] * coverage;
            }
        }
    }
    gaussian(&mut layer, w, h, blur);
    let mut pixels = Vec::with_capacity(layer.len() * 4);
    for p in layer {
        let a = p[3].clamp(0., 1.);
        if a <= 0. {
            pixels.extend([0; 4]);
        } else {
            pixels.extend([
                (p[0] / a * 255.).round().clamp(0., 255.) as u8,
                (p[1] / a * 255.).round().clamp(0., 255.) as u8,
                (p[2] / a * 255.).round().clamp(0., 255.) as u8,
                (a * 255.).round() as u8,
            ]);
        }
    }
    Ok(RgbaTexture {
        width: w,
        height: h,
        pixels,
    })
}
fn gaussian(layer: &mut Vec<[f32; 4]>, w: u32, h: u32, sigma: f64) {
    if sigma <= 0.001 {
        return;
    }
    // Three variance-matched box passes approximate the Gaussian blur with
    // linear work. Wide original shadows must not cost O(pixels * radius).
    if sigma > 2. {
        let ideal = (4. * sigma * sigma + 1.).sqrt();
        let mut low = ideal.floor() as i32;
        if low % 2 == 0 {
            low -= 1;
        }
        low = low.max(1);
        let high = low + 2;
        let n = ((12. * sigma * sigma - 3. * (low * low) as f64 - 12. * low as f64 - 9.)
            / (-4. * low as f64 - 4.))
            .round()
            .clamp(0., 3.) as usize;
        for pass in 0..3 {
            let radius = (if pass < n { low } else { high }) / 2;
            box_blur(layer, w, h, radius);
        }
        return;
    }
    let radius = (sigma * 3.).ceil() as i32;
    let mut weights = (-radius..=radius)
        .map(|x| (-(x as f64).powi(2) / (2. * sigma * sigma)).exp() as f32)
        .collect::<Vec<_>>();
    let total = weights.iter().sum::<f32>();
    for x in &mut weights {
        *x /= total;
    }
    let mut output = vec![[0.; 4]; layer.len()];
    for horizontal in [true, false] {
        for y in 0..h as i32 {
            for x in 0..w as i32 {
                let mut p = [0.; 4];
                for (k, weight) in (-radius..=radius).zip(&weights) {
                    let sx = x + if horizontal { k } else { 0 };
                    let sy = y + if horizontal { 0 } else { k };
                    if sx >= 0 && sy >= 0 && sx < w as i32 && sy < h as i32 {
                        let sample = layer[sy as usize * w as usize + sx as usize];
                        for c in 0..4 {
                            p[c] += sample[c] * weight;
                        }
                    }
                }
                output[y as usize * w as usize + x as usize] = p;
            }
        }
        std::mem::swap(layer, &mut output);
    }
}
fn box_blur(layer: &mut Vec<[f32; 4]>, w: u32, h: u32, r: i32) {
    if r == 0 {
        return;
    }
    let mut output = vec![[0.; 4]; layer.len()];
    let weight = 1. / (2 * r + 1) as f32;
    for horizontal in [true, false] {
        let length = if horizontal { w } else { h } as i32;
        let rows = if horizontal { h } else { w } as i32;
        for row in 0..rows {
            let index = |column: i32| {
                if horizontal {
                    row as usize * w as usize + column as usize
                } else {
                    column as usize * w as usize + row as usize
                }
            };
            let mut sum = [0.; 4];
            for column in 0..=r.min(length - 1) {
                for c in 0..4 {
                    sum[c] += layer[index(column)][c];
                }
            }
            for column in 0..length {
                for c in 0..4 {
                    output[index(column)][c] = sum[c] * weight;
                }
                let remove = column - r;
                let add = column + r + 1;
                if remove >= 0 {
                    for c in 0..4 {
                        sum[c] -= layer[index(remove)][c];
                    }
                }
                if add < length {
                    for c in 0..4 {
                        sum[c] += layer[index(add)][c];
                    }
                }
            }
        }
        std::mem::swap(layer, &mut output);
    }
}
// Interpolate premultiplied samples, then unpremultiply. Transparent colored edges cannot halo.
fn sample(source: &RgbaTexture, p: [f64; 2], t: CardTransform) -> [u8; 4] {
    if p[0] < 0. || p[1] < 0. || p[0] >= t.width || p[1] >= t.height {
        return [0; 4];
    }
    let x = (p[0] / t.width * source.width as f64 - 0.5).clamp(0., source.width as f64 - 1.);
    let y = (p[1] / t.height * source.height as f64 - 0.5).clamp(0., source.height as f64 - 1.);
    let (ix, iy) = (x.floor() as u32, y.floor() as u32);
    let (fx, fy) = (x - x.floor(), y - y.floor());
    let mut rgba = [0.; 4];
    for (dx, dy, weight) in [
        (0, 0, (1. - fx) * (1. - fy)),
        (1, 0, fx * (1. - fy)),
        (0, 1, (1. - fx) * fy),
        (1, 1, fx * fy),
    ] {
        let i = (((iy + dy).min(source.height - 1) * source.width
            + (ix + dx).min(source.width - 1))
            * 4) as usize;
        let a = source.pixels[i + 3] as f64 / 255.;
        for c in 0..3 {
            rgba[c] += source.pixels[i + c] as f64 * a * weight;
        }
        rgba[3] += a * weight;
    }
    if rgba[3] <= 0. {
        return [0; 4];
    }
    [
        (rgba[0] / rgba[3]).round() as u8,
        (rgba[1] / rgba[3]).round() as u8,
        (rgba[2] / rgba[3]).round() as u8,
        (rgba[3] * 255.).round() as u8,
    ]
}

#[cfg(test)]
mod tests {
    #[test]
    fn translated_projection_reuses_local_raster_preserving_mask_matrix_and_hit() {
        use super::*;
        PROJECTION_CACHE.with(|c| c.borrow_mut().clear());
        let source = RgbaTexture {
            width: 100,
            height: 30,
            pixels: vec![255; 100 * 30 * 4],
        };
        let t = CardTransform {
            width: 100.,
            height: 30.,
            scale: 1.,
            y_degrees: 0.,
            perspective: 0.72,
        };
        let mask = Some(RailMask {
            top: 0.,
            height: 200.,
        });
        let a = ProjectedCard::render_with_effects(
            &source,
            t,
            [30., 30.],
            [500., 500.],
            2.,
            0.7,
            mask,
            None,
            CardEffects::default(),
        )
        .unwrap();
        let raster = PROJECTION_CACHE.with(|c| c.borrow().front().unwrap().raster.clone());
        let b = ProjectedCard::render_with_effects(
            &source,
            t,
            [30., 40.],
            [500., 500.],
            2.,
            0.7,
            mask,
            None,
            CardEffects::default(),
        )
        .unwrap();
        assert!(
            PROJECTION_CACHE.with(|c| Arc::ptr_eq(&raster, &c.borrow().front().unwrap().raster))
        );
        assert_eq!(b.bounds[1] - a.bounds[1], 10.);
        assert_eq!(
            b.source_to_world_matrix()[5] - a.source_to_world_matrix()[5],
            10.
        );
        assert_eq!(a.inverse_hit([50., 40.]), b.inverse_hit([50., 50.]));
        for y in 0..b.texture.height {
            for x in 0..b.texture.width {
                let i = (y as usize * b.texture.width as usize + x as usize) * 4;
                let expected = (raster.pixels[i + 3] as f64
                    * 0.7
                    * mask.unwrap().alpha(b.bounds[1] + (y as f64 + 0.5) / 2.))
                .round() as u8;
                assert_eq!(b.texture.pixels[i + 3], expected);
                assert_eq!(&a.texture.pixels[i..i + 3], &b.texture.pixels[i..i + 3]);
            }
        }
    }
    #[test]
    fn projection_cache_reuses_translation_but_not_changed_geometry() {
        use super::*;
        PROJECTION_CACHE.with(|c| c.borrow_mut().clear());
        let source = Arc::new(RgbaTexture {
            width: 300,
            height: 80,
            pixels: vec![191; 300 * 80 * 4],
        });
        let t = CardTransform {
            width: 300.,
            height: 80.,
            scale: 1.,
            y_degrees: -7.,
            perspective: 0.72,
        };
        let inverse = Homography::rotation(300., 80., 1., -7., [0., 1., 0.], 0.72)
            .unwrap()
            .inverse()
            .unwrap();
        let begin = std::time::Instant::now();
        let cold = cached_projection(&source, inverse, [0., 0.], t, 0., 2., 600, 160);
        let cold_time = begin.elapsed();
        let begin = std::time::Instant::now();
        let warm = cached_projection(&source, inverse, [0., 0.], t, 0., 2., 600, 160);
        let warm_time = begin.elapsed();
        assert!(Arc::ptr_eq(&cold, &warm));
        for y in 0..160 {
            for x in 0..600 {
                let expected = inverse
                    .apply([(x as f64 + 0.5) / 2., (y as f64 + 0.5) / 2.])
                    .map_or([0; 4], |p| sample(&source, p, t));
                assert_eq!(
                    &cold.pixels[(y * 600 + x) * 4..(y * 600 + x) * 4 + 4],
                    &expected
                );
            }
        }
        let changed = Homography::rotation(300., 80., 1., -8., [0., 1., 0.], 0.72)
            .unwrap()
            .inverse()
            .unwrap();
        assert!(!Arc::ptr_eq(
            &cold,
            &cached_projection(&source, changed, [0., 0.], t, 0., 2., 600, 160)
        ));
        eprintln!(
            "projection_cache cold_us={} warm_us={} pixels_exact=true",
            cold_time.as_micros(),
            warm_time.as_micros()
        );
    }
    use super::*;
    #[test]
    fn native_material_matrix_matches_foreground_and_inverse_hit_in_world_points() {
        let t = transform();
        let transition = ScrollTransition {
            scale: 0.9,
            degrees: 11.,
            axis: [1., 0.16, 0.],
            perspective: 0.72,
            offset_before: [-4., 0.],
        };
        for outer in [None, Some(transition)] {
            let card = ProjectedCard::render_with_effects(
                &texture(),
                t,
                [40., 20.],
                [500., 200.],
                2.,
                1.,
                None,
                outer,
                CardEffects::default(),
            )
            .unwrap();
            let raw = card.source_to_world_matrix();
            let m = Homography([
                [raw[0], raw[1], raw[2]],
                [raw[3], raw[4], raw[5]],
                [raw[6], raw[7], raw[8]],
            ]);
            for local in [[45., 20.], [180., 50.], [290., 70.]] {
                let world = m.apply(local).unwrap();
                let hit = card.inverse_hit(world).unwrap();
                assert!((hit[0] - local[0]).abs() < 1e-8 && (hit[1] - local[1]).abs() < 1e-8);
            }
        }
        let plain =
            ProjectedCard::render(&texture(), t, [40., 20.], [500., 200.], 2., 1., None).unwrap();
        let raw = plain.source_to_world_matrix();
        let m = Homography([
            [raw[0], raw[1], raw[2]],
            [raw[3], raw[4], raw[5]],
            [raw[6], raw[7], raw[8]],
        ]);
        let local = [50., 25.];
        let actual = m.apply(local).unwrap();
        let expected = t.project_point(local);
        assert!(
            (actual[0] - expected[0] - 40.).abs() < 1e-8
                && (actual[1] - expected[1] - 20.).abs() < 1e-8
        );
    }
    #[test]
    fn prepared_effects_reuse_pixels_when_only_scroll_geometry_changes() {
        let source = texture();
        let shadow = Some(CardShadow {
            radius: 3.,
            offset: [0., 2.],
            rgba: [0, 0, 0, 120],
        });
        let a = cached_effects_texture(&source, 0.16, shadow, 12).unwrap();
        let b = cached_effects_texture(&source, 0.16, shadow, 12).unwrap();
        assert!(Arc::ptr_eq(&a, &b));
        let c = cached_effects_texture(&source, 0.32, shadow, 12).unwrap();
        assert!(!Arc::ptr_eq(&a, &c));
    }
    #[test]
    fn wide_shadow_blur_preserves_color_and_spreads_real_alpha() {
        let source = RgbaTexture {
            width: 8,
            height: 8,
            pixels: vec![255; 8 * 8 * 4],
        };
        let raster = effects_texture(
            &source,
            0.,
            Some(CardShadow {
                radius: 4.,
                offset: [0., 4.],
                rgba: [0, 0, 255, 128],
            }),
            20,
        )
        .unwrap();
        let i = (34 * raster.width as usize + 24) * 4;
        assert!(raster.pixels[i + 3] > 0);
        assert!(raster.pixels[i + 2] > raster.pixels[i]);
    }
    #[test]
    fn outer_scroll_rotation_composes_and_inverse_hit_returns_original_local_point() {
        let t = transform();
        let outer = ScrollTransition {
            scale: 0.9,
            degrees: -13.,
            axis: [1., 0.16, 0.],
            perspective: 0.72,
            offset_before: [-9., 0.],
        };
        let matrix = Homography::rotation(
            t.width,
            t.height,
            outer.scale,
            outer.degrees,
            outer.axis,
            outer.perspective,
        )
        .unwrap()
        .multiply(Homography::translate(-9., 0.))
        .multiply(
            Homography::rotation(
                t.width,
                t.height,
                t.scale,
                t.y_degrees,
                [0., 1., 0.],
                t.perspective,
            )
            .unwrap(),
        );
        let expected = matrix.apply([110., 50.]).unwrap();
        let card = ProjectedCard::render_with_effects(
            &texture(),
            t,
            [30., 30.],
            [400., 200.],
            1.,
            1.,
            None,
            Some(outer),
            CardEffects::default(),
        )
        .unwrap();
        let hit = card
            .inverse_hit([expected[0] + 30., expected[1] + 30.])
            .unwrap();
        assert!((hit[0] - 110.).abs() < 1e-8 && (hit[1] - 50.).abs() < 1e-8);
        assert!(matrix.apply([0., 0.]).unwrap() != t.project_point([0., 0.]));
    }
    #[test]
    fn whole_card_shadow_has_transparent_padding_but_never_owns_pointer() {
        let source = RgbaTexture {
            width: 8,
            height: 8,
            pixels: vec![255; 8 * 8 * 4],
        };
        let t = CardTransform {
            width: 8.,
            height: 8.,
            scale: 1.,
            y_degrees: 0.,
            perspective: 0.72,
        };
        let card = ProjectedCard::render_with_effects(
            &source,
            t,
            [20., 20.],
            [80., 80.],
            1.,
            1.,
            None,
            None,
            CardEffects {
                blur_radius: 0.,
                shadow: Some(CardShadow {
                    radius: 1.,
                    offset: [0., 4.],
                    rgba: [0, 200, 255, 128],
                }),
            },
        )
        .unwrap();
        assert!(card.bounds[0] < 20. && card.bounds[1] < 20.);
        assert_eq!(card.inverse_hit([23., 30.]), None);
        assert_eq!(card.inverse_hit([23., 23.]), Some([3., 3.]));
        let x = ((23.5 - card.bounds[0]) as u32).min(card.texture.width - 1);
        let y = ((30.5 - card.bounds[1]) as u32).min(card.texture.height - 1);
        let i = (y as usize * card.texture.width as usize + x as usize) * 4;
        assert!(card.texture.pixels[i + 3] > 0);
        assert!(card.texture.pixels[i + 2] > card.texture.pixels[i]);
    }
    #[test]
    fn outer_blur_filters_complete_rgba_before_projection_without_black_halo() {
        let source = RgbaTexture {
            width: 1,
            height: 1,
            pixels: vec![255, 0, 0, 255],
        };
        let raster = effects_texture(&source, 1., None, 4).unwrap();
        let center = (4 * raster.width as usize + 4) * 4;
        let neighbor = (4 * raster.width as usize + 5) * 4;
        assert!(
            raster.pixels[neighbor + 3] > 0
                && raster.pixels[neighbor + 3] < raster.pixels[center + 3]
        );
        assert_eq!(raster.pixels[neighbor], 255);
        assert_eq!(raster.pixels[neighbor + 1], 0);
    }
    fn transform() -> CardTransform {
        CardTransform {
            width: 294.,
            height: 76.,
            scale: 1.,
            y_degrees: -10.,
            perspective: 0.72,
        }
    }
    fn texture() -> RgbaTexture {
        RgbaTexture {
            width: 2,
            height: 2,
            pixels: vec![
                255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255,
            ],
        }
    }
    #[test]
    fn trailing_anchor_and_inverse_are_exact() {
        let t = transform();
        assert_eq!(t.project_point([294., 38.]), [294., 38.]);
        for p in [[0., 0.], [294., 76.], [81., 42.]] {
            let q = t.inverse_point(t.project_point(p)).unwrap();
            assert!((q[0] - p[0]).abs() < 1e-9 && (q[1] - p[1]).abs() < 1e-9);
        }
    }
    #[test]
    fn far_edge_has_actual_projective_vertical_convergence() {
        let t = transform();
        let a = t.project_point([0., 0.]);
        let b = t.project_point([294., 0.]);
        assert!(a[1] > b[1]);
    }
    #[test]
    fn rail_mask_is_alpha_not_black_cover() {
        let m = RailMask {
            top: 0.,
            height: 100.,
        };
        assert_eq!(m.alpha(0.), 0.);
        assert!((m.alpha(4.) - 0.5).abs() < 1e-9);
        assert_eq!(m.alpha(50.), 1.);
        assert!(m.alpha(100.) == 0.);
    }
    #[test]
    fn complete_rgba_and_bgra_render_image_are_real() {
        let t = CardTransform {
            width: 2.,
            height: 2.,
            scale: 1.,
            y_degrees: 0.,
            perspective: 0.72,
        };
        let p = ProjectedCard::render(&texture(), t, [0., 0.], [2., 2.], 1., 1., None).unwrap();
        assert_eq!(p.texture.pixels, texture().pixels);
        assert_eq!(
            &p.render_image().as_bytes(0).unwrap()[0..4],
            &[0, 0, 255, 255]
        );
        assert_eq!(p.inverse_hit([0.5, 0.5]), Some([0.5, 0.5]));
    }
    #[test]
    fn transparent_texture_and_mask_do_not_intercept_pointer() {
        let mut tex = texture();
        tex.pixels[3] = 0;
        let t = CardTransform {
            width: 2.,
            height: 2.,
            scale: 1.,
            y_degrees: 0.,
            perspective: 0.72,
        };
        let p = ProjectedCard::render(&tex, t, [0., 0.], [2., 2.], 1., 1., None).unwrap();
        assert_eq!(p.inverse_hit([0.5, 0.5]), None);
        assert_eq!(&p.texture.pixels[..4], &[0, 0, 0, 0]);
    }
    #[test]
    fn transparent_colored_edge_cannot_tint_bilinear_samples() {
        let tex = RgbaTexture {
            width: 2,
            height: 1,
            pixels: vec![255, 0, 0, 0, 0, 0, 255, 255],
        };
        let t = CardTransform {
            width: 2.,
            height: 1.,
            scale: 1.,
            y_degrees: 0.,
            perspective: 0.72,
        };
        assert_eq!(sample(&tex, [1., 0.5], t), [0, 0, 255, 128]);
    }
    #[test]
    fn alpha_mask_preserves_rgb_and_transparency_over_any_background() {
        let t = CardTransform {
            width: 2.,
            height: 2.,
            scale: 1.,
            y_degrees: 0.,
            perspective: 0.72,
        };
        let p = ProjectedCard::render(
            &texture(),
            t,
            [0., 0.],
            [2., 2.],
            1.,
            1.,
            Some(RailMask {
                top: 0.,
                height: 25.,
            }),
        )
        .unwrap();
        assert_eq!(&p.texture.pixels[..4], &[255, 0, 0, 64]);
    }
    #[test]
    fn retinascale_changes_resolution_not_inverse_pointer_geometry() {
        let t = transform();
        let p =
            ProjectedCard::render(&texture(), t, [10., 20.], [400., 200.], 2., 1., None).unwrap();
        let local = [180., 50.];
        let q = t.project_point(local);
        let hit = p.inverse_hit([q[0] + 10., q[1] + 20.]).unwrap();
        assert!((hit[0] - local[0]).abs() < 1e-9 && (hit[1] - local[1]).abs() < 1e-9);
        assert_eq!(p.bounds[2], p.texture.width as f64 / 2.);
    }
    #[test]
    fn singular_projection_and_invalid_data_return_error() {
        let mut t = transform();
        t.y_degrees = 90.;
        assert!(
            ProjectedCard::render(&texture(), t, [0., 0.], [400., 200.], 1., 1., None).is_err()
        );
        let mut tex = texture();
        tex.pixels.pop();
        assert!(
            ProjectedCard::render(&tex, transform(), [0., 0.], [400., 200.], 1., 1., None).is_err()
        );
    }
}
