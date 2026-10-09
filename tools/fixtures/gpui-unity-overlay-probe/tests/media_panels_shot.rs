//! 逐屏视觉对照入口 — every panel of this overlay layer, painted for real.
//!
//! Why: the 2026-10-09 complaint batch was all about **what you see when you
//! open the app** (「节目单还是旧的」「电视面板很难看」). A number in a unit test
//! cannot answer that, and `screencapture`/synthetic input are both forbidden
//! here. So this harness mounts the **real** `MediaPane` (the same entity the
//! Unity overlay mounts, not a mock) at the panel's own 590×458, feeds it a
//! fixed host-shaped projection, and writes the RGBA frame GPUI's headless Metal
//! renderer produces.
//!
//! Frames written (set `GMGN_SHOTS_DIR`):
//!
//! * `media-tv.png`             — the 电视 section with a playing screen whose
//!                                host playlist is 2/10 at 1:23 / 4:05;
//! * `media-tv-empty.png`       — the 电视 section with no screen in the space;
//! * `media-program-catalog.png`— the 音乐与节目 section with the 62-item catalog
//!                                the real-device screenshot showed.
//!
//! Every frame is a judgement too: it must carry real ink and more than a
//! couple of colours, so a panel that regresses to a blank card fails here.
//! `scene::SELECTED` pixels are counted for the frames whose subject is a
//! selected/playing state.
#![recursion_limit = "256"]

use std::sync::Arc;

use gmgn_gpui_overlay_probe::UiCommandQueue;
use gmgn_gpui_overlay_probe::media_ui::MediaPane;
use gpui_kit::prelude::*;
use gpui_kit::test::TestWindowExt as _;
use gpui_kit::*;
use serde_json::json;

/// The overlay panel's own box (`shell_ui::panel_container(false, 590., 458., …)`).
const PANEL: (f32, f32) = (590., 458.);

struct Shot {
    pane: Entity<MediaPane>,
}

impl Render for Shot {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
            .size_full()
            .bg(rgba(0x2b2f36ff))
            .p(px(10.))
            .child(self.pane.clone())
    }
}

fn catalog() -> (Vec<serde_json::Value>, Vec<serde_json::Value>) {
    let programs: Vec<serde_json::Value> = (0..2)
        .map(|i| {
            // Host shape: `UnityDJProgramBridge` publishes name/count/active.
            json!({
                "id": format!("program-{i}"),
                "name": format!("夜跑电台 {i}"),
                "count": 12,
                "active": i == 0,
                "pending": false,
                "activeSlotIndex": 0,
                "tracks": [],
            })
        })
        .collect();
    let playlists: Vec<serde_json::Value> = (0..60)
        .map(|i| {
            // Host shape: `UnityMusicLibraryBridge` publishes name/provider/count.
            json!({
                "id": format!("playlist-{i}"),
                "name": if i == 0 { "我喜欢的音乐".to_owned() } else { format!("歌单 {i}") },
                "provider": if i % 2 == 0 { "netease" } else { "qq-music" },
                "count": 8 + i,
                "artworkURL": serde_json::Value::Null,
            })
        })
        .collect();
    (programs, playlists)
}

