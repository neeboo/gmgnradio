//! 「还有 N 件」 must be a click that changes what is on screen.
//!
//! Measured facts first (2026-10-09, defect 「我的物件的窗口很小，下面的『还有 x 件』
//! 展开不了」):
//!
//! - **Height comes from the shell, not the pane.** The overlay pins the 物品 pane
//!   into `panel_container(content_sized = true, …)` at the window's bottom-right
//!   corner (`shell_ui.rs::panel_container`), capped by
//!   `panel_extent(viewport).1.min(stage::PANEL_MAX_HEIGHT)`; the pane adds its own
//!   `props::PANEL_MAX_HEIGHT`. This harness *is* that container at that viewport,
//!   so every rect below is the panel a user would get.
//! - **The width used to be 190 pt, not 340.** With `max_w` alone the pane
//!   shrink-to-fit inside the shell's `flex_1` content wrapper, and the original's
//!   `widthAnchor.constraint(equalToConstant: 340)` is a width. 190 pt is the
//!   reported 「窗口很小」.
//! - **`remainingCount` is the host side's own statement** (`inventory_ui.rs::project`,
//!   `ROW_BUDGET = 6`): the component only ever draws the rows it is handed, and no
//!   host op asks for the rest.
//! - Nothing below reads a constant back as an answer: the panel rect is the real
//!   prepared-layout bound the overlay traces (`on_children_prepainted`), and a row
//!   is "visible" exactly when GPUI's own content mask left pixels for it
//!   (`ElementSnapshot::visible`, the same fact the accessibility tree has).
//!
//! The regression this pins: the line used to be a `div` with an `.id()` and no
//! click handler, sitting after the last row *inside* the scroll, in a pane whose
//! own 390 pt frame could be taller than the box the shell clips it to. At
//! 720×482/400 that left it below the fold and outside the box: drawn,
//! unreachable, unclickable. It is now a kit `Button` in the panel's fixed footer
//! whose click lifts the frame to the extent the window allows.

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;

use gmgn_gpui_ui::stage_panels::ResidentPropEditorPane;
use gmgn_gpui_ui::ui_tokens::{props as m, shell as metrics, stage};

use gpui_kit::prelude::*;
use gpui_kit::test::{ElementSnapshot, TestWindowExt as _};
use gpui_kit::*;
use serde_json::{Value, json};

/// The lab app's own windowed stage size: the pane's 390 pt body sits in a 374 pt
/// box here (the extent), which is the reported 「窗口很小」.
const REPRO: (f32, f32) = (720., 482.);
/// Narrower still — the box is 292 pt, so a frame taller than the extent puts its
/// own footer outside the clip.
const TIGHT: (f32, f32) = (720., 400.);
/// A viewport with room above the shell's 390 pt body: the extent is 612 and the
/// shell's own ceiling for a non-chat pane is 458, so 「展开」 can really grow.
const ROOMY: (f32, f32) = (1280., 720.);
/// How many rows the projection delivered (the host's budget).
const DELIVERED: usize = 6;
/// The host's own count of withheld rows, stated on the control's face.
const REMAINING: u64 = 3;

fn row(index: usize, group: &str) -> Value {
    json!({
        "id": format!("p{index}"),
        "objectID": format!("obj-{index}"),
        "jobID": null,
        "name": format!("物件{index}"),
        "state": if group == "inInventory" { "inInventory" } else { "placed" },
        "statusText": if group == "inInventory" { "在库里（没摆）" } else { "已摆放" },
        "actions": ["withdraw", "delete"],
        "deviceTemplateID": null
    })
}

