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

use gmgn_gpui_ui::shell::{self, TransportControl};
use gmgn_gpui_ui::ui_tokens::shell as m;
use gpui_kit::assets::IconName;
use gpui_kit::component::slider::{Slider, SliderState};
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
            shell::transport_popover(Slider::new(&volume)).into_any_element()
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

fn frame(cx: &mut HeadlessAppContext, volume: Entity<SliderState>, open: bool) -> Frame {
    let facts = Rc::new(RefCell::new(Facts::default()));
    let state = facts.clone();
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

/// GPUI's macOS platform must be created on the main thread, so this is a
/// `harness = false` binary test (like `ui_shots`), not a `#[test]`.
fn main() {
    let mut cx = HeadlessAppContext::with_platform(
        gpui_kit::platform::current_platform(true).text_system(),
        Arc::new(gpui_kit::assets::Assets),
        gpui_kit::platform::current_headless_renderer,
    );
    cx.update(gpui_kit::init);
    let volume = cx.update(|cx| cx.new(|_| SliderState::new().min(0.).max(1.).step(0.01)));

    let closed = frame(&mut cx, volume.clone(), false);
    let open = frame(&mut cx, volume.clone(), true);
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
            // The panel itself: a 132 pt wide card with a slider in it, not a
            // stray anti-aliased pixel. The bar's own icon highlight is below
            // `bar_top` and is already excluded by the bound above.
            let (width, height) = (max_x - min_x + 1, max_y - min_y + 1);
            if count <= 500 || width < (100. * scale) as u32 || height < (20. * scale) as u32 {
                failures.push(format!(
                    "the popover must paint a real panel above the bar, painted \
                     {count} px in {width}x{height} (bbox=({min_x},{min_y})-({max_x},{max_y}))"
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
    assert!(
        failures.is_empty(),
        "{} transport popover check(s) failed:\n  - {}",
        failures.len(),
        failures.join("\n  - ")
    );
}
