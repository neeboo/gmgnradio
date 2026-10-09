//! Renders the reworked 「我的物件」 pane to a PNG through GPUI's headless Metal
//! renderer.
//!
//! Why this exists: the window-server path (`screencapture` of a launched lab
//! app) is unavailable in this environment, so the visual check goes through the
//! same headless render the existing `ui_shots` harness uses — the **real**
//! `ResidentPropEditorPane`, driven by a host-shaped projection, is painted into
//! an RGBA image.
//!
//! What the two frames are for (2026-10-09 「基础物品也是物品，不能删除而已，也是放在房间里」):
//!
//! - `props-list.png`: one list. 音乐播放器 (a placed built-in device) sits in the
//!   same 在房间里 group, with the same row shape and status words as the
//!   generated props, and its row carries **no** 删除 action; 许愿机 is in
//!   在库里（没摆）. The panel title is the current scope (我的物件), not the old
//!   fixed 摆放.
//! - `props-device-selected.png`: the selected 音乐播放器 shows exactly the one
//!   operation the world authority takes for a device (摆放 / 重新摆放) and no
//!   删除 entry at all.
//!
//! The projection fields are the ones `inventory_ui.rs` publishes (that adapter's
//! own tests pin the shape); nothing here invents a host fact.
//!
//! It is also a regression: each frame must contain real painted content (more
//! than one colour, a meaningful share of non-background pixels).
//!
//! Set `GMGN_SHOTS_DIR=/some/dir` to write both PNGs there.
#![recursion_limit = "256"]

use std::sync::Arc;

use gmgn_gpui_ui::stage_panels::ResidentPropEditorPane;

use gpui_kit::prelude::*;
use gpui_kit::test::TestWindowExt as _;
use gpui_kit::*;
use serde_json::json;

/// The projection the adapter builds from the Unity host's facts: the same
/// sections/groups/status words for objects and for the world's own devices.
fn projection(
    placed_only: bool,
    selected: Option<serde_json::Value>,
    only_the_device_row: bool,
) -> serde_json::Value {
    let mut snapshot = json!({
        "isSaving": false,
        "placedOnly": placed_only,
        "canUndo": false,
        "remainingCount": 0,
        "holdPoints": [],
        "wallPlacementText": "",
        "notice": "",
        "sections": if only_the_device_row {
            json!([
                {"group": "inRoom", "title": "在房间里 (1)", "isFolded": false, "rows": [
                    {"id": "device:prop.jukebox", "objectID": "prop.jukebox", "jobID": null,
                     "name": "音乐播放器", "state": "placed", "statusText": "已摆放",
                     "actions": ["place"], "deviceTemplateID": "prop.jukebox"}
                ]}
            ])
        } else {
            json!([
                {"group": "inInventory", "title": "在库里 (1)", "isFolded": false, "rows": [
                    {"id": "device:wish_machine.device", "objectID": "wish_machine.device", "jobID": null,
                     "name": "许愿机", "state": "inInventory", "statusText": "在库里（没摆）",
                     "actions": ["place"], "deviceTemplateID": "wish_machine.device"}
                ]},
                {"group": "inRoom", "title": "在房间里 (2)", "isFolded": false, "rows": [
                    {"id": "object:prop-placed", "objectID": "prop-placed", "jobID": null, "name": "落地灯",
                     "state": "placed", "statusText": "已摆放",
                     "actions": ["withdraw", "delete"], "deviceTemplateID": null},
                    {"id": "device:prop.jukebox", "objectID": "prop.jukebox", "jobID": null,
                     "name": "音乐播放器", "state": "placed", "statusText": "已摆放",
                     "actions": ["place"], "deviceTemplateID": "prop.jukebox"}
                ]},
                {"group": "ended", "title": "已结束 (1)", "isFolded": true, "rows": []}
            ])
        },
        "legend": [],
        "wallFaces": 0,
        "wallPlaceableCells": 0
    });
    snapshot["selected"] = selected.unwrap_or(serde_json::Value::Null);
    snapshot
}

struct Shot {
    pane: Entity<ResidentPropEditorPane>,
}

impl Render for Shot {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        // The layer's own dark backdrop, so the panel's card, hairlines and rows
        // are the only content in the frame.
        div()
            .size_full()
            .bg(rgba(0x2b2f36ff))
            .p(px(12.))
            .child(self.pane.clone())
    }
}

fn ink(image: &image::RgbaImage, background: [u8; 4]) -> (u64, usize) {
    let mut coloured = 0u64;
    let mut seen: std::collections::HashSet<[u8; 4]> = std::collections::HashSet::new();
    for pixel in image.pixels() {
        let value = [pixel[0], pixel[1], pixel[2], pixel[3]];
        if value != background {
            coloured += 1;
        }
        if seen.len() < 4096 {
            seen.insert(value);
        }
    }
    (coloured, seen.len())
}

/// Renders one projection into an RGBA frame and (optionally) writes the PNG.
fn capture(cx: &mut HeadlessAppContext, snapshot: serde_json::Value, name: &str, dir: &Option<std::path::PathBuf>) -> (u64, usize, u64) {
    let (width, height) = (360., 640.);
    let (handle, _) = cx
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
                |window, cx| {
                    let pane = cx.new(|cx| {
                        let mut pane = ResidentPropEditorPane::new(window, cx);
                        pane.update_snapshot(snapshot.clone(), window, cx);
                        pane
                    });
                    let _ = pane.update(cx, |pane, _| pane.take_commands());
                    cx.new(|_| Shot { pane })
                },
            )
        })
        .expect("headless window");
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
    })
    .unwrap();
    let shot = cx
        .capture_screenshot(handle)
        .expect("GPUI's headless Metal renderer must be available on macOS");
    let (coloured, colours) = ink(&shot, [0x2b, 0x2f, 0x36, 0xff]);
    let total = u64::from(shot.width()) * u64::from(shot.height());
    assert!(
        coloured * 100 / total.max(1) > 3,
        "{name}: the panel must cover a visible share of the frame, painted {coloured}/{total} px"
    );
    assert!(
        colours > 24,
        "{name}: a painted panel has text, icons and chrome, not {colours} colours"
    );
    if let Some(dir) = dir {
        let path = dir.join(name);
        shot.save(&path).expect("write png");
        eprintln!("SHOTS wrote {}", path.display());
    }
    (coloured, colours, total)
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
    let dir = std::env::var_os("GMGN_SHOTS_DIR").map(std::path::PathBuf::from);
    if let Some(dir) = &dir {
        std::fs::create_dir_all(dir).expect("shots dir");
    }

    let list = capture(&mut cx, projection(false, None, false), "props-list.png", &dir);
    let selected = capture(
        &mut cx,
        projection(
            false,
            Some(json!({
                "objectID": "prop.jukebox", "name": "音乐播放器", "held": false,
                "enabled": true, "deviceTemplateID": "prop.jukebox", "holdPoint": "hand"
            })),
            true,
        ),
        "props-device-selected.png",
        &dir,
    );
    println!(
        "PASS props_pane_shot: list painted {}/{} px ({} colours); device-selected painted {}/{} px ({} colours)",
        list.0, list.2, list.1, selected.0, selected.2, selected.1
    );
}
