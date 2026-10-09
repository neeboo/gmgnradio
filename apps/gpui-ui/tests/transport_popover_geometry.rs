//! The 音量 popover must have somewhere to paint: **inside the window** and
//! **above the transport bar**.
//!
//! The defect this pins (2026-10-09): the floating bar in `gmgn_gpui_ui::shell`
//! was built with `.absolute().relative()`. In GPUI the last position setter
//! wins, so the bar stopped being anchored to the canvas' bottom-right corner
//! and became an ordinary in-flow child of the shell root: laid out at the
//! canvas' top-left, stretched across it, with `right`/`bottom` degraded into
//! relative offsets that moved it to `(-22, -22)`. The popover opens
//! `TRANSPORT_HEIGHT + TRANSPORT_POPOVER_GAP` above the bar's own top edge, so
//! the whole panel landed at negative `y` and GPUI's window clip threw it away —
//! clicking 音量 only lit the icon, which is the reported symptom.
//!
//! Nothing here reads a constant: the bar rect is the real prepared-layout
//! bound (the same numbers the overlay reports as hit regions), and the popover
//! is measured as the pixels that actually appear when it opens.
#![recursion_limit = "1024"]

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;

use gmgn_gpui_ui::primitives as ui;
use gmgn_gpui_ui::shell::{self, TransportControl};
use gmgn_gpui_ui::ui_tokens::shell as m;
use gpui_kit::assets::IconName;
use gpui_kit::component::slider::SliderState;
use gpui_kit::prelude::*;
use gpui_kit::test::TestWindowExt as _;
use gpui_kit::*;

/// The window the overlay probe attaches its view at (`probe_attach_view(..,
/// 1280, 720)`), so the product's 14-control bar fits the canvas.
const WINDOW: (f32, f32) = (1280., 720.);

#[derive(Default)]
struct Facts {
    bar: Option<Bounds<Pixels>>,
    viewport: Option<Size<Pixels>>,
}

/// The product's control table, in the product's order (`shell_ui.rs`), so the
/// 音量 slot is where it really is — a one-control bar would place the popover
/// at the bar's left edge and measure the wrong rectangle.
///
/// The open panel is the **production** content: [`ui::volume_slider`]'s
/// vertical track above [`ui::volume_mute_button`]'s icon, built exactly as
/// `shell_ui.rs` builds it. The track's axis is what this harness measures in
/// pixels below, so substituting a horizontal `Slider` here is what turns the
/// vertical assertions red.
fn controls(volume: Entity<SliderState>, open: bool) -> Vec<TransportControl> {
    let mut rows: Vec<TransportControl> = vec![
        TransportControl::new("program", "program", IconName::FileText, "音乐与节目"),
        TransportControl::new("previous", "previous", IconName::ChevronLeft, "上一首"),
        TransportControl::new("play", "play", IconName::Play, "播放"),
        TransportControl::new("next", "next", IconName::ChevronRight, "下一首").ends_group(true),
        TransportControl::new("voice", "voice", IconName::Mic, "按住说话").hold(true),
        TransportControl::new("chat", "chat", IconName::Bot, "聊天"),
        TransportControl::new("inbox", "inbox", IconName::Bell, "通知"),
        TransportControl::new("lyrics", "lyrics", IconName::Music, "显示或隐藏歌词"),
    ];
    let mut volume_control = TransportControl::new("volume", "volume", IconName::Volume2, "音量");
    if open {
        volume_control = volume_control.popover(move |_, _| {
            // The panel's **content** only: `shell::transport_popover` is the one
            // surface the bar itself draws it in (`transport_bar_slots`), so
            // wrapping it here as well nests a second, empty card under the
            // panel — the stray strip that used to sit right above the bar.
            div()
                .flex()
                .flex_col()
                .items_center()
                .gap(px(6.))
                .child(ui::volume_slider(&volume, true))
                .child(ui::volume_mute_button(false, true))
                .into_any_element()
        });
    }
    rows.push(volume_control);
    rows.push(TransportControl::new("compact", "compact", IconName::Minimize, "小窗"));
    rows.push(TransportControl::new("props", "props", IconName::SquareStack, "物品"));
    rows.push(TransportControl::new(
        "screen",
        "screen",
        IconName::MousePointerClick,
        "电视",
    ));
    rows.push(
        TransportControl::new("visual", "visual", IconName::Settings, "设置").face_text("设置"),
    );
    rows.push(TransportControl::new("mode", "mode", IconName::Maximize, "全屏"));
    rows
}

struct Harness {
    volume: Entity<SliderState>,
    open: bool,
    facts: Rc<RefCell<Facts>>,
}

