use crate::projective_card::{
    CardEffects, CardShadow, CardTransform, ProjectedCard, RailMask, RgbaTexture, ScrollTransition,
};

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
use gpui_kit::component::button::*;
use gpui_kit::*;
use serde_json::{Value, json};
use std::{cell::RefCell, collections::HashMap, rc::Rc, sync::Arc};
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
    let (w, h, r) = if catalog {
        (306., 74., 22.)
    } else {
        (294., 76., 23.)
    };
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
    let icon_edge = if catalog { 42 } else { 44 };
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
    let title_size = if current && !catalog { 17. } else { 16. };
    body.push_str(&svg_text(
        card["title"].as_str().unwrap_or(""),
        if catalog { 69. } else { 71. },
        33.,
        title_size,
        600,
        "#ebeff2",
        if catalog { 207. } else { 209. },
    ));
    body.push_str(&svg_text(
        card[if catalog { "subtitle" } else { "artist" }]
            .as_str()
            .unwrap_or(""),
        if catalog { 69. } else { 71. },
        54.,
        if catalog { 13. } else { 14. },
        500,
        "#ffffff7a",
        if catalog { 207. } else { 164. },
    ));
    if catalog {
        if card["isPending"].as_bool() == Some(true) {
            body.push_str(r##"<path d="M286 29l2 7 7 2-7 2-2 7-2-7-7-2 7-2z" fill="#7af2ff"/>"##);
        } else {
            body.push_str(r##"<path d="M284 32l5 6-5 6" fill="none" stroke="#ffffff" stroke-opacity=".34" stroke-width="1.8"/>"##);
        }
    } else {
        for i in 0..7 {
            let height = energy_height(card["energy"].as_f64().unwrap_or(0.) as f32, i);
            body.push_str(&format!(r##"<rect x="{}" y="{}" width="2" height="{height}" rx="1" fill="#00ffff" fill-opacity=".42"/>"##,252+i*4,49.-height/2.));
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
    let focused = card["isFocused"]
        .as_bool()
        .unwrap_or(card["isCurrent"].as_bool() == Some(true));
    CardTransform {
        width: if catalog { 306. } else { 294. },
        height: if catalog { 74. } else { 76. },
        scale: if catalog {
            1.
        } else {
            card["scale"].as_f64().unwrap_or(1.) + if focused { 0.055 } else { 0. }
        },
        y_degrees: if catalog {
            -7.
        } else if focused {
            -4.
        } else {
            -10. - card["relativeIndex"].as_i64().unwrap_or(0).clamp(-2, 2) as f64 * 2.5
        },
        perspective: 0.72,
    }
}
fn energy_height(energy: f32, index: usize) -> f32 {
    5. + 13. * energy * (0.36 + ((index + 1) as f32 * 1.7).sin().abs() * 0.64)
}

const TRACK_HEIGHT: f32 = 76.;
const TRACK_SPACING: f32 = -7.;
const PROGRAM_SPACING: f32 = 4.;

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

pub struct StageProgramRailPane {
    snapshot: Value,
    commands: Vec<Value>,
    scroll: ScrollHandle,
    center_active: bool,
    scroll_start: Option<f32>,
    snap_task: Option<Task<()>>,
    renderer: SvgRenderer,
    card_cache: HashMap<String, (String, Arc<RgbaTexture>)>,
    pressed_card: Option<(String, bool)>,
    projection_cache: ProjectionCache,
    focus_handles: HashMap<String, FocusHandle>,
}
impl StageProgramRailPane {
    pub fn new(_window: &mut Window, _cx: &mut Context<Self>) -> Self {
        Self {
            snapshot: Value::Null,
            commands: vec![json!({"op":"stage.program.load"})],
            scroll: ScrollHandle::new(),
            center_active: true,
            scroll_start: None,
            snap_task: None,
            renderer: SvgRenderer::new(Arc::new(())),
            card_cache: HashMap::new(),
            pressed_card: None,
            projection_cache: Rc::new(RefCell::new(HashMap::new())),
            focus_handles: HashMap::new(),
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
                self.snap_task = None;
                self.scroll_start = None;
            }
            if self.snapshot["route"] != snapshot["route"] {
                self.card_cache.clear();
                self.pressed_card = None;
                self.projection_cache.borrow_mut().clear();
                self.focus_handles.clear();
            }
            self.snapshot = snapshot;
            cx.notify();
        }
    }
    pub fn take_commands(&mut self) -> Vec<Value> {
        std::mem::take(&mut self.commands)
    }
    fn projected_card(
        &mut self,
        card: &Value,
        catalog: bool,
        playlist: bool,
        op: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
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
        let artwork = if playlist {
            card["artworkURL"]
                .as_str()
                .filter(|url| url.starts_with("https://") || url.starts_with("http://"))
                .and_then(|url| {
                    window.use_asset::<ImageAssetLoader>(&Resource::Uri(url.to_owned().into()), cx)
                })
                .and_then(Result::ok)
        } else {
            None
        };
        let key = format!(
            "{}/{audio}/{catalog}/{playlist}/{:?}",
            json!({"title":card["title"],"artist":card["artist"],"subtitle":card["subtitle"],"isCurrent":card["isCurrent"],"hasBoundVideo":card["hasBoundVideo"],"isPending":card["isPending"],"energy":card["energy"]}),
            artwork.as_ref().map(|image| image.id)
        );
        let texture =
            if let Some((old, texture)) = self.card_cache.get(&id).filter(|(old, _)| old == &key) {
                let _ = old;
                texture.clone()
            } else {
                let svg = card_svg_content(card, &audio, catalog, playlist, artwork.is_some());
                let Ok(image) = self.renderer.render_single_frame(svg.as_bytes(), 1.) else {
                    return div()
                        .w(px(if catalog { 306. } else { 294. }))
                        .h(px(if catalog { 74. } else { 76. }))
                        .child("卡片显示失败")
                        .into_any_element();
                };
                let dimensions = image.size(0);
                let mut pixels = image.as_bytes(0).unwrap_or_default().to_vec();
                for pixel in pixels.chunks_exact_mut(4) {
                    pixel.swap(0, 2);
                }
                let mut texture = RgbaTexture {
                    width: dimensions.width.0 as u32,
                    height: dimensions.height.0 as u32,
                    pixels,
                };
                if let Some(artwork) = &artwork {
                    composite_artwork(&mut texture, artwork);
                }
                let texture = Arc::new(texture);
                self.card_cache.insert(id.clone(), (key, texture.clone()));
                texture
            };
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
            card["horizontalOffset"].as_f64().unwrap_or(0.)
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
        let focus = self
            .focus_handles
            .entry(id.clone())
            .or_insert_with(|| cx.focus_handle())
            .clone();
        let mouse_focus = focus.clone();
        let keyboard_play = play.clone();
        let accessibility_id = id.clone();
        let canvas = canvas(
            move |bounds, window, _| {
                let viewport = scroll.bounds();
                let origin = [
                    f64::from(f32::from(bounds.origin.x)),
                    f64::from(f32::from(bounds.origin.y)),
                ];
                let mask = RailMask {
                    top: f64::from(f32::from(viewport.origin.y)),
                    height: f64::from(f32::from(viewport.size.height)),
                };
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
                    return None;
                }
                let window_size = [
                    f64::from(f32::from(window.viewport_size().width)),
                    f64::from(f32::from(window.viewport_size().height)),
                ];
                let cache_key = format!(
                    "{:p}/{transform:?}/{origin:?}/{window_size:?}/{}/{opacity}/{mask:?}/{transition:?}/{effects:?}",
                    Arc::as_ptr(&texture),
                    window.scale_factor()
                );
                if let Some((key, projected, image)) = cache
                    .borrow()
                    .get(&cache_id)
                    .filter(|(key, _, _)| key == &cache_key)
                {
                    let _ = key;
                    return Some((projected.clone(), image.clone()));
                }
                let projected = Arc::new(
                    ProjectedCard::render_with_effects(
                        &texture,
                        transform,
                        origin,
                        window_size,
                        window.scale_factor() as f64,
                        opacity,
                        Some(mask),
                        transition,
                        effects,
                    )
                    .ok()?,
                );
                let image = projected.render_image();
                cache
                    .borrow_mut()
                    .insert(cache_id, (cache_key, projected.clone(), image.clone()));
                Some((projected, image))
            },
            move |_, projected, window, _| {
                let Some((projected, image)) = projected else {
                    return;
                };
                let b = projected.bounds;
                let bounds = Bounds::new(
                    point(px(b[0] as f32), px(b[1] as f32)),
                    size(px(b[2] as f32), px(b[3] as f32)),
                );
                let _ = window.paint_image(bounds, bounds, Corners::default(), image, 0, false);
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
                    if let Some(local) = down_projected.inverse_hit(point) {
                        window.focus(&mouse_focus, cx);
                        let video_hit = video
                            && local[0] >= 259.
                            && local[0] <= 285.
                            && local[1] >= 8.
                            && local[1] <= 34.;
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
                    if let Some(local) = projected.inverse_hit(point) {
                        let video_hit = video
                            && local[0] >= 259.
                            && local[0] <= 285.
                            && local[1] >= 8.
                            && local[1] <= 34.;
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
            let video_focus = self
                .focus_handles
                .entry(format!("video-{}", card["trackID"]))
                .or_insert_with(|| cx.focus_handle())
                .clone();
            let command = json!({"op":"stage.program.video","trackID":card["trackID"]});
            wrapper = wrapper.child(
                div()
                    .id(format!("video-{}", card["trackID"]))
                    .absolute()
                    .right(px(9.))
                    .top(px(8.))
                    .w(px(26.))
                    .h(px(26.))
                    .role(Role::Button)
                    .aria_label("播放绑定视频")
                    .track_focus(&video_focus)
                    .on_key_down(cx.listener(move |this, event: &KeyDownEvent, _, cx| {
                        if !event.keystroke.modifiers.modified()
                            && matches!(event.keystroke.key.as_str(), "enter" | "space")
                        {
                            this.commands.push(command.clone());
                            cx.stop_propagation();
                            cx.notify();
                        }
                    })),
            );
        }
        wrapper.into_any_element()
    }
    fn button(
        &self,
        id: impl Into<ElementId>,
        label: impl Into<SharedString>,
        command: Value,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        Button::new(id)
            .label(label)
            .on_click(cx.listener(move |this, _, _, cx| {
                this.commands.push(command.clone());
                cx.notify();
            }))
            .into_any_element()
    }
    fn icon_button(
        &self,
        id: impl Into<ElementId>,
        icon: gpui_kit::assets::IconName,
        tooltip: &'static str,
        command: Value,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        Button::new(id)
            .icon(icon)
            .tooltip(tooltip)
            .w(px(26.))
            .h(px(26.))
            .rounded_full()
            .on_click(cx.listener(move |this, _, _, cx| {
                this.commands.push(command.clone());
                cx.notify();
            }))
            .into_any_element()
    }
}
impl Render for StageProgramRailPane {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let tracks = self.snapshot["route"]
            .as_str()
            .is_some_and(|r| r != "programs");
        let mut content = div()
            .flex()
            .flex_col()
            .items_end()
            .gap(px(if tracks {
                TRACK_SPACING
            } else {
                PROGRAM_SPACING
            }))
            .py(px(18.));
        let mut header = div()
            .flex()
            .items_center()
            .gap(px(10.))
            .px(px(14.))
            .w_full();
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
                    gpui_kit::assets::IconName::ChevronLeft,
                    "返回节目单",
                    json!({"op":"stage.program.back"}),
                    cx,
                ))
                .child(div().flex_1())
                .child(self.snapshot["title"].as_str().unwrap_or("").to_uppercase());
            if self.snapshot["isPlaylist"].as_bool() != Some(true) {
                header = header.child(self.icon_button(
                    "program-replan",
                    gpui_kit::assets::IconName::RefreshCw,
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
                    let scroll = self.scroll.clone();
                    window.on_next_frame(move |window, _| {
                        let viewport: f32 = scroll.bounds().size.height.into();
                        let maximum: f32 = scroll.max_offset().y.into();
                        scroll.set_offset(point(
                            px(0.),
                            px(active_center_offset(index, viewport, maximum.abs())),
                        ));
                        window.refresh();
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
            if self.snapshot["hasMore"].as_bool() == Some(true) {
                content = content.child(self.button(
                    "program-load-more",
                    "加载更多",
                    json!({"op":"stage.program.more"}),
                    cx,
                ));
            }
            if self.snapshot["tracks"]
                .as_array()
                .is_none_or(|a| a.is_empty())
            {
                content = content.child(
                    self.snapshot["emptyMessage"]
                        .as_str()
                        .unwrap_or("正在加载歌曲…")
                        .to_owned(),
                );
            }
        } else {
            header = header
                .child(self.icon_button(
                    "program-replan",
                    gpui_kit::assets::IconName::RefreshCw,
                    "重新编排",
                    json!({"op":"stage.program.replan"}),
                    cx,
                ))
                .child(div().flex_1())
                .child("歌单");
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
            if self.snapshot["programs"]
                .as_array()
                .is_none_or(|a| a.is_empty())
                && self.snapshot["playlists"]
                    .as_array()
                    .is_none_or(|a| a.is_empty())
            {
                content = content.child(
                    self.snapshot["emptyMessage"]
                        .as_str()
                        .unwrap_or("暂无歌单")
                        .to_owned(),
                );
            }
        }
        div()
            .id("stage-program-rail")
            .capture_any_mouse_down(cx.listener(|this, _, _, _| this.pressed_card = None))
            .w(px(350.))
            .h(px(430.))
            .pt(px(42.))
            .pr(px(10.))
            .flex()
            .flex_col()
            .gap(px(8.))
            .text_color(rgb(0xe5e7ea))
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
                            if this.scroll_start.is_none()
                                || event.touch_phase == TouchPhase::Started
                            {
                                this.scroll_start = Some(this.scroll.offset().y.into());
                            }
                            if event.touch_phase == TouchPhase::Cancelled {
                                this.snap_task = None;
                                this.scroll_start = None;
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
    }
}

fn active_center_offset(index: usize, viewport: f32, maximum: f32) -> f32 {
    -(18. + index as f32 * (TRACK_HEIGHT + TRACK_SPACING) + TRACK_HEIGHT / 2. - viewport / 2.)
        .clamp(0., maximum)
}

#[cfg(test)]
mod tests {
    use super::{
        PROGRAM_SPACING, TRACK_SPACING, active_center_offset, card_effects, card_priority,
        card_svg, card_transform, energy_height, scroll_phase, snap_offset,
    };
    use serde_json::json;
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
        cx.update_window(handle.into(), |_, window, cx| window.draw(cx).clear(cx))
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
        cx.update_window(projected.into(), |_, window, cx| window.draw(cx).clear(cx))
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
        cx.update_window(tracks.into(), |_, window, cx| window.draw(cx).clear(cx))
            .unwrap();
        cx.update_window(tracks.into(), |_, window, cx| window.draw(cx).clear(cx))
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
        cx.update_window(projected.into(), |_, window, cx| window.draw(cx).clear(cx))
            .unwrap();
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
