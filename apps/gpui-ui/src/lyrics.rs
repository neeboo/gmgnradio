//! Original stage lyric compositions, rendered through GPUI's SVG drawing API.
//! The host supplies the resolved mode and original scene models; no lyric clock or
//! scene director is reconstructed here. SVG handles rotation, blur and glow;
//! out-of-plane rotations use projected glyph positions and horizontal scale.
use gpui_kit::component::{button::*, *};
use gpui_kit::*;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::fmt::Write;
use std::sync::Arc;
use std::time::Instant;

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
struct Scene<'a> {
    snapshot: &'a Value,
    width: f64,
    height: f64,
    svg: String,
    primary: String,
    accent: String,
    secondary: String,
    outlines: HashMap<(String, u64, u16, u64), outline::Line>,
    weight: u16,
    tracking: f64,
    projection: Option<(f64, f64, f64, (f64, f64, f64), f64)>,
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
            svg,
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
                if let Some((cx, cy, angle, axis, width)) = self.projection {
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
            let path = if self.projection.is_some() {
                outline::projected_path(&shaped.commands, map)
            } else {
                outline::svg_path(&shaped.commands, map)
            };
            let _ = write!(
                self.svg,
                r#"<path aria-label="{}" d="{path}" fill="{color}" opacity="{opacity}" filter="url(#textShadow)"/>"#,
                escape(text)
            );
            return;
        }
        let _ = write!(
            self.svg,
            r#"<text x="{x}" y="{y}" text-anchor="{anchor}" dominant-baseline="middle" font-family="system-ui, PingFang SC, sans-serif" font-size="{size}" font-weight="600" fill="{color}" opacity="{opacity}">{}</text>"#,
            escape(text)
        );
    }
    fn outlined(&mut self, text: &str, size: f64) -> Option<outline::Line> {
        let key = (
            text.to_owned(),
            size.to_bits(),
            self.weight,
            self.tracking.to_bits(),
        );
        if let Some(line) = self.outlines.get(&key) {
            return Some(line.clone());
        }
        let line = outline::shape_styled(text, size, self.weight, self.tracking)?;
        self.outlines.insert(key, line.clone());
        Some(line)
    }
    fn measured_width(&mut self, text: &str, size: f64) -> f64 {
        self.outlined(text, size)
            .map(|line| line.width)
            .unwrap_or_else(|| text.chars().count() as f64 * size * 0.6)
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
        if text.is_empty() {
            return;
        }
        let mut resolved = size;
        let mut lines = outline::wrap(text, size, width);
        while lines.len() > max_lines && resolved > size * min_scale + 0.1 {
            resolved = (resolved - 0.5).max(size * min_scale);
            lines = outline::wrap(text, resolved, width);
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
        let top = y - (lines.len().saturating_sub(1) as f64) * line_height / 2.;
        for (index, line) in lines.iter().enumerate() {
            self.line(
                line,
                x,
                top + index as f64 * line_height,
                resolved,
                opacity,
                color,
                anchor,
            );
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
            let path = outline::projected_path(&line.commands, |point| {
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
            });
            let _ = write!(
                self.svg,
                r#"<path aria-label="{}" d="{path}" fill="{color}" opacity="{opacity}"/>"#,
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
        let _ = write!(
            self.svg,
            r#"<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}" stroke="{stroke}" stroke-width="1" opacity="{opacity}"/>"#
        );
    }
    fn translation(&mut self, x: f64, y: f64, size: f64, anchor: &str) {
        let value = text(&self.snapshot["flow"], "translation");
        if !value.is_empty() {
            let width = match self.snapshot["mode"].as_str().unwrap_or("") {
                "luminous" => 720.,
                "confession" => 620.,
                "cloud_steps" => 520f64.min(self.width * 0.5),
                "article" => 680.,
                "diorama" => self.width * 0.6,
                _ => self.width * 0.64,
            };
            self.paragraph(
                &value,
                x,
                y,
                size,
                width,
                2,
                1.,
                0.58,
                &self.primary.clone(),
                anchor,
            );
        }
    }
    fn glyphs(&mut self, cx: f64, cy: f64, size: f64, arc: bool) {
        let previous_style = (self.weight, self.tracking);
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
        let spacing = size * if arc { 0.012 } else { 0.015 };
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
            let _ = write!(
                self.svg,
                r#"<g transform="translate({x} {y}) rotate({rotation}) scale({} {scale})" opacity="{opacity}">"#,
                scale
            );
            if phase == "active" {
                let glow = if chorus {
                    self.secondary.clone()
                } else {
                    self.accent.clone()
                };
                self.svg
                    .push_str(r#"<g filter="url(#glow)" opacity="0.7">"#);
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
                    if phase == "waiting" { 0.26 } else { 1. },
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
                    if phase == "waiting" { 0.26 } else { 1. },
                    &fill,
                    "middle",
                );
            }
            self.svg.push_str("</g>");
        }
        (self.weight, self.tracking) = previous_style;
        self.projection = projection;
    }
    fn active_text(&self) -> String {
        text(&self.snapshot["flow"]["activeLine"], "text")
    }
    fn flow(&mut self) {
        let size = font_size(&self.active_text(), self.width);
        let cx = self.width * 0.5 + self.rail(150.);
        let cy = self.height * 0.5 - 8.;
        self.line(
            &text(&self.snapshot["flow"]["previousLine"], "text"),
            cx - 42.,
            cy - size - 22.,
            (size * 0.28).clamp(15., 24.),
            0.18,
            &self.primary.clone(),
            "middle",
        );
        self.glyphs(
            cx,
            cy + (num(self.snapshot, "animationTime", 0.) * 0.72).sin() * 2.2,
            size,
            false,
        );
        self.translation(cx, cy + size * 0.7 + 22., (size * 0.22).max(16.), "middle");
        self.line(
            &text(&self.snapshot["flow"]["nextLine"], "text"),
            cx + 42.,
            cy + size + 66.,
            (size * 0.28).clamp(15., 24.),
            0.28,
            &self.primary.clone(),
            "middle",
        );
    }
    fn depth(&mut self) {
        let mut lines = items(&self.snapshot["depth"], "lines");
        lines.sort_by_key(|line| num(line, "position", 1.) == 0.);
        for line in lines {
            let p = num(&line, "position", 0.);
            let current = p == 0.;
            let size = if current { 38. } else { 24. }
                * num(&line, "scale", 1.)
                * if current {
                    self.audio("expansion", 1.)
                } else {
                    1.
                };
            let cx = self.width * 0.5 + self.rail(150.) + p * 92.;
            let cy = self.height * 0.5
                + p * 96.
                + if current {
                    self.audio("beatLift", 0.) * 0.24
                } else {
                    0.
                };
            self.perspective_line(
                &text(&line, "text"),
                cx,
                cy,
                size,
                num(&line, "opacity", 1.),
                "url(#lyricGradient)",
                -p * 12.,
                (0.08, 1., 0.),
                0.68,
                "middle",
            );
        }
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
        let mut row = 0;
        let x = (self.width * 0.08).max(62.) + self.rail(104.);
        for segment in items(&self.snapshot["tilt"], "segments") {
            if time < num(&segment, "revealAt", f64::MAX) {
                continue;
            }
            let tilted = segment["isTilted"].as_bool() == Some(true);
            let sx = x + self.width * num(&segment, "xOffset", 0.);
            let y = self.height * 0.38 + row as f64 * size * 1.08 - 14.;
            let _ = write!(
                self.svg,
                r#"<g transform="translate({sx} {y}) rotate({})">"#,
                if tilted { -7. } else { 0. }
            );
            let fill = if tilted {
                "url(#tiltGradient)".to_owned()
            } else {
                self.primary.clone()
            };
            self.line(
                &text(&segment, "text"),
                0.,
                0.,
                size * if tilted { 1.14 } else { 1. },
                1.,
                &fill,
                "start",
            );
            self.svg.push_str("</g>");
            row += 1;
        }
        self.translation(
            x,
            self.height * 0.38 + row as f64 * size * 1.08 + 8.,
            (size * 0.2).max(15.),
            "start",
        );
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
        let height = (self.height * 0.7).min(520.);
        self.rect(
            x,
            self.height * 0.5 - height / 2.,
            3. + self.audio("high", 0.) * 2.,
            height,
            2.,
            "url(#posterGradient)",
            "none",
            0.9,
        );
        for entry in entries {
            let offset = num(&entry, "offset", 0.);
            let sx = x + 28. + offset.abs() * 18. + if offset > 0. { 12. } else { 0. };
            let y = self.height * 0.5 + offset * (size * 0.6 + 14.);
            if offset == 0. {
                self.glyphs(sx + self.width * 0.31, y, size, false);
                self.translation(sx, y + size * 0.6, (size * 0.2).max(15.), "start");
            } else {
                let opacity = if offset < 0. {
                    0.16 + 0.05 / offset.abs()
                } else {
                    0.34 - (offset.abs() - 1.) * 0.07
                };
                self.line(
                    &text(&entry["line"], "text"),
                    sx,
                    y,
                    (size * 0.34).clamp(17., 28.),
                    opacity,
                    &self.primary.clone(),
                    "start",
                );
            }
        }
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
            let width = 520f64.min(self.width * 0.46) * scale * rotation.to_radians().cos();
            self.rect(
                cx + self.width * dx - width / 2.,
                self.height * y - 34.,
                width,
                68.,
                24.,
                "#ffffff",
                "#ffffff",
                0.025,
            );
            self.perspective_line(
                &value,
                cx + self.width * dx,
                self.height * y,
                24. * scale,
                opacity,
                &self.primary.clone(),
                rotation,
                (if key == "previousLine" { 0.08 } else { 0.06 }, 1., 0.),
                0.68,
                "middle",
            );
        }
        let size = font_size(&self.active_text(), self.width * 0.6);
        let cy = self.height * 0.5;
        self.projection = Some((
            0.,
            0.,
            (time * 0.23).sin() * 2.4,
            (0.04, 1., 0.),
            self.width * 0.6,
        ));
        self.rect(
            cx - self.width * 0.3 - 34.,
            cy - size / 2. - 28.,
            self.width * 0.6 + 68.,
            size + 84.,
            28.,
            "#000000",
            &self.accent.clone(),
            0.26,
        );
        self.glyphs(cx, cy, size, false);
        self.translation(cx, cy + size * 0.6 + 14., (size * 0.18).max(15.), "middle");
        self.projection = None;
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
            let rotation = if historical { direction * 90. * p } else { 0. };
            let _ = write!(
                self.svg,
                r#"<g transform="translate({x} {y}) rotate({rotation}) scale({scale})" opacity="{opacity}">"#
            );
            let active = lines.iter().position(|l| l["id"] == fold["activeLineID"]);
            let mut cy = -(lines.len() as f64) * 34.;
            for (index, line) in lines.iter().enumerate() {
                let current = !historical && line["id"] == fold["activeLineID"];
                let size = (font_size(&text(line, "text"), width) * 0.72).clamp(28., 72.);
                let alpha = if historical {
                    0.5
                } else if current {
                    1.
                } else if active.is_some_and(|i| index < i) {
                    0.82
                } else {
                    0.22
                };
                self.weight = if current { 900 } else { 700 };
                self.perspective_line(
                    &text(line, "text"),
                    0.,
                    cy,
                    size,
                    alpha,
                    &if current {
                        self.accent.clone()
                    } else {
                        self.primary.clone()
                    },
                    if historical { direction * 7. * p } else { 0. },
                    (0., 1., 0.),
                    0.72,
                    "start",
                );
                cy += size + 8.;
                if current {
                    let translation = text(line, "translation");
                    if !translation.is_empty() {
                        self.line(
                            &translation,
                            0.,
                            cy,
                            16.,
                            0.58,
                            &self.primary.clone(),
                            "start",
                        );
                        cy += 19.;
                    }
                }
            }
            self.svg.push_str("</g>");
        }
    }
    fn finish(mut self) -> String {
        if self.snapshot["flow"]["activeLine"].is_null() && self.snapshot["mode"] != "folding_verse"
        {
            self.svg.push_str("</svg>");
            return self.svg;
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
        self.svg
    }
}