impl Render for Harness {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let facts = self.facts.clone();
        self.facts.borrow_mut().viewport = Some(window.viewport_size());
        // The shell root is `div().relative().size_full()` in the overlay probe:
        // the bar is absolutely positioned inside it, pinned to the bottom-right
        // corner, and it is the only child of the root.
        div()
            .relative()
            .size_full()
            .on_children_prepainted(move |bounds, _, _| {
                if let Some(bar) = bounds.first() {
                    facts.borrow_mut().bar = Some(*bar);
                }
            })
            .child(shell::transport_bar_in(
                controls(self.volume.clone(), self.open),
                window,
                cx,
                |_, _, _| {},
                |_, _, _, _| {},
            ))
    }
}

/// One rendered frame of the shell and the window facts behind it.
struct Frame {
    shot: image::RgbaImage,
    bar: Bounds<Pixels>,
    viewport: Size<Pixels>,
}

fn frame(cx: &mut HeadlessAppContext, volume: Entity<SliderState>, open: bool, level: f32) -> Frame {
    let facts = Rc::new(RefCell::new(Facts::default()));
    let state = facts.clone();
    // The handle the level is set through after the window exists; the harness
    // owns its own clone.
    let level_entity = volume.clone();
    let (width, height) = WINDOW;
    let handle = cx
        .update(|cx| {
            gpui_kit::open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(Bounds {
                        origin: Default::default(),
                        size: size(px(width), px(height)),
                    })),
                    focus: false,
                    show: false,
                    ..Default::default()
                },
                cx,
                move |_, cx| {
                    cx.new(|_| Harness {
                        volume: volume.clone(),
                        open,
                        facts: state,
                    })
                },
            )
        })
        .expect("headless window")
        .0;
    cx.update_window(handle, |_, window, cx| {
        // The track's level before the frame is painted, so two frames of the
        // same open panel differ in exactly the slider's own pixels.
        level_entity.update(cx, |slider, cx| slider.set_value(level, window, cx));
        window.render_frame(cx);
    })
    .unwrap();
    let shot = cx
        .capture_screenshot(handle)
        .expect("GPUI's headless Metal renderer must be available on macOS");
    let (bar, viewport) = {
        let facts = facts.borrow();
        (
            facts.bar.expect("the transport bar must be laid out"),
            facts.viewport.expect("the window must report a viewport"),
        )
    };
    Frame { shot, bar, viewport }
}

/// The bounding box and pixel count of the pixels that differ between two
/// frames, in device pixels.
fn diff(before: &image::RgbaImage, after: &image::RgbaImage) -> Option<(u32, u32, u32, u32, u64)> {
    assert_eq!(
        (before.width(), before.height()),
        (after.width(), after.height())
    );
    let (mut min_x, mut min_y, mut max_x, mut max_y, mut count) = (u32::MAX, u32::MAX, 0, 0, 0);
    for (x, y, pixel) in after.enumerate_pixels() {
        if pixel != before.get_pixel(x, y) {
            min_x = min_x.min(x);
            min_y = min_y.min(y);
            max_x = max_x.max(x);
            max_y = max_y.max(y);
            count += 1;
        }
    }
    (count > 0).then_some((min_x, min_y, max_x, max_y, count))
}

/// The bar's **real** laid-out width for the product control set, read back off
/// the prepared-layout rect GPUI hands the root — the same rectangle the overlay
/// reports as the bar's hit region.
///
/// One window is opened for the whole check and re-rendered per control set:
/// GPUI's `open_window` reuses the window it is handed, so opening three windows
/// in a row would leave two of them rendering the first harness' empty control
/// list (a 10 pt bar) and silently compare against the wrong rectangle.
fn rendered_bar_widths(cx: &mut HeadlessAppContext, sets: Vec<Vec<TransportControl>>) -> Vec<f32> {
    let facts = Rc::new(RefCell::new(Facts::default()));
    let state = facts.clone();
    let (width, height) = WINDOW;
    let count = sets.len();
    let (handle, entity) = cx
        .update(|cx| {
            let app = cx;
            gpui_kit::open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(Bounds {
                        origin: Default::default(),
                        size: size(px(width), px(height)),
                    })),
                    focus: false,
                    show: false,
                    ..Default::default()
                },
                app,
                move |_, cx| {
                    cx.new(|_| WidthHarness {
                        controls: sets,
                        index: 0,
                        facts: state,
                    })
                },
            )
        })
        .expect("headless window");
    let mut widths = Vec::with_capacity(count);
    for index in 0..count {
        entity.update(cx, |harness, cx| {
            harness.index = index;
            cx.notify();
        });
        cx.update_window(handle, |_, window, cx| {
            window.render_frame(cx);
        })
        .unwrap();
        widths.push(f32::from(
            facts
                .borrow()
                .bar
                .expect("the transport bar must be laid out")
                .size
                .width,
        ));
    }
    widths
}