/// The shape `inventory_ui.rs::project` publishes when the row budget cuts a
/// nine-row inventory: six rows grouped, three counted as remaining.
fn projection() -> Value {
    json!({
        "isSaving": false,
        "placedOnly": false,
        "canUndo": false,
        "rowCount": 9,
        "remainingCount": REMAINING,
        "holdPoints": [],
        "wallPlacementText": "",
        "notice": "",
        "legend": [],
        "wallFaces": 0,
        "wallPlaceableCells": 0,
        "sections": [
            {"group": "inInventory", "title": "在库里 (3)", "isFolded": false, "rows": [
                row(0, "inInventory"), row(1, "inInventory"), row(2, "inInventory")
            ]},
            {"group": "inRoom", "title": "在房间里 (3)", "isFolded": false, "rows": [
                row(3, "inRoom"), row(4, "inRoom"), row(5, "inRoom")
            ]}
        ],
        "selected": serde_json::Value::Null
    })
}

/// A delivered row's own head control, the element the pane keys it by.
fn row_id(index: usize) -> SharedString {
    format!("props-row-p{index}").into()
}

/// `shell_ui.rs::panel_extent` for the windowed shape, from the live viewport and
/// the shell's own tokens.
fn panel_extent(viewport: Size<Pixels>) -> (f32, f32) {
    (
        (f32::from(viewport.width) - metrics::TRANSPORT_INSET * 2.).max(0.),
        (f32::from(viewport.height) - m::PANEL_VIEWPORT_BOTTOM_BAND).max(0.),
    )
}

/// `shell_ui.rs::panel_container(content_sized = true, …)`: the 物品 pane sizes
/// itself inside this bottom-right pinned, `overflow_hidden` box.
fn panel_container(width: f32, height: f32, bottom_gap: f32) -> Div {
    div()
        .absolute()
        .right(px(metrics::TRANSPORT_INSET))
        .bottom(px(
            metrics::TRANSPORT_INSET + metrics::TRANSPORT_HEIGHT + bottom_gap,
        ))
        .w(px(width))
        .max_h(px(height))
        .flex()
        .flex_col()
        .items_end()
        .justify_end()
        .min_h_0()
        .min_w_0()
        .overflow_hidden()
}

#[derive(Default)]
struct Facts {
    panel: Option<Bounds<Pixels>>,
}

struct Harness {
    pane: Entity<ResidentPropEditorPane>,
    facts: Rc<RefCell<Facts>>,
}

impl Render for Harness {
    fn render(&mut self, window: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        let (panel_width, panel_height) = panel_extent(window.viewport_size());
        let facts = self.facts.clone();
        div().relative().size_full().child(
            panel_container(
                panel_width.min(stage::PANEL_MAX_WIDTH),
                panel_height.min(stage::PANEL_MAX_HEIGHT),
                stage::PROP_EDITOR_BOTTOM_GAP,
            )
            .on_children_prepainted(move |bounds, _, _| {
                facts.borrow_mut().panel = bounds.first().copied();
            })
            .child(
                // `shell_ui.rs::panel_content` as it stands today: the box is
                // pinned to the panel's own width (100 % of the container), not
                // left to size itself from the pane inside it.
                div()
                    .w_full()
                    .flex_1()
                    .min_h_0()
                    .min_w_0()
                    .overflow_hidden()
                    .child(self.pane.clone()),
            ),
        )
    }
}

/// An open window plus the facts its layout reports.
struct Session {
    handle: gpui_kit::AnyWindowHandle,
    facts: Rc<RefCell<Facts>>,
    viewport: Size<Pixels>,
}

/// One read of the frame: the panel's real rect, every delivered row's real rect
/// and visible flag, and the toggle's own snapshot.
struct Probe {
    /// The shell's content box for this pane (`panel_content`), the rect the
    /// overlay itself traces.
    shell_box: Bounds<Pixels>,
    /// The panel card's rect, read off the painted frame: the card is the only
    /// dark surface on the harness' light backdrop, so its bounding box is where
    /// the pane really is. This is the number a person sees, not a style.
    panel: Bounds<Pixels>,
    rows: Vec<(usize, Bounds<Pixels>, bool)>,
    toggle: Option<ElementSnapshot>,
}

