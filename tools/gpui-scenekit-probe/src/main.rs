use gpui_kit::component::input::InputEvent;
use gpui_kit::component::{button::*, input::*, *};
use gpui_kit::*;
use raw_window_handle::{HasWindowHandle, RawWindowHandle};

unsafe extern "C" {
    fn probe_attach(view: *mut std::ffi::c_void);
    fn probe_route(enabled: i32);
    fn probe_modal(enabled: i32);
    fn probe_reset_camera();
    fn probe_cleanup();
}

struct Probe {
    input: Entity<InputState>,
    count: usize,
    _input_subscription: Subscription,
    compact: bool,
}
impl Render for Probe {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if self.compact {
            return div()
                .size_full()
                .rounded(px(28.))
                .overflow_hidden()
                .flex()
                .flex_col()
                .justify_between()
                .text_color(cx.theme().foreground)
                .child(
                    div()
                        .h(px(32.))
                        .px_3()
                        .py_1()
                        .bg(cx.theme().tokens.background)
                        .window_control_area(WindowControlArea::Drag)
                        .child("GMGN · SceneKit"),
                )
                .child(
                    div()
                        .h(px(144.))
                        .p_2()
                        .bg(cx.theme().tokens.background)
                        .flex()
                        .flex_col()
                        .gap_1()
                        .child(format!(
                            "消息 {} · 字符 {}",
                            self.count,
                            self.input.read(cx).value().chars().count()
                        ))
                        .child(Input::new(&self.input).small())
                        .child(
                            div()
                                .flex()
                                .gap_1()
                                .child(
                                    Button::new("compact-send")
                                        .small()
                                        .primary()
                                        .label("发送")
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            this.count += 1;
                                            cx.notify();
                                        })),
                                )
                                .child(
                                    Button::new("compact-camera")
                                        .small()
                                        .label("复位")
                                        .on_click(|_, _, _| unsafe {
                                            probe_reset_camera();
                                        }),
                                ),
                        )
                        .child(
                            Button::new("compact-close")
                                .small()
                                .label("关闭小窗")
                                .on_click(|_, window, _| window.remove_window()),
                        ),
                )
                .into_any_element();
        }
        div()
            .size_full()
            .p_6()
            .child(
                div()
                    .w(px(360.))
                    .p_4()
                    .rounded_lg()
                    .bg(rgba(0x172a36dd))
                    .text_color(rgb(0xffffff))
                    .flex()
                    .flex_col()
                    .gap_3()
                    .child("Live SceneKit + GPUI Kit overlay")
                    .child(format!("GPUI button count: {}", self.count))
                    .child(format!(
                        "Input characters: {}",
                        self.input.read(cx).value().chars().count()
                    ))
                    .child(
                        div()
                            .text_color(rgb(0x111111))
                            .child(Input::new(&self.input)),
                    )
                    .child(
                        Button::new("increment")
                            .primary()
                            .label("GPUI button")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.count += 1;
                                cx.notify();
                            })),
                    )
                    .child(Button::new("dialog").label("Open GPUI dialog").on_click(
                        |_, window, cx| {
                            unsafe {
                                probe_modal(1);
                            }
                            window.open_dialog(cx, |dialog, _, _| {
                                dialog
                                    .title("GPUI dialog over SceneKit")
                                    .on_close(|_, _, _| unsafe {
                                        probe_modal(0);
                                    })
                                    .child(
                                        "The rotating cube must remain visible behind this modal.",
                                    )
                                    .footer(
                                        Button::new("close-dialog")
                                            .primary()
                                            .label("Close dialog")
                                            .on_click(|_, window, cx| {
                                                unsafe {
                                                    probe_modal(0);
                                                }
                                                window.close_dialog(cx);
                                            }),
                                    )
                            });
                        },
                    ))
                    .child(
                        Button::new("route")
                            .label("Enable SceneKit hit routing")
                            .on_click(|_, _, _| unsafe {
                                probe_route(1);
                            }),
                    )
                    .child(Button::new("raw").label("Raw GPUI hit testing").on_click(
                        |_, _, _| unsafe {
                            probe_route(0);
                        },
                    ))
                    .child(
                        Button::new("reset-camera")
                            .label("Reset SceneKit camera")
                            .on_click(|_, _, _| unsafe {
                                probe_reset_camera();
                            }),
                    ),
            )
            .into_any_element()
    }
}
fn main() {
    gpui_kit::application().run(|cx| {
        gpui_kit::init(cx);
        let compact = std::env::var("GMGN_PROBE_COMPACT").as_deref() == Ok("1");
        if compact {
            Theme::change(ThemeMode::Dark, None, cx);
        }
        cx.on_window_closed(|cx, _| {
            unsafe {
                probe_cleanup();
            }
            cx.quit();
        })
        .detach();
        let options = WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                point(px(80.), px(80.)),
                if compact {
                    size(px(224.), px(336.))
                } else {
                    size(px(1100.), px(760.))
                },
            ))),
            kind: if compact {
                // macOS PopUp creates NSPanel with NonactivatingPanel from init.
                // The probe's native adapter sets its level to Floating afterward.
                WindowKind::PopUp
            } else {
                WindowKind::Normal
            },
            titlebar: if compact {
                None
            } else {
                Some(TitlebarOptions::default())
            },
            is_resizable: !compact,
            focus: !compact,
            window_background: WindowBackgroundAppearance::Transparent,
            ..Default::default()
        };
        cx.open_window(options, |window, cx| {
            let handle = HasWindowHandle::window_handle(window).expect("AppKit handle");
            if std::env::var("GMGN_PROBE_NATIVE").as_deref() != Ok("0")
                && let RawWindowHandle::AppKit(handle) = handle.as_raw()
            {
                unsafe {
                    probe_attach(handle.ns_view.as_ptr());
                }
            }
            let view = cx.new(|cx| {
                let input = cx.new(|cx| {
                    InputState::new(window, cx).placeholder("中文 / keyboard focus test")
                });
                let subscription =
                    cx.subscribe(&input, |_: &mut Probe, _, _: &InputEvent, cx| cx.notify());
                Probe {
                    input,
                    count: 0,
                    _input_subscription: subscription,
                    compact,
                }
            });
            // Kit's default component RootPlugin paints a solid theme background.
            // Root's instance style explicitly overrides that default, retaining dialogs.
            cx.new(|cx| gpui_kit::base::Root::new(view, window, cx).bg(rgba(0x00000000)))
        })
        .expect("probe window");
        if !compact {
            cx.activate(true);
        }
    });
}