/// Renders one control set and nothing else, so the only prepared child is the
/// bar.
struct WidthHarness {
    controls: Vec<Vec<TransportControl>>,
    index: usize,
    facts: Rc<RefCell<Facts>>,
}

impl Render for WidthHarness {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let entity = cx.entity().downgrade();
        let controls = self.controls[self.index].clone();
        div()
            .relative()
            .size_full()
            .on_children_prepainted(move |bounds, _, cx| {
                if let Some(bar) = bounds.first() {
                    entity
                        .update(cx, |harness, _| {
                            harness.facts.borrow_mut().bar = Some(*bar);
                        })
                        .ok();
                }
            })
            .child(shell::transport_bar_in(
                controls,
                window,
                cx,
                |_, _, _| {},
                |_, _, _, _| {},
            ))
    }
}

/// **The derivation must equal what the bar really lays out at.**
///
/// This is the pixel-truth half of the 2026-10-09 栏宽 defect. `transport_width`
/// summed the slot widths plus *two* `GROUP_GAP`s while [`shell::transport_bar_in`]
/// is a flex row that gaps every neighbouring pair of its children — the control
/// slots, plus the group divider a `.ends_group(true)` control paints after
/// itself. For a real 14-control set with one divider that is 15 children and 14
/// gaps, so the old derivation said 734 - 72 = 662 where the bar laid out at 735:
/// a bar wider than the canvas placed as if it fit, so the leftmost 「节目」 entry
/// was clipped (the product's 760 pt minimum window hid it on the 720 pt Unity
/// sample).
///
/// Reading the bar's own prepared rect is what makes a wrong derivation fail — a
/// bounds read cannot be satisfied by a second copy of the arithmetic.
///
/// The tolerance is `[0, 2)`: the derivation must never *understate* the bar (a
/// bar placed by a smaller number runs off the canvas edge, which is the defect)
/// and may not overstate it by a gap either. One point of overshoot is real and
/// expected — `TRANSPORT_ROUNDING` is the original's 1 pt guard while GPUI's flex
/// measurement comes out 1 pt wider than the summed children (measured: 1 control
/// derives 53 / lays out at 54, 2 controls 103 / 104, the 14-control set 734 /
/// 735). A derivation that miscounts *any* gap is off by a multiple of 6 pt, so
/// it cannot hide inside this window.
fn transport_width_matches_the_rendered_bar(cx: &mut HeadlessAppContext) {
    let volume = cx.update(|cx| cx.new(|_| SliderState::new().min(0.).max(1.).step(0.01)));

    let labeled: Vec<(&str, Vec<TransportControl>)> = vec![
        ("the product's fourteen-control table", controls(volume.clone(), false)),
        ("the 音量 panel's open bar", controls(volume.clone(), true)),
        // A deliberately divider-heavy set: 音量 also ends a group there, so a
        // derivation that ignores dividers is off by two of them here.
        (
            "a two-divider set",
            {
                let mut rows = controls(volume.clone(), false);
                rows.iter_mut()
                    .find(|row| row.id.as_ref() == "volume")
                    .expect("the 音量 control")
                    .ends_group = true;
                rows
            },
        ),
    ];
    let derived: Vec<f32> = labeled
        .iter()
        .map(|(_, rows)| shell::transport_width(rows))
        .collect();
    let painted = rendered_bar_widths(cx, labeled.iter().map(|(_, rows)| rows.clone()).collect());
    let mut failures: Vec<String> = Vec::new();
    for ((label, _), (derived, painted)) in labeled.iter().zip(derived.iter().zip(painted.iter())) {
        eprintln!("[width] {label}: derived={derived} painted={painted} ({WINDOW:?} canvas)");
        if *painted < *derived || *painted - *derived >= 2. {
            failures.push(format!(
                "{label}: transport_width derived {derived} pt but the bar really lays \
                 out at {painted} pt — the derivation and the render have drifted apart"
            ));
        }
    }
    assert!(
        failures.is_empty(),
        "{} transport width check(s) failed:\n  - {}",
        failures.len(),
        failures.join("\n  - ")
    );
    println!("PASS transport_width: the derivation equals the rendered bar's own rect");
}