impl Probe {
    fn visible_rows(&self) -> Vec<usize> {
        self.rows
            .iter()
            .filter(|(_, _, visible)| *visible)
            .map(|(index, _, _)| *index)
            .collect()
    }
    fn visible_row_count(&self) -> usize {
        self.visible_rows().len()
    }
    fn width(&self) -> f32 {
        f32::from(self.panel.size.width)
    }
    fn height(&self) -> f32 {
        f32::from(self.panel.size.height)
    }
    fn bottom(&self) -> f32 {
        f32::from(self.panel.origin.y) + self.height()
    }
    fn right(&self) -> f32 {
        f32::from(self.panel.origin.x) + self.width()
    }
    fn toggle_label(&self) -> String {
        self.toggle
            .as_ref()
            .and_then(|toggle| toggle.label())
            .unwrap_or("")
            .to_owned()
    }
    fn toggle_visible(&self) -> bool {
        self.toggle.as_ref().is_some_and(|toggle| toggle.visible())
    }
    fn toggle_bottom(&self) -> f32 {
        self.toggle
            .as_ref()
            .map(|toggle| f32::from(toggle.bounds().origin.y) + f32::from(toggle.bounds().size.height))
            .unwrap_or(f32::NAN)
    }
}

/// The panel card's real rect, read off the painted frame. The harness' backdrop
/// is light and the card's `scene::CARD_BG` is the only dark surface, so its
/// bounding box is the panel a person would see. Device pixels ÷ scale.
fn card_box(shot: &image::RgbaImage, scale: f32) -> Bounds<Pixels> {
    let (mut min_x, mut min_y, mut max_x, mut max_y) = (u32::MAX, u32::MAX, 0u32, 0u32);
    for (x, y, pixel) in shot.enumerate_pixels() {
        if pixel[0] < 0x60 && pixel[1] < 0x60 && pixel[2] < 0x60 {
            min_x = min_x.min(x);
            min_y = min_y.min(y);
            max_x = max_x.max(x);
            max_y = max_y.max(y);
        }
    }
    assert!(min_x != u32::MAX, "the panel card must paint something");
    Bounds {
        origin: point(px(min_x as f32 / scale), px(min_y as f32 / scale)),
        size: gpui_kit::size(
            px((max_x - min_x + 1) as f32 / scale),
            px((max_y - min_y + 1) as f32 / scale),
        ),
    }
}

fn open(cx: &mut HeadlessAppContext, bounds: (f32, f32)) -> Session {
    let (width, height) = bounds;
    let facts = Rc::new(RefCell::new(Facts::default()));
    let state = facts.clone();
    let (handle, _) = cx
        .update(|cx| {
            gpui_kit::open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(Bounds {
                        origin: Default::default(),
                        size: gpui_kit::size(px(width), px(height)),
                    })),
                    focus: false,
                    show: false,
                    ..Default::default()
                },
                cx,
                move |window, cx| {
                    let pane = cx.new(|cx| {
                        let mut pane = ResidentPropEditorPane::new(window, cx);
                        pane.update_snapshot(projection(), window, cx);
                        pane
                    });
                    let _ = pane.update(cx, |pane, _| pane.take_commands());
                    cx.new(|_| Harness {
                        pane,
                        facts: state,
                    })
                },
            )
        })
        .expect("headless window");
    let viewport = cx
        .update_window(handle, |_, window, _| window.viewport_size())
        .unwrap();
    Session {
        handle,
        facts,
        viewport,
    }
}

fn probe(cx: &mut HeadlessAppContext, session: &Session) -> Probe {
    let shot = shot(cx, session);
    let scale = shot.width() as f32 / f32::from(session.viewport.width);
    let panel = card_box(&shot, scale);
    let (shell_box, rows, toggle) = cx
        .update_window(session.handle, |_, window, cx| {
            window.render_frame(cx);
            let shell_box = session
                .facts
                .borrow()
                .panel
                .expect("the 物品 pane must be laid out");
            let rows = (0..DELIVERED)
                .map(|index| {
                    let snapshot = window
                        .try_find(row_id(index))
                        .unwrap_or_else(|| panic!("row {index} must be observed"));
                    (index, snapshot.bounds(), snapshot.visible())
                })
                .collect();
            (shell_box, rows, window.try_find("props-remaining-toggle"))
        })
        .unwrap();
    Probe {
        shell_box,
        panel,
        rows,
        toggle,
    }
}

