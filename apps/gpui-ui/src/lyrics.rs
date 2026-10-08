//! Original stage lyric compositions, rendered through GPUI's SVG drawing API.
//! The host supplies the resolved mode and original scene models; no lyric clock or
//! scene director is reconstructed here. SVG handles rotation, blur and glow;
//! out-of-plane rotations project shaped contours and complete panel geometry.
use gpui_kit::component::{button::*, *};
use gpui_kit::*;
use serde_json::{Value, json};
use std::cell::RefCell;
use std::collections::HashMap;
use std::fmt::Write;
use std::rc::Rc;
use std::sync::{Arc, Condvar, Mutex};
#[path = "lyrics/gpu_scene.rs"]
mod gpu_scene;
pub use gpu_scene::{GpuLyricsAtlas, GpuLyricsBatch, GpuLyricsFrame, GpuLyricsGlyph};
type ShapeKey = (String, u64, u16, u64, bool);
thread_local! {static SHAPED_LINES:RefCell<HashMap<ShapeKey,outline::Line>>=RefCell::new(HashMap::new());}

fn num(value: &Value, key: &str, default: f64) -> f64 {
    value[key]
        .as_f64()
        .filter(|v| v.is_finite())
        .unwrap_or(default)
}
fn text(value: &Value, key: &str) -> String {
    value[key].as_str().unwrap_or("").to_owned()
}
fn items(value: &Value, key: &str) -> Vec<Value> {
    value[key].as_array().cloned().unwrap_or_default()
}
fn escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}
fn font_size(text: &str, width: f64) -> f64 {
    (width * 0.78 / text.chars().filter(|c| !c.is_whitespace()).count().max(6) as f64 * 0.92)
        .clamp(18., 112.)
}
fn color(theme: &Value, key: &str, default: &str) -> String {
    if let Some(hex) = theme[key].as_str().filter(|s| {
        s.len() == 7 && s.starts_with('#') && s[1..].bytes().all(|b| b.is_ascii_hexdigit())
    }) {
        return hex.to_owned();
    }
    let value = &theme[key];
    if let (Some(r), Some(g), Some(b)) = (
        value["red"].as_f64(),
        value["green"].as_f64(),
        value["blue"].as_f64(),
    ) {
        return format!(
            "#{:02x}{:02x}{:02x}",
            (r.clamp(0., 1.) * 255.) as u8,
            (g.clamp(0., 1.) * 255.) as u8,
            (b.clamp(0., 1.) * 255.) as u8
        );
    }
    default.to_owned()
}
pub(crate) struct ShapedSvgText {
    pub(crate) width: f64,
    pub(crate) path: String,
}
/// Shared contour seam for projected stage cards. The path is baseline-relative
/// at (0, 0), with x to the right and y downward, ready for SVG transforms.
pub(crate) fn shaped_text_svg(
    text: &str,
    size: f64,
    weight: u16,
    tracking: f64,
) -> Option<ShapedSvgText> {
    let line = outline::shape_font(text, size, weight, tracking, false)?;
    Some(ShapedSvgText {
        width: line.width,
        path: outline::svg_path(&line.commands, |point| outline::Point {
            x: point.x,
            y: -point.y,
        }),
    })
}
struct ParagraphLayout {
    lines: Vec<String>,
    size: f64,
    line_height: f64,
}
impl ParagraphLayout {
    fn height(&self) -> f64 {
        self.line_height * self.lines.len() as f64
    }
}
struct Scene<'a> {
    snapshot: &'a Value,
    width: f64,
    height: f64,
    svg: String,
    primary: String,
    accent: String,
    secondary: String,
    outlines: HashMap<(String, u64, u16, u64, bool), outline::Line>,
    weight: u16,
    tracking: f64,
    projection: Option<(f64, f64, f64, (f64, f64, f64), f64)>,
    panel: Option<PanelTransform>,
    local: Option<(f64, f64, f64, f64)>,
    text_filter: String,
    italic: bool,
    gpu: Option<Vec<gpu_scene::Primitive>>,
}
#[derive(Clone, Copy, Debug)]
struct PanelTransform {
    anchor: outline::Point,
    angle: f64,
    axis: (f64, f64, f64),
    perspective: f64,
    width: f64,
    rotation: f64,
    scale: f64,
    scale_anchor: outline::Point,
    position: outline::Point,
}
impl PanelTransform {
    fn map(self, point: outline::Point) -> outline::Point {
        let (s, c) = self.rotation.to_radians().sin_cos();
        let dx = point.x - self.anchor.x;
        let dy = point.y - self.anchor.y;
        let rotated = outline::Point {
            x: dx * c - dy * s,
            y: dx * s + dy * c,
        };
        let projected =
            outline::project(rotated, self.angle, self.axis, self.perspective, self.width);
        let point = outline::Point {
            x: self.anchor.x + projected.x,
            y: self.anchor.y + projected.y,
        };
        outline::Point {
            x: self.position.x + self.scale_anchor.x + (point.x - self.scale_anchor.x) * self.scale,
            y: self.position.y + self.scale_anchor.y + (point.y - self.scale_anchor.y) * self.scale,
        }
    }
}
fn confession_panel(width: f64, height: f64) -> PanelTransform {
    PanelTransform {
        anchor: outline::Point {
            x: 0.,
            y: height / 2.,
        },
        angle: -4.,
        axis: (0.02, 1., 0.),
        perspective: 0.76,
        width: width * 0.78 + (width * 0.08).max(62.),
        rotation: 0.,
        scale: 1.,
        scale_anchor: outline::Point::default(),
        position: outline::Point::default(),
    }
}
#[derive(Clone, Copy, Debug)]
struct TranslationStyle {
    weight: u16,
    tracking: f64,
    opacity: f64,
    max_lines: usize,
    min_scale: f64,
    width: f64,
}
fn translation_style(mode: &str, width: f64) -> TranslationStyle {
    let mut style = TranslationStyle {
        weight: 500,
        tracking: 0.,
        opacity: 0.58,
        max_lines: 2,
        min_scale: 1.,
        width: width * 0.64,
    };
    match mode {
        "luminous" => {
            style.tracking = 0.7;
            style.opacity = 0.66;
            style.width = 720f64.min(width);
        }
        "confession" => {
            style.opacity = 0.56;
            style.width = 620f64.min(width * 0.78);
            style.max_lines = usize::MAX;
        }
        "claddagh" => {
            style.opacity = 0.58;
            style.max_lines = usize::MAX;
            style.width = width;
        }
        "monet_poster" => {
            style.opacity = 0.54;
            style.width = width * 0.62;
        }
        "article" => style.width = 680f64.min(width * 0.64),
        "cloud_steps" => {
            style.tracking = 0.8;
            style.opacity = 0.48;
            style.width = 520f64.min(width * 0.5);
        }
        "chorus_chat" => style.opacity = 0.56,
        "diorama" => {
            style.opacity = 0.54;
            style.width = width * 0.6;
        }
        "folding_verse" => {
            style.weight = 600;
            style.max_lines = 1;
            style.min_scale = 0.7;
        }
        _ => {}
    }
    style
}
fn rounded_rectangle(x: f64, y: f64, w: f64, h: f64, r: f64) -> Vec<outline::Command> {
    use outline::{Command::*, Point};
    let r = r.min(w / 2.).min(h / 2.);
    let p = |x, y| Point { x, y };
    vec![
        Move(p(x + r, y)),
        Line(p(x + w - r, y)),
        Quad(p(x + w, y), p(x + w, y + r)),
        Line(p(x + w, y + h - r)),
        Quad(p(x + w, y + h), p(x + w - r, y + h)),
        Line(p(x + r, y + h)),
        Quad(p(x, y + h), p(x, y + h - r)),
        Line(p(x, y + r)),
        Quad(p(x, y), p(x + r, y)),
        Close,
    ]
}
impl<'a> Scene<'a> {
    fn new(snapshot: &'a Value, width: f64, height: f64) -> Self {
        let primary = color(&snapshot["theme"], "primary", "#ecf8ff");
        let accent = color(&snapshot["theme"], "accent", "#66dcff");
        let secondary = color(&snapshot["theme"], "secondary", "#d4b3ff");
        let svg = format!(
            r#"<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}"><defs><filter id="glow" x="-80%" y="-80%" width="260%" height="260%"><feGaussianBlur stdDeviation="8"/></filter><filter id="contextBlur"><feGaussianBlur stdDeviation="1.2"/></filter><filter id="textShadow" x="-50%" y="-80%" width="200%" height="260%"><feDropShadow dx="0" dy="0" stdDeviation="3" flood-color="black" flood-opacity="0.78"/></filter><linearGradient id="lyricGradient"><stop stop-color="{primary}"/><stop offset="1" stop-color="{accent}"/></linearGradient><linearGradient id="tiltGradient"><stop stop-color="{secondary}"/><stop offset="0.5" stop-color="{accent}"/><stop offset="1" stop-color="{primary}"/></linearGradient><linearGradient id="posterGradient" x1="0" y1="0" x2="0" y2="1"><stop stop-color="{accent}" stop-opacity="0.9"/><stop offset="0.5" stop-color="{secondary}" stop-opacity="0.4"/><stop offset="1" stop-color="{secondary}" stop-opacity="0"/></linearGradient></defs>"#
        );
        Self {
            snapshot,
            width,
            height,
            primary,
            accent,
            secondary,
            outlines: HashMap::new(),
            weight: 600,
            tracking: 0.,
            projection: None,
            panel: None,
            local: None,
            text_filter: "url(#textShadow)".to_owned(),
            italic: false,
            svg,
            gpu: None,
        }
    }
    fn rail(&self, amount: f64) -> f64 {
        if self.snapshot["isProgramRailVisible"].as_bool() == Some(true) {
            -amount
        } else {
            0.
        }
    }
    fn audio(&self, key: &str, default: f64) -> f64 {
        num(&self.snapshot["audioMotion"], key, default)
    }
    fn panel_point(&self, mut point: outline::Point) -> outline::Point {
        if let Some((x, y, rotation, scale)) = self.local {
            let (s, c) = rotation.to_radians().sin_cos();
            point = outline::Point {
                x: x + scale * (point.x * c - point.y * s),
                y: y + scale * (point.x * s + point.y * c),
            };
        }
        self.panel.map(|panel| panel.map(point)).unwrap_or(point)
    }
    fn line(
        &mut self,
        text: &str,
        x: f64,
        y: f64,
        size: f64,
        opacity: f64,
        color: &str,
        anchor: &str,
    ) {
        if let Some(shaped) = self.outlined(text, size) {
            let offset = match anchor {
                "middle" => -shaped.width / 2.,
                "end" => -shaped.width,
                _ => 0.,
            };
            let baseline = y + (shaped.ascent - shaped.descent) / 2.;
            let map = |point: outline::Point| {
                let point = outline::Point {
                    x: x + offset + point.x,
                    y: baseline - point.y,
                };
                if self.panel.is_some() {
                    self.panel_point(point)
                } else if let Some((cx, cy, angle, axis, width)) = self.projection {
                    let projected = outline::project(
                        outline::Point {
                            x: point.x - cx,
                            y: point.y - cy,
                        },
                        angle,
                        axis,
                        0.72,
                        width,
                    );
                    outline::Point {
                        x: cx + projected.x,
                        y: cy + projected.y,
                    }
                } else {
                    point
                }
            };
            let path = if self.gpu.is_some() {
                String::new()
            } else if self.projection.is_some() || self.panel.is_some() {
                outline::projected_path(&shaped.commands, map)
            } else {
                outline::svg_path(&shaped.commands, map)
            };
            let gpu_id = if self.gpu.is_some() {
                let padding = size * 0.3;
                let width = (shaped.width + padding * 2.).max(1.);
                let height = (shaped.ascent + shaped.descent + padding * 2.).max(1.);
                let source = outline::svg_path(&shaped.commands, |p| outline::Point {
                    x: p.x + padding,
                    y: shaped.ascent + padding - p.y,
                });
                let matrix = gpu_scene::homography(width, height, |p| {
                    map(outline::Point {
                        x: p.x - padding,
                        y: shaped.ascent + padding - p.y,
                    })
                });
                let list = self.gpu.as_mut().unwrap();
                let id = list.len();
                list.push(gpu_scene::Primitive {
                    path: source,
                    width,
                    height,
                    matrix,
                    fill: color.into(),
                    stroke: "none".into(),
                    stroke_width: 0.,
                    opacity,
                    filter: self.text_filter.clone(),
                });
                format!(r#" data-gpu="{id}""#)
            } else {
                String::new()
            };
            let _ = write!(
                self.svg,
                r#"<path{gpu_id} aria-label="{}" d="{path}" fill="{color}" opacity="{opacity}" filter="{}"/>"#,
                escape(text),
                self.text_filter
            );
            return;
        }
        let _ = write!(
            self.svg,
            r#"<text x="{x}" y="{y}" text-anchor="{anchor}" dominant-baseline="middle" font-family="system-ui, PingFang SC, sans-serif" font-size="{size}" font-weight="{}" font-style="{}" letter-spacing="{}" fill="{color}" opacity="{opacity}">{}</text>"#,
            self.weight,
            if self.italic { "italic" } else { "normal" },
            self.tracking,
            escape(text)
        );
    }
    fn outlined(&mut self, text: &str, size: f64) -> Option<outline::Line> {
        let key = (
            text.to_owned(),
            size.to_bits(),
            self.weight,
            self.tracking.to_bits(),
            self.italic,
        );
        if let Some(line) = self.outlines.get(&key) {
            return Some(line.clone());
        }
        let cached = SHAPED_LINES.with(|cache| cache.borrow().get(&key).cloned());
        let line = if let Some(line) = cached {
            line
        } else {
            let line = outline::shape_font(text, size, self.weight, self.tracking, self.italic)?;
            SHAPED_LINES.with(|cache| {
                let mut cache = cache.borrow_mut();
                if cache.len() >= 512
                    || cache
                        .values()
                        .map(|line| line.commands.len())
                        .sum::<usize>()
                        > 100_000
                {
                    cache.clear();
                }
                cache.insert(key.clone(), line.clone());
            });
            line
        };
        self.outlines.insert(key, line.clone());
        Some(line)
    }
    fn measured_width(&mut self, text: &str, size: f64) -> f64 {
        self.outlined(text, size)
            .map(|line| line.width)
            .unwrap_or_else(|| text.chars().count() as f64 * size * 0.6)
    }
    fn text_height(&mut self, text: &str, size: f64, width: f64, max_lines: usize) -> f64 {
        let lines = outline::wrap_styled(text, size, width, self.weight, self.tracking);
        self.outlined("Ag中文", size)
            .map(|line| line.ascent + line.descent)
            .unwrap_or(size * 1.2)
            * lines.len().min(max_lines) as f64
    }
    fn fitted_size(&mut self, text: &str, size: f64, width: f64, minimum: f64) -> f64 {
        let mut resolved = size;
        while self.measured_width(text, resolved) > width && resolved > size * minimum + 0.1 {
            resolved = (resolved - 0.5).max(size * minimum);
        }
        resolved
    }
    fn panel_rect(
        &mut self,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        r: f64,
        fill: &str,
        fill_opacity: f64,
        stroke: &str,
        stroke_opacity: f64,
        stroke_width: f64,
    ) {
        let commands = rounded_rectangle(x, y, w, h, r);
        let path = if self.gpu.is_some() {
            String::new()
        } else {
            outline::projected_path(&commands, |point| self.panel_point(point))
        };
        if self.gpu.is_some() {
            let fill_id = self.gpu_shape(&commands, x, y, w, h, fill, "none", 0., fill_opacity);
            let stroke_id = self.gpu_shape(
                &commands,
                x,
                y,
                w,
                h,
                "none",
                stroke,
                stroke_width,
                stroke_opacity,
            );
            let _ = write!(
                self.svg,
                r#"<path{fill_id} d="{path}"/><path{stroke_id} d="{path}"/>"#
            );
            return;
        }
        let _ = write!(
            self.svg,
            r#"<path d="{path}" fill="{fill}" fill-opacity="{fill_opacity}" stroke="{stroke}" stroke-opacity="{stroke_opacity}" stroke-width="{stroke_width}"/>"#
        );
    }
    fn gpu_shape(
        &mut self,
        commands: &[outline::Command],
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        fill: &str,
        stroke: &str,
        stroke_width: f64,
        opacity: f64,
    ) -> String {
        if self.gpu.is_none() {
            return String::new();
        }
        let pad = stroke_width + 1.;
        let width = (w + pad * 2.).max(1.);
        let height = (h + pad * 2.).max(1.);
        let path = outline::svg_path(commands, |p| outline::Point {
            x: p.x - x + pad,
            y: p.y - y + pad,
        });
        let matrix = gpu_scene::homography(width, height, |p| {
            self.panel_point(outline::Point {
                x: p.x + x - pad,
                y: p.y + y - pad,
            })
        });
        let list = self.gpu.as_mut().unwrap();
        let id = list.len();
        list.push(gpu_scene::Primitive {
            path,
            width,
            height,
            matrix,
            fill: fill.into(),
            stroke: stroke.into(),
            stroke_width,
            opacity,
            filter: "none".into(),
        });
        format!(r#" data-gpu="{id}""#)
    }
    fn paragraph(
        &mut self,
        text: &str,
        x: f64,
        y: f64,
        size: f64,
        width: f64,
        max_lines: usize,
        min_scale: f64,
        opacity: f64,
        color: &str,
        anchor: &str,
    ) {
        let layout = self.paragraph_layout(text, size, width, max_lines, min_scale);
        let top = y - (layout.lines.len().saturating_sub(1) as f64) * layout.line_height / 2.;
        for (index, line) in layout.lines.iter().enumerate() {
            self.line(
                line,
                x,
                top + index as f64 * layout.line_height,
                layout.size,
                opacity,
                color,
                anchor,
            );
        }
    }
    fn paragraph_layout(
        &mut self,
        text: &str,
        size: f64,
        width: f64,
        max_lines: usize,
        min_scale: f64,
    ) -> ParagraphLayout {
        if text.is_empty() {
            return ParagraphLayout {
                lines: vec![],
                size,
                line_height: 0.,
            };
        }
        let mut resolved = size;
        let mut lines = outline::wrap_styled(text, size, width, self.weight, self.tracking);
        while lines.len() > max_lines && resolved > size * min_scale + 0.1 {
            resolved = (resolved - 0.5).max(size * min_scale);
            lines = outline::wrap_styled(text, resolved, width, self.weight, self.tracking);
        }
        if lines.len() > max_lines {
            lines.truncate(max_lines);
            if let Some(last) = lines.last_mut() {
                while self.measured_width(&format!("{last}…"), resolved) > width && !last.is_empty()
                {
                    last.pop();
                }
                last.push('…');
            }
        }
        let line_height = self
            .outlined("Ag中文", resolved)
            .map(|l| l.ascent + l.descent)
            .unwrap_or(resolved * 1.2);
        ParagraphLayout {
            lines,
            size: resolved,
            line_height,
        }
    }
    fn perspective_line(
        &mut self,
        text: &str,
        x: f64,
        y: f64,
        size: f64,
        opacity: f64,
        color: &str,
        angle: f64,
        axis: (f64, f64, f64),
        perspective: f64,
        anchor: &str,
    ) {
        if let Some(line) = self.outlined(text, size) {
            let offset = match anchor {
                "middle" => -line.width / 2.,
                "end" => -line.width,
                _ => 0.,
            };
            let baseline = (line.ascent - line.descent) / 2.;
            let path = if self.gpu.is_some() {
                String::new()
            } else {
                outline::projected_path(&line.commands, |point| {
                    let source = outline::Point {
                        x: point.x + offset,
                        y: baseline - point.y,
                    };
                    let projected =
                        outline::project(source, angle, axis, perspective, line.width.max(size));
                    outline::Point {
                        x: x + projected.x,
                        y: y + projected.y,
                    }
                })
            };
            let gpu_id = if self.gpu.is_some() {
                let padding = size * 0.3;
                let width = (line.width + padding * 2.).max(1.);
                let height = (line.ascent + line.descent + padding * 2.).max(1.);
                let source = outline::svg_path(&line.commands, |p| outline::Point {
                    x: p.x + padding,
                    y: line.ascent + padding - p.y,
                });
                let matrix = gpu_scene::homography(width, height, |p| {
                    let projected = outline::project(
                        outline::Point {
                            x: p.x - padding + offset,
                            y: p.y - padding - (line.ascent + line.descent) / 2.,
                        },
                        angle,
                        axis,
                        perspective,
                        line.width.max(size),
                    );
                    outline::Point {
                        x: x + projected.x,
                        y: y + projected.y,
                    }
                });
                let list = self.gpu.as_mut().unwrap();
                let id = list.len();
                list.push(gpu_scene::Primitive {
                    path: source,
                    width,
                    height,
                    matrix,
                    fill: color.into(),
                    stroke: "none".into(),
                    stroke_width: 0.,
                    opacity,
                    filter: "none".into(),
                });
                format!(r#" data-gpu="{id}""#)
            } else {
                String::new()
            };
            let _ = write!(
                self.svg,
                r#"<path{gpu_id} aria-label="{}" d="{path}" fill="{color}" opacity="{opacity}"/>"#,
                escape(text)
            );
        } else {
            self.line(text, x, y, size, opacity, color, anchor);
        }
    }
    fn rect(
        &mut self,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        r: f64,
        fill: &str,
        stroke: &str,
        opacity: f64,
    ) {
        if self.gpu.is_some() {
            let commands = rounded_rectangle(x, y, w, h, r);
            let fill_id = self.gpu_shape(&commands, x, y, w, h, fill, "none", 0., 1.);
            let stroke_id = self.gpu_shape(&commands, x, y, w, h, "none", stroke, 1., 1.);
            let path = String::new();
            let _ = write!(
                self.svg,
                r#"<g opacity="{opacity}"><path{fill_id} d="{path}"/><path{stroke_id} d="{path}"/></g>"#
            );
            return;
        }
        if self.panel.is_some() {
            let commands = rounded_rectangle(x, y, w, h, r);
            let path = outline::projected_path(&commands, |point| self.panel_point(point));
            let _ = write!(
                self.svg,
                r#"<path d="{path}" fill="{fill}" stroke="{stroke}" stroke-width="1" opacity="{opacity}"/>"#
            );
            return;
        }
        let _ = write!(
            self.svg,
            r#"<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}" stroke="{stroke}" stroke-width="1" opacity="{opacity}"/>"#
        );
    }
    fn translation(&mut self, x: f64, y: f64, size: f64, anchor: &str) {
        let value = text(&self.snapshot["flow"], "translation");
        if !value.is_empty() {
            let style = translation_style(self.snapshot["mode"].as_str().unwrap_or(""), self.width);
            let previous = (self.weight, self.tracking);
            let previous_filter = self.text_filter.clone();
            (self.weight, self.tracking) = (style.weight, style.tracking);
            if self.snapshot["mode"] == "luminous" {
                self.svg.push_str(r#"<defs><filter id="translationShadow" x="-50%" y="-100%" width="200%" height="300%"><feDropShadow dx="0" dy="0" stdDeviation="2.5" flood-color="black" flood-opacity="0.9"/></filter></defs>"#);
                self.text_filter = "url(#translationShadow)".to_owned();
            } else {
                self.text_filter = "none".to_owned();
            }
            self.paragraph(
                &value,
                x,
                y,
                size,
                style.width,
                style.max_lines,
                style.min_scale,
                style.opacity,
                &if self.snapshot["mode"] == "claddagh" {
                    "#ffffff".to_owned()
                } else {
                    self.primary.clone()
                },
                anchor,
            );
            (self.weight, self.tracking) = previous;
            self.text_filter = previous_filter;
        }
    }
    fn glyphs(&mut self, cx: f64, cy: f64, size: f64, arc: bool) {
        let previous_style = (self.weight, self.tracking);
        let previous_filter = self.text_filter.clone();
        self.text_filter = "none".to_owned();
        let projection = self.projection;
        self.weight = 700;
        self.tracking = size * -0.018;
        let flow = &self.snapshot["flow"];
        let glyphs = items(flow, "glyphs");
        let count = glyphs.len().max(1);
        let time = num(self.snapshot, "animationTime", 0.);
        let chorus = flow["isChorus"].as_bool() == Some(true);
        let widths: Vec<f64> = glyphs
            .iter()
            .map(|glyph| self.measured_width(&text(glyph, "text"), size))
            .collect();
        let spacing = size
            * if arc
                || self.snapshot["mode"] == "diorama"
                || self.snapshot["mode"] == "monet_poster"
            {
                0.012
            } else {
                0.015
            };
        let total = widths.iter().sum::<f64>() + spacing * count.saturating_sub(1) as f64;
        let mut cursor = cx - total / 2.;
        for (index, glyph) in glyphs.iter().enumerate() {
            let unit = if count == 1 {
                0.5
            } else {
                index as f64 / (count - 1) as f64
            };
            let angle = (unit - 0.5) * 1.58;
            let phase = glyph["phase"].as_str().unwrap_or("waiting");
            let progress = num(glyph, "progress", 0.).clamp(0., 1.);
            let pulse = (progress * std::f64::consts::PI).sin();
            let glow_id = format!("glyphGlow{index}");
            let _ = write!(
                self.svg,
                r#"<defs><filter id="{glow_id}" x="-150%" y="-150%" width="400%" height="400%"><feGaussianBlur stdDeviation="{}"/></filter><filter id="glyphWaiting"><feGaussianBlur stdDeviation="0.55"/></filter></defs>"#,
                10. + pulse * 8.
            );
            let (opacity, scale, lift, motion) = match phase {
                "active" => (1., 1.04 + pulse * 0.035, -2. - pulse * 4., 0.18),
                "passed" => (0.96, 1., 0., 0.04),
                _ => (0.72, 0.98, 3., 0.08),
            };
            let mut x = cursor + widths[index] / 2. + num(glyph, "xOffset", 0.) * motion;
            cursor += widths[index] + spacing;
            let mut y = cy + num(glyph, "yOffset", 0.) * motion + lift;
            if arc {
                x = cx + angle.sin() * 430f64.min(self.width * 0.38) * self.audio("expansion", 1.);
                y = cy - 92. * angle.cos()
                    + (time * 0.55 + unit * 4.).sin() * 4.
                    + self.audio("beatLift", 0.) * (0.12 + unit * 0.1);
            }
            let fill = if phase == "waiting" {
                self.primary.clone()
            } else if phase == "active" && glyph["semanticColorHex"].as_str().is_some() {
                color(glyph, "semanticColorHex", &self.primary)
            } else if chorus {
                self.secondary.clone()
            } else if phase == "passed" {
                self.accent.clone()
            } else {
                self.primary.clone()
            };
            let scale = scale * num(glyph, "restingScale", 1.);
            let rotation = num(glyph, "rotation", 0.) * motion;
            self.projection =
                projection.map(|(_, _, angle, axis, width)| (cx - x, cy - y, angle, axis, width));
            if self.panel.is_some() {
                self.local = Some((x, y, rotation, scale));
                let _ = write!(
                    self.svg,
                    r#"<g opacity="{opacity}" filter="{}">"#,
                    if phase == "waiting" {
                        "url(#glyphWaiting)"
                    } else {
                        "none"
                    }
                );
            } else {
                let _ = write!(
                    self.svg,
                    r#"<g transform="translate({x} {y}) rotate({rotation}) scale({scale})" opacity="{opacity}" filter="{}">"#,
                    if phase == "waiting" {
                        "url(#glyphWaiting)"
                    } else {
                        "none"
                    }
                );
            }
            if phase == "active" {
                let glow = if chorus {
                    self.secondary.clone()
                } else {
                    self.accent.clone()
                };
                let _ = write!(self.svg, r#"<g filter="url(#{glow_id})" opacity="0.7">"#);
                if arc {
                    self.perspective_line(
                        &text(glyph, "text"),
                        0.,
                        0.,
                        size,
                        1.,
                        &glow,
                        (unit - 0.5) * -34.,
                        (0.12, 1., 0.),
                        0.7,
                        "middle",
                    );
                } else {
                    self.line(&text(glyph, "text"), 0., 0., size, 1., &glow, "middle");
                }
                self.svg.push_str("</g>");
            }
            if arc {
                self.perspective_line(
                    &text(glyph, "text"),
                    0.,
                    0.,
                    size,
                    if phase == "waiting" {
                        0.26
                    } else if phase == "passed" {
                        0.88
                    } else {
                        1.
                    },
                    &fill,
                    (unit - 0.5) * -34.,
                    (0.12, 1., 0.),
                    0.7,
                    "middle",
                );
            } else {
                self.line(
                    &text(glyph, "text"),
                    0.,
                    0.,
                    size,
                    if phase == "waiting" {
                        0.26
                    } else if phase == "passed" {
                        0.88
                    } else {
                        1.
                    },
                    &fill,
                    "middle",
                );
            }
            self.svg.push_str("</g>");
            self.local = None;
        }
        (self.weight, self.tracking) = previous_style;
        self.text_filter = previous_filter;
        self.projection = projection;
    }
    fn active_text(&self) -> String {
        text(&self.snapshot["flow"]["activeLine"], "text")
    }
    fn flow(&mut self) {
        let size = font_size(&self.active_text(), self.width);
        let cx = self.width * 0.5 + self.rail(150.);
        let cy = self.height * 0.5 - 8.;
        let previous = text(&self.snapshot["flow"]["previousLine"], "text");
        let next = text(&self.snapshot["flow"]["nextLine"], "text");
        let translation = text(&self.snapshot["flow"], "translation");
        let context_size = (size * 0.28).clamp(15., 24.);
        let context_width = 680f64.min(self.width);
        self.weight = 600;
        self.tracking = 0.5;
        let previous_height = self
            .paragraph_layout(&previous, context_size, context_width, 1, 0.72)
            .height();
        let next_height = self
            .paragraph_layout(&next, context_size, context_width, 1, 0.72)
            .height();
        self.weight = 700;
        self.tracking = size * -0.018;
        let glyph_height = self
            .outlined("Ag中文", size)
            .map(|line| line.ascent + line.descent)
            .unwrap_or(size * 1.2);
        self.weight = 500;
        self.tracking = 0.7;
        let translation_size = (size * 0.22).max(16.);
        let translation_height = self
            .paragraph_layout(
                &translation,
                translation_size,
                720f64.min(self.width),
                2,
                1.,
            )
            .height();
        let count = 1
            + usize::from(!previous.is_empty())
            + usize::from(!next.is_empty())
            + usize::from(!translation.is_empty());
        let height = previous_height
            + next_height
            + glyph_height
            + translation_height
            + 22. * count.saturating_sub(1) as f64;
        let expansion = self.audio("expansion", 1.);
        let _ = write!(
            self.svg,
            r#"<g transform="translate({} {}) scale({expansion}) translate({} {})"><defs><filter id="flowPreviousBlur"><feGaussianBlur stdDeviation="1.5"/></filter><filter id="flowNextBlur"><feGaussianBlur stdDeviation="0.9"/></filter><filter id="flowCompositeShadow" x="-100%" y="-100%" width="300%" height="300%"><feDropShadow dx="0" dy="0" stdDeviation="{}" flood-color="{}" flood-opacity="{}"/><feDropShadow dx="0" dy="0" stdDeviation="3" flood-color="black" flood-opacity="0.78"/></filter></defs>"#,
            self.width / 2.,
            self.height / 2.,
            -self.width / 2.,
            -self.height / 2.,
            if self.snapshot["flow"]["isChorus"] == true {
                22.
            } else {
                14.
            },
            if self.snapshot["flow"]["isChorus"] == true {
                &self.secondary
            } else {
                &self.accent
            },
            if self.snapshot["flow"]["isChorus"] == true {
                0.3
            } else {
                0.22
            }
        );
        let mut top = cy - height / 2.;
        self.text_filter = "none".to_owned();
        if !previous.is_empty() {
            self.weight = 600;
            self.tracking = 0.5;
            self.svg.push_str(r#"<g filter="url(#flowPreviousBlur)">"#);
            self.paragraph(
                &previous,
                cx - context_width / 2. - 42.,
                top + previous_height / 2.,
                context_size,
                context_width,
                1,
                0.72,
                0.18,
                &self.primary.clone(),
                "start",
            );
            self.svg.push_str("</g>");
            top += previous_height + 22.;
        }
        self.svg
            .push_str(r#"<g filter="url(#flowCompositeShadow)">"#);
        self.glyphs(
            cx,
            top + glyph_height / 2.
                + (num(self.snapshot, "animationTime", 0.) * 0.72).sin() * 2.2
                + self.audio("beatLift", 0.) * 0.18,
            size,
            false,
        );
        self.svg.push_str("</g>");
        top += glyph_height;
        if !translation.is_empty() {
            top += 22.;
            self.translation(
                cx,
                top + translation_height / 2.,
                translation_size,
                "middle",
            );
            top += translation_height;
        }
        if !next.is_empty() {
            top += 22.;
            self.weight = 600;
            self.tracking = 0.5;
            self.svg.push_str(r#"<g filter="url(#flowNextBlur)">"#);
            self.paragraph(
                &next,
                cx + context_width / 2. + 42.,
                top + next_height / 2.,
                context_size,
                context_width,
                1,
                0.72,
                0.28,
                &self.primary.clone(),
                "end",
            );
            self.svg.push_str("</g>");
        }
        self.svg.push_str("</g>");
        self.weight = 600;
        self.tracking = 0.;
        self.text_filter = "url(#textShadow)".to_owned();
    }
    fn depth(&mut self) {
        let mut lines = items(&self.snapshot["depth"], "lines");
        lines.sort_by_key(|line| num(line, "position", 1.) == 0.);
        let _ = write!(
            self.svg,
            r#"<defs><linearGradient id="depthContextGradient"><stop stop-color="{}" stop-opacity="0.76"/><stop offset="1" stop-color="{}" stop-opacity="0.5"/></linearGradient></defs>"#,
            self.primary, self.accent
        );
        for (index, line) in lines.into_iter().enumerate() {
            let current = num(&line, "position", 0.) == 0.;
            let p = num(&line, "presentationPosition", num(&line, "position", 0.));
            self.weight = if current { 700 } else { 600 };
            self.tracking = if current { 0.4 } else { 0.1 };
            let size = num(&line, "presentationSize", if current { 38. } else { 24. });
            let scale = num(&line, "scale", 1.)
                * if current {
                    self.audio("expansion", 1.)
                } else {
                    1.
                };
            let width = (if current { 760f64 } else { 620f64 }).min(self.width);
            let cx = self.width * 0.5 + self.rail(150.) + p * 92.;
            let cy = self.height * 0.5
                + p * 96.
                + if current {
                    self.audio("beatLift", 0.) * 0.24
                } else {
                    0.
                };
            let _ = write!(
                self.svg,
                r#"<defs><filter id="depthShadow{index}" x="-100%" y="-100%" width="300%" height="300%"><feDropShadow dx="0" dy="0" stdDeviation="{}" flood-color="{}" flood-opacity="{}"/><feDropShadow dx="0" dy="0" stdDeviation="4" flood-color="black" flood-opacity="0.96"/></filter><filter id="depthBlur{index}" x="-100%" y="-100%" width="300%" height="300%"><feGaussianBlur stdDeviation="{}"/></filter></defs><g opacity="{}" filter="url(#depthBlur{index})"><g filter="url(#depthShadow{index})">"#,
                if current { 18. } else { 7. },
                if current { &self.accent } else { "black" },
                if current { 0.5 } else { 0.72 },
                num(&line, "blurRadius", 0.),
                num(&line, "opacity", 1.)
            );
            self.panel = Some(PanelTransform {
                anchor: outline::Point::default(),
                angle: -p * 12.,
                axis: (0.08, 1., 0.),
                perspective: 0.68,
                width,
                rotation: 0.,
                scale: 1.,
                scale_anchor: outline::Point::default(),
                position: outline::Point { x: cx, y: cy },
            });
            self.local = Some((0., 0., 0., scale));
            self.text_filter = "none".to_owned();
            self.paragraph(
                &text(&line, "text"),
                0.,
                0.,
                size,
                width,
                2,
                1.,
                1.,
                if current {
                    "url(#lyricGradient)"
                } else {
                    "url(#depthContextGradient)"
                },
                "middle",
            );
            self.svg.push_str("</g></g>");
            self.panel = None;
            self.local = None;
        }
        self.weight = 600;
        self.tracking = 0.;
        self.text_filter = "url(#textShadow)".to_owned();
    }
    fn cloud(&mut self) {
        let glyphs = items(&self.snapshot["flow"], "glyphs");
        let size = (self.width * 0.7 / glyphs.len().max(1) as f64).clamp(25., 68.);
        for placement in items(&self.snapshot["partita"], "placements") {
            if let Some(glyph) = glyphs.iter().find(|g| g["id"] == placement["glyphID"]) {
                let x = self.width * (0.5 + num(&placement, "x", 0.)) + self.rail(140.);
                let y = self.height * (0.5 + num(&placement, "y", 0.));
                let rotation = num(&placement, "rotationDegrees", 0.);
                let scale =
                    num(&placement, "scale", 1.) * (1. + self.audio("sceneEnergy", 0.) * 0.025);
                let _ = write!(
                    self.svg,
                    r#"<g transform="translate({x} {y}) rotate({}) scale({} {scale})">"#,
                    rotation * 0.28,
                    scale
                );
                self.perspective_line(
                    &text(glyph, "text"),
                    0.,
                    0.,
                    size,
                    if glyph["phase"] == "waiting" {
                        0.26
                    } else {
                        1.
                    },
                    &self.accent.clone(),
                    rotation * 0.72,
                    (0.08, 1., 0.),
                    0.72,
                    "middle",
                );
                self.svg.push_str("</g>");
            }
        }
        self.translation(
            self.width * 0.5 + self.rail(140.),
            self.height * 0.84,
            15.,
            "middle",
        );
    }
    fn chorus(&mut self) {
        let size = font_size(&self.active_text(), self.width * 0.5);
        let cx = self.width * 0.5 + self.rail(140.);
        let cy = self.height * 0.5;
        let w = (self.width * 0.72).min(860.);
        let h = size + 76.;
        self.rect(
            cx - w / 2.,
            cy - h / 2.,
            w,
            h,
            30.,
            "#000000",
            &self.accent.clone(),
            0.32,
        );
        self.glyphs(cx, cy - 10., size, false);
        self.translation(cx, cy + size * 0.55, (size * 0.19).max(14.), "middle");
        for (key, y, dx) in [
            ("previousLine", cy - h / 2. - 40., 40.),
            ("nextLine", cy + h / 2. + 40., -40.),
        ] {
            let line = text(&self.snapshot["flow"][key], "text");
            if !line.is_empty() {
                self.rect(
                    cx - w * 0.35 + dx,
                    y - 22.,
                    w * 0.7,
                    44.,
                    22.,
                    "#ffffff",
                    "#ffffff",
                    0.045,
                );
                self.line(
                    &line,
                    cx + dx,
                    y,
                    18.,
                    0.36,
                    &self.primary.clone(),
                    "middle",
                );
            }
        }
    }
    fn cinematic(&mut self) {
        let size = font_size(&self.active_text(), self.width * 0.76);
        let time = num(self.snapshot, "playbackTime", 0.);
        let padding = (self.width * 0.08).max(62.);
        let frame_width = self.width * 0.78;
        let mut rows = vec![];
        let mut content_height = 0.;
        let spacing = size * 0.08;
        let lifecycle_segments = self.snapshot["_presentation"]["renderSegments"].as_array();
        let segments = lifecycle_segments
            .cloned()
            .unwrap_or_else(|| items(&self.snapshot["tilt"], "segments"));
        for segment in segments {
            if lifecycle_segments.is_none() && time < num(&segment, "revealAt", f64::MAX) {
                continue;
            }
            let tilted = segment["isTilted"].as_bool() == Some(true);
            let progress = num(
                &self.snapshot["_presentation"]["segments"],
                &text(&segment, "id"),
                1.,
            );
            self.weight = if tilted { 300 } else { 700 };
            self.tracking = 0.;
            self.italic = tilted;
            let value = text(&segment, "text");
            let font = size * if tilted { 1.14 } else { 1. };
            let height = self.text_height(&value, font, frame_width, usize::MAX);
            if !rows.is_empty() {
                content_height += spacing * progress.max(0.);
            }
            content_height += height * progress.max(0.);
            rows.push((segment, tilted, progress, font, height, value));
        }
        self.weight = 500;
        self.tracking = 0.;
        self.italic = false;
        let translation = text(&self.snapshot["flow"], "translation");
        let translation_size = (size * 0.2).max(15.);
        let translation_height = self.text_height(
            &translation,
            translation_size,
            620f64.min(frame_width),
            usize::MAX,
        );
        if translation_height > 0. {
            content_height += translation_height + 8. + if rows.is_empty() { 0. } else { spacing };
        }
        self.panel = Some(confession_panel(self.width, self.height));
        let _ = write!(
            self.svg,
            r#"<defs><linearGradient id="confessionStraight" x1="0" y1="0" x2="0" y2="1"><stop stop-color="{}"/><stop offset="1" stop-color="{}" stop-opacity="0.76"/></linearGradient><filter id="confessionPlainShadow" x="-50%" y="-100%" width="200%" height="300%"><feDropShadow dx="0" dy="0" stdDeviation="2.5" flood-color="black" flood-opacity="0.72"/></filter><filter id="confessionTiltShadow" x="-100%" y="-100%" width="300%" height="300%"><feDropShadow dx="0" dy="0" stdDeviation="9" flood-color="{}" flood-opacity="0.32"/></filter></defs>"#,
            self.primary, self.primary, self.accent
        );
        let mut top = (self.height - content_height) / 2.;
        let row_count = rows.len();
        for (index, (segment, tilted, progress, font, height, value)) in
            rows.into_iter().enumerate()
        {
            if index > 0 {
                top += spacing * progress.max(0.);
            }
            self.weight = if tilted { 300 } else { 700 };
            self.italic = tilted;
            self.text_filter = if tilted {
                "url(#confessionTiltShadow)"
            } else {
                "url(#confessionPlainShadow)"
            }
            .to_owned();
            let rotation: f64 = if tilted { -7. } else { 0. };
            let scale = if tilted {
                1. + self.audio("mid", 0.) * 0.045
            } else {
                1.
            };
            let offset_x = self.width * num(&segment, "xOffset", 0.);
            let offset_y = self.audio("beatLift", 0.) * if tilted { 0.22 } else { 0.08 };
            let (s, c) = rotation.to_radians().sin_cos();
            self.local = Some((
                padding
                    + self.rail(104.)
                    + scale * (offset_x * c - offset_y * s)
                    + (if tilted { 34. } else { -22. }) * (1. - progress),
                top + height * progress.max(0.) / 2. - 14. + scale * (offset_x * s + offset_y * c),
                rotation,
                scale,
            ));
            self.paragraph(
                &value,
                0.,
                0.,
                font,
                frame_width,
                usize::MAX,
                1.,
                progress.clamp(0., 1.),
                if tilted {
                    "url(#tiltGradient)"
                } else {
                    "url(#confessionStraight)"
                },
                "start",
            );
            self.local = None;
            top += height * progress.max(0.);
        }
        self.italic = false;
        self.text_filter = "url(#textShadow)".to_owned();
        if translation_height > 0. {
            top += 8. + if row_count > 0 { spacing } else { 0. };
            self.translation(
                padding + self.rail(104.),
                top + translation_height / 2. - 14.,
                translation_size,
                "start",
            );
        }
        self.panel = None;
        self.weight = 600;
        self.tracking = 0.;
    }
    fn orbit(&mut self) {
        let count = items(&self.snapshot["flow"], "glyphs").len().max(1);
        let size = (self.width * 0.7 / count as f64).clamp(26., 72.);
        let cx = self.width * 0.5 + self.rail(150.);
        self.glyphs(cx, self.height * 0.5 - 18., size, true);
        self.translation(cx, self.height * 0.5 + 60., 17., "middle");
    }
    fn poster(&mut self) {
        let entries = items(&self.snapshot["monet"], "entries");
        let size = font_size(&self.active_text(), self.width * 0.58);
        let x = (self.width * 0.075).max(60.) + self.rail(96.);
        let height = (self.height * 0.7).min(520.) * self.audio("expansion", 1.);
        let bar_width = 3. + self.audio("high", 0.) * 2.;
        let max_width = self.width * 0.62;
        self.rect(
            x,
            self.height * 0.5 - height / 2.,
            bar_width,
            height,
            2.,
            "url(#posterGradient)",
            "none",
            1.,
        );
        let mut rows = vec![];
        let mut total_height = 0.;
        for entry in entries {
            let active = entry["status"] == "active";
            let row_height = if active {
                self.weight = 700;
                self.tracking = size * -0.018;
                let glyph_height = self
                    .outlined("Ag中文", size)
                    .map(|line| line.ascent + line.descent)
                    .unwrap_or(size * 1.2);
                self.weight = 500;
                self.tracking = 0.;
                let translation_size = (size * 0.2).max(15.);
                let translation_height = self
                    .paragraph_layout(
                        &text(&self.snapshot["flow"], "translation"),
                        translation_size,
                        max_width,
                        2,
                        1.,
                    )
                    .height();
                glyph_height
                    + if translation_height > 0. {
                        10. + translation_height
                    } else {
                        0.
                    }
                    + 20.
            } else {
                self.weight = if entry["status"] == "passed" {
                    500
                } else {
                    600
                };
                self.tracking = 0.;
                self.paragraph_layout(
                    &text(&entry["line"], "text"),
                    (size * 0.34).clamp(17., 28.),
                    max_width * 0.82,
                    2,
                    0.72,
                )
                .height()
            };
            if !rows.is_empty() {
                total_height += 14.;
            }
            total_height += row_height;
            rows.push((entry, active, row_height));
        }
        let mut top = self.height / 2. - total_height / 2.;
        for (index, (entry, active, row_height)) in rows.into_iter().enumerate() {
            if index > 0 {
                top += 14.;
            }
            let offset = num(&entry, "offset", 0.);
            let sx = x + bar_width + 28. + offset.abs() * 18. + if offset > 0. { 12. } else { 0. };
            let transition = &entry["_presentation"];
            let y = top + row_height / 2. + num(transition, "offsetY", 0.);
            let _ = write!(
                self.svg,
                r#"<defs><filter id="monetBlur{index}" x="-100%" y="-100%" width="300%" height="300%"><feGaussianBlur stdDeviation="{}"/></filter></defs><g opacity="{}" filter="url(#monetBlur{index})">"#,
                if active { 0. } else { offset.abs() * 0.34 },
                num(transition, "opacity", 1.)
            );
            self.text_filter = "none".to_owned();
            if active {
                self.weight = 700;
                self.tracking = size * -0.018;
                let glyphs = items(&self.snapshot["flow"], "glyphs");
                let glyph_width = glyphs
                    .iter()
                    .map(|glyph| self.measured_width(&text(glyph, "text"), size))
                    .sum::<f64>()
                    + size * 0.012 * glyphs.len().saturating_sub(1) as f64;
                let glyph_height = self
                    .outlined("Ag中文", size)
                    .map(|line| line.ascent + line.descent)
                    .unwrap_or(size * 1.2);
                let _ = write!(
                    self.svg,
                    r#"<defs><filter id="monetActiveShadow" x="-100%" y="-100%" width="300%" height="300%"><feDropShadow dx="0" dy="0" stdDeviation="22" flood-color="{}" flood-opacity="{}"/></filter></defs><g filter="url(#monetActiveShadow)"><g transform="translate({sx} {}) scale({} {})">"#,
                    self.accent,
                    0.18 + self.audio("glow", 0.) * 0.18,
                    top + 10. + glyph_height / 2.,
                    self.audio("expansion", 1.),
                    1. + self.audio("mid", 0.) * 0.025
                );
                self.glyphs(glyph_width / 2., 0., size, false);
                self.svg.push_str("</g>");
                let translation_size = (size * 0.2).max(15.);
                self.weight = 500;
                self.tracking = 0.;
                let translation_height = self
                    .paragraph_layout(
                        &text(&self.snapshot["flow"], "translation"),
                        translation_size,
                        max_width,
                        2,
                        1.,
                    )
                    .height();
                if translation_height > 0. {
                    self.translation(
                        sx,
                        top + 10. + glyph_height + 10. + translation_height / 2.,
                        translation_size,
                        "start",
                    );
                }
                self.svg.push_str("</g>");
            } else {
                let passed = entry["status"] == "passed";
                self.weight = if passed { 500 } else { 600 };
                self.tracking = 0.;
                let opacity = if passed {
                    0.16 + 0.05 / offset.abs()
                } else {
                    0.34 - (offset.abs() - 1.) * 0.07
                };
                self.paragraph(
                    &text(&entry["line"], "text"),
                    sx,
                    y,
                    (size * 0.34).clamp(17., 28.),
                    max_width * 0.82,
                    2,
                    0.72,
                    opacity,
                    &if passed {
                        self.secondary.clone()
                    } else {
                        self.primary.clone()
                    },
                    "start",
                );
            }
            self.svg.push_str("</g>");
            top += row_height;
        }
        self.weight = 600;
        self.tracking = 0.;
        self.text_filter = "url(#textShadow)".to_owned();
    }
    fn editorial(&mut self) {
        let target = &self.snapshot["article"]["cameraTarget"];
        for block in items(&self.snapshot["article"], "blocks") {
            if block["lineID"] == self.snapshot["flow"]["activeLine"]["id"] {
                continue;
            }
            let bx = num(&block, "x", 0.5);
            let by = num(&block, "y", 0.5);
            let distance = (by - num(target, "y", 0.5)).abs();
            let x = self.width * (0.5 + (bx - num(target, "x", 0.5)) * 1.45);
            let y = self.height * (0.5 + (by - num(target, "y", 0.5)) * 2.25);
            let max_width = self.width * num(&block, "width", 0.42).min(0.42);
            let _ = write!(self.svg, r#"<g filter="url(#contextBlur)">"#);
            self.paragraph(
                &text(&block, "text"),
                x + if bx < 0.5 {
                    -max_width / 2.
                } else {
                    max_width / 2.
                },
                y,
                17. + (1. - distance * 4.).max(0.) * 8.,
                max_width,
                3,
                1.,
                (0.34 - distance * 0.72).max(0.07),
                &self.primary.clone(),
                if bx < 0.5 { "start" } else { "end" },
            );
            self.svg.push_str("</g>");
        }
        let size = font_size(&self.active_text(), self.width * 0.62);
        let cx = self.width * 0.5 + self.rail(140.);
        let cy = self.height * 0.5;
        self.rect(
            cx - self.width * 0.32 - 32.,
            cy - size / 2. - 26.,
            self.width * 0.64 + 64.,
            size + 80.,
            34.,
            "#000000",
            "#ffffff",
            0.16,
        );
        self.glyphs(cx, cy, size, false);
        self.translation(cx, cy + size * 0.6 + 16., (size * 0.19).max(15.), "middle");
    }
    fn pendulum(&mut self) {
        let radius = self.width.min(self.height) * 0.48 * self.audio("expansion", 1.);
        let cx = self.width * 0.04 + self.rail(140.);
        let cy = self.height * 0.5;
        let _ = write!(
            self.svg,
            r#"<path d="M {cx} {} A {radius} {radius} 0 0 1 {cx} {}" stroke="{}" stroke-opacity="0.58" stroke-width="{}" fill="none"/>"#,
            cy - radius,
            cy + radius,
            self.accent,
            1.2 + self.audio("high", 0.) * 1.4
        );
        for item in items(&self.snapshot["wheel"], "items") {
            let x = cx + num(&item, "x", 0.) * radius;
            let y = cy + num(&item, "y", 0.) * radius;
            let size = if item["isActive"].as_bool() == Some(true) {
                font_size(&self.active_text(), self.width * 0.56)
            } else {
                24.
            };
            let scale = num(&item, "scale", 1.);
            let _ = write!(
                self.svg,
                r#"<g transform="translate({x} {y}) rotate({}) scale({scale})" opacity="{}">"#,
                num(&item, "angleDegrees", 0.) * 0.16,
                num(&item, "opacity", 1.)
            );
            self.line(
                &text(&item["line"], "text"),
                0.,
                0.,
                size,
                1.,
                &self.primary.clone(),
                "start",
            );
            self.svg.push_str("</g>");
        }
        let _ = write!(
            self.svg,
            r#"<circle cx="{cx}" cy="{cy}" r="{}" fill="{}" opacity="0.8" filter="url(#glow)"/>"#,
            (28. + self.audio("beat", 0.) * 14.) / 2.,
            self.accent
        );
    }
    fn diorama(&mut self) {
        let time = num(self.snapshot, "animationTime", 0.);
        let energy = self.audio("particleEnergy", 0.).max(0.08);
        for index in 0..180 {
            let seed = index as f64 * 12.9898;
            let drift =
                (time * (0.16 + self.audio("mid", 0.) * 0.2) + seed).sin() * (8. + energy * 24.);
            let x = (seed * 0.71).sin().abs() * self.width + drift;
            let y = (seed * 1.17).cos().abs() * self.height + (time * 0.2 + seed).cos() * 7.;
            let depth = 0.35 + (seed * 0.33).sin().abs() * 0.65;
            let diameter = 0.7 + depth * (1.5 + self.audio("onset", 0.) * 2.4);
            let fill = match index % 3 {
                0 => &self.accent,
                1 => &self.secondary,
                _ => &self.primary,
            };
            let _ = write!(
                self.svg,
                r#"<circle cx="{x}" cy="{y}" r="{}" fill="{fill}" opacity="{}"/>"#,
                diameter / 2.,
                0.12 + energy * 0.28
            );
        }
        let cx = self.width * 0.5 + self.rail(140.);
        for (key, dx, y, scale, opacity, rotation) in [
            ("previousLine", -0.27, 0.3, 0.76, 0.2, 34f64),
            ("nextLine", 0.28, 0.7, 0.82, 0.28, -38f64),
        ] {
            let value = text(&self.snapshot["flow"][key], "text");
            if value.is_empty() {
                continue;
            }
            self.weight = 600;
            self.tracking = 0.;
            let width = 520f64.min(self.width * 0.46);
            let height = self.text_height(&value, 24., width, 2) + 44.;
            self.panel = Some(PanelTransform {
                anchor: outline::Point::default(),
                angle: rotation,
                axis: (if key == "previousLine" { 0.08 } else { 0.06 }, 1., 0.),
                perspective: 0.68,
                width,
                rotation: 0.,
                scale,
                scale_anchor: outline::Point::default(),
                position: outline::Point {
                    x: cx + self.width * dx,
                    y: self.height * y,
                },
            });
            self.panel_rect(
                -width / 2.,
                -height / 2.,
                width,
                height,
                24.,
                "#ffffff",
                0.025,
                "#ffffff",
                0.07,
                0.8,
            );
            self.paragraph(
                &value,
                0.,
                0.,
                24.,
                width,
                2,
                1.,
                opacity,
                &self.primary.clone(),
                "middle",
            );
            self.panel = None;
        }
        let size = font_size(&self.active_text(), self.width * 0.6);
        self.weight = 700;
        self.tracking = size * -0.018;
        let glyphs = items(&self.snapshot["flow"], "glyphs");
        let content_width = glyphs
            .iter()
            .map(|glyph| self.measured_width(&text(glyph, "text"), size))
            .sum::<f64>()
            + size * 0.012 * glyphs.len().saturating_sub(1) as f64;
        let glyph_height = self
            .outlined("Ag中文", size)
            .map(|line| line.ascent + line.descent)
            .unwrap_or(size * 1.2);
        let translation = text(&self.snapshot["flow"], "translation");
        let translation_size = (size * 0.18).max(15.);
        self.weight = 500;
        self.tracking = 0.;
        let translation_height =
            self.text_height(&translation, translation_size, self.width * 0.6, 2);
        let content_height = glyph_height
            + if translation.is_empty() {
                0.
            } else {
                14. + translation_height
            };
        let width = content_width.max(if translation.is_empty() {
            0.
        } else {
            self.measured_width(&translation, translation_size)
                .min(self.width * 0.6)
        }) + 68.;
        let height = content_height + 56.;
        self.panel = Some(PanelTransform {
            anchor: outline::Point::default(),
            angle: (time * 0.23).sin() * 2.4,
            axis: (0.04, 1., 0.),
            perspective: 0.72,
            width,
            rotation: 0.,
            scale: self.audio("expansion", 1.),
            scale_anchor: outline::Point::default(),
            position: outline::Point {
                x: cx,
                y: self.height * 0.5 + self.audio("beatLift", 0.) * 0.22,
            },
        });
        let shadow = 26. + self.audio("high", 0.) * 18.;
        let glow = self.audio("glow", 0.) * 0.7;
        let _ = write!(
            self.svg,
            r#"<defs><linearGradient id="dioramaBorder" x1="0" y1="0" x2="1" y2="1"><stop stop-color="{}" stop-opacity="0.5"/><stop offset="0.5" stop-color="{}" stop-opacity="0.24"/><stop offset="1" stop-color="{}" stop-opacity="0.38"/></linearGradient><filter id="dioramaShadow" x="-100%" y="-100%" width="300%" height="300%"><feDropShadow dx="0" dy="0" stdDeviation="{}" flood-color="{}" flood-opacity="{glow}"/></filter></defs><g filter="url(#dioramaShadow)">"#,
            self.accent,
            self.secondary,
            self.primary,
            shadow / 2.,
            self.accent
        );
        self.panel_rect(
            -width / 2.,
            -height / 2.,
            width,
            height,
            28.,
            "#000000",
            0.26,
            "url(#dioramaBorder)",
            1.,
            1.,
        );
        self.glyphs(0., -content_height / 2. + glyph_height / 2., size, false);
        self.translation(
            0.,
            content_height / 2. - translation_height / 2.,
            translation_size,
            "middle",
        );
        self.svg.push_str("</g>");
        self.panel = None;
    }
    fn folding(&mut self) {
        let fold = &self.snapshot["fold"];
        let p = num(fold, "transitionProgress", 0.).clamp(0., 1.);
        let p = p * p * (3. - 2. * p);
        let direction = if fold["direction"] == "left" { -1. } else { 1. };
        for (key, historical) in [("previousLines", true), ("currentLines", false)] {
            let lines = items(fold, key);
            let width = self.width * if historical { 0.58 } else { 0.68 };
            let x = self.width * 0.5 - width / 2.
                + self.rail(138.)
                + if historical {
                    direction * self.width * 0.29 * p
                } else {
                    direction * self.width * 0.035 * (1. - p)
                };
            let y = self.height * 0.5 - 8.
                + if historical {
                    -self.height * 0.07 * p
                } else {
                    self.height * 0.68 * (1. - p)
                };
            let scale = if historical {
                1. - p * 0.18
            } else {
                0.92 + p * 0.08
            };
            let opacity = if historical {
                1. - p * 0.5
            } else {
                0.16 + p * 0.84
            };
            let active = lines.iter().position(|l| l["id"] == fold["activeLineID"]);
            let mut rows = vec![];
            let mut height = 0.;
            for (index, line) in lines.iter().enumerate() {
                let current = !historical && line["id"] == fold["activeLineID"];
                self.weight = if current { 900 } else { 700 };
                self.tracking = if current { -1.2 } else { -0.6 };
                let value = text(line, "text");
                let size = (font_size(&value, width) * 0.72).clamp(28., 72.);
                let size = self.fitted_size(&value, size, width, 0.56);
                let text_height = self.text_height(&value, size, width, 1);
                let alpha = if historical {
                    0.5
                } else if current {
                    1.
                } else if active.is_some_and(|i| index < i) {
                    0.82
                } else if active.is_none() {
                    0.26
                } else {
                    0.22
                };
                let translation = if current {
                    text(line, "translation")
                } else {
                    String::new()
                };
                self.weight = 600;
                self.tracking = 0.;
                let translation_size = self.fitted_size(&translation, 16., width, 0.7);
                let translation_height = self.text_height(&translation, translation_size, width, 1);
                rows.push((
                    value,
                    current,
                    size,
                    text_height,
                    alpha,
                    translation,
                    translation_size,
                    translation_height,
                ));
                height += text_height
                    + if translation_height > 0. {
                        3. + translation_height
                    } else {
                        0.
                    }
                    + if index + 1 < lines.len() { 8. } else { 0. };
            }
            self.panel = Some(PanelTransform {
                anchor: outline::Point {
                    x: if direction < 0. { 0. } else { width },
                    y: height / 2.,
                },
                angle: if historical { direction * 7. * p } else { 0. },
                axis: (0., 1., 0.),
                perspective: 0.72,
                width,
                rotation: if historical { direction * 90. * p } else { 0. },
                scale,
                scale_anchor: outline::Point {
                    x: width / 2.,
                    y: if historical { height / 2. } else { height },
                },
                position: outline::Point {
                    x,
                    y: y - height / 2.,
                },
            });
            let _ = write!(self.svg, r#"<g opacity="{opacity}">"#);
            let mut top = 0.;
            for (
                value,
                current,
                size,
                text_height,
                alpha,
                translation,
                translation_size,
                translation_height,
            ) in rows
            {
                self.weight = if current { 900 } else { 700 };
                self.tracking = if current { -1.2 } else { -0.6 };
                self.paragraph(
                    &value,
                    0.,
                    top + text_height / 2.,
                    size,
                    width,
                    1,
                    1.,
                    alpha,
                    &if current {
                        self.accent.clone()
                    } else {
                        self.primary.clone()
                    },
                    "start",
                );
                top += text_height;
                if translation_height > 0. {
                    self.weight = 600;
                    self.tracking = 0.;
                    top += 3.;
                    self.paragraph(
                        &translation,
                        0.,
                        top + translation_height / 2.,
                        translation_size,
                        width,
                        1,
                        1.,
                        0.58,
                        &self.primary.clone(),
                        "start",
                    );
                    top += translation_height;
                }
                top += 8.;
            }
            self.svg.push_str("</g>");
            self.panel = None;
        }
        self.weight = 600;
        self.tracking = 0.;
    }
    fn draw(&mut self) {
        if self.snapshot["flow"]["activeLine"].is_null() && self.snapshot["mode"] != "folding_verse"
        {
            self.svg.push_str("</svg>");
            return;
        }
        match self.snapshot["mode"].as_str().unwrap_or("") {
            "luminous" => self.flow(),
            "mindscape" => self.depth(),
            "cloud_steps" => self.cloud(),
            "chorus_chat" => self.chorus(),
            "confession" => self.cinematic(),
            "claddagh" => self.orbit(),
            "monet_poster" => self.poster(),
            "article" => self.editorial(),
            "pendulum" => self.pendulum(),
            "diorama" => self.diorama(),
            "folding_verse" => self.folding(),
            _ => {}
        }
        self.svg.push_str("</svg>");
    }
    fn finish(mut self) -> String {
        self.draw();
        self.svg
    }
    fn finish_gpu(mut self) -> (String, Vec<gpu_scene::Primitive>) {
        self.gpu = Some(vec![]);
        self.draw();
        (self.svg, self.gpu.unwrap())
    }
}

pub struct StageLyricsPane {
    snapshot: Value,
    width: f64,
    height: f64,
    worker: Option<LatestWorker<LyricFrame, Result<LyricOutput, String>>>,
    gpu_renderer: Option<Rc<dyn Fn(&GpuLyricsFrame) -> bool>>,
    active: bool,
    generation: u64,
    scope: Option<(String, String, u64, u64, u32)>,
    submitted: Option<(Value, u64, u64, u32)>,
    image: Option<Arc<RenderImage>>,
    render_error: Option<String>,
    outgoing: Option<Value>,
    transition_started: f64,
    segments: SegmentLifecycle,
}
const SEGMENT_RESPONSE: f64 = 0.55;
const SEGMENT_DAMPING: f64 = 0.82;
const SEGMENT_SETTLE: f64 = SEGMENT_RESPONSE * 3.;
#[derive(Clone, Debug)]
struct SegmentTransition {
    segment: Value,
    order: usize,
    started: f64,
    from: f64,
    velocity: f64,
    target: f64,
}
impl SegmentTransition {
    fn sample(&self, now: f64) -> (f64, f64) {
        let elapsed = (now - self.started).max(0.);
        if elapsed >= SEGMENT_SETTLE {
            return (self.target, 0.);
        }
        let omega = std::f64::consts::TAU / SEGMENT_RESPONSE;
        let decay = SEGMENT_DAMPING * omega;
        let frequency = omega * (1. - SEGMENT_DAMPING * SEGMENT_DAMPING).sqrt();
        let a = self.from - self.target;
        let b = (self.velocity + decay * a) / frequency;
        let (s, c) = (frequency * elapsed).sin_cos();
        let exponential = (-decay * elapsed).exp();
        let displacement = a * c + b * s;
        (
            self.target + exponential * displacement,
            exponential * ((-a * s + b * c) * frequency - decay * displacement),
        )
    }
    fn retarget(&mut self, target: f64, now: f64) {
        if self.target == target {
            return;
        }
        let (from, velocity) = self.sample(now);
        self.from = from;
        self.velocity = velocity;
        self.target = target;
        self.started = now;
    }
}
#[derive(Clone, Default)]
struct SegmentLifecycle {
    scope: Option<(String, String, String)>,
    states: HashMap<String, SegmentTransition>,
    last_time: f64,
}
impl SegmentLifecycle {
    fn update(&mut self, snapshot: &Value) {
        let now = num(snapshot, "animationTime", 0.);
        let scope = (
            text(snapshot, "trackID"),
            text(&snapshot["flow"]["activeLine"], "id"),
            text(snapshot, "mode"),
        );
        let reset = self.scope.as_ref() != Some(&scope) || now < self.last_time;
        if reset {
            self.states.clear();
            self.scope = Some(scope);
        }
        self.last_time = now;
        if snapshot["mode"] != "confession" {
            self.states.clear();
            return;
        }
        let playback = num(snapshot, "playbackTime", 0.);
        let segments = items(&snapshot["tilt"], "segments");
        for state in self.states.values_mut() {
            if !segments
                .iter()
                .any(|segment| segment["id"] == state.segment["id"])
            {
                state.retarget(0., now);
            }
        }
        for (order, segment) in segments.into_iter().enumerate() {
            let id = text(&segment, "id");
            let visible = playback >= num(&segment, "revealAt", f64::MAX);
            if let Some(state) = self.states.get_mut(&id) {
                state.segment = segment;
                state.order = order;
                state.retarget(if visible { 1. } else { 0. }, now);
            } else if visible {
                self.states.insert(
                    id,
                    SegmentTransition {
                        segment,
                        order,
                        started: now,
                        from: if reset { 1. } else { 0. },
                        velocity: 0.,
                        target: 1.,
                    },
                );
            }
        }
        self.states
            .retain(|_, state| state.target != 0. || now - state.started < SEGMENT_SETTLE);
    }
    fn presentation(&self, now: f64) -> Value {
        let mut ordered: Vec<_> = self
            .states
            .iter()
            .filter(|(_, state)| state.target != 0. || now - state.started < SEGMENT_SETTLE)
            .collect();
        ordered.sort_by_key(|(_, state)| state.order);
        let mut progress = serde_json::Map::new();
        let mut segments = vec![];
        for (id, state) in ordered {
            progress.insert(id.clone(), json!(state.sample(now).0));
            segments.push(state.segment.clone());
        }
        json!({"segments":progress,"renderSegments":segments})
    }
}
#[derive(Clone, Copy, Debug, PartialEq)]
enum TransitionCurve {
    Immediate,
    Spring(f64, f64),
    EaseOut(f64),
}
#[derive(Clone, Copy, Debug)]
struct TransitionSpec {
    curve: TransitionCurve,
    scale: f64,
    move_x: f64,
    move_y: f64,
    depth: bool,
    fold: bool,
}
fn transition_key(snapshot: &Value) -> String {
    match snapshot["mode"].as_str().unwrap_or("") {
        "folding_verse" => String::new(),
        "mindscape" => items(&snapshot["depth"], "lines")
            .iter()
            .find(|line| num(line, "position", 1.) == 0.)
            .map(|line| text(line, "id"))
            .unwrap_or_default(),
        _ => text(&snapshot["flow"]["activeLine"], "id"),
    }
}
fn transition_spec(mode: &str) -> TransitionSpec {
    let mut spec = TransitionSpec {
        curve: TransitionCurve::Immediate,
        scale: 1.,
        move_x: 0.,
        move_y: 0.,
        depth: false,
        fold: false,
    };
    match mode {
        "luminous" => {
            spec.curve = TransitionCurve::Spring(0.44, 0.84);
            spec.scale = 0.94;
        }
        "mindscape" => {
            spec.curve = TransitionCurve::EaseOut(0.26);
            spec.depth = true;
        }
        "cloud_steps" => spec.move_y = 1.,
        "chorus_chat" | "article" => spec.scale = 0.96,
        "confession" => spec.move_x = -1.,
        "claddagh" => spec.scale = 0.9,
        "pendulum" => spec.curve = TransitionCurve::Spring(0.72, 0.86),
        "diorama" => spec.scale = 0.92,
        "folding_verse" => spec.fold = true,
        _ => {}
    }
    spec
}
impl TransitionSpec {
    fn progress(self, elapsed: f64) -> f64 {
        match self.curve {
            TransitionCurve::Immediate => 1.,
            TransitionCurve::Spring(response, damping) => {
                spring_progress(elapsed.max(0.), response, damping)
            }
            TransitionCurve::EaseOut(duration) => {
                let t = (elapsed / duration).clamp(0., 1.);
                1. - (1. - t).powi(3)
            }
        }
    }
    fn duration(self) -> f64 {
        match self.curve {
            TransitionCurve::Immediate => 0.,
            TransitionCurve::Spring(response, _) => response * 3.,
            TransitionCurve::EaseOut(duration) => duration,
        }
    }
}
fn spring_progress(seconds: f64, response: f64, damping: f64) -> f64 {
    let omega = std::f64::consts::TAU / response;
    let damped = omega * (1. - damping * damping).sqrt();
    1. - (-damping * omega * seconds).exp()
        * ((damped * seconds).cos() + damping * omega / damped * (damped * seconds).sin())
}
fn scene_layer(
    svg: &str,
    width: f64,
    height: f64,
    opacity: f64,
    scale: f64,
    dx: f64,
    dy: f64,
) -> String {
    let body = svg
        .split_once('>')
        .map(|(_, body)| body.trim_end_matches("</svg>"))
        .unwrap_or("");
    format!(
        r#"<g opacity="{opacity}" transform="translate({} {}) scale({scale}) translate({} {})">{body}</g>"#,
        width / 2. + dx,
        height / 2. + dy,
        -width / 2.,
        -height / 2.
    )
}
fn advance_outgoing(old: &Value, current: &Value) -> Value {
    let mut old = old.clone();
    for key in [
        "animationTime",
        "playbackTime",
        "audioMotion",
        "audioFeatures",
        "isProgramRailVisible",
        "theme",
    ] {
        old[key] = current[key].clone();
    }
    old
}
fn depth_transition(current: &Value, old: &Value, progress: f64) -> Value {
    let mut snapshot = current.clone();
    let old_lines = items(&old["depth"], "lines");
    let mut lines = items(&current["depth"], "lines");
    for line in &mut lines {
        if let Some(previous) = old_lines
            .iter()
            .find(|previous| previous["id"] == line["id"])
        {
            let from = num(previous, "position", 0.);
            let to = num(line, "position", 0.);
            line["presentationPosition"] = json!(from + (to - from) * progress);
            let from_size = if from == 0. { 38. } else { 24. };
            let to_size = if to == 0. { 38. } else { 24. };
            line["presentationSize"] = json!(from_size + (to_size - from_size) * progress);
            for key in ["opacity", "scale", "blurRadius"] {
                let a = num(previous, key, if key == "blurRadius" { 0. } else { 1. });
                let b = num(line, key, if key == "blurRadius" { 0. } else { 1. });
                line[key] = json!(a + (b - a) * progress);
            }
        } else {
            line["opacity"] = json!(num(line, "opacity", 1.) * progress);
        }
    }
    for mut line in old_lines {
        if !lines.iter().any(|current| current["id"] == line["id"]) {
            line["opacity"] = json!(num(&line, "opacity", 1.) * (1. - progress));
            lines.push(line);
        }
    }
    snapshot["depth"]["lines"] = json!(lines);
    snapshot
}
/// A single consumer, one replaceable pending request, and one completed result.
/// Same-generation completed frames remain publishable under continuous input.
struct LatestQueue<P, R> {
    pending: Option<(u64, P)>,
    completed: Option<(u64, R)>,
    generation: u64,
    closed: bool,
    stopped: bool,
    inflight: bool,
}
struct LatestWorker<P, R> {
    shared: Arc<(Mutex<LatestQueue<P, R>>, Condvar)>,
}
impl<P: Send + 'static, R: Send + 'static> LatestWorker<P, R> {
    fn new(mut process: impl FnMut(P) -> R + Send + 'static) -> Self {
        let shared = Arc::new((
            Mutex::new(LatestQueue {
                pending: None,
                completed: None,
                generation: 0,
                closed: false,
                stopped: false,
                inflight: false,
            }),
            Condvar::new(),
        ));
        let state = shared.clone();
        std::thread::Builder::new()
            .name("stage-lyrics-render".into())
            .spawn(move || {
                loop {
                    let (generation, input) = {
                        let (lock, wake) = &*state;
                        let mut queue = lock.lock().unwrap();
                        while queue.pending.is_none() && !queue.closed {
                            queue = wake.wait(queue).unwrap();
                        }
                        if queue.closed {
                            break;
                        }
                        queue.inflight = true;
                        queue.pending.take().unwrap()
                    };
                    let result = process(input);
                    let mut queue = state.0.lock().unwrap();
                    queue.inflight = false;
                    if queue.closed {
                        break;
                    }
                    if generation == queue.generation {
                        queue.completed = Some((generation, result));
                    }
                }
                state.0.lock().unwrap().stopped = true;
            })
            .expect("stage lyric worker creation failed");
        Self { shared }
    }
    fn submit(&self, generation: u64, input: P) {
        let mut queue = self.shared.0.lock().unwrap();
        if queue.closed {
            return;
        }
        if queue.generation != generation {
            queue.completed = None;
        }
        queue.generation = generation;
        queue.pending = Some((generation, input));
        self.shared.1.notify_one();
    }
    fn take(&self, generation: u64) -> Option<R> {
        let mut queue = self.shared.0.lock().unwrap();
        queue
            .completed
            .take()
            .and_then(|(epoch, result)| (epoch == generation).then_some(result))
    }
    fn close(&self) {
        let mut queue = self.shared.0.lock().unwrap();
        queue.closed = true;
        queue.pending = None;
        queue.completed = None;
        self.shared.1.notify_one();
    }
    fn stopped(&self) -> bool {
        self.shared.0.lock().unwrap().stopped
    }
    fn closed(&self) -> bool {
        self.shared.0.lock().unwrap().closed
    }
    fn needs_poll(&self) -> bool {
        let queue = self.shared.0.lock().unwrap();
        queue.inflight || queue.pending.is_some() || queue.completed.is_some()
    }
}
impl<P, R> Drop for LatestWorker<P, R> {
    fn drop(&mut self) {
        let mut queue = self.shared.0.lock().unwrap();
        queue.closed = true;
        queue.pending = None;
        queue.completed = None;
        self.shared.1.notify_one();
    }
}
struct LyricFrame {
    snapshot: Value,
    outgoing: Option<Value>,
    segments: SegmentLifecycle,
    started: f64,
    width: f64,
    height: f64,
    scale: f32,
    generation: u64,
    gpu: bool,
}
enum LyricOutput {
    Cpu(Arc<RenderImage>),
    Gpu(GpuLyricsFrame),
}
impl LyricFrame {
    fn svg(&self) -> String {
        let (w, h) = (self.width, self.height);
        let now = num(&self.snapshot, "animationTime", 0.);
        let elapsed = (now - self.started).max(0.);
        let spec = transition_spec(self.snapshot["mode"].as_str().unwrap_or(""));
        let mut snapshot = self.snapshot.clone();
        snapshot["_presentation"] = self.segments.presentation(now);
        if spec.depth && elapsed < spec.duration() {
            if let Some(old) = &self.outgoing {
                snapshot = depth_transition(&snapshot, old, spec.progress(elapsed));
            }
        }
        let svg = Scene::new(&snapshot, w, h).finish();
        if !spec.fold && !spec.depth && elapsed < spec.duration() {
            let progress = spec.progress(elapsed);
            let mut body = String::new();
            if let Some(old) = &self.outgoing {
                body.push_str(&scene_layer(
                    &Scene::new(&advance_outgoing(old, &snapshot), w, h).finish(),
                    w,
                    h,
                    (1. - progress).clamp(0., 1.),
                    1. - (1. - spec.scale) * progress,
                    spec.move_x * w * progress,
                    spec.move_y * h * progress,
                ));
            }
            body.push_str(&scene_layer(
                &svg,
                w,
                h,
                progress.clamp(0., 1.),
                spec.scale + (1. - spec.scale) * progress,
                spec.move_x * w * (1. - progress),
                spec.move_y * h * (1. - progress),
            ));
            format!(
                r#"<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">{body}</svg>"#
            )
        } else {
            svg
        }
    }
}
fn new_lyric_worker() -> LatestWorker<LyricFrame, Result<LyricOutput, String>> {
    LatestWorker::new({
        // Renderer construction, native shaping, SVG parsing and blur rasterization
        // all execute on this worker, never in GPUI's Render callback.
        let mut renderer = None;
        let mut atlases = gpu_scene::AtlasCache::default();
        move |frame: LyricFrame| {
            let renderer = renderer.get_or_insert_with(|| SvgRenderer::new(Arc::new(())));
            if frame.gpu {
                let now = num(&frame.snapshot, "animationTime", 0.);
                let spec = transition_spec(frame.snapshot["mode"].as_str().unwrap_or(""));
                let elapsed = (now - frame.started).max(0.);
                let mut snapshot = frame.snapshot.clone();
                snapshot["_presentation"] = frame.segments.presentation(now);
                if spec.depth && elapsed < spec.duration() {
                    if let Some(old) = &frame.outgoing {
                        snapshot = depth_transition(&snapshot, old, spec.progress(elapsed));
                    }
                }
                let (mut svg, mut primitives) =
                    Scene::new(&snapshot, frame.width, frame.height).finish_gpu();
                if !spec.depth && !spec.fold && elapsed < spec.duration() {
                    let p = spec.progress(elapsed);
                    let mut body = String::new();
                    if let Some(old) = &frame.outgoing {
                        let (old_svg, mut old_primitives) = Scene::new(
                            &advance_outgoing(old, &snapshot),
                            frame.width,
                            frame.height,
                        )
                        .finish_gpu();
                        let old_svg = old_svg
                            .replace("id=\"", "id=\"outgoing-")
                            .replace("url(#", "url(#outgoing-");
                        for primitive in &mut old_primitives {
                            primitive.fill = primitive.fill.replace("url(#", "url(#outgoing-");
                            primitive.stroke = primitive.stroke.replace("url(#", "url(#outgoing-");
                            primitive.filter = primitive.filter.replace("url(#", "url(#outgoing-");
                        }
                        let offset = old_primitives.len();
                        for index in (0..primitives.len()).rev() {
                            svg = svg.replace(
                                &format!("data-gpu=\"{index}\""),
                                &format!("data-gpu=\"{}\"", index + offset),
                            );
                        }
                        old_primitives.append(&mut primitives);
                        primitives = old_primitives;
                        body.push_str(&scene_layer(
                            &old_svg,
                            frame.width,
                            frame.height,
                            (1. - p).clamp(0., 1.),
                            1. - (1. - spec.scale) * p,
                            spec.move_x * frame.width * p,
                            spec.move_y * frame.height * p,
                        ));
                    }
                    body.push_str(&scene_layer(
                        &svg,
                        frame.width,
                        frame.height,
                        p.clamp(0., 1.),
                        spec.scale + (1. - spec.scale) * p,
                        spec.move_x * frame.width * (1. - p),
                        spec.move_y * frame.height * (1. - p),
                    ));
                    svg = format!(
                        r#"<svg xmlns="http://www.w3.org/2000/svg" width="{}" height="{}">{body}</svg>"#,
                        frame.width, frame.height
                    );
                }
                return atlases
                    .frame(
                        renderer,
                        &svg,
                        &primitives,
                        frame.width,
                        frame.height,
                        frame.scale,
                        frame.generation,
                    )
                    .map(LyricOutput::Gpu);
            }
            let svg = frame.svg();
            renderer
                .render_single_frame(svg.as_bytes(), frame.scale)
                .map(LyricOutput::Cpu)
                .map_err(|_| "lyrics_svg_render_failed".to_owned())
        }
    })
}
impl StageLyricsPane {
    pub fn new(_window: &mut Window, cx: &mut Context<Self>) -> Self {
        cx.on_release(|this, app| {
            if let Some(image) = this.image.take() {
                app.drop_image(image, None);
            }
            if let Some(worker) = &this.worker {
                worker.close();
            }
        })
        .detach();
        Self {
            snapshot: Value::Null,
            width: 0.,
            height: 0.,
            worker: None,
            gpu_renderer: None,
            active: true,
            generation: 0,
            scope: None,
            submitted: None,
            image: None,
            render_error: None,
            outgoing: None,
            transition_started: 0.,
            segments: SegmentLifecycle::default(),
        }
    }
    pub fn update_snapshot(
        &mut self,
        snapshot: Value,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.snapshot != snapshot {
            if transition_key(&self.snapshot) != transition_key(&snapshot)
                || self.snapshot["mode"] != snapshot["mode"]
            {
                self.outgoing = (!self.snapshot.is_null()).then(|| self.snapshot.clone());
                self.transition_started = num(&snapshot, "animationTime", 0.);
            }
            self.segments.update(&snapshot);
            self.snapshot = snapshot;
            cx.notify();
        }
    }
    pub fn set_viewport_size(&mut self, width: f32, height: f32) {
        self.width = width.max(0.) as f64;
        self.height = height.max(0.) as f64;
    }
    pub fn set_gpu_renderer(&mut self, renderer: Rc<dyn Fn(&GpuLyricsFrame) -> bool>) {
        self.gpu_renderer = Some(renderer);
        self.generation += 1;
        if let Some(worker) = &self.worker {
            worker.close();
        }
        self.submitted = None;
    }
    pub fn set_visible(&mut self, active: bool, cx: &mut Context<Self>) {
        if self.active == active {
            return;
        }
        self.active = active;
        self.generation += 1;
        if let Some(worker) = &self.worker {
            worker.close();
        }
        self.submitted = None;
        self.scope = None;
        if let Some(image) = self.image.take() {
            cx.drop_image(image, None);
        }
    }
    pub fn take_commands(&mut self) -> Vec<Value> {
        vec![]
    }
    pub fn render_error(&self) -> Option<&str> {
        self.render_error.as_deref()
    }
}
impl Render for StageLyricsPane {
    fn render(&mut self, window: &mut Window, _cx: &mut Context<Self>) -> impl IntoElement {
        let size = window.viewport_size();
        let w = if self.width > 0. {
            self.width
        } else {
            f64::from(size.width)
        };
        let h = if self.height > 0. {
            self.height
        } else {
            f64::from(size.height)
        };
        if !self.active || self.snapshot.is_null() {
            if let Some(worker) = &self.worker {
                worker.close();
            }
            self.submitted = None;
            if let Some(image) = self.image.take() {
                _ = window.drop_image(image);
            }
            return div().size_full();
        }
        if self.worker.as_ref().is_some_and(|worker| worker.closed()) {
            if self.worker.as_ref().is_some_and(|worker| !worker.stopped()) {
                window.request_animation_frame();
                return div().size_full();
            }
            self.worker = None;
        }
        let scale = window.scale_factor();
        let scope = (
            text(&self.snapshot, "trackID"),
            text(&self.snapshot, "mode"),
            w.to_bits(),
            h.to_bits(),
            scale.to_bits(),
        );
        if self.scope.as_ref() != Some(&scope) {
            self.generation += 1;
            self.scope = Some(scope);
            self.submitted = None;
            if let Some(renderer) = &self.gpu_renderer {
                let cleared = renderer(&GpuLyricsFrame {
                    width: w,
                    height: h,
                    scale,
                    generation: self.generation,
                    atlases: vec![],
                    batches: vec![],
                });
                self.render_error = if cleared {
                    None
                } else {
                    Some(format!(
                        "lyrics_gpu_clear_failed mode={} generation={}",
                        text(&self.snapshot, "mode"),
                        self.generation
                    ))
                };
            }
            if let Some(image) = self.image.take() {
                _ = window.drop_image(image);
            }
        }
        let worker = self.worker.get_or_insert_with(new_lyric_worker);
        if let Some(result) = worker.take(self.generation) {
            match result {
                Ok(LyricOutput::Gpu(frame)) => {
                    if self
                        .gpu_renderer
                        .as_ref()
                        .is_some_and(|renderer| renderer(&frame))
                    {
                        if let Some(image) = self.image.take() {
                            _ = window.drop_image(image);
                        }
                        self.render_error = None;
                    } else {
                        self.render_error = Some(format!(
                            "lyrics_gpu_submit_failed mode={} {}",
                            text(&self.snapshot, "mode"),
                            frame.diagnostics()
                        ));
                    }
                }
                Ok(LyricOutput::Cpu(image)) => {
                    if let Some(old) = self.image.replace(image) {
                        _ = window.drop_image(old);
                    }
                    self.render_error = None;
                }
                Err(error) => {
                    self.render_error = Some(format!(
                        "{error} mode={} generation={}",
                        text(&self.snapshot, "mode"),
                        self.generation
                    ));
                }
            }
        }
        let key = (
            self.snapshot.clone(),
            w.to_bits(),
            h.to_bits(),
            scale.to_bits(),
        );
        if self.submitted.as_ref() != Some(&key) {
            worker.submit(
                self.generation,
                LyricFrame {
                    snapshot: self.snapshot.clone(),
                    outgoing: self.outgoing.clone(),
                    segments: self.segments.clone(),
                    started: self.transition_started,
                    width: w,
                    height: h,
                    scale,
                    generation: self.generation,
                    gpu: self.gpu_renderer.is_some(),
                },
            );
            self.submitted = Some(key);
        }
        if worker.needs_poll() {
            window.request_animation_frame();
        }
        let mut root = div().size_full();
        if let Some(image) = self.image.clone() {
            root = root.child(img(image).w_full().h_full().object_fit(ObjectFit::Contain));
        }
        root
    }
}

pub struct StageBoundVideoPromptPane {
    snapshot: Value,
    commands: Vec<Value>,
}
impl StageBoundVideoPromptPane {
    pub fn new(_window: &mut Window, _cx: &mut Context<Self>) -> Self {
        Self {
            snapshot: Value::Null,
            commands: vec![],
        }
    }
    pub fn update_snapshot(
        &mut self,
        snapshot: Value,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.snapshot != snapshot {
            let new_id = snapshot["id"]
                .as_str()
                .filter(|s| !s.is_empty())
                .map(str::to_owned);
            let changed = self.snapshot["id"] != snapshot["id"];
            self.snapshot = snapshot;
            if changed {
                if let Some(id) = new_id {
                    cx.spawn_in(window, async move |view, cx| {
                        cx.background_executor()
                            .timer(std::time::Duration::from_secs(3))
                            .await;
                        _ = view.update_in(cx, |this, _, cx| {
                            if this.snapshot["id"].as_str() == Some(&id) {
                                this.commands
                                    .push(json!({"op":"stage.video.pending.dismiss","id":id}));
                                cx.notify();
                            }
                        });
                    })
                    .detach();
                }
            }
            cx.notify();
        }
    }
    pub fn take_commands(&mut self) -> Vec<Value> {
        std::mem::take(&mut self.commands)
    }
    pub fn is_visible(&self) -> bool {
        self.snapshot["id"].as_str().is_some_and(|s| !s.is_empty())
    }
}
impl Render for StageBoundVideoPromptPane {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if !self.is_visible() {
            return div().into_any_element();
        }
        let id = self.snapshot["id"].clone();
        let close_id = id.clone();
        div()
            .w(px(330.))
            .h(px(58.))
            .rounded(px(18.))
            .bg(rgba(0x151b25e8))
            .border_1()
            .border_color(rgba(0x00ffff3d))
            .text_color(rgba(0xffffffe6))
            .relative()
            .child(
                div()
                    .size_full()
                    .pl(px(10.))
                    .pr(px(28.))
                    .flex()
                    .items_center()
                    .gap(px(12.))
                    .child(
                        div()
                            .w(px(34.))
                            .h(px(34.))
                            .rounded_full()
                            .bg(rgba(0x00ffff21))
                            .flex()
                            .items_center()
                            .justify_center()
                            .child(Icon::new(gpui_kit::assets::IconName::Video).size(px(16.))),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .gap(px(3.))
                            .child(
                                div()
                                    .text_size(px(13.))
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .child("这首歌有专属画面"),
                            )
                            .child(
                                div()
                                    .text_size(px(11.))
                                    .text_color(rgba(0xffffff7a))
                                    .child(text(&self.snapshot, "name")),
                            ),
                    )
                    .child(div().flex_1())
                    .child(
                        Button::new("bound-video-play")
                            .icon(gpui_kit::assets::IconName::Play)
                            .tooltip("播放")
                            .accessibility_label("播放")
                            .with_size(gpui_kit::component::Size::Small)
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.commands
                                    .push(json!({"op":"stage.video.pending.play","id":id}));
                                cx.notify();
                            })),
                    ),
            )
            .child(
                div().absolute().top(px(7.)).right(px(7.)).child(
                    Button::new("bound-video-dismiss")
                        .icon(gpui_kit::assets::IconName::Close)
                        .tooltip("忽略绑定视频")
                        .accessibility_label("忽略绑定视频")
                        .with_size(gpui_kit::component::Size::XSmall)
                        .w(px(20.))
                        .h(px(20.))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.commands
                                .push(json!({"op":"stage.video.pending.dismiss","id":close_id}));
                            cx.notify();
                        })),
                ),
            )
            .into_any_element()
    }
}

/// Native shaping is confined to macOS. Other platforms retain the SVG text
/// renderer, which resolves its own system font database without Unix APIs.
mod outline {
    use std::fmt::Write;
    #[derive(Clone, Copy, Debug, Default)]
    #[repr(C)]
    pub struct Point {
        pub x: f64,
        pub y: f64,
    }
    #[derive(Clone, Debug)]
    pub enum Command {
        Move(Point),
        Line(Point),
        Quad(Point, Point),
        Cubic(Point, Point, Point),
        Close,
    }
    #[derive(Clone, Debug)]
    pub struct Line {
        pub width: f64,
        pub ascent: f64,
        pub descent: f64,
        pub commands: Vec<Command>,
    }
    pub fn project(
        point: Point,
        degrees: f64,
        axis: (f64, f64, f64),
        perspective: f64,
        width: f64,
    ) -> Point {
        let length = (axis.0 * axis.0 + axis.1 * axis.1 + axis.2 * axis.2).sqrt();
        let (x, y, z) = (axis.0 / length, axis.1 / length, axis.2 / length);
        let angle = degrees.to_radians();
        let (c, s) = (angle.cos(), angle.sin());
        let dot = x * point.x + y * point.y;
        let rx = point.x * c - z * point.y * s + x * dot * (1. - c);
        let ry = point.y * c + z * point.x * s + y * dot * (1. - c);
        let rz = (x * point.y - y * point.x) * s + z * dot * (1. - c);
        let w = 1. - perspective * rz / width;
        Point {
            x: rx / w,
            y: ry / w,
        }
    }
    pub fn projected_path(commands: &[Command], map: impl Fn(Point) -> Point) -> String {
        // Perspective turns polynomial Beziers into rational curves. Flatten
        // their original contours before projecting, so far and near edges
        // keep different vertical scales instead of horizontal compression.
        let mut output = String::new();
        let mut current = Point::default();
        let mut start = current;
        let mut emit = |kind: char, p: Point| {
            let p = map(p);
            let _ = write!(output, "{kind}{:.3},{:.3}", p.x, p.y);
        };
        for command in commands {
            match command {
                Command::Move(p) => {
                    emit('M', *p);
                    current = *p;
                    start = *p;
                }
                Command::Line(p) => {
                    emit('L', *p);
                    current = *p;
                }
                Command::Quad(a, b) => {
                    for step in 1..=24 {
                        let t = step as f64 / 24.;
                        let u = 1. - t;
                        emit(
                            'L',
                            Point {
                                x: u * u * current.x + 2. * u * t * a.x + t * t * b.x,
                                y: u * u * current.y + 2. * u * t * a.y + t * t * b.y,
                            },
                        );
                    }
                    current = *b;
                }
                Command::Cubic(a, b, c) => {
                    for step in 1..=32 {
                        let t = step as f64 / 32.;
                        let u = 1. - t;
                        emit(
                            'L',
                            Point {
                                x: u * u * u * current.x
                                    + 3. * u * u * t * a.x
                                    + 3. * u * t * t * b.x
                                    + t * t * t * c.x,
                                y: u * u * u * current.y
                                    + 3. * u * u * t * a.y
                                    + 3. * u * t * t * b.y
                                    + t * t * t * c.y,
                            },
                        );
                    }
                    current = *c;
                }
                Command::Close => {
                    emit('L', start);
                    current = start;
                }
            }
        }
        output
    }
    pub fn svg_path(commands: &[Command], map: impl Fn(Point) -> Point) -> String {
        let mut output = String::new();
        for command in commands {
            match command {
                Command::Move(p) => {
                    let p = map(*p);
                    let _ = write!(output, "M{:.3},{:.3}", p.x, p.y);
                }
                Command::Line(p) => {
                    let p = map(*p);
                    let _ = write!(output, "L{:.3},{:.3}", p.x, p.y);
                }
                Command::Quad(a, b) => {
                    let a = map(*a);
                    let b = map(*b);
                    let _ = write!(output, "Q{:.3},{:.3} {:.3},{:.3}", a.x, a.y, b.x, b.y);
                }
                Command::Cubic(a, b, c) => {
                    let a = map(*a);
                    let b = map(*b);
                    let c = map(*c);
                    let _ = write!(
                        output,
                        "C{:.3},{:.3} {:.3},{:.3} {:.3},{:.3}",
                        a.x, a.y, b.x, b.y, c.x, c.y
                    );
                }
                Command::Close => output.push('Z'),
            }
        }
        output
    }
    #[cfg(all(not(target_os = "macos"), test))]
    pub fn shape(_text: &str, _size: f64) -> Option<Line> {
        None
    }
    #[cfg(all(not(target_os = "macos"), test))]
    pub fn shape_styled(_text: &str, _size: f64, _weight: u16, _tracking: f64) -> Option<Line> {
        None
    }
    #[cfg(not(target_os = "macos"))]
    pub fn shape_font(
        _text: &str,
        _size: f64,
        _weight: u16,
        _tracking: f64,
        _italic: bool,
    ) -> Option<Line> {
        None
    }
    #[cfg(not(target_os = "macos"))]
    pub fn wrap(text: &str, size: f64, width: f64) -> Vec<String> {
        let limit = (width / (size * 0.6)).max(1.) as usize;
        let chars: Vec<char> = text.chars().collect();
        chars
            .chunks(limit)
            .map(|chunk| chunk.iter().collect())
            .collect()
    }
    #[cfg(not(target_os = "macos"))]
    pub fn wrap_styled(
        text: &str,
        size: f64,
        width: f64,
        _weight: u16,
        tracking: f64,
    ) -> Vec<String> {
        wrap(text, size, width / (1. + tracking / (size * 0.6)).max(0.1))
    }
    #[cfg(all(target_os = "macos", test))]
    pub use native::wrap;
    #[cfg(all(target_os = "macos", test))]
    pub use native::{shape, shape_styled};
    #[cfg(target_os = "macos")]
    pub use native::{shape_font, wrap_styled};
    #[cfg(target_os = "macos")]
    mod native {
        use super::{Command, Line, Point};
        use std::{ffi::c_void, ptr};
        type Ref = *const c_void;
        #[repr(C)]
        #[derive(Clone, Copy)]
        struct Range {
            location: isize,
            length: isize,
        }
        #[repr(C)]
        struct PathElement {
            kind: i32,
            points: *const Point,
        }
        #[link(name = "CoreFoundation", kind = "framework")]
        unsafe extern "C" {
            fn CFStringCreateWithBytes(
                allocator: Ref,
                bytes: *const u8,
                length: isize,
                encoding: u32,
                external: bool,
            ) -> Ref;
            fn CFDictionaryCreate(
                allocator: Ref,
                keys: *const Ref,
                values: *const Ref,
                count: isize,
                key_callbacks: Ref,
                value_callbacks: Ref,
            ) -> Ref;
            fn CFDictionaryGetValue(dictionary: Ref, key: Ref) -> Ref;
            fn CFAttributedStringCreate(allocator: Ref, string: Ref, attributes: Ref) -> Ref;
            fn CFArrayGetCount(array: Ref) -> isize;
            fn CFArrayGetValueAtIndex(array: Ref, index: isize) -> Ref;
            fn CFRelease(value: Ref);
            fn CFNumberCreate(allocator: Ref, kind: isize, value: *const c_void) -> Ref;
        }
        #[link(name = "CoreText", kind = "framework")]
        unsafe extern "C" {
            static kCTFontAttributeName: Ref;
            static kCTKernAttributeName: Ref;
            static kCTFontWeightTrait: Ref;
            static kCTFontTraitsAttribute: Ref;
            fn CTFontCopyFontDescriptor(font: Ref) -> Ref;
            fn CTFontDescriptorCreateCopyWithAttributes(descriptor: Ref, attributes: Ref) -> Ref;
            fn CTFontCreateWithFontDescriptor(descriptor: Ref, size: f64, matrix: Ref) -> Ref;
            fn CTFontCreateUIFontForLanguage(kind: u32, size: f64, language: Ref) -> Ref;
            fn CTFontCreateCopyWithSymbolicTraits(
                font: Ref,
                size: f64,
                matrix: Ref,
                traits: u32,
                mask: u32,
            ) -> Ref;
            fn CTFontGetSlantAngle(font: Ref) -> f64;
            fn CTFontCreateCopyWithAttributes(
                font: Ref,
                size: f64,
                matrix: Ref,
                descriptor: Ref,
            ) -> Ref;
            fn CTLineCreateWithAttributedString(string: Ref) -> Ref;
            fn CTLineGetGlyphRuns(line: Ref) -> Ref;
            fn CTLineGetTypographicBounds(
                line: Ref,
                ascent: *mut f64,
                descent: *mut f64,
                leading: *mut f64,
            ) -> f64;
            fn CTRunGetGlyphCount(run: Ref) -> isize;
            fn CTRunGetGlyphs(run: Ref, range: Range, glyphs: *mut u16);
            fn CTRunGetPositions(run: Ref, range: Range, positions: *mut Point);
            fn CTRunGetAttributes(run: Ref) -> Ref;
            fn CTFontCreatePathForGlyph(font: Ref, glyph: u16, matrix: Ref) -> Ref;
            fn CTTypesetterCreateWithAttributedString(string: Ref) -> Ref;
            fn CTTypesetterSuggestLineBreak(typesetter: Ref, start: isize, width: f64) -> isize;
        }
        #[link(name = "CoreGraphics", kind = "framework")]
        unsafe extern "C" {
            fn CGPathApply(
                path: Ref,
                info: *mut c_void,
                callback: unsafe extern "C" fn(*mut c_void, *const PathElement),
            );
        }
        #[link(name = "AppKit", kind = "framework")]
        unsafe extern "C" {
            static NSFontDescriptorSystemDesignRounded: Ref;
        }
        #[link(name = "objc")]
        unsafe extern "C" {
            fn sel_registerName(name: *const std::ffi::c_char) -> Ref;
            #[link_name = "objc_msgSend"]
            fn objc_message(receiver: Ref, selector: Ref, design: Ref) -> Ref;
        }
        struct Owned(Ref);
        impl Drop for Owned {
            fn drop(&mut self) {
                if !self.0.is_null() {
                    unsafe { CFRelease(self.0) }
                }
            }
        }
        unsafe fn string(text: &str) -> Owned {
            Owned(unsafe {
                CFStringCreateWithBytes(
                    ptr::null(),
                    text.as_ptr(),
                    text.len() as isize,
                    0x08000100,
                    false,
                )
            })
        }
        struct Collector {
            commands: Vec<Command>,
            origin: Point,
        }
        unsafe extern "C" fn collect(info: *mut c_void, element: *const PathElement) {
            let collector = unsafe { &mut *(info as *mut Collector) };
            let element = unsafe { &*element };
            let point = |i| {
                let p = unsafe { *element.points.add(i) };
                Point {
                    x: p.x + collector.origin.x,
                    y: p.y + collector.origin.y,
                }
            };
            let command = match element.kind {
                0 => Command::Move(point(0)),
                1 => Command::Line(point(0)),
                2 => Command::Quad(point(0), point(1)),
                3 => Command::Cubic(point(0), point(1), point(2)),
                4 => Command::Close,
                _ => return,
            };
            collector.commands.push(command);
        }
        #[cfg(test)]
        pub fn shape(text: &str, size: f64) -> Option<Line> {
            shape_styled(text, size, 600, 0.)
        }
        #[cfg(test)]
        pub fn shape_styled(text: &str, size: f64, weight: u16, tracking: f64) -> Option<Line> {
            shape_font(text, size, weight, tracking, false)
        }
        pub fn shape_font(
            text: &str,
            size: f64,
            weight: u16,
            tracking: f64,
            italic: bool,
        ) -> Option<Line> {
            if text.is_empty() || !size.is_finite() || size <= 0. {
                return None;
            }
            // Every Create result is released; run fonts and glyph arrays are
            // borrowed only while their owning CTLine remains alive.
            unsafe {
                let base = weighted_font(size, weight);
                let italic_font = if italic {
                    italic_font(&base, size)
                } else {
                    Owned(ptr::null())
                };
                let font = if italic && !italic_font.0.is_null() {
                    italic_font.0
                } else {
                    base.0
                };
                if font.is_null() {
                    return None;
                }
                let content = string(text);
                let kern = Owned(CFNumberCreate(
                    ptr::null(),
                    13,
                    &tracking as *const f64 as *const c_void,
                ));
                let keys = [kCTFontAttributeName, kCTKernAttributeName];
                let values = [font, kern.0];
                let attrs = Owned(CFDictionaryCreate(
                    ptr::null(),
                    keys.as_ptr(),
                    values.as_ptr(),
                    2,
                    ptr::null(),
                    ptr::null(),
                ));
                if attrs.0.is_null() {
                    return None;
                }
                let attributed = Owned(CFAttributedStringCreate(ptr::null(), content.0, attrs.0));
                if attributed.0.is_null() {
                    return None;
                }
                let line = Owned(CTLineCreateWithAttributedString(attributed.0));
                if line.0.is_null() {
                    return None;
                }
                let (mut ascent, mut descent, mut leading) = (0., 0., 0.);
                let width =
                    CTLineGetTypographicBounds(line.0, &mut ascent, &mut descent, &mut leading);
                let runs = CTLineGetGlyphRuns(line.0);
                let mut collector = Collector {
                    commands: vec![],
                    origin: Point::default(),
                };
                for index in 0..CFArrayGetCount(runs) {
                    let run = CFArrayGetValueAtIndex(runs, index);
                    let count = CTRunGetGlyphCount(run);
                    if count <= 0 {
                        continue;
                    }
                    let mut glyphs = vec![0; count as usize];
                    let mut positions = vec![Point::default(); count as usize];
                    let range = Range {
                        location: 0,
                        length: 0,
                    };
                    CTRunGetGlyphs(run, range, glyphs.as_mut_ptr());
                    CTRunGetPositions(run, range, positions.as_mut_ptr());
                    let run_font =
                        CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName);
                    for (glyph, position) in glyphs.into_iter().zip(positions) {
                        let path = Owned(CTFontCreatePathForGlyph(run_font, glyph, ptr::null()));
                        if !path.0.is_null() {
                            collector.origin = position;
                            CGPathApply(
                                path.0,
                                &mut collector as *mut Collector as *mut c_void,
                                collect,
                            );
                        }
                    }
                }
                Some(Line {
                    width,
                    ascent,
                    descent,
                    commands: collector.commands,
                })
            }
        }
        unsafe fn italic_font(base: &Owned, size: f64) -> Owned {
            unsafe {
                let font = Owned(CTFontCreateCopyWithSymbolicTraits(
                    base.0,
                    size,
                    ptr::null(),
                    1,
                    1,
                ));
                if !font.0.is_null() && CTFontGetSlantAngle(font.0).abs() > 0.01 {
                    return font;
                }
                // Rounded UI fonts have no italic face. Preserve their design,
                // using the system UI italic font's actual slant angle rather
                // than a hardcoded synthetic skew.
                let system = Owned(CTFontCreateUIFontForLanguage(2, size, ptr::null()));
                let italic = Owned(CTFontCreateCopyWithSymbolicTraits(
                    system.0,
                    size,
                    ptr::null(),
                    1,
                    1,
                ));
                if italic.0.is_null() {
                    return italic;
                }
                #[repr(C)]
                struct Matrix {
                    a: f64,
                    b: f64,
                    c: f64,
                    d: f64,
                    tx: f64,
                    ty: f64,
                }
                let matrix = Matrix {
                    a: 1.,
                    b: 0.,
                    c: (-CTFontGetSlantAngle(italic.0)).to_radians().tan(),
                    d: 1.,
                    tx: 0.,
                    ty: 0.,
                };
                Owned(CTFontCreateCopyWithAttributes(
                    base.0,
                    size,
                    &matrix as *const Matrix as Ref,
                    ptr::null(),
                ))
            }
        }
        unsafe fn weighted_font(size: f64, weight: u16) -> Owned {
            unsafe {
                // Obtain the UI font through the public API, then apply the
                // public rounded design and descriptor weight trait.
                let base = Owned(CTFontCreateUIFontForLanguage(2, size, ptr::null()));
                if base.0.is_null() {
                    return base;
                }
                let value: f64 = match weight {
                    0..=399 => -0.4,
                    400..=599 => 0.23,
                    600..=699 => 0.3,
                    700..=899 => 0.4,
                    _ => 0.62,
                };
                let number = Owned(CFNumberCreate(
                    ptr::null(),
                    13,
                    &value as *const f64 as *const c_void,
                ));
                let traits = Owned(CFDictionaryCreate(
                    ptr::null(),
                    [kCTFontWeightTrait].as_ptr(),
                    [number.0].as_ptr(),
                    1,
                    ptr::null(),
                    ptr::null(),
                ));
                let attrs = Owned(CFDictionaryCreate(
                    ptr::null(),
                    [kCTFontTraitsAttribute].as_ptr(),
                    [traits.0].as_ptr(),
                    1,
                    ptr::null(),
                    ptr::null(),
                ));
                let descriptor = Owned(CTFontCopyFontDescriptor(base.0));
                // CTFontDescriptor and NSFontDescriptor are toll-free bridged.
                // This +0 design result remains alive through this synchronous
                // shaping call; only Create/Copy results are CF-released.
                let rounded = objc_message(
                    descriptor.0,
                    sel_registerName(c"fontDescriptorWithDesign:".as_ptr()),
                    NSFontDescriptorSystemDesignRounded,
                );
                let weighted = Owned(CTFontDescriptorCreateCopyWithAttributes(
                    if rounded.is_null() {
                        descriptor.0
                    } else {
                        rounded
                    },
                    attrs.0,
                ));
                Owned(CTFontCreateWithFontDescriptor(
                    weighted.0,
                    size,
                    ptr::null(),
                ))
            }
        }
        #[cfg(test)]
        pub fn wrap(text: &str, size: f64, width: f64) -> Vec<String> {
            wrap_styled(text, size, width, 600, 0.)
        }
        pub fn wrap_styled(
            text: &str,
            size: f64,
            width: f64,
            weight: u16,
            tracking: f64,
        ) -> Vec<String> {
            if text.is_empty() {
                return vec![];
            }
            unsafe {
                let font = weighted_font(size, weight);
                let content = string(text);
                let kern = Owned(CFNumberCreate(
                    ptr::null(),
                    13,
                    &tracking as *const f64 as *const c_void,
                ));
                let keys = [kCTFontAttributeName, kCTKernAttributeName];
                let values = [font.0, kern.0];
                let attrs = Owned(CFDictionaryCreate(
                    ptr::null(),
                    keys.as_ptr(),
                    values.as_ptr(),
                    2,
                    ptr::null(),
                    ptr::null(),
                ));
                let attributed = Owned(CFAttributedStringCreate(ptr::null(), content.0, attrs.0));
                let typesetter = Owned(CTTypesetterCreateWithAttributedString(attributed.0));
                if typesetter.0.is_null() {
                    return vec![text.to_owned()];
                }
                let utf16: Vec<u16> = text.encode_utf16().collect();
                let mut start = 0usize;
                let mut output = vec![];
                while start < utf16.len() {
                    let length =
                        CTTypesetterSuggestLineBreak(typesetter.0, start as isize, width.max(1.))
                            .max(1) as usize;
                    let end = (start + length).min(utf16.len());
                    output.push(
                        String::from_utf16_lossy(&utf16[start..end])
                            .trim_end_matches(['\r', '\n'])
                            .to_owned(),
                    );
                    start = end;
                }
                output
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{Scene, escape};
    use serde_json::json;

    #[test]
    fn real_pane_generation_clears_gpu_before_new_song_and_exposes_submit_error() {
        use gpui_kit::{AppContext, TestAppContext};
        let mut cx = TestAppContext::single();
        cx.update(gpui_kit::init);
        let calls = std::rc::Rc::new(std::cell::RefCell::new(vec![]));
        let stored = std::rc::Rc::new(std::cell::RefCell::new(None));
        let (events, entity) = (calls.clone(), stored.clone());
        let handle = cx.add_window(move |window, cx| {
            let pane = cx.new(|cx| {
                let mut pane = super::StageLyricsPane::new(window, cx);
                pane.snapshot = json!({"trackID":"first","mode":"luminous"});
                pane.set_gpu_renderer(std::rc::Rc::new(move |frame| {
                    events
                        .borrow_mut()
                        .push((frame.generation, frame.batches.is_empty()));
                    frame.batches.is_empty()
                }));
                pane
            });
            *entity.borrow_mut() = Some(pane.clone());
            gpui_kit::base::Root::new(pane, window, cx)
        });
        cx.update_window(handle.into(), |_, window, cx| { window.refresh(); window.draw(cx).clear(cx) })
            .unwrap();
        let pane = stored.borrow().clone().unwrap();
        let previous = calls.borrow().last().unwrap().0;
        cx.update_window(handle.into(), |_, window, cx| {
            pane.update(cx, |pane, cx| {
                pane.update_snapshot(json!({"trackID":"second","mode":"mindscape"}), window, cx)
            });
            { window.refresh(); window.draw(cx).clear(cx) };
        })
        .unwrap();
        let generation = calls.borrow().last().unwrap().0;
        assert!(generation > previous);
        assert_eq!(
            calls.borrow().last().unwrap().1,
            true,
            "new scope must immediately clear old GPU text"
        );
        cx.update_window(handle.into(), |_, window, cx| {
            pane.update(cx, |pane, _| {
                let mut queue = pane.worker.as_ref().unwrap().shared.0.lock().unwrap();
                // This fixture injects a worker result without its normal wakeup.
                // The manual frame below refreshes Fast's cached entity tree.
                queue.completed = Some((
                    generation,
                    Ok(super::LyricOutput::Gpu(super::GpuLyricsFrame {
                        width: 100.,
                        height: 100.,
                        scale: 1.,
                        generation,
                        atlases: vec![],
                        batches: vec![super::GpuLyricsBatch {
                            parent: None,
                            glyphs: vec![],
                            sigma: 88.,
                            glow: [0.; 4],
                            blur_mix: 0.,
                            opacity: 1.,
                        }],
                    })),
                ));
            });
            { window.refresh(); window.draw(cx).clear(cx) };
            pane.update(cx, |pane, cx| {
                let error = pane.render_error().unwrap();
                assert!(error.contains("mode=mindscape"));
                assert!(error.contains("depth=1"));
                assert!(error.contains("glyph_limit_exceeded=false"));
                assert!(!error.contains("sigma="));
                pane.set_visible(false, cx);
            });
        })
        .unwrap();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn production_gpu_luminous_keeps_effect_tree_and_reuses_packed_atlas() {
        let phrase = "真实中文歌词保持辉光与等待逐字动画";
        let glyphs:Vec<_>=phrase.chars().enumerate().map(|(i,c)|json!({"id":format!("g{i}"),"text":c.to_string(),"phase":if i%3==0{"active"}else if i%3==1{"waiting"}else{"passed"},"progress":0.4,"rotation":3.,"xOffset":4.,"yOffset":2.})).collect();
        let mut snapshot = json!({"mode":"luminous","animationTime":10.,"flow":{"activeLine":{"id":"a","text":phrase},"previousLine":{"text":"上一句真实排版"},"nextLine":{"text":"下一句真实排版"},"translation":"Real shaped translation","glyphs":glyphs},"audioMotion":{"expansion":1.01,"beatLift":4.}});
        let renderer = super::SvgRenderer::new(std::sync::Arc::new(()));
        let mut cache = super::gpu_scene::AtlasCache::default();
        let (svg, primitives) = Scene::new(&snapshot, 1180., 760.).finish_gpu();
        let first = cache
            .frame(&renderer, &svg, &primitives, 1180., 760., 2., 1)
            .unwrap();
        assert!(!first.atlases.is_empty() && first.atlases.len() <= 16);
        assert!(first.batches.len() <= 256);
        assert!(
            first
                .batches
                .iter()
                .any(|batch| batch.sigma > 10. && batch.blur_mix == 1.)
        );
        assert!(first.batches.iter().any(|batch| batch.glow[3] > 0.));
        assert!(
            first
                .batches
                .iter()
                .any(|batch| (batch.opacity - 0.7).abs() < 1e-9)
        );
        for (index, batch) in first.batches.iter().enumerate() {
            if let Some(parent) = batch.parent {
                assert!(parent < index);
            }
            let mut depth = 1;
            let mut parent = batch.parent;
            while let Some(index) = parent {
                depth += 1;
                parent = first.batches[index].parent;
            }
            assert!(depth <= 8);
        }
        snapshot["animationTime"] = json!(10.2);
        snapshot["audioMotion"]["expansion"] = json!(1.04);
        snapshot["flow"]["glyphs"][0]["progress"] = json!(0.8);
        let (svg, primitives) = Scene::new(&snapshot, 1180., 760.).finish_gpu();
        let second = cache
            .frame(&renderer, &svg, &primitives, 1180., 760., 2., 1)
            .unwrap();
        assert_eq!(first.atlases.len(), second.atlases.len());
        for (a, b) in first.atlases.iter().zip(&second.atlases) {
            assert_eq!(a.id, b.id);
            assert!(
                std::sync::Arc::ptr_eq(&a.rgba, &b.rgba),
                "dynamic frames must not reraster or repack static glyphs"
            );
        }
        assert_ne!(
            first
                .batches
                .iter()
                .flat_map(|b| b.glyphs.iter())
                .next()
                .unwrap()
                .matrix,
            second
                .batches
                .iter()
                .flat_map(|b| b.glyphs.iter())
                .next()
                .unwrap()
                .matrix
        );
        if let Ok(path) = std::env::var("GMGN_LYRICS_FRAME_EXPORT") {
            use base64::Engine;
            let atlases:Vec<_>=first.atlases.iter().map(|a|json!({"id":a.id,"width":a.width,"height":a.height,"rgba":base64::engine::general_purpose::STANDARD.encode(a.rgba.as_slice())})).collect();
            let batches:Vec<_>=first.batches.iter().map(|b|json!({"parent":b.parent,"opacity":b.opacity,"sigma":b.sigma,"blur_mix":b.blur_mix,"glow":b.glow,"glyphs":b.glyphs.iter().map(|g|json!({"atlas_id":g.atlas_id,"width":g.width,"height":g.height,"matrix":g.matrix,"uv":g.uv,"rgba":g.rgba})).collect::<Vec<_>>()})).collect();
            std::fs::write(path,serde_json::to_vec(&json!({"width":first.width,"height":first.height,"scale":first.scale,"atlases":atlases,"batches":batches})).unwrap()).unwrap();
        }
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn production_gpu_mindscape_and_confession_preserve_actual_projection() {
        for snapshot in [
            json!({"mode":"mindscape","flow":{"activeLine":{"id":"a","text":"真实深度"}},"depth":{"lines":[{"id":"a","text":"真实深度","position":0,"opacity":1.,"scale":1.},{"id":"b","text":"背景投影","position":1,"opacity":0.5,"scale":0.9,"blurRadius":2.}]}}),
            json!({"mode":"confession","flow":{"activeLine":{"id":"a","text":"真实倾斜"}},"playbackTime":5.,"tilt":{"segments":[{"id":"s","text":"真实倾斜","revealAt":0.,"isTilted":true,"xOffset":0.1,"yOffset":0.1}]}}),
        ] {
            let (svg, primitives) = Scene::new(&snapshot, 1000., 700.).finish_gpu();
            let renderer = super::SvgRenderer::new(std::sync::Arc::new(()));
            let frame = super::gpu_scene::AtlasCache::default()
                .frame(&renderer, &svg, &primitives, 1000., 700., 1., 1)
                .unwrap();
            assert!(
                frame
                    .batches
                    .iter()
                    .flat_map(|b| b.glyphs.iter())
                    .any(|g| g.matrix[6].abs() + g.matrix[7].abs() > 1e-6)
            );
            assert!(frame.batches.iter().any(|b| b.glow[3] > 0.));
        }
    }

    #[test]
    fn gpu_homography_preserves_real_panel_projection_inside_quad() {
        let panel = super::confession_panel(1000., 700.);
        let matrix = super::gpu_scene::homography(500., 80., |p| panel.map(p));
        for (x, y) in [(0., 0.), (500., 80.), (125., 20.), (250., 60.), (490., 1.)] {
            let denominator = matrix[6] * x + matrix[7] * y + matrix[8];
            let actual = super::outline::Point {
                x: (matrix[0] * x + matrix[1] * y + matrix[2]) / denominator,
                y: (matrix[3] * x + matrix[4] * y + matrix[5]) / denominator,
            };
            let expected = panel.map(super::outline::Point { x, y });
            assert!((actual.x - expected.x).abs() < 1e-8);
            assert!((actual.y - expected.y).abs() < 1e-8);
        }
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn long_context_and_luminous_transition_fit_native_gpu_budgets() {
        let text = "在很长的歌词里保留真正的文字轮廓与完整光影".repeat(5);
        let worker = super::new_lyric_worker();
        for (i, mode) in ["monet_poster", "diorama", "luminous"].iter().enumerate() {
            let glyphs: Vec<_> = "真正的逐字辉光过渡".chars().enumerate().map(|(i,c)|
                json!({"id":format!("g{i}"),"text":c.to_string(),"phase":"active","progress":0.5})).collect();
            let snapshot = json!({"mode":mode,"animationTime":10.2,"playbackTime":5.,
                "flow":{"activeLine":{"id":"new","text":"真正的逐字辉光过渡"},"previousLine":{"text":text},"nextLine":{"text":text},"translation":text,"glyphs":glyphs},
                "monet":{"entries":[{"line":{"text":text,"translation":text},"offset":-1,"status":"passed"},{"line":{"text":text},"offset":0,"status":"active"},{"line":{"text":text},"offset":1,"status":"upcoming"}]}});
            let mut old = snapshot.clone();
            old["flow"]["activeLine"]["id"] = json!("old");
            let generation = i as u64 + 1;
            worker.submit(
                generation,
                super::LyricFrame {
                    snapshot,
                    outgoing: Some(old),
                    segments: super::SegmentLifecycle::default(),
                    started: 10.,
                    width: 1180.,
                    height: 760.,
                    scale: 2.,
                    generation,
                    gpu: true,
                },
            );
            wait_until(|| worker.shared.0.lock().unwrap().completed.is_some());
            let super::LyricOutput::Gpu(frame) = worker
                .take(generation)
                .unwrap()
                .unwrap_or_else(|error| panic!("{mode}: {error}"))
            else {
                panic!("GPU required")
            };
            assert!(!frame.atlases.is_empty(), "{mode}: missing text");
            assert!(
                frame.atlases.len() <= 16 && frame.batches.len() <= 256,
                "{mode}: page/batch budget"
            );
            assert!(frame.batches.iter().map(|b| b.glyphs.len()).sum::<usize>() <= 4096);
            for batch in &frame.batches {
                let mut depth = 1;
                let mut parent = batch.parent;
                while let Some(index) = parent {
                    depth += 1;
                    parent = frame.batches[index].parent;
                }
                assert!(depth <= 8, "{mode}: depth={depth}");
                for glyph in &batch.glyphs {
                    assert!(frame.atlases.iter().any(|a| a.id == glyph.atlas_id));
                }
            }
        }
        worker.close();
        wait_until(|| worker.stopped());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn production_lyric_worker_shapes_and_rasterizes_real_scene() {
        let worker = super::new_lyric_worker();
        worker.submit(
            1,
            super::LyricFrame {
                snapshot: json!({"mode":"luminous","animationTime":1.,"flow":{
                    "activeLine":{"id":"actual","text":"真实歌词"},
                    "glyphs":[{"id":"g1","text":"真","phase":"active","progress":0.5}]
                }}),
                outgoing: None,
                segments: super::SegmentLifecycle::default(),
                started: 0.,
                width: 160.,
                height: 100.,
                scale: 1.,
                generation: 1,
                gpu: false,
            },
        );
        wait_until(|| worker.shared.0.lock().unwrap().completed.is_some());
        let output = worker
            .take(1)
            .expect("completed frame")
            .expect("native SVG frame");
        let super::LyricOutput::Cpu(image) = output else {
            panic!("expected CPU frame");
        };
        assert_eq!(image.frame_count(), 1);
        worker.close();
        wait_until(|| worker.stopped());
    }

    fn wait_until(mut ready: impl FnMut() -> bool) {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
        while !ready() {
            assert!(
                std::time::Instant::now() < deadline,
                "worker did not reach boundary"
            );
            std::thread::yield_now();
        }
    }

    #[test]
    fn lyric_worker_bounds_pending_and_publishes_under_continuous_input() {
        let (entered_tx, entered) = std::sync::mpsc::channel();
        let (release, released) = std::sync::mpsc::channel();
        let caller = std::thread::current().id();
        let worker = super::LatestWorker::new(move |input: u32| {
            assert_ne!(std::thread::current().id(), caller);
            entered_tx.send(input).unwrap();
            released.recv().unwrap();
            input
        });
        worker.submit(1, 0);
        assert_eq!(
            entered
                .recv_timeout(std::time::Duration::from_secs(3))
                .unwrap(),
            0
        );
        for frame in 1..10_000 {
            worker.submit(1, frame);
        }
        assert_eq!(worker.shared.0.lock().unwrap().pending, Some((1, 9999)));
        release.send(()).unwrap();
        assert_eq!(
            entered
                .recv_timeout(std::time::Duration::from_secs(3))
                .unwrap(),
            9999
        );
        assert_eq!(
            worker.take(1),
            Some(0),
            "newer input must not starve completed same-scope frames"
        );
        release.send(()).unwrap();
        wait_until(|| worker.shared.0.lock().unwrap().completed.is_some());
        assert_eq!(worker.take(1), Some(9999));
    }

    #[test]
    fn lyric_worker_rejects_old_generation_and_close_drops_pending() {
        let (entered_tx, entered) = std::sync::mpsc::channel();
        let (release, released) = std::sync::mpsc::channel();
        let worker = super::LatestWorker::new(move |input: u32| {
            entered_tx.send(input).unwrap();
            released.recv().unwrap();
            input
        });
        worker.submit(1, 10);
        assert_eq!(
            entered
                .recv_timeout(std::time::Duration::from_secs(3))
                .unwrap(),
            10
        );
        worker.submit(2, 20);
        release.send(()).unwrap();
        assert_eq!(
            entered
                .recv_timeout(std::time::Duration::from_secs(3))
                .unwrap(),
            20
        );
        assert_eq!(worker.take(2), None);
        worker.submit(2, 30);
        worker.close();
        assert!(worker.shared.0.lock().unwrap().pending.is_none());
        release.send(()).unwrap();
        wait_until(|| worker.stopped());
        assert_eq!(worker.take(2), None);
        assert!(
            entered.try_recv().is_err(),
            "closing must not execute queued frames"
        );
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn luminous_context_keeps_real_tracking_leading_trailing_and_blur() {
        let snapshot = json!({"mode":"luminous","flow":{"activeLine":{"text":"main"},"previousLine":{"text":"previous"},"nextLine":{"text":"next"},"translation":"translation","glyphs":[{"text":"main","phase":"passed"}]}});
        let mut scene = Scene::new(&snapshot, 1000., 700.);
        scene.flow();
        assert!(
            scene
                .outlines
                .keys()
                .any(|key| key.0 == "previous" && key.2 == 600 && key.3 == 0.5f64.to_bits())
        );
        assert!(
            scene
                .outlines
                .keys()
                .any(|key| key.0 == "next" && key.2 == 600 && key.3 == 0.5f64.to_bits())
        );
        assert!(scene.svg.contains("filter=\"url(#flowPreviousBlur)\""));
        assert!(scene.svg.contains("stdDeviation=\"1.5\""));
        assert!(scene.svg.contains("filter=\"url(#flowNextBlur)\""));
        assert!(scene.svg.contains("stdDeviation=\"0.9\""));
        let x = |label: &str| {
            let marker = format!("aria-label=\"{label}\" d=\"M");
            let rest = scene.svg.split_once(&marker).unwrap().1;
            rest.split_once(',').unwrap().0.parse::<f64>().unwrap()
        };
        assert!(x("previous") < 200.);
        assert!(x("next") > 700.);
        assert_eq!((scene.weight, scene.tracking), (600, 0.));
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn mindscape_wraps_before_scaling_and_keeps_context_gradient_blur_and_shadows() {
        let snapshot = json!({"mode":"mindscape","flow":{"activeLine":{"text":"active"}},"depth":{"lines":[{"id":"current","text":"当前文字".repeat(12),"position":0,"scale":0.9,"opacity":1.,"blurRadius":0.},{"id":"context","text":"上下文字".repeat(10),"position":1,"scale":0.8,"opacity":0.3,"blurRadius":2.}]}});
        let mut scene = Scene::new(&snapshot, 1000., 700.);
        scene.depth();
        assert_eq!(scene.svg.matches("fill=\"url(#lyricGradient)\"").count(), 2);
        assert_eq!(
            scene
                .svg
                .matches("fill=\"url(#depthContextGradient)\"")
                .count(),
            2
        );
        assert!(scene.svg.contains("stop-opacity=\"0.76\""));
        assert!(scene.svg.contains("stop-opacity=\"0.5\""));
        assert!(scene.svg.contains("stdDeviation=\"18\""));
        assert!(scene.svg.contains("stdDeviation=\"7\""));
        assert!(scene.svg.contains("stdDeviation=\"4\""));
        assert!(scene.svg.contains("stdDeviation=\"2\""));
        assert!(
            scene
                .outlines
                .keys()
                .any(|key| key.1 == 38f64.to_bits() && key.2 == 700 && key.3 == 0.4f64.to_bits())
        );
        assert!(
            scene
                .outlines
                .keys()
                .any(|key| key.1 == 24f64.to_bits() && key.2 == 600 && key.3 == 0.1f64.to_bits())
        );
        assert!(
            scene
                .svg
                .find("fill=\"url(#depthContextGradient)\"")
                .unwrap()
                < scene.svg.find("fill=\"url(#lyricGradient)\"").unwrap()
        );
        assert!(scene.panel.is_none());
        assert!(scene.local.is_none());
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn monet_context_uses_original_status_weight_color_and_row_blur() {
        let snapshot = json!({"mode":"monet_poster","theme":{"primary":"#112233","secondary":"#778899"},"flow":{"activeLine":{"text":"active"},"glyphs":[{"text":"active","phase":"active"}]},"monet":{"entries":[{"line":{"text":"passed"},"offset":-2,"status":"passed"},{"line":{"text":"active"},"offset":0,"status":"active"},{"line":{"text":"upcoming"},"offset":2,"status":"upcoming"}]}});
        let mut scene = Scene::new(&snapshot, 1000., 700.);
        scene.poster();
        assert!(
            scene
                .outlines
                .keys()
                .any(|key| key.0 == "passed" && key.2 == 500 && key.3 == 0f64.to_bits())
        );
        assert!(
            scene
                .outlines
                .keys()
                .any(|key| key.0 == "upcoming" && key.2 == 600 && key.3 == 0f64.to_bits())
        );
        assert!(scene.svg.contains("fill=\"#778899\" opacity=\"0.185\""));
        assert!(scene.svg.contains("fill=\"#112233\" opacity=\"0.27\""));
        assert!(scene.svg.contains("stdDeviation=\"0.68\""));
        assert!(scene.svg.contains("stdDeviation=\"22\""));
        scene.weight = 500;
        scene.tracking = 0.;
        let layout = scene.paragraph_layout(&"多行文字".repeat(30), 28., 508.4, 2, 0.72);
        assert_eq!(layout.lines.len(), 2);
        assert!(layout.size >= 28. * 0.72);
        assert!(layout.size < 28.);
    }
    fn segment_snapshot(animation: f64, playback: f64) -> serde_json::Value {
        json!({"trackID":"track","mode":"confession","animationTime":animation,"playbackTime":playback,"flow":{"activeLine":{"id":"line","text":"test"}},"tilt":{"segments":[{"id":"first","text":"first","revealAt":0.,"isTilted":false},{"id":"second","text":"second","revealAt":2.,"isTilted":true},{"id":"third","text":"third","revealAt":4.,"isTilted":false}]}})
    }
    #[test]
    fn seek_backward_keeps_exiting_segments_until_original_spring_settles() {
        let mut lifecycle = super::SegmentLifecycle::default();
        lifecycle.update(&segment_snapshot(10., 5.));
        let mut reversed = segment_snapshot(11., 1.);
        lifecycle.update(&reversed);
        let start = lifecycle.presentation(11.);
        assert_eq!(start["renderSegments"].as_array().unwrap().len(), 3);
        assert_eq!(start["segments"]["second"], 1.);
        let half = lifecycle.presentation(11.1);
        let progress = half["segments"]["second"].as_f64().unwrap();
        assert!(progress > 0. && progress < 1.);
        // Original transition offsets are tilted +34 and normal -22; their
        // existing renderer now receives exit progress instead of deletion.
        reversed["_presentation"] = half;
        let svg = Scene::new(&reversed, 1000., 700.).finish();
        assert!(svg.contains("aria-label=\"second\""));
        assert!(svg.contains("aria-label=\"third\""));
        let end = 11. + super::SEGMENT_SETTLE;
        let settled = lifecycle.presentation(end);
        assert_eq!(settled["renderSegments"].as_array().unwrap().len(), 1);
        reversed["_presentation"] = settled;
        let svg = Scene::new(&reversed, 1000., 700.).finish();
        assert!(!svg.contains("aria-label=\"second\""));
        lifecycle.update(&segment_snapshot(end, 1.));
        assert_eq!(lifecycle.states.len(), 1);
    }
    #[test]
    fn segment_reentry_preserves_position_and_velocity_without_duplicate_rows() {
        let mut lifecycle = super::SegmentLifecycle::default();
        lifecycle.update(&segment_snapshot(10., 5.));
        lifecycle.update(&segment_snapshot(11., 1.));
        let before = lifecycle.states["second"].sample(11.1);
        lifecycle.update(&segment_snapshot(11.1, 3.));
        let after = lifecycle.states["second"].sample(11.1);
        assert!((before.0 - after.0).abs() < 1e-12);
        assert!((before.1 - after.1).abs() < 1e-12);
        assert_eq!(lifecycle.states["second"].target, 1.);
        assert_eq!(
            lifecycle.presentation(11.1)["renderSegments"]
                .as_array()
                .unwrap()
                .iter()
                .filter(|segment| segment["id"] == "second")
                .count(),
            1
        );
    }
    #[test]
    fn exit_uses_animation_time_even_when_playback_is_paused() {
        let mut lifecycle = super::SegmentLifecycle::default();
        lifecycle.update(&segment_snapshot(10., 5.));
        lifecycle.update(&segment_snapshot(11., 1.));
        let first = lifecycle.presentation(11.)["segments"]["second"]
            .as_f64()
            .unwrap();
        lifecycle.update(&segment_snapshot(11.2, 1.));
        let next = lifecycle.presentation(11.2)["segments"]["second"]
            .as_f64()
            .unwrap();
        assert!(next < first);
    }
    #[test]
    fn segment_scope_changes_drop_old_track_line_and_mode_lifecycles() {
        for key in ["trackID", "line", "mode"] {
            let mut lifecycle = super::SegmentLifecycle::default();
            lifecycle.update(&segment_snapshot(10., 5.));
            lifecycle.update(&segment_snapshot(11., 1.));
            let mut changed = segment_snapshot(11.1, 1.);
            if key == "line" {
                changed["flow"]["activeLine"]["id"] = json!("new-line");
            } else {
                changed[key] = json!(if key == "mode" {
                    "luminous"
                } else {
                    "new-track"
                });
            }
            lifecycle.update(&changed);
            assert!(!lifecycle.states.contains_key("second"));
            assert!(!lifecycle.states.contains_key("third"));
        }
    }
    #[test]
    fn missing_model_segment_can_exit_using_only_its_prior_real_snapshot() {
        let mut lifecycle = super::SegmentLifecycle::default();
        lifecycle.update(&segment_snapshot(10., 5.));
        let mut changed = segment_snapshot(11., 5.);
        changed["tilt"]["segments"]
            .as_array_mut()
            .unwrap()
            .truncate(1);
        lifecycle.update(&changed);
        assert_eq!(
            lifecycle.presentation(11.)["renderSegments"][1]["id"],
            "second"
        );
        assert_eq!(
            lifecycle.presentation(11. + super::SEGMENT_SETTLE)["renderSegments"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
    }
    #[test]
    fn confession_uses_original_leading_frame_projection() {
        let panel = super::confession_panel(1000., 700.);
        assert_eq!(
            (panel.angle, panel.perspective, panel.axis, panel.width),
            (-4., 0.76, (0.02, 1., 0.), 860.)
        );
        assert_eq!((panel.anchor.x, panel.anchor.y), (0., 350.));
        let anchor = panel.map(panel.anchor);
        assert_eq!((anchor.x, anchor.y), (0., 350.));
        assert_ne!(
            panel.map(super::outline::Point { x: 700., y: 200. }).y,
            200.
        );
    }
    #[test]
    fn confession_segments_keep_native_styles_and_reset_after_drawing() {
        let snapshot = json!({"mode":"confession","playbackTime":2.,"flow":{"activeLine":{"id":"line","text":"正常倾斜"},"translation":"真实翻译"},"tilt":{"segments":[{"id":"normal","text":"正常","isTilted":false,"revealAt":0.,"xOffset":0.},{"id":"tilted","text":"倾斜","isTilted":true,"revealAt":1.,"xOffset":0.1},{"id":"future","text":"未入场","revealAt":3.}]},"audioMotion":{"beatLift":5.,"mid":0.4}});
        let mut scene = Scene::new(&snapshot, 1000., 700.);
        scene.cinematic();
        assert!(scene.svg.contains("url(#confessionStraight)"));
        assert!(scene.svg.contains("url(#tiltGradient)"));
        assert!(scene.svg.contains("url(#confessionPlainShadow)"));
        assert!(scene.svg.contains("url(#confessionTiltShadow)"));
        assert!(scene.svg.contains("aria-label=\"正常\""));
        assert!(scene.svg.contains("aria-label=\"倾斜\""));
        assert!(!scene.svg.contains("未入场"));
        assert_eq!(
            (scene.weight, scene.tracking, scene.italic),
            (600, 0., false)
        );
        assert!(scene.local.is_none());
        assert!(scene.panel.is_none());
    }
    #[test]
    fn glyph_phase_filters_keep_original_waiting_glow_and_passed_opacity() {
        let snapshot = json!({"mode":"luminous","flow":{"activeLine":{"id":"a","text":"等待活动经过"},"glyphs":[{"id":"wait","text":"等","phase":"waiting"},{"id":"active","text":"活","phase":"active","progress":0.5},{"id":"passed","text":"过","phase":"passed"}]}});
        let svg = Scene::new(&snapshot, 1000., 700.).finish();
        assert!(svg.contains("stdDeviation=\"0.55\""));
        assert!(svg.contains("stdDeviation=\"18\""));
        assert!(svg.contains("filter=\"url(#glyphWaiting)\""));
        assert!(svg.contains("filter=\"url(#glyphGlow1)\""));
        assert!(svg.contains("opacity=\"0.88\""));
        assert!(svg.contains("opacity=\"0.96\""));
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn native_italic_changes_the_actual_glyph_contours() {
        for text in ["Confession", "中文倾斜"] {
            let straight = super::outline::shape_font(text, 32., 300, 0., false).unwrap();
            let italic = super::outline::shape_font(text, 32., 300, 0., true).unwrap();
            assert_ne!(
                super::outline::svg_path(&straight.commands, |p| p),
                super::outline::svg_path(&italic.commands, |p| p)
            );
        }
    }
    #[test]
    fn translation_styles_preserve_original_mode_parameters() {
        let luminous = super::translation_style("luminous", 1000.);
        assert_eq!(
            (
                luminous.weight,
                luminous.tracking,
                luminous.opacity,
                luminous.width
            ),
            (500, 0.7, 0.66, 720.)
        );
        let cloud = super::translation_style("cloud_steps", 800.);
        assert_eq!(
            (cloud.tracking, cloud.opacity, cloud.width),
            (0.8, 0.48, 400.)
        );
        for (mode, opacity) in [
            ("confession", 0.56),
            ("claddagh", 0.58),
            ("monet_poster", 0.54),
            ("article", 0.58),
            ("chorus_chat", 0.56),
            ("diorama", 0.54),
        ] {
            let style = super::translation_style(mode, 1000.);
            assert_eq!((style.weight, style.opacity), (500, opacity));
        }
        let fold = super::translation_style("folding_verse", 1000.);
        assert_eq!((fold.weight, fold.max_lines, fold.min_scale), (600, 1, 0.7));
    }
    #[test]
    fn fold_group_anchors_stay_fixed_through_rotation_and_bottom_scale() {
        use super::outline::Point;
        for x in [0., 400.] {
            let transform = super::PanelTransform {
                anchor: Point { x, y: 150. },
                angle: 7.,
                axis: (0., 1., 0.),
                perspective: 0.72,
                width: 400.,
                rotation: 90.,
                scale: 1.,
                scale_anchor: Point::default(),
                position: Point::default(),
            };
            let projected = transform.map(Point { x, y: 150. });
            assert_eq!((projected.x, projected.y), (x, 150.));
        }
        let bottom = Point { x: 200., y: 300. };
        let transform = super::PanelTransform {
            anchor: Point::default(),
            angle: 0.,
            axis: (0., 1., 0.),
            perspective: 0.72,
            width: 400.,
            rotation: 0.,
            scale: 0.92,
            scale_anchor: bottom,
            position: Point::default(),
        };
        let projected = transform.map(bottom);
        assert_eq!((projected.x, projected.y), (bottom.x, bottom.y));
        assert_eq!(transform.map(Point::default()).y, 24.);
    }
    #[test]
    fn diorama_projects_background_and_text_as_one_panel() {
        let snapshot = json!({"mode":"diorama","animationTime":10.,"flow":{"activeLine":{"id":"active","text":"当前"},"previousLine":{"id":"prev","text":"上一句"},"nextLine":{"id":"next","text":"下一句"},"translation":"translation","glyphs":[{"id":"g1","text":"当","phase":"active"},{"id":"g2","text":"前","phase":"waiting"}]},"audioMotion":{"expansion":1.03,"beatLift":5.}});
        let svg = Scene::new(&snapshot, 1000., 700.).finish();
        assert!(svg.contains("dioramaBorder"));
        assert!(svg.contains("dioramaShadow"));
        assert!(svg.contains("stroke-opacity=\"0.07\" stroke-width=\"0.8\""));
        assert!(!svg.contains("<rect"));
        assert!(svg.contains("aria-label=\"上一句\""));
        assert!(svg.contains("aria-label=\"translation\""));
    }
    #[test]
    fn transition_specs_and_triggers_follow_each_original_frame() {
        use super::{TransitionCurve, transition_spec};
        assert_eq!(transition_spec("luminous").scale, 0.94);
        assert_eq!(transition_spec("claddagh").scale, 0.9);
        assert_eq!(transition_spec("diorama").scale, 0.92);
        for mode in ["article", "chorus_chat"] {
            assert_eq!(transition_spec(mode).scale, 0.96);
        }
        assert_eq!(transition_spec("cloud_steps").move_y, 1.);
        assert_eq!(transition_spec("confession").move_x, -1.);
        assert_eq!(
            transition_spec("confession").curve,
            TransitionCurve::Immediate
        );
        assert_eq!(
            transition_spec("pendulum").curve,
            TransitionCurve::Spring(0.72, 0.86)
        );
        assert!(transition_spec("folding_verse").fold);
        assert_eq!(
            transition_spec("mindscape").curve,
            TransitionCurve::EaseOut(0.26)
        );
        let depth = json!({"mode":"mindscape","flow":{"activeLine":{"id":"different"}},"depth":{"lines":[{"id":"actual","position":0}]}});
        assert_eq!(super::transition_key(&depth), "actual");
        assert_eq!(
            super::transition_key(
                &json!({"mode":"folding_verse","flow":{"activeLine":{"id":"irrelevant"}}})
            ),
            ""
        );
    }
    #[test]
    fn outgoing_scene_keeps_original_current_store_time_and_audio() {
        let old = json!({"animationTime":10.,"playbackTime":4.,"flow":{"activeLine":{"id":"old"}},"audioMotion":{"beat":0.1}});
        let current = json!({"animationTime":11.,"playbackTime":5.,"flow":{"activeLine":{"id":"new"}},"audioMotion":{"beat":0.8}});
        let outgoing = super::advance_outgoing(&old, &current);
        assert_eq!(outgoing["animationTime"], 11.);
        assert_eq!(outgoing["playbackTime"], 5.);
        assert_eq!(outgoing["audioMotion"]["beat"], 0.8);
        assert_eq!(outgoing["flow"]["activeLine"]["id"], "old");
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn native_wrap_uses_the_same_weight_and_tracking_as_shaped_text() {
        let text = "LLLL LLLL";
        let regular = super::outline::shape_styled(text, 32., 500, 0.).unwrap();
        let tracked = super::outline::shape_styled(text, 32., 500, -2.).unwrap();
        let width = (regular.width + tracked.width) / 2.;
        assert!(
            super::outline::wrap_styled(text, 32., width, 500, 0.).len()
                > super::outline::wrap_styled(text, 32., width, 500, -2.).len()
        );
    }
    #[test]
    fn spring_enters_from_zero_and_settles_at_one() {
        assert_eq!(super::spring_progress(0., 0.44, 0.84), 0.);
        assert!(super::spring_progress(0.1, 0.44, 0.84) > 0.);
        assert!((super::spring_progress(1.5, 0.44, 0.84) - 1.).abs() < 0.0001);
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn native_tracking_changes_real_shaped_advances() {
        let ordinary = super::outline::shape_styled("Lyrics", 32., 700, 0.).unwrap();
        let tracked = super::outline::shape_styled("Lyrics", 32., 700, -0.576).unwrap();
        assert!(tracked.width < ordinary.width);
        let light = super::outline::shape_styled("Lyrics", 32., 300, 0.).unwrap();
        assert_ne!(
            super::outline::svg_path(&light.commands, |p| p),
            super::outline::svg_path(&ordinary.commands, |p| p)
        );
    }
    #[test]
    fn perspective_projects_near_and_far_edges_at_different_heights() {
        let near = super::outline::project(
            super::outline::Point { x: -80., y: 20. },
            34.,
            (0., 1., 0.),
            0.7,
            200.,
        );
        let far = super::outline::project(
            super::outline::Point { x: 80., y: 20. },
            34.,
            (0., 1., 0.),
            0.7,
            200.,
        );
        assert!((near.y - far.y).abs() > 1.);
        let neutral = super::outline::project(
            super::outline::Point { x: 80., y: 20. },
            0.,
            (0., 1., 0.),
            0.7,
            200.,
        );
        assert_eq!((neutral.x, neutral.y), (80., 20.));
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn native_shaping_keeps_variable_advances_and_utf16_line_boundaries() {
        let narrow = super::outline::shape("iiii", 32.).unwrap();
        let wide = super::outline::shape("WWWW", 32.).unwrap();
        assert!(wide.width > narrow.width * 2.);
        assert!(!wide.commands.is_empty());
        let text = "中文😀歌词 automatic layout";
        let lines = super::outline::wrap(text, 24., 100.);
        assert!(lines.len() > 1);
        assert_eq!(lines.concat(), text);
        assert!(!lines.iter().any(|line| line.contains('\u{fffd}')));
    }
    #[test]
    fn escapes_all_lyric_xml_content() {
        assert_eq!(escape("<&\"'>"), "&lt;&amp;&quot;&apos;&gt;");
    }
    #[test]
    fn modes_keep_distinct_real_scene_compositions() {
        let base = json!({"flow":{"activeLine":{"text":"真实歌词"},"glyphs":[{"id":"g","text":"真","phase":"active"}]},"partita":{"placements":[{"glyphID":"g","x":0.1,"y":0.2,"scale":1.}]},"depth":{"lines":[{"text":"真实歌词","position":0}]},"tilt":{"segments":[{"text":"真实歌词","revealAt":0}]},"monet":{"entries":[{"line":{"text":"真实歌词"},"offset":0}]},"wheel":{"items":[{"line":{"text":"真实歌词"},"isActive":true}]},"fold":{"currentLines":[{"text":"真实歌词"}],"transitionProgress":1.}});
        let mut unique = std::collections::HashSet::new();
        for mode in [
            "luminous",
            "mindscape",
            "cloud_steps",
            "chorus_chat",
            "confession",
            "claddagh",
            "monet_poster",
            "article",
            "pendulum",
            "diorama",
            "folding_verse",
        ] {
            let mut snapshot = base.clone();
            snapshot["mode"] = json!(mode);
            let svg = Scene::new(&snapshot, 1280., 720.).finish();
            assert!(svg.contains("真实歌词") || svg.contains("真"));
            unique.insert(svg);
            #[cfg(target_os = "macos")]
            {
                let (svg, primitives) = Scene::new(&snapshot, 1280., 720.).finish_gpu();
                let renderer = super::SvgRenderer::new(std::sync::Arc::new(()));
                let frame = super::gpu_scene::AtlasCache::default()
                    .frame(&renderer, &svg, &primitives, 1280., 720., 1., 1)
                    .unwrap_or_else(|error| panic!("{mode}: {error}"));
                assert!(!frame.batches.is_empty(), "{mode}: lost scene");
                assert!(frame.batches.len() <= 256, "{mode}: batch budget");
                assert!(frame.atlases.len() <= 16, "{mode}: atlas page budget");
                for batch in &frame.batches {
                    let mut depth = 1;
                    let mut parent = batch.parent;
                    while let Some(index) = parent {
                        depth += 1;
                        parent = frame.batches[index].parent;
                    }
                    assert!(depth <= 8, "{mode}: nested effects exceed native budget");
                }
            }
        }
        assert_eq!(unique.len(), 11);
    }
    #[test]
    fn native_svg_renderer_draws_real_chinese_glyphs_with_rotation_and_glow() {
        let value = json!({"mode":"luminous","flow":{"activeLine":{"text":"真实歌词"},"glyphs":[{"id":"g","text":"真","phase":"active","progress":0.5,"rotation":12.}]}});
        let svg = Scene::new(&value, 640., 360.).finish();
        let renderer = gpui_kit::SvgRenderer::new(std::sync::Arc::new(()));
        let image = renderer
            .render_single_frame(svg.as_bytes(), 1.)
            .expect("native SVG scene should rasterize");
        assert!(
            image
                .as_bytes(0)
                .unwrap()
                .chunks_exact(4)
                .any(|pixel| pixel[3] > 0)
        );
    }
    #[test]
    fn unrevealed_cinematic_segments_are_not_visible() {
        let value = json!({"mode":"confession","playbackTime":2.,"flow":{"activeLine":{"text":"未到揭示时间"}},"tilt":{"segments":[{"text":"未到揭示时间","revealAt":3.}]}});
        assert!(
            !Scene::new(&value, 1280., 720.)
                .finish()
                .contains("未到揭示时间")
        );
    }
}
