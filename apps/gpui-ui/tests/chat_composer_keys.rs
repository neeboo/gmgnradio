//! The composer's system text shortcuts, as **behaviour**, through the real
//! `ResidentChatPane` and the real kit `Textarea`.
//!
//! Why this exists (user report, 2026-10-09: 「聊天框不支持粘贴」): the 粘贴
//! complaint had no failing judgement anywhere in this repo. The existing
//! harnesses render pixels or read style values; none of them press ⌘V and look
//! at the field. This test does exactly that, and while it is here it pins the
//! whole family the report implies — 剪切 / 复制 / 全选 / 撤销 / 重做 — so a fix
//! for one of them cannot leave the others silently dead.
//!
//! Every judgement is a real key press against the real focus path and a read of
//! the real `TextareaState`/clipboard, so undoing the wiring (dropping
//! `Textarea`'s paste handler, forgetting `gpui_kit::init`'s key bindings,
//! breaking focus) turns a line red.
//!
//! **Why every step is its own window update**: GPUI flushes the emit queue when
//! the window borrow is released, so an assertion written inside the same
//! `update_window` that dispatched the key reads the *pre-flush* state. An
//! earlier draft of this test did that and saw an empty draft even though the
//! `Change` events were really delivered — the reads have to happen after the
//! step, which is also how the shipping host observes them (it reads the pane on
//! its next frame, not inside the keystroke).
//!
//! There is **no synthetic input** here: `window.press` is gpui-kit's test
//! bridge, which dispatches the same `Keystroke`/action path the native view
//! generates. The forbidden things (`CGEvent`, AX, osascript) are not used.

use gmgn_gpui_ui::chat::ResidentChatPane;
use gpui_kit::{
    App, AppContext, Bounds, ClipboardItem, Context, Entity, Point, Render, TestAppContext, Window,
    WindowBounds, WindowHandle, WindowOptions, base::Root, div, prelude::*, px, size,
    test::TestWindowExt,
};

struct Harness {
    pane: Entity<ResidentChatPane>,
}

impl Render for Harness {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().size_full().child(self.pane.clone())
    }
}

fn mount(
    cx: &mut TestAppContext,
) -> (WindowHandle<Root>, Entity<Harness>, Entity<ResidentChatPane>) {
    cx.update(gpui_kit::init);
    cx.update(|cx| {
        let (handle, harness) = gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds {
                    origin: Point::default(),
                    size: size(px(620.), px(420.)),
                })),
                focus: false,
                show: false,
                ..Default::default()
            },
            cx,
            |window, cx| {
                let pane = cx.new(|cx| ResidentChatPane::new(window, cx));
                cx.new(|_| Harness { pane })
            },
        )
        .expect("open test window");
        let pane = harness.read(cx).pane.clone();
        (handle.downcast::<Root>().expect("Base Root"), harness, pane)
    })
}

/// Focus the composer and let the frame settle, **outside** the update that
/// dispatches keys, so the focus path is built before anything is pressed.
fn focus(cx: &mut TestAppContext, handle: WindowHandle<Root>, pane: &Entity<ResidentChatPane>) {
    cx.update_window(handle.into(), |_, window, cx| {
        pane.update(cx, |pane, cx| pane.focus_composer(window, cx));
        window.render_frame(cx);
    })
    .unwrap();
}

/// One real key press, flushed.
fn press(cx: &mut TestAppContext, handle: WindowHandle<Root>, key: &str) {
    cx.update_window(handle.into(), |_, window, cx| window.press(key, cx))
        .unwrap();
}

/// One real text input, flushed.
fn type_text(cx: &mut TestAppContext, handle: WindowHandle<Root>, text: &str) {
    cx.update_window(handle.into(), |_, window, cx| window.input(text, cx))
        .unwrap();
}

fn clipboard(cx: &mut TestAppContext, value: &str) {
    cx.update(|cx| cx.write_to_clipboard(ClipboardItem::new_string(value.to_owned())));
}

fn read_clipboard(cx: &mut TestAppContext) -> Option<String> {
    cx.update(|cx| cx.read_from_clipboard().and_then(|item| item.text()))
}