fn shot(cx: &mut HeadlessAppContext, session: &Session) -> image::RgbaImage {
    cx.update_window(session.handle, |_, window, cx| {
        window.render_frame(cx);
    })
    .unwrap();
    cx.capture_screenshot(session.handle)
        .expect("GPUI's headless Metal renderer must be available on macOS")
}

fn click_toggle(cx: &mut HeadlessAppContext, session: &Session) {
    cx.update_window(session.handle, |_, window, cx| {
        window.click("props-remaining-toggle", cx);
    })
    .unwrap();
}

/// One wheel gesture over a row inside the list's scroll region.
fn wheel(cx: &mut HeadlessAppContext, session: &Session, target: SharedString, dy: f32) {
    cx.update_window(session.handle, |_, window, cx| {
        window.scroll(target, gpui_kit::ScrollDelta::Pixels(point(px(0.), px(dy))), cx);
    })
    .unwrap();
}

fn save(image: &image::RgbaImage, path: &str) {
    image.save(path).unwrap_or_else(|e| panic!("write {path}: {e}"));
    println!("SHOT {path} {}x{}", image.width(), image.height());
}

/// Scroll the list's one scroll region until the last delivered row is on
/// screen. The wheel goes to a row that is visible *at that moment*: the target
/// is re-read every step, because a scroll can carry the previous one away.
fn reach_last_row(cx: &mut HeadlessAppContext, session: &Session) -> (bool, Vec<usize>) {
    let mut visible = probe(cx, session).visible_rows();
    for _ in 0..12 {
        if visible.contains(&(DELIVERED - 1)) {
            return (true, visible);
        }
        let Some(target) = visible.get(visible.len() / 2).map(|index| row_id(*index)) else {
            return (false, visible);
        };
        wheel(cx, session, target, -240.);
        visible = probe(cx, session).visible_rows();
    }
    (visible.contains(&(DELIVERED - 1)), visible)
}