/// A host-shaped snapshot: only keys `UnityMediaHost` really publishes.
fn snapshot(with_screen: bool) -> serde_json::Value {
    let (programs, playlists) = catalog();
    let screens = if with_screen {
        json!([{"objectID": "tv", "name": "客厅电视", "state": "播放中 · 播放列表 2/10", "playing": true}])
    } else {
        json!([])
    };
    let video_screens = if with_screen {
        json!([{
            "objectID": "tv", "state": "播放中",
            "currentSeconds": 83.0, "durationSeconds": 245.0,
            "playbackRate": 1, "timeControlStatus": "playing",
            "decodedFrames": 4096, "playbackEndCount": 1, "isLive": false,
            "playlistIndex": 1, "playlistCount": 10, "playlistRevision": 3
        }])
    } else {
        json!([])
    };
    json!({
        "world": {"worldID": "shot-world"},
        "music": {"queueIndex": 0, "queue": []},
        "musicLibrary": {
            "programs": programs,
            "playlists": playlists,
            "playlistID": null,
            "name": null,
            "loaded": 0,
            "total": 0,
            "tracks": [],
            "currentTrackID": null,
        },
        "inbox": {"status": "completed", "pending": false, "entries": []},
        "wish": {"status": "completed", "pending": false, "entries": []},
        "screenVideo": {
            "screens": screens,
            "commandNotice": "",
            "video": {"screens": video_screens, "pendingBoundVideo": null},
        },
    })
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

/// Pixels carrying the overlay's pinned selected blue, `scene::SELECTED`.
fn selected_blue(image: &image::RgbaImage) -> u64 {
    image
        .pixels()
        .filter(|pixel| {
            let (r, g, b) = (i32::from(pixel[0]), i32::from(pixel[1]), i32::from(pixel[2]));
            (r - 0x3b).abs() <= 10 && (g - 0x9e).abs() <= 10 && (b - 0xff).abs() <= 10
        })
        .count() as u64
}

fn capture(
    cx: &mut HeadlessAppContext,
    section: &str,
    with_screen: bool,
    name: &str,
    dir: &Option<std::path::PathBuf>,
) -> (u64, usize, u64) {
    let (handle, _shot) = cx
        .update(|cx| {
            let commands: UiCommandQueue = std::rc::Rc::new(std::cell::RefCell::new(
                std::collections::VecDeque::new(),
            ));
            gpui_kit::open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(Bounds {
                        origin: Default::default(),
                        size: size(px(PANEL.0), px(PANEL.1)),
                    })),
                    focus: false,
                    show: false,
                    ..Default::default()
                },
                cx,
                move |window, cx| {
                    let commands = commands.clone();
                    let pane = cx.new(|cx| {
                        let mut pane = MediaPane::new(window, cx, commands);
                        pane.select_section(section, cx);
                        pane.update_snapshot(&snapshot(with_screen), window, cx);
                        pane
                    });
                    cx.new(|_| Shot { pane })
                },
            )
        })
        .expect("headless media window");
    // The rail rasterizes each card on its own worker (`CardPrepareWorker`), so
    // the first frames are placeholders; pump like a live window does at 60 Hz.
    for _ in 0..200 {
        cx.update_window(handle, |_, window, cx| window.render_frame(cx))
            .unwrap();
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    let shot = cx
        .capture_screenshot(handle)
        .expect("GPUI's headless Metal renderer must be available on macOS");
    let (coloured, colours) = ink(&shot, [0x2b, 0x2f, 0x36, 0xff]);
    let total = u64::from(shot.width()) * u64::from(shot.height());
    assert!(
        coloured * 100 / total.max(1) > 5,
        "{name}: the panel must cover a visible share of the frame, painted {coloured}/{total} px"
    );
    assert!(
        colours > 24,
        "{name}: a painted panel has text, icons and chrome, not {colours} colours"
    );
    let selected = selected_blue(&shot);
    if let Some(dir) = dir {
        let path = dir.join(name);
        shot.save(&path).expect("write png");
        eprintln!("SHOTS wrote {} (selected-blue {selected} px)", path.display());
    }
    (coloured, colours, selected)
}

fn main() {
    let mut cx = HeadlessAppContext::with_platform(
        gpui_kit::platform::current_platform(true).text_system(),
        Arc::new(gpui_kit::assets::Assets),
        gpui_kit::platform::current_headless_renderer,
    );
    cx.update(gpui_kit::init);
    // The probe's real mount changes the kit theme to dark
    // (`gmgn_gpui_probe_mount` → `Theme::change(ThemeMode::Dark, None, cx)`);
    // without it the kit `Input` paints its light-theme chrome and the frame is
    // not a picture of the shipping panel.
    cx.update(|cx| {
        gpui_kit::component::Theme::change(gpui_kit::component::ThemeMode::Dark, None, cx)
    });
    let dir = std::env::var_os("GMGN_SHOTS_DIR").map(std::path::PathBuf::from);
    if let Some(dir) = &dir {
        std::fs::create_dir_all(dir).expect("shots dir");
    }
    let tv = capture(&mut cx, "screen", true, "media-tv.png", &dir);
    let empty = capture(&mut cx, "screen", false, "media-tv-empty.png", &dir);
    let catalog = capture(&mut cx, "programs", true, "media-program-catalog.png", &dir);
    println!(
        "PASS media_panels_shot: tv ink {}/{} colours/{} selected-blue; tv-empty ink {}/{}; \
         catalog ink {}/{}",
        tv.0, tv.1, tv.2, empty.0, empty.1, catalog.0, catalog.1
    );
}