/// GPUI's macOS platform must be created on the main thread, so this is a
/// `harness = false` binary test (like `ui_shots`), not a `#[test]`.
fn main() {
    let mut cx = HeadlessAppContext::with_platform(
        gpui_kit::platform::current_platform(true).text_system(),
        // The product registers the whole catalog (`AllAssets`), which is what
        // makes 静音's `volume-x` glyph paint rather than an empty square.
        Arc::new(gpui_kit::assets::AllAssets),
        gpui_kit::platform::current_headless_renderer,
    );
    cx.update(gpui_kit::init);
    let volume = cx.update(|cx| cx.new(|_| SliderState::new().min(0.).max(1.).step(0.01)));

    // The derivation-vs-paint check runs first and on its own: it is the
    // assertion the defective derivation fails, and it must not be reachable
    // only after the popover checks pass.
    transport_width_matches_the_rendered_bar(&mut cx);

    let closed = frame(&mut cx, volume.clone(), false, 0.5);
    let open = frame(&mut cx, volume.clone(), true, 0.5);
    let scale = closed.shot.width() as f32 / f32::from(closed.viewport.width);
    let to_device = |value: Pixels| (f32::from(value) * scale).round() as i32;
    eprintln!(
        "[probe] viewport={:?} bar={:?} shot={}x{} scale={scale}",
        closed.viewport,
        closed.bar,
        closed.shot.width(),
        closed.shot.height()
    );

    // Every check reports together: a bar that is not pinned to the corner and
    // a popover that never appears are two faces of the same defect, and the
    // failure output should show both.
    let mut failures: Vec<String> = Vec::new();

    // 1. The bar is anchored to the canvas' bottom-right corner at its own
    //    content width. This is what leaves the canvas above it drawable; a bar
    //    in flow at the canvas' top (or stretched across the canvas) leaves
    //    nothing above it to paint in.
    let corner = point(closed.viewport.width, closed.viewport.height)
        - point(px(m::TRANSPORT_INSET), px(m::TRANSPORT_INSET));
    if closed.bar.bottom_right() != corner {
        failures.push(format!(
            "the bar must be pinned to the canvas' bottom-right corner {} px in: \
             bar={:?} corner={corner:?} viewport={:?}",
            m::TRANSPORT_INSET,
            closed.bar,
            closed.viewport
        ));
    }
    if closed.bar.size.height != px(m::TRANSPORT_HEIGHT) {
        failures.push(format!(
            "the bar keeps its {} pt height: bar={:?}",
            m::TRANSPORT_HEIGHT,
            closed.bar
        ));
    }
    if !(closed.bar.size.width < closed.viewport.width && closed.bar.origin.x >= px(0.)) {
        failures.push(format!(
            "the bar must be content sized and inside the canvas, not stretched \
             across it: bar={:?} viewport={:?}",
            closed.bar, closed.viewport
        ));
    }

    // 2. Opening the popover must paint ink strictly above the bar's top edge,
    //    inside the canvas. Clipped-away pixels are pixels that never appear.
    let bar_top = to_device(closed.bar.origin.y);
    match diff(&closed.shot, &open.shot) {
        None => failures.push(format!(
            "opening the volume popover painted nothing at all: the panel is not \
             inside the canvas (bar={:?}, viewport={:?})",
            closed.bar, closed.viewport
        )),
        Some((min_x, min_y, max_x, max_y, count)) => {
            eprintln!(
                "[probe] changed bbox=({min_x},{min_y})-({max_x},{max_y}) count={count} \
                 bar_top_device={bar_top}"
            );
            if (min_y as i32) >= bar_top {
                failures.push(format!(
                    "the volume popover must paint above the bar: the changed pixels \
                     start at y={min_y}, not above the bar's top edge {bar_top} \
                     (bar={:?})",
                    closed.bar
                ));
            }
            if (max_y as i32) > bar_top {
                failures.push(format!(
                    "the volume popover must not paint below the bar's top edge: the \
                     changed pixels reach y={max_y} > {bar_top} (bar={:?})",
                    closed.bar
                ));
            }
            if !(max_x < closed.shot.width() && max_y < closed.shot.height()) {
                failures.push(format!(
                    "the changed pixels must be inside the canvas: bbox=({min_x},{min_y})-\
                     ({max_x},{max_y}) shot={}x{}",
                    closed.shot.width(),
                    closed.shot.height()
                ));
            }
            // The panel's bottom edge sits **exactly** one
            // `TRANSPORT_POPOVER_GAP` above the bar's top edge. Its containing
            // block is the bar's own box (the slot spans `TRANSPORT_HEIGHT`), so
            // `bottom = TRANSPORT_HEIGHT + TRANSPORT_POPOVER_GAP` really is
            // measured from the bar's bottom. A slot that stops at the 44 pt
            // control face sits 2 pt inside the bar and lifts the whole panel
            // with it (a 10 pt gap instead of 8), which is what this pins.
            let expected_bottom = bar_top - (shell::TRANSPORT_POPOVER_GAP * scale).round() as i32;
            let painted_bottom = max_y as i32 + 1;
            if painted_bottom != expected_bottom {
                failures.push(format!(
                    "the panel's bottom edge must sit exactly {} pt above the bar's top \
                     ({expected_bottom}); the painted bottom edge is {painted_bottom} \
                     (bbox bottom {max_y}, bar top {bar_top})",
                    shell::TRANSPORT_POPOVER_GAP
                ));
            }
            // The panel is the **vertical card**: as wide as its content column
            // plus padding (the derived token, read back off the painted
            // pixels) and taller than it is wide. The rejected horizontal
            // popover was a 132 pt strip — wider than tall.
            let (width, height) = (max_x - min_x + 1, max_y - min_y + 1);
            let painted_width = width as f32 / scale;
            let painted_height = height as f32 / scale;
            if count <= 500 || width < (40. * scale) as u32 || height < (150. * scale) as u32 {
                failures.push(format!(
                    "the popover must paint a real panel above the bar, painted \
                     {count} px in {width}x{height} (bbox=({min_x},{min_y})-({max_x},{max_y}))"
                ));
            }
            if (painted_width - shell::TRANSPORT_POPOVER_WIDTH).abs() > 1.5 {
                failures.push(format!(
                    "the panel's painted width is {painted_width} pt, not the vertical \
                     card's {} pt (the horizontal strip the person rejected was 132 pt)",
                    shell::TRANSPORT_POPOVER_WIDTH
                ));
            }
            if painted_height <= painted_width {
                failures.push(format!(
                    "音量's panel must be taller than it is wide — a column around a \
                     vertical track — but it painted {painted_width}x{painted_height} pt"
                ));
            }
            let clearance =
                to_device(px(m::TRANSPORT_HEIGHT + shell::TRANSPORT_POPOVER_GAP)) + height as i32;
            if bar_top < clearance {
                failures.push(format!(
                    "the canvas above the bar must fit the bar's height, the gap and \
                     the panel: bar top {bar_top} < {clearance}"
                ));
            }
            if failures.is_empty() {
                println!(
                    "PASS transport_popover_geometry: bar={:?} anchored bottom-right; the open \
                     popover painted {count} px in {width}x{height} at ({min_x},{min_y}) — above \
                     the bar's top edge {bar_top} inside the {}x{} canvas",
                    closed.bar,
                    closed.shot.width(),
                    closed.shot.height()
                );
            }
        }
    }

    // 3. The track's own direction, in pixels. Between a 20% and an 80% level the
    //    **filled** part of a vertical track grows upward, so the changed
    //    rectangle is taller than it is wide; a horizontal slider inside the same
    //    box would repaint a wide, short strip instead. This is why the axis is
    //    asserted here rather than only in `primitives.rs`: it is the painted
    //    result, not the builder flag, that the person sees.
    let low = frame(&mut cx, volume.clone(), true, 0.2);
    let high = frame(&mut cx, volume.clone(), true, 0.8);
    match diff(&low.shot, &high.shot) {
        None => failures.push(
            "dragging 音量 from 20% to 80% painted nothing: the panel is not showing \
             the slider it owns"
                .to_string(),
        ),
        Some((min_x, min_y, max_x, max_y, count)) => {
            let (width, height) = (max_x - min_x + 1, max_y - min_y + 1);
            eprintln!(
                "[probe] volume level 20%→80% changed bbox=({min_x},{min_y})-({max_x},{max_y}) \
                 {width}x{height} count={count}"
            );
            if count < 100 {
                failures.push(format!(
                    "a level change must repaint a real track, not {count} px"
                ));
            }
            if height <= width {
                failures.push(format!(
                    "音量's track is vertical: 20%→80% must paint a taller-than-wide strip, \
                     but it changed {width}x{height} px (a horizontal bar changes a wide, \
                     short one)"
                ));
            }
            if (max_y as i32) >= bar_top {
                failures.push(format!(
                    "the track's fill must stay inside the panel above the bar: changed \
                     pixels reach y={max_y}, bar top {bar_top}"
                ));
            }
        }
    }
    assert!(
        failures.is_empty(),
        "{} transport popover check(s) failed:\n  - {}",
        failures.len(),
        failures.join("\n  - ")
    );
}