fn main() {
    let mut cx = HeadlessAppContext::with_platform(
        gpui_kit::platform::current_platform(true).text_system(),
        Arc::new(gpui_kit::assets::Assets),
        gpui_kit::platform::current_headless_renderer,
    );
    cx.update(gpui_kit::init);
    let mut failures: Vec<String> = Vec::new();

    // ---- The reproduced window and the narrower one: the frame must fit the box
    // the shell clips it to, the footer must be painted inside it, and the
    // 「还有 N 件」 face must be a control that really toggles. -----------------
    for (name, size) in [("720×482 (repro)", REPRO), ("720×400 (tight)", TIGHT)] {
        let session = open(&mut cx, size);
        let extent = panel_extent(session.viewport).1.min(stage::PANEL_MAX_HEIGHT);
        let collapsed = probe(&mut cx, &session);
        println!(
            "MEASURE {name}: viewport={}×{} shell_cap={:.0}\n  collapsed shell_box={:?} painted_card={}×{} at x={} y={} rows_visible={:?}\n  toggle label={:?} visible={} toggle_bottom={} panel_bottom={}",
            f32::from(session.viewport.width),
            f32::from(session.viewport.height),
            extent,
            collapsed.shell_box,
            collapsed.width(),
            collapsed.height(),
            f32::from(collapsed.panel.origin.x),
            f32::from(collapsed.panel.origin.y),
            collapsed.visible_rows(),
            collapsed.toggle_label(),
            collapsed.toggle_visible(),
            collapsed.toggle_bottom(),
            collapsed.bottom(),
        );

        // The original's `widthAnchor.constraint(equalToConstant: 340)` is the
        // panel's width, not a ceiling it never reaches (measured before the fix:
        // 190 pt, which is the reported 「窗口很小」).
        if (collapsed.width() - m::PANEL_WIDTH).abs() > 0.5 {
            failures.push(format!(
                "{name}: the panel must be the original's {} pt wide, was {} pt",
                m::PANEL_WIDTH,
                collapsed.width()
            ));
        }
        // The control exists, is painted, and states the host's own count.
        if !collapsed.toggle_visible() {
            failures.push(format!("{name}: 「还有 N 件」 must be painted, not clipped"));
        }
        let label = collapsed.toggle_label();
        if !label.contains(&format!("还有 {REMAINING} 件")) {
            failures.push(format!(
                "{name}: the control must carry the host's count, label={label:?}"
            ));
        }
        if !label.contains("展开列表") {
            failures.push(format!(
                "{name}: the collapsed control must offer 展开列表, label={label:?}"
            ));
        }
        // It is the frame's own footer, so it can never be clipped by the box the
        // shell gives the pane — being below the fold *and* outside that box is
        // what made the old line unclickable.
        if collapsed.toggle_bottom() > collapsed.bottom() + 0.5 {
            failures.push(format!(
                "{name}: the footer at {} must be inside the panel's bottom {}",
                collapsed.toggle_bottom(),
                collapsed.bottom()
            ));
        }
        if collapsed.height() > extent + 0.5 {
            failures.push(format!(
                "{name}: the frame {} must not exceed the shell's cap {extent}",
                collapsed.height()
            ));
        }
        // The original's corner, read off the painted card: trailing ==
        // transportControls.trailing and bottom == transportControls.top - 12
        // (`StageWindowController.swift:1521-1523`). A 100 %-wide shell box must
        // not leave the card anywhere else.
        let corner_right = f32::from(session.viewport.width) - metrics::TRANSPORT_INSET;
        if (collapsed.right() - corner_right).abs() > 1.0 {
            failures.push(format!(
                "{name}: the panel's trailing edge {} must sit on the transport bar's {corner_right}",
                collapsed.right()
            ));
        }
        let corner_bottom = f32::from(session.viewport.height)
            - metrics::TRANSPORT_INSET
            - metrics::TRANSPORT_HEIGHT
            - stage::PROP_EDITOR_BOTTOM_GAP;
        if (collapsed.bottom() - corner_bottom).abs() > 1.0 {
            failures.push(format!(
                "{name}: the panel's bottom {} must sit {} above the transport bar's top {corner_bottom}",
                collapsed.bottom(),
                stage::PROP_EDITOR_BOTTOM_GAP
            ));
        }

        // ---- The click, read at the same scroll offset as the collapsed probe.
        click_toggle(&mut cx, &session);
        let expanded = probe(&mut cx, &session);
        println!(
            "  expanded panel={}×{} rows_visible={:?} toggle label={:?} visible={} toggle_bottom={}",
            expanded.width(),
            expanded.height(),
            expanded.visible_rows(),
            expanded.toggle_label(),
            expanded.toggle_visible(),
            expanded.toggle_bottom(),
        );
        if !expanded.toggle_label().contains("收起列表") {
            failures.push(format!(
                "{name}: one click must flip the control to 收起列表, label={:?}",
                expanded.toggle_label()
            ));
        }
        if expanded.height() > extent + 0.5 {
            failures.push(format!(
                "{name}: the expanded frame {} must stay inside the shell's cap {extent}",
                expanded.height()
            ));
        }
        if !expanded.toggle_visible() || expanded.toggle_bottom() > expanded.bottom() + 0.5 {
            failures.push(format!(
                "{name}: the expanded control must stay inside the frame (bottom {} vs panel {})",
                expanded.toggle_bottom(),
                expanded.bottom()
            ));
        }
        if expanded.height() < collapsed.height() {
            failures.push(format!(
                "{name}: expanding must not shrink the frame ({} -> {})",
                collapsed.height(),
                expanded.height()
            ));
        }

        // ---- 收起 restores exactly the frame and the rows it started from.
        click_toggle(&mut cx, &session);
        let restored = probe(&mut cx, &session);
        if restored.visible_rows() != collapsed.visible_rows() {
            failures.push(format!(
                "{name}: 收起 must restore the visible rows {:?}, got {:?}",
                collapsed.visible_rows(),
                restored.visible_rows()
            ));
        }
        if (restored.height() - collapsed.height()).abs() > 0.5 {
            failures.push(format!(
                "{name}: 收起 must restore the frame height {}, got {}",
                collapsed.height(),
                restored.height()
            ));
        }
        if !restored.toggle_label().contains("展开列表") {
            failures.push(format!(
                "{name}: 收起 must restore the 展开列表 label, got {:?}",
                restored.toggle_label()
            ));
        }

        // ---- The one list scroll really reaches the last delivered row, and the
        // footer stays out of that scroll while it happens.
        let (reached, visible) = reach_last_row(&mut cx, &session);
        if !reached {
            failures.push(format!(
                "{name}: the last delivered row must be reachable in the one scroll, rows_visible={visible:?}"
            ));
        }
        let scrolled = probe(&mut cx, &session);
        if !scrolled.toggle_visible() {
            failures.push(format!("{name}: the footer must survive scrolling the list"));
        }
        if !scrolled.toggle_label().contains("展开列表") {
            failures.push(format!(
                "{name}: scrolling must not reset the control, got {:?}",
                scrolled.toggle_label()
            ));
        }
    }

    // ---- A viewport with room above the original's 390 pt body: the click must
    // really put more rows on screen, and the frame must grow to it. -----------
    let session = open(&mut cx, ROOMY);
    let collapsed = probe(&mut cx, &session);
    save(&shot(&mut cx, &session), "/tmp/props-collapsed.png");
    click_toggle(&mut cx, &session);
    let expanded = probe(&mut cx, &session);
    save(&shot(&mut cx, &session), "/tmp/props-expanded.png");
    println!(
        "MEASURE 1280×720 (roomy): collapsed {}×{} rows={:?} -> expanded {}×{} rows={:?}",
        collapsed.width(),
        collapsed.height(),
        collapsed.visible_rows(),
        expanded.width(),
        expanded.height(),
        expanded.visible_rows(),
    );
    if expanded.visible_row_count() <= collapsed.visible_row_count() {
        failures.push(format!(
            "1280×720: the click must put more rows on screen ({} -> {})",
            collapsed.visible_row_count(),
            expanded.visible_row_count()
        ));
    }
    if expanded.height() <= collapsed.height() {
        failures.push(format!(
            "1280×720: the click must grow the frame ({} -> {})",
            collapsed.height(),
            expanded.height()
        ));
    }
    if expanded.height() > stage::PANEL_MAX_HEIGHT + 0.5 {
        failures.push(format!(
            "1280×720: the frame {} must not exceed the shell's ceiling {}",
            expanded.height(),
            stage::PANEL_MAX_HEIGHT
        ));
    }
    // The frame grew onto the *next* rows, in order: the same rows are still on
    // screen and the ones below them now are too.
    if !expanded.visible_rows().starts_with(&collapsed.visible_rows()) {
        failures.push(format!(
            "1280×720: expanding must keep the rows it showed and add the next ones ({:?} -> {:?})",
            collapsed.visible_rows(),
            expanded.visible_rows()
        ));
    }
    // 「展开后能滚动看完」: in the expanded frame the one scroll still reaches the
    // last delivered row, and the footer is untouched by that scroll.
    let (reached, visible) = reach_last_row(&mut cx, &session);
    if !reached {
        failures.push(format!(
            "1280×720: the expanded list must scroll to the last delivered row, rows_visible={visible:?}"
        ));
    }
    let scrolled = probe(&mut cx, &session);
    if !scrolled.toggle_visible() || !scrolled.toggle_label().contains("收起列表") {
        failures.push(format!(
            "1280×720: the footer must survive scrolling the expanded list, label={:?}",
            scrolled.toggle_label()
        ));
    }

    if failures.is_empty() {
        println!("PASS props_remaining_toggle");
    } else {
        for failure in &failures {
            eprintln!("FAIL {failure}");
        }
        panic!("{} 「还有 N 件」 assertions failed", failures.len());
    }
}