pub struct StageLyricsPane {
    snapshot: Value,
    width: f64,
    height: f64,
    renderer: SvgRenderer,
    image: Option<Arc<RenderImage>>,
    render_key: String,
    render_error: Option<String>,
    outgoing: Option<Value>,
    transition_started: Instant,
}
fn spring_progress(seconds: f64, response: f64, damping: f64) -> f64 {
    let omega = std::f64::consts::TAU / response;
    let damped = omega * (1. - damping * damping).sqrt();
    1. - (-damping * omega * seconds).exp()
        * ((damped * seconds).cos() + damping * omega / damped * (damped * seconds).sin())
}
fn scene_layer(svg: &str, width: f64, height: f64, opacity: f64, scale: f64) -> String {
    let body = svg
        .split_once('>')
        .map(|(_, body)| body.trim_end_matches("</svg>"))
        .unwrap_or("");
    format!(
        r#"<g opacity="{opacity}" transform="translate({} {}) scale({scale}) translate({} {})">{body}</g>"#,
        width / 2.,
        height / 2.,
        -width / 2.,
        -height / 2.
    )
}
impl StageLyricsPane {
    pub fn new(_window: &mut Window, _cx: &mut Context<Self>) -> Self {
        Self {
            snapshot: Value::Null,
            width: 0.,
            height: 0.,
            renderer: SvgRenderer::new(Arc::new(())),
            image: None,
            render_key: String::new(),
            render_error: None,
            outgoing: None,
            transition_started: Instant::now(),
        }
    }
    pub fn update_snapshot(
        &mut self,
        snapshot: Value,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.snapshot != snapshot {
            if self.snapshot["flow"]["activeLine"]["id"] != snapshot["flow"]["activeLine"]["id"]
                || self.snapshot["mode"] != snapshot["mode"]
            {
                self.outgoing = (!self.snapshot.is_null()).then(|| self.snapshot.clone());
                self.transition_started = Instant::now();
            }
            self.snapshot = snapshot;
            cx.notify();
        }
    }
    pub fn set_viewport_size(&mut self, width: f32, height: f32) {
        self.width = width.max(0.) as f64;
        self.height = height.max(0.) as f64;
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
        let mut svg = Scene::new(&self.snapshot, w, h).finish();
        let elapsed = self.transition_started.elapsed().as_secs_f64();
        if elapsed < 1.5 {
            let (response, damping) = match self.snapshot["mode"].as_str().unwrap_or("") {
                "pendulum" => (0.72, 0.86),
                "confession" => (0.55, 0.82),
                _ => (0.44, 0.84),
            };
            let progress = spring_progress(elapsed, response, damping);
            let scale_mode = matches!(self.snapshot["mode"].as_str(), Some("luminous" | "diorama"));
            let mut body = String::new();
            if let Some(old) = &self.outgoing {
                body.push_str(&scene_layer(
                    &Scene::new(old, w, h).finish(),
                    w,
                    h,
                    (1. - progress).clamp(0., 1.),
                    if scale_mode { 1. - 0.08 * progress } else { 1. },
                ));
            }
            body.push_str(&scene_layer(
                &svg,
                w,
                h,
                progress.clamp(0., 1.),
                if scale_mode {
                    0.92 + 0.08 * progress
                } else {
                    1.
                },
            ));
            svg = format!(
                r#"<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">{body}</svg>"#
            );
            window.request_animation_frame();
        } else {
            self.outgoing = None;
        }
        if self.render_key != svg {
            self.render_key = svg;
            match self
                .renderer
                .render_single_frame(self.render_key.as_bytes(), window.scale_factor())
            {
                Ok(image) => {
                    self.image = Some(image);
                    self.render_error = None;
                }
                Err(_) => {
                    self.image = None;
                    self.render_error = Some("lyrics_svg_render_failed".to_owned());
                }
            }
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
                            .label("播放")
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
                        .label("×")
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
    #[cfg(not(target_os = "macos"))]
    pub fn shape_styled(_text: &str, _size: f64, _weight: u16, _tracking: f64) -> Option<Line> {
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
    #[cfg(all(target_os = "macos", test))]
    pub use native::shape;
    #[cfg(target_os = "macos")]
    pub use native::{shape_styled, wrap};
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
            fn descriptor_with_design(receiver: Ref, selector: Ref, design: Ref) -> Ref;
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
        pub fn shape_styled(text: &str, size: f64, weight: u16, tracking: f64) -> Option<Line> {
            if text.is_empty() || !size.is_finite() || size <= 0. {
                return None;
            }
            // Every Create result is released; run fonts and glyph arrays are
            // borrowed only while their owning CTLine remains alive.
            unsafe {
                let font = weighted_font(size, weight);
                if font.0.is_null() {
                    return None;
                }
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
                let rounded = descriptor_with_design(
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
        pub fn wrap(text: &str, size: f64, width: f64) -> Vec<String> {
            if text.is_empty() {
                return vec![];
            }
            unsafe {
                let font = weighted_font(size, 600);
                let content = string(text);
                let keys = [kCTFontAttributeName];
                let values = [font.0];
                let attrs = Owned(CFDictionaryCreate(
                    ptr::null(),
                    keys.as_ptr(),
                    values.as_ptr(),
                    1,
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