/// The press a Mac sends for ⌘V / ⌘C / ⌘X / ⌘A / ⌘Z / ⇧⌘Z. Named once so the
/// platform branch is not repeated (and cannot drift) across the assertions.
fn chord(key: &str) -> &'static str {
    match key {
        "paste" => {
            if cfg!(target_os = "macos") {
                "cmd-v"
            } else {
                "ctrl-v"
            }
        }
        "copy" => {
            if cfg!(target_os = "macos") {
                "cmd-c"
            } else {
                "ctrl-c"
            }
        }
        "cut" => {
            if cfg!(target_os = "macos") {
                "cmd-x"
            } else {
                "ctrl-x"
            }
        }
        "select-all" => {
            if cfg!(target_os = "macos") {
                "cmd-a"
            } else {
                "ctrl-a"
            }
        }
        "undo" => {
            if cfg!(target_os = "macos") {
                "cmd-z"
            } else {
                "ctrl-z"
            }
        }
        "redo" => {
            if cfg!(target_os = "macos") {
                "cmd-shift-z"
            } else {
                "ctrl-y"
            }
        }
        other => panic!("unknown chord {other}"),
    }
}

#[gpui_kit::test]
fn composer_paste_puts_the_clipboard_into_the_real_field_and_the_draft(cx: &mut TestAppContext) {
    let (handle, _harness, pane) = mount(cx);
    focus(cx, handle, &pane);
    assert!(
        cx.update(|cx| pane.read(cx).composer_text(cx)).is_empty(),
        "the composer starts empty"
    );
    // The reporter's exact complaint: 粘贴 does nothing.
    clipboard(cx, "粘进来的一段话");
    press(cx, handle, chord("paste"));
    assert_eq!(
        cx.update(|cx| pane.read(cx).composer_text(cx)),
        "粘进来的一段话",
        "⌘V must insert the clipboard text into the composer field"
    );
    assert_eq!(
        cx.update(|cx| pane.read(cx).draft().to_owned()),
        "粘进来的一段话",
        "⌘V must also reach the draft the send path reads — text that is visible \
         but not in the draft makes the 发送 control refuse it"
    );
}

#[gpui_kit::test]
fn composer_select_copy_cut_undo_and_redo_are_all_live(cx: &mut TestAppContext) {
    let (handle, _harness, pane) = mount(cx);
    focus(cx, handle, &pane);
    type_text(cx, handle, "一二三四");
    assert_eq!(cx.update(|cx| pane.read(cx).composer_text(cx)), "一二三四");
    assert_eq!(
        cx.update(|cx| pane.read(cx).draft().to_owned()),
        "一二三四",
        "typing must mirror into the draft (the send path reads it)"
    );

    // 全选 + 复制: the field's own selection, not a host clipboard shim.
    press(cx, handle, chord("select-all"));
    press(cx, handle, chord("copy"));
    assert_eq!(
        read_clipboard(cx).as_deref(),
        Some("一二三四"),
        "⌘A then ⌘C must put the whole field on the clipboard"
    );

    // 剪切: the text leaves the field and lands on the clipboard.
    press(cx, handle, chord("cut"));
    assert_eq!(
        cx.update(|cx| pane.read(cx).composer_text(cx)),
        "",
        "⌘X must remove the selection"
    );
    assert_eq!(
        read_clipboard(cx).as_deref(),
        Some("一二三四"),
        "⌘X must put the cut text on the clipboard"
    );

    // 撤销 / 重做 over the same edit history.
    press(cx, handle, chord("undo"));
    assert_eq!(
        cx.update(|cx| pane.read(cx).composer_text(cx)),
        "一二三四",
        "⌘Z must restore the cut text"
    );
    press(cx, handle, chord("redo"));
    assert_eq!(
        cx.update(|cx| pane.read(cx).composer_text(cx)),
        "",
        "⇧⌘Z must re-apply the cut"
    );

    // 粘贴 from the state the reporter was in: an empty field after editing.
    clipboard(cx, "恢复的草稿");
    press(cx, handle, chord("paste"));
    assert_eq!(cx.update(|cx| pane.read(cx).composer_text(cx)), "恢复的草稿");
    assert_eq!(
        cx.update(|cx| pane.read(cx).draft().to_owned()),
        "恢复的草稿",
        "the pasted text must reach the draft the send path uses"
    );
}
