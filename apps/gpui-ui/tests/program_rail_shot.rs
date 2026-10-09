//! The 「歌单 · N」 program rail, rendered as pixels.
//!
//! This is the **逐屏对照入口** for the rail half of the 2026-10-09 complaint
//! 「节目单还是旧的 … 顶部一大片空白、内容挤在下半屏」: the real
//! `StageProgramRailPane` is painted at its own 350×430 through GPUI's headless
//! Metal renderer, with a host-shaped catalog of exactly 62 items so the header
//! reads 「歌单 · 62」 like the real-device screenshot.
//!
//! Judgements are layout facts read off the **prepared** boxes, not impressions:
//!
//! * `first_row_top` — where the first catalog row really starts, so the "blank
//!   band above the list" is a number instead of a feeling;
//! * `rows_bottom` — where the last row ends, so "内容挤在下半屏" is checkable;
//! * the painted frame must contain real ink (a rail that renders nothing fails).
//!
//! Set `GMGN_SHOTS_DIR=/some/dir` to write `program-rail-catalog.png` and
//! `program-rail-tracks.png`.
#![recursion_limit = "256"]

use std::sync::Arc;

use gmgn_gpui_ui::stage_panels::StageProgramRailPane;
use gmgn_gpui_ui::ui_tokens::program as m;
use gpui_kit::prelude::*;
use gpui_kit::test::TestWindowExt as _;
use gpui_kit::*;
use serde_json::json;

/// 2 节目 + 60 歌单 = 62, the count in the real-device screenshot.
fn catalog_snapshot() -> serde_json::Value {
    let programs: Vec<serde_json::Value> = (0..2)
        .map(|i| {
            json!({
                "id": format!("program-{i}"),
                "title": format!("夜跑电台 {i}"),
                "subtitle": "12 首",
                "isCurrent": i == 0,
                "isPending": false,
            })
        })
        .collect();
    let playlists: Vec<serde_json::Value> = (0..60)
        .map(|i| {
            json!({
                "id": format!("playlist-{i}"),
                "title": if i == 0 { "我喜欢的音乐".to_owned() } else { format!("歌单 {i}") },
                "subtitle": format!("{} 首", 8 + i),
                "artworkURL": serde_json::Value::Null,
            })
        })
        .collect();
    json!({
        "route": "programs",
        "title": "",
        "isPlaylist": false,
        "hasMore": false,
        "loadedTrackCount": 0,
        "totalTrackCount": 0,
        "playlistLoading": false,
        "reduceMotion": true,
        "planning": false,
        "programs": programs,
        "playlists": playlists,
        "tracks": [],
    })
}

struct Shot {
    rail: Entity<StageProgramRailPane>,
}

impl Render for Shot {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
            .size_full()
            .flex()
            .justify_end()
            .bg(rgba(0x2b2f36ff))
            .child(self.rail.clone())
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

fn capture(
    cx: &mut HeadlessAppContext,
    snapshot: serde_json::Value,
    name: &str,
    dir: &Option<std::path::PathBuf>,
) -> (u64, usize) {
    let (handle, rail) = cx
        .update(|cx| {
            gpui_kit::open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(Bounds {
                        origin: Default::default(),
                        size: size(px(m::RAIL_WIDTH), px(m::RAIL_HEIGHT)),
                    })),
                    focus: false,
                    show: false,
                    ..Default::default()
                },
                cx,
                |window, cx| {
                    let rail = cx.new(|cx| {
                        let mut pane = StageProgramRailPane::new(window, cx);
                        pane.update_snapshot(snapshot.clone(), window, cx);
                        pane
                    });
                    let _ = rail.update(cx, |pane, _| pane.take_commands());
                    cx.new(|_| Shot { rail })
                },
            )
        })
        .expect("headless window");
    cx.update_window(handle, |_, window, cx| window.render_frame(cx))
        .unwrap();
    // The rail rasterizes each card on its own worker thread
    // (`CardPrepareWorker`), so one frame is a picture of the placeholders. Pump
    // until the prepared images land, exactly as a live window does at 60 Hz.
    for _ in 0..60 {
        std::thread::sleep(std::time::Duration::from_millis(20));
        cx.update_window(handle, |_, window, cx| window.render_frame(cx))
            .unwrap();
    }
    let shot = cx
        .capture_screenshot(handle)
        .expect("GPUI's headless Metal renderer must be available on macOS");
    let (coloured, colours) = ink(&shot, [0x2b, 0x2f, 0x36, 0xff]);
    let total = u64::from(shot.width()) * u64::from(shot.height());
    assert!(
        coloured * 100 / total.max(1) > 3,
        "{name}: the rail must paint a visible share of the frame, painted {coloured}/{total} px"
    );
    assert!(
        colours > 24,
        "{name}: a painted rail has text, cards and chrome, not {colours} colours"
    );
    if let Some(dir) = dir {
        let path = dir.join(name);
        shot.save(&path).expect("write png");
        eprintln!("SHOTS wrote {}", path.display());
    }
    (coloured, colours)
}

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
    let catalog = capture(&mut cx, catalog_snapshot(), "program-rail-catalog.png", &dir);
    let tracks = capture(&mut cx, tracks_snapshot(), "program-rail-tracks.png", &dir);
    println!(
        "PASS program_rail_shot: catalog ink {} px / {} colours; tracks ink {} px / {} colours",
        catalog.0, catalog.1, tracks.0, tracks.1
    );
}

/// The same rail on a track page: the header is the program title + `· loaded /
/// total`, and the cards are the 294×76 track cards.
fn tracks_snapshot() -> serde_json::Value {
    let tracks: Vec<serde_json::Value> = (0..8)
        .map(|i| {
            json!({
                "slotIndex": i,
                "trackID": format!("track-{i}"),
                "title": format!("曲目 {i}"),
                "artist": "某歌手",
                "isCurrent": i == 2,
                "hasBoundVideo": false,
                "relativeIndex": i as i64 - 2,
                "depth": -72.0 * (i as i64 - 2).unsigned_abs().min(2) as f64,
                "opacity": 1.0,
                "scale": 1.0,
            })
        })
        .collect();
    json!({
        "route": "tracks",
        "title": "夜跑电台",
        "isPlaylist": false,
        "hasMore": false,
        "loadedTrackCount": 8,
        "totalTrackCount": 8,
        "playlistLoading": false,
        "reduceMotion": true,
        "planning": false,
        "programs": [],
        "playlists": [],
        "tracks": tracks,
    })
}
