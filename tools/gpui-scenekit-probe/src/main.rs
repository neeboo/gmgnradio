use gmgn_gpui_ui::{ResidentChatPane, state::ChatCommand};
use gpui_kit::component::input::InputEvent;
use gpui_kit::component::{button::*, input::*, *};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::*;
use raw_window_handle::{HasWindowHandle, RawWindowHandle};
use std::time::Duration;

unsafe extern "C" {
    fn probe_attach(view: *mut std::ffi::c_void);
    fn probe_route(enabled: i32);
    fn probe_modal(enabled: i32);
    fn probe_reset_camera();
    fn probe_cleanup();
    fn probe_production_requested() -> i32;
    fn probe_hide_briefly();
}

struct Probe {
    input: Entity<InputState>,
    count: usize,
    _input_subscription: Subscription,
    compact: bool,
    production: bool,
    chat: Option<Entity<ResidentChatPane>>,
    chat_warning_visible: bool,
    _chat_poller: Option<Task<()>>,
}
impl Probe {
    fn consume_chat_commands(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(chat) = self.chat.clone() else {
            return;
        };
        let commands = chat.update(cx, |chat, _| chat.take_commands());
        for command in commands {
            match command {
                ChatCommand::Send { request_id, text } => {
                    // No transport is connected: never acknowledge or invent a reply.
                    eprintln!(
                        "PROBE_CHAT_NOT_CONNECTED request_id={request_id} characters={}",
                        text.chars().count()
                    );
                    self.chat_warning_visible = false;
                    chat.update(cx, |chat, cx| {
                        chat.failed(request_id, "对话服务尚未接入此验证窗口".into(), window, cx)
                    });
                    cx.notify();
                }
                ChatCommand::Cancel { request_id } => {
                    eprintln!("PROBE_CHAT_CANCEL_NO_TRANSPORT request_id={request_id}");
                }
            }
        }
    }
    fn render_chat(&self, chat: Entity<ResidentChatPane>, cx: &App) -> AnyElement {
        let pane = div()
            .flex()
            .flex_col()
            .bg(cx.theme().tokens.background)
            .text_color(cx.theme().foreground)
            .when(self.chat_warning_visible, |this| {
                this.child(div().px_3().text_xs().child("对话服务尚未接入此验证窗口"))
            })
            .child(chat);
        if self.compact {
            div()
                .size_full()
                .rounded(px(28.))
                .overflow_hidden()
                .flex()
                .flex_col()
                .justify_between()
                .child(
                    div()
                        .h(px(32.))
                        .px_2()
                        .flex()
                        .items_center()
                        .justify_between()
                        .bg(cx.theme().tokens.background)
                        .text_color(cx.theme().foreground)
                        .child(
                            div()
                                .flex_1()
                                .text_xs()
                                .window_control_area(WindowControlArea::Drag)
                                .child("居民对话"),
                        )
                        .child(
                            Button::new("compact-chat-close")
                                .small()
                                .label("关闭")
                                .on_click(|_, window, _| window.remove_window()),
                        ),
                )
                .child(div().h(px(144.)).overflow_hidden().child(pane))
                .into_any_element()
        } else {
            div()
                .size_full()
                .p_6()
                .child(div().w(px(360.)).child(pane).when(self.production, |this| {
                    this.child(
                        Button::new("chat-minimize")
                            .label("最小化宿主窗口")
                            .on_click(|_, window, _| window.minimize_window()),
                    )
                    .child(
                        Button::new("chat-hide").label("隐藏 4 秒后恢复").on_click(
                            |_, _, _| unsafe {
                                probe_hide_briefly();
                            },
                        ),
                    )
                }))
                .into_any_element()
        }
    }
}
impl Render for Probe {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if let Some(chat) = self.chat.clone() {
            return self.render_chat(chat, cx);
        }
        let production = self.production;
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
                        .child(if self.production {
                            "GMGN · 原生宿主"
                        } else {
                            "GMGN · SceneKit"
                        }),
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
                                        .label(if self.production {
                                            "生产视口"
                                        } else {
                                            "复位"
                                        })
                                        .disabled(self.production)
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
                    .bg(cx.theme().tokens.background)
                    .text_color(cx.theme().foreground)
                    .flex()
                    .flex_col()
                    .gap_3()
                    .child(if self.production {
                        "Production RenderHost + GPUI Kit"
                    } else {
                        "Live SceneKit + GPUI Kit overlay"
                    })
                    .child(format!("GPUI button count: {}", self.count))
                    .child(format!(
                        "Input characters: {}",
                        self.input.read(cx).value().chars().count()
                    ))
                    .child(
                        div()
                            .text_color(cx.theme().foreground)
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
                        move |_, window, cx| {
                            unsafe {
                                probe_modal(1);
                            }
                            window.open_dialog(cx, move |dialog, _, _| {
                                dialog
                                    .title("GPUI dialog over SceneKit")
                                    .on_close(|_, _, _| unsafe {
                                        probe_modal(0);
                                    })
                                    .child(if production {
                                        "真实渲染宿主保持显示，弹窗期间阻断场景输入。"
                                    } else {
                                        "The rotating cube must remain visible behind this modal."
                                    })
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
                            .disabled(self.production)
                            .on_click(|_, _, _| unsafe {
                                probe_reset_camera();
                            }),
                    )
                    .when(self.production, |this| {
                        this.child(
                            Button::new("minimize-production")
                                .label("最小化宿主窗口")
                                .on_click(|_, window, _| window.minimize_window()),
                        )
                        .child(
                            Button::new("hide-production")
                                .label("隐藏 4 秒后恢复")
                                .on_click(|_, _, _| unsafe {
                                    probe_hide_briefly();
                                }),
                        )
                    }),
            )
            .into_any_element()
    }
}
fn main() {
    let production = unsafe { probe_production_requested() != 0 };
    gpui_kit::application().run(move |cx| {
        gpui_kit::init(cx);
        let compact = std::env::var("GMGN_PROBE_COMPACT").as_deref() == Ok("1");
        let chat_ui = production || std::env::var("GMGN_PROBE_CHAT_UI").as_deref() == Ok("1");
        Theme::change(ThemeMode::Dark, None, cx);
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
                let chat = chat_ui
                    .then(|| cx.new(|cx| ResidentChatPane::new(window, cx).compact(compact)));
                let chat_poller = chat_ui.then(|| {
                    cx.spawn_in(window, async move |view, cx| {
                        loop {
                            cx.background_executor()
                                .timer(Duration::from_millis(100))
                                .await;
                            if view
                                .update_in(cx, |view: &mut Probe, window, cx| {
                                    view.consume_chat_commands(window, cx)
                                })
                                .is_err()
                            {
                                break;
                            }
                        }
                    })
                });
                Probe {
                    input,
                    count: 0,
                    _input_subscription: subscription,
                    compact,
                    production,
                    chat,
                    chat_warning_visible: true,
                    _chat_poller: chat_poller,
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
