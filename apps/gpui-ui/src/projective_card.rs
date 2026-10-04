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
pub struct ProjectedCard {
    pub texture: RgbaTexture,
    /// World logical coordinates; texture covers exactly this clipped rectangle.
    pub bounds: [f64; 4],
    transform: CardTransform,
    origin: [f64; 2],
    source: RgbaTexture,
    opacity: f64,
    mask: Option<RailMask>,
}
impl ProjectedCard {
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
        })
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
        let local = self
            .transform
            .inverse_point([world[0] - self.origin[0], world[1] - self.origin[1]])?;
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
    use super::*;
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
