//! Product settings controls. Catalogs and all side effects come from ProductHost.
use gpui_kit::assets::IconName;
use gpui_kit::component::input::InputEvent;
use gpui_kit::component::{button::*, input::*, menu::*, switch::Switch, *};
use gpui_kit::component::{
    color_picker::{ColorPicker, ColorPickerEvent, ColorPickerState},
    slider::{Slider, SliderEvent, SliderState},
};
use gpui_kit::prelude::FluentBuilder;
use gpui_kit::*;
use serde_json::{Value, json};

fn avatar_detail(package: &Value) -> String {
    if let Some(detail) = package["displayDetail"].as_str() {
        return detail.to_owned();
    }
    let engine = match package["engine"].as_str() {
        Some("orb") => "呼吸球",
        Some("pmx") => "PMX",
        Some("vrm") => "VRM",
        Some("live2D" | "live2d") => "Live2D",
        _ => "",
    };
    if package["isBuiltIn"].as_bool() == Some(true) {
        format!("内置 · {engine}")
    } else {
        package["detail"].as_str().unwrap_or("").replacen(
            package["engine"].as_str().unwrap_or(""),
            engine,
            1,
        )
    }
}
fn motion_format(value: &str) -> &str {
    match value {
        "procedural" => "内置动态",
        "vmd" => "VMD",
        "bvh" => "BVH",
        "vrma" => "VRMA",
        "bones" => "Bones",
        other => other,
    }
}

fn orb_preview() -> impl IntoElement {
    div()
        .size(px(40.))
        .flex_shrink_0()
        .rounded_lg()
        .bg(rgba(0x007aff12))
        .with_animation(
            "settings-orb-breath",
            Animation::new(std::time::Duration::from_millis(3491)).repeat(),
            |this, phase| {
                let breath = 0.94 + 0.03 * ((phase * std::f32::consts::TAU).sin() + 1.);
                this.child(
                    canvas(
                        |_, _, _| (),
                        move |bounds: Bounds<Pixels>, _, window, _| {
                            let center = bounds.center();
                            let radius = px(17. * breath);
                            let colors = [
                                [1., 1., 1.],
                                [0.30, 0.66, 1.],
                                [0.08, 0.35, 0.95],
                                [1., 1., 1.],
                            ];
                            for slice in 0..96 {
                                let position = slice as f32 / 96.;
                                let index = (position * 3.).floor() as usize;
                                let blend = position * 3. - index as f32;
                                let color = Rgba {
                                    r: colors[index][0]
                                        + (colors[index + 1][0] - colors[index][0]) * blend,
                                    g: colors[index][1]
                                        + (colors[index + 1][1] - colors[index][1]) * blend,
                                    b: colors[index][2]
                                        + (colors[index + 1][2] - colors[index][2]) * blend,
                                    a: 1.,
                                };
                                let first = position * std::f32::consts::TAU;
                                let last = (slice as f32 + 1.05) / 96. * std::f32::consts::TAU;
                                let mut path = PathBuilder::fill();
                                path.move_to(center);
                                path.line_to(point(
                                    center.x + radius * first.cos(),
                                    center.y + radius * first.sin(),
                                ));
                                path.line_to(point(
                                    center.x + radius * last.cos(),
                                    center.y + radius * last.sin(),
                                ));
                                path.close();
                                if let Ok(path) = path.build() {
                                    window.paint_path(path, color);
                                }
                            }
                            let mut outline = PathBuilder::stroke(px(1.));
                            for step in 0..=96 {
                                let angle = step as f32 / 96. * std::f32::consts::TAU;
                                let point = point(
                                    center.x + radius * angle.cos(),
                                    center.y + radius * angle.sin(),
                                );
                                if step == 0 {
                                    outline.move_to(point);
                                } else {
                                    outline.line_to(point);
                                }
                            }
                            if let Ok(path) = outline.build() {
                                window.paint_path(path, rgba(0xffffffe6));
                            }
                        },
                    )
                    .size_full(),
                )
            },
        )
}

fn presence_preview(package: &Value) -> AnyElement {
    if let Some(path) = package["thumbnailPath"]
        .as_str()
        .filter(|path| !path.is_empty())
    {
        div()
            .size(px(40.))
            .flex_shrink_0()
            .rounded_lg()
            .overflow_hidden()
            .child(
                img(std::path::PathBuf::from(path))
                    .size_full()
                    .object_fit(ObjectFit::Cover),
            )
            .into_any_element()
    } else if package["engine"].as_str() == Some("orb") {
        orb_preview().into_any_element()
    } else {
        div()
            .size(px(40.))
            .flex_shrink_0()
            .flex()
            .items_center()
            .justify_center()
            .rounded_lg()
            .bg(rgba(0x007aff12))
            .text_color(rgba(0x007affbf))
            .child(
                Icon::new(if package["engine"].as_str() == Some("pmx") {
                    IconName::PersonStanding
                } else {
                    IconName::UserRound
                })
                .size(px(30.)),
            )
            .into_any_element()
    }
}

#[derive(IntoElement)]
struct SettingsGroup {
    title: &'static str,
    content: Div,
}
impl SettingsGroup {
    fn row_gap(mut self,gap:Pixels)->Self{self.content=self.content.gap(gap);self}
    fn new(title: &'static str, border: Hsla) -> Self {
        Self {
            title,
            content: div()
                .flex()
                .flex_col()
                .gap_3()
                .p_3()
                .rounded_lg()
                .border_1()
                .border_color(border),
        }
    }
}
impl ParentElement for SettingsGroup {
    fn extend(&mut self, elements: impl IntoIterator<Item = AnyElement>) {
        self.content.extend(elements);
    }
}
impl RenderOnce for SettingsGroup {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let mut group = div().flex().flex_col().gap(px(8.));
        if !self.title.is_empty() {
            group = group.child(
                div()
                    .pl(px(12.))
                    .text_sm()
                    .text_color(cx.theme().muted_foreground)
                    .child(self.title),
            );
        }
        group.child(self.content)
    }
}

pub struct AgentSettingsPane {
    snapshot: Value,
    draft: Value,
    inputs: Vec<Entity<InputState>>,
    personas: Vec<Entity<TextareaState>>,
    commands: Vec<Value>,
    initialized: bool,
    page: usize,
    extra_inputs: Vec<Entity<InputState>>,
    motion_category: String,
    orb_color: Entity<ColorPickerState>,
    orb_intensity: Entity<SliderState>,
    _subscriptions: Vec<Subscription>,
    import_link_open: bool,
    custom_voice_open: bool,
    import_link_window: Option<AnyWindowHandle>,
    import_link_pending: bool,
    import_link_revision: u64,
}
impl AgentSettingsPane {
    fn open_import_link(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.import_link_open = true;
        self.import_link_pending = false;
        self.import_link_revision = self.snapshot["presence"]["downloadRevision"]
            .as_u64()
            .unwrap_or(0);
        self.import_link_window = Some(Window::window_handle(window));
        let weak = cx.entity().downgrade();
        window.open_dialog(cx,move|dialog,_,cx|{
            let Some(entity)=weak.upgrade()else{return dialog;};let this=entity.read(cx);
            let input=this.extra_inputs[4].clone();let working=this.import_link_pending||this.snapshot["presence"]["working"].as_bool()==Some(true);
            let notice=this.snapshot["presence"]["notice"].as_str().filter(|_|this.snapshot["presence"]["hasError"].as_bool()==Some(true)).map(str::to_owned);
            let disabled=working||input.read(cx).value().trim().is_empty();let cancel=weak.clone();let submit=weak.clone();let close=weak.clone();let escape_input=weak.clone();let escape_footer=weak.clone();let escape_action=weak.clone();
            let mut body=div().flex().flex_col().gap(px(12.))
                .capture_key_down(move|event,window,cx|{
                    if event.keystroke.key=="escape"{_=escape_input.update(cx,|this,cx|{this.import_link_open=false;cx.notify();});window.close_dialog(cx);cx.stop_propagation();}
                })
                .child(div().text_sm().child("支持 HTTPS 地址指向 VRM、ZIP 或 gmgnpet 模型包。"))
                .child(Input::new(&input));
            if let Some(notice)=notice{body=body.child(div().text_xs().child(notice));}
            dialog.w(px(460.)).h(px(230.)).p(px(24.)).title("从链接导入角色").close_button(false).overlay_closable(false).child(body)
                .footer(div().flex().justify_end().items_center().gap_2().capture_key_down(move|event,window,cx|{
                    if event.keystroke.key=="escape"{_=escape_footer.update(cx,|this,cx|{this.import_link_open=false;cx.notify();});window.close_dialog(cx);cx.stop_propagation();}
                })
                    .child(Button::new("cancel-link").label("取消").on_click(move|_,window,cx|{_=cancel.update(cx,|this,cx|{this.import_link_open=false;cx.notify();});window.close_dialog(cx);} ))
                    .child(Button::new("import-link").label(if working{"正在下载…"}else{"下载并安装"}).disabled(disabled).on_click(move|_,_,cx|{_=submit.update(cx,|this,cx|{
                        this.commands.push(json!({"op":"presence.import.link","url":this.extra_inputs[4].read(cx).value().to_string()}));this.import_link_pending=true;this.import_link_revision=this.snapshot["presence"]["downloadRevision"].as_u64().unwrap_or(0);cx.notify();
                    });})))
                .on_cancel(move|_,window,cx|{_=escape_action.update(cx,|this,cx|{this.import_link_open=false;cx.notify();});window.close_dialog(cx);true})
                .on_close(move|_,_,cx|{_=close.update(cx,|this,cx|{this.import_link_open=false;cx.notify();});})
        });
        cx.notify();
    }
    fn remove_menu(
        &self,
        id: impl Into<ElementId>,
        label: &'static str,
        command: Value,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let weak = cx.entity().downgrade();
        Button::new(id)
            .icon(IconName::Ellipsis)
            .w(px(22.))
            .h(px(22.))
            .dropdown_menu(move |menu, _, _| {
                let weak = weak.clone();
                let command = command.clone();
                menu.item(PopupMenuItem::new(label).on_click(move |_, _, cx| {
                    _ = weak.update(cx, |this, cx| {
                        this.commands.push(command.clone());
                        cx.notify();
                    });
                }))
            })
            .into_any_element()
    }
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let inputs: Vec<Entity<InputState>> = [
            "居民人格",
            "DJ 人格与偏好",
            "使用 Codex 默认模型",
            "自定义音色 ID",
        ]
        .into_iter()
        .enumerate()
        .map(|(i, label)| {
            cx.new(|cx| {
                let input = InputState::new(window, cx).placeholder(label);
                let _ = i;
                input
            })
        })
        .collect();
        let personas = ["居民人格", "DJ 人格与偏好"]
            .map(|label| cx.new(|cx| TextareaState::new(window, cx).placeholder(label).rows(4)))
            .to_vec();
        let extra_inputs = [
            "新的 TTS API Key",
            "新的 ASR API Key",
            "新的 Marble API Key",
            "https://…/catalog.json",
            "https://…/avatar.vrm",
            "生成服务地址",
            "生成服务密钥",
        ]
        .into_iter()
        .enumerate()
        .map(|(index, label)| {
            cx.new(|cx| {
                let mut state = InputState::new(window, cx).placeholder(label);
                if index < 3 || index == 6 {
                    state.set_masked(true, window, cx);
                }
                state
            })
        })
        .collect();
        let orb_color = cx.new(|cx| ColorPickerState::new(window, cx));
        let orb_intensity = cx.new(|_| SliderState::new().min(0.35).max(1.5).step(0.01));
        let weak=cx.entity().downgrade();
        let escape_subscription=cx.intercept_keystrokes(move|event,window,cx|{
            if event.keystroke.key!="escape"{return;}
            _=weak.update(cx,|this,cx|{
                if this.import_link_open&&this.import_link_window==Some(Window::window_handle(window)) {
                    this.import_link_open=false;window.close_dialog(cx);cx.stop_propagation();cx.notify();
                    eprintln!("GMGN_GPUI_SETTINGS_LINK_ESCAPE closed=true");
                }
            });
        });
        let subscriptions=vec![escape_subscription,cx.subscribe(&inputs[2],|this,input,event:&InputEvent,cx|{
            if matches!(event,InputEvent::Change) && this.initialized {this.commands.push(json!({"op":"agent.save","planningModel":input.read(cx).value().to_string()}));}
        }),cx.subscribe(&orb_color,|this,_,event:&ColorPickerEvent,cx|{
            if let ColorPickerEvent::Change(Some(color))=event{let color=color.to_rgb();this.commands.push(json!({"op":"presence.orb.color","red":color.r,"green":color.g,"blue":color.b}));cx.notify();}
        }),cx.subscribe(&orb_intensity,|this,_,event:&SliderEvent,cx|{
            if let SliderEvent::Change(value)=event{this.commands.push(json!({"op":"presence.orb.intensity","value":value.start()}));cx.notify();}
        })];
        Self {
            snapshot: Value::Null,
            draft: Value::Null,
            inputs,
            personas,
            commands: vec![json!({"op":"settings.load"})],
            initialized: false,
            page: 0,
            extra_inputs,
            motion_category: String::new(),
            orb_color,
            orb_intensity,
            _subscriptions: subscriptions,
            import_link_open: false,
            custom_voice_open: false,
            import_link_window: None,
            import_link_pending: false,
            import_link_revision: 0,
        }
    }
    pub fn take_commands(&mut self) -> Vec<Value> {
        std::mem::take(&mut self.commands)
    }
    pub fn select_page(&mut self, page: &str, cx: &mut Context<Self>) {
        if self.page == 3 {
            self.commands.push(json!({"op":"shortcuts.cancel"}));
        }
        self.page = match page {
            "music" => 1,
            "space" => 2,
            "shortcuts" => 3,
            "agent" | "dj" => 4,
            _ => 0,
        };
        if self.page == 0 {
            self.commands.push(json!({"op":"presence.load"}));
        }
        cx.notify();
    }
    pub fn dismissed(&mut self, cx: &mut Context<Self>) {
        self.commands.push(json!({"op":"shortcuts.cancel"}));
        self.commands.push(json!({"op":"tts.stop"}));
        cx.notify();
    }
    pub fn update_snapshot(
        &mut self,
        snapshot: Value,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if snapshot.is_null() || self.snapshot == snapshot {
            return;
        }
        if !self.initialized {
            self.draft = snapshot.clone();
            for (i, section, field) in [
                (0, "agent", "residentPersona"),
                (1, "agent", "hostPrompt"),
                (2, "agent", "planningModel"),
                (3, "tts", "voiceID"),
            ] {
                let text = snapshot[section][field].as_str().unwrap_or("").to_owned();
                if i < 2 {
                    self.personas[i].update(cx, |input, cx| input.set_value(text, window, cx));
                } else {
                    self.inputs[i].update(cx, |input, cx| input.set_value(text, window, cx));
                }
            }
            self.initialized = true;
            for (index, section, field) in
                [(3, "presence", "catalogURL"), (5, "space", "propEndpoint")]
            {
                let value = snapshot[section][field].as_str().unwrap_or("").to_owned();
                self.extra_inputs[index].update(cx, |input, cx| input.set_value(value, window, cx));
            }
            let orb = &snapshot["presence"]["orb"];
            if let (Some(r), Some(g), Some(b)) = (
                orb["red"].as_f64(),
                orb["green"].as_f64(),
                orb["blue"].as_f64(),
            ) {
                self.orb_color.update(cx, |state, cx| {
                    state.set_value(
                        Rgba {
                            r: r as f32,
                            g: g as f32,
                            b: b as f32,
                            a: 1.,
                        },
                        window,
                        cx,
                    )
                });
            }
            if let Some(value) = orb["flowIntensity"].as_f64() {
                self.orb_intensity
                    .update(cx, |state, cx| state.set_value(value as f32, window, cx));
            }
        } else if self.snapshot["tts"]["providerID"] != snapshot["tts"]["providerID"] {
            self.draft["tts"] = snapshot["tts"].clone();
            let voice = snapshot["tts"]["voiceID"].as_str().unwrap_or("").to_owned();
            self.inputs[3].update(cx, |input, cx| input.set_value(voice, window, cx));
        } else if self.draft["tts"]["modelID"]
            .as_str()
            .unwrap_or("")
            .is_empty()
        {
            self.draft["tts"]["modelID"] = snapshot["tts"]["modelID"].clone();
        }
        if self.snapshot["asr"]["providerID"] != snapshot["asr"]["providerID"]
            || self.draft["asr"]["modelID"]
                .as_str()
                .unwrap_or("")
                .is_empty()
        {
            self.draft["asr"] = snapshot["asr"].clone();
        }
        if self.import_link_pending
            && snapshot["presence"]["downloadRevision"]
                .as_u64()
                .is_some_and(|revision| revision > self.import_link_revision)
            && matches!(
                snapshot["presence"]["downloadState"].as_str(),
                Some("succeeded" | "failed")
            )
        {
            self.import_link_pending = false;
            if snapshot["presence"]["downloadState"].as_str() == Some("succeeded") {
                if let Some(handle) = self.import_link_window {
                    _ = handle.update(cx, |_, window, cx| window.close_dialog(cx));
                }
                self.import_link_open = false;
            }
        }
        self.snapshot = snapshot;
        cx.notify();
    }
    fn selection(
        &mut self,
        section: &str,
        field: &str,
        value: Value,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.draft[section][field] = value.clone();
        if matches!(section, "tts" | "asr") && field == "providerID" {
            self.extra_inputs[if section == "tts" { 0 } else { 1 }]
                .update(cx, |input, cx| input.set_value("", window, cx));
            self.commands
                .push(json!({"op":format!("{section}.provider"),"id":value}));
        }
        if section == "space" && field == "defaultSpace" {
            self.commands
                .push(json!({"op":"space.default","value":value}));
        }
        if section == "agent" {
            let mut command = json!({"op":"agent.save"});
            command[field] = value.clone();
            self.commands.push(command);
        }
        if section == "tts" && field == "voiceID" {
            self.inputs[3].update(cx, |input, cx| {
                input.set_value(value.as_str().unwrap_or(""), window, cx)
            });
        }
        cx.notify();
    }
    fn options(&self, section: &str, key: &str) -> Vec<(Value, String)> {
        self.snapshot[section][key]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|v| {
                if let Some(n) = v.as_u64() {
                    Some((
                        json!(n),
                        if n == 0 {
                            "0 轮（不再新起）".to_owned()
                        } else {
                            format!("{n} 轮")
                        },
                    ))
                } else {
                    let mut name = v.get("name")?.as_str()?.to_owned();
                    if v.get("installed").and_then(Value::as_bool) == Some(false) {
                        name.push_str("（未安装）");
                    }
                    Some((v.get("id")?.clone(), name))
                }
            })
            .collect()
    }
    fn dropdown(
        &self,
        id: &'static str,
        label: &'static str,
        section: &'static str,
        field: &'static str,
        items: Vec<(Value, String)>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let value = self.draft[section][field].clone();
        let selected = items
            .iter()
            .find(|(id, _)| *id == value)
            .map(|(_, name)| name.clone())
            .unwrap_or_else(|| {
                value
                    .as_str()
                    .filter(|s| !s.is_empty())
                    .unwrap_or("请选择")
                    .into()
            });
        let weak = cx.entity().downgrade();
        div()
            .flex()
            .items_center()
            .justify_between()
            .gap_3()
            .child(label)
            .child(
                Button::new(id)
                    .label(selected)
                    .dropdown_caret(true)
                    .disabled(items.is_empty())
                    .dropdown_menu(move |mut menu, _, _| {
                        for (value, name) in &items {
                            let weak = weak.clone();
                            let value = value.clone();
                            menu = menu.item(PopupMenuItem::new(name.clone()).on_click(
                                move |_, window, cx| {
                                    _ = weak.update(cx, |this, cx| {
                                        this.selection(section, field, value.clone(), window, cx)
                                    });
                                },
                            ));
                        }
                        menu
                    }),
            )
            .into_any_element()
    }
    fn toggle(
        &self,
        id: &'static str,
        label: &'static str,
        field: &'static str,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        Switch::new(id)
            .label(label)
            .checked(self.draft["agent"][field].as_bool().unwrap_or(false))
            .on_change(cx.listener(move |this, value: &bool, _, cx| {
                this.draft["agent"][field] = json!(*value);
                let mut command = json!({"op":"agent.save"});
                command[field] = json!(*value);
                this.commands.push(command);
                cx.notify();
            }))
            .into_any_element()
    }
    fn tts_action(&mut self, op: &str, cx: &mut Context<Self>) {
        let mut tts = self.draft["tts"].clone();
        tts["voiceID"] = json!(self.inputs[3].read(cx).value().to_string());
        tts["apiKey"] = json!(self.extra_inputs[0].read(cx).value().to_string());
        tts["op"] = json!(op);
        self.commands.push(tts);
    }
}
impl AgentSettingsPane {
    fn dj_form(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let theme = cx.theme();
        let border = theme.border;
        let valid_model = self.snapshot["tts"]["models"]
            .as_array()
            .is_some_and(|models| {
                models
                    .iter()
                    .any(|model| model["id"] == self.draft["tts"]["modelID"])
            });
        let mut form = div()
            .flex()
            .flex_col()
            .gap_3()
            .bg(theme.tokens.background)
            .text_color(theme.foreground);
        if !self.initialized {
            return form
                .child("正在读取原应用配置与 Rust 服务能力…")
                .into_any_element();
        }
        let group = |title: &'static str| SettingsGroup::new(title, border);
        form=form.child(group("DJ 内核")
            .child(div().flex().justify_between().child(div().flex().flex_col().child("gmgn DJ").child(match self.snapshot["agent"]["codexState"].as_str(){Some("signedIn")=>"已登录",Some("unavailable")=>"未安装",_=>"未登录"}))
                .child(Button::new("codex-login").label(if self.snapshot["agent"]["codexState"].as_str()==Some("signedIn"){"退出登录"}else{"登录"})
                    .disabled(self.snapshot["agent"]["working"].as_bool()==Some(true)||self.snapshot["agent"]["codexState"].as_str()==Some("unavailable"))
                    .on_click(cx.listener(|this,_,_,_|this.commands.push(json!({"op":if this.snapshot["agent"]["codexState"].as_str()==Some("signedIn"){"agent.logout"}else{"agent.login"}}))))))
            .child(self.toggle("takeover","允许 DJ 自动接管","takeoverEnabled",cx))
            .child(div().text_xs().child("可以自主切歌、暂停、继续、重排节目和调整视觉。"))
            .child(div().flex().justify_between().items_center().child("策划模型").child(div().w(px(220.)).child(Input::new(&self.inputs[2])))))
            .child(group("DJ 人格与偏好").child(div().h(px(150.)).min_h(px(150.)).flex_shrink_0()
                .child(Textarea::new(&self.personas[1]).h(px(150.)).aria_label("DJ 人格与偏好").accessibility_id("dj-host-prompt")))
            .child(div().flex().justify_between().items_center().child(div().flex_1().text_sm().child("用自然语言告诉 DJ 怎么策划和主持。"))
                .child(Button::new("save-dj").label("保存").on_click(cx.listener(|this,_,_,cx|this.commands.push(json!({"op":"agent.save","hostPrompt":this.personas[1].read(cx).value().to_string()})))))))
            .child(group("居民人格").child(div().h(px(120.)).min_h(px(120.)).flex_shrink_0()
                .child(Textarea::new(&self.personas[0]).h(px(120.)).aria_label("居民人格").accessibility_id("resident-persona")))
            .child(div().flex().justify_between().items_center().child(div().flex_1().text_sm().child("只影响居民，和上面的 DJ 偏好分开。人格只改语气和关注点，不改变它能做什么。"))
                .child(Button::new("save-resident").label("保存").on_click(cx.listener(|this,_,_,cx|this.commands.push(json!({"op":"agent.save","residentPersona":this.personas[0].read(cx).value().to_string()})))))))
            .child(group("聊天模型")
            .child(self.dropdown("backend","模型","agent","backendID",self.options("agent","backends"),cx))
            .child(div().text_xs().child("空间和 Live Cam 共用这里选定的 Agent；文字和语音转写进入同一个会话。"))
            .child(self.toggle("autonomy","允许居民自主安排活动","autonomyEnabled",cx))
            .child(div().text_xs().child("打开后，居民会自己观察和行动，会消耗模型额度。设为 0 就不再新起一轮，要先停下请按停止。"))
            .child(self.dropdown("budget","每小时后台思考预算","agent","backgroundTurnsPerHour",self.options("agent","budgetOptions"),cx))
            .child(div().text_xs().child("按最近一小时算，默认 6。这只数后台思考的次数，不等于请求次数或费用。")))
            .child(group("回复语音")
            .child(self.toggle("auto-speak","自动朗读 Agent 回复","autoSpeak",cx))
            .child(self.dropdown("tts-provider","服务","tts","providerID",self.options("tts","providers"),cx))
            .child(div().flex().items_center().justify_between().child("API Key").child(div().w(px(280.)).child(Input::new(&self.extra_inputs[0]).aria_label("新的 TTS API Key"))))
            .child(self.dropdown("tts-voice","声音","tts","voiceID",self.options("tts","voices"),cx))
            .child(div().flex().items_center().gap_2()
                .child(Button::new("refresh-voices").label("刷新声音").disabled(self.snapshot["tts"]["loading"].as_bool()==Some(true)).on_click(cx.listener(|this,_,_,cx|this.tts_action("tts.refresh",cx))))
                .child(Button::new("preview-tts").label(if self.snapshot["tts"]["isSpeaking"].as_bool()==Some(true){"停止试听"}else{"试听声音"}).disabled(!valid_model||self.inputs[3].read(cx).value().trim().is_empty()).on_click(cx.listener(|this,_,_,cx|this.tts_action(if this.snapshot["tts"]["isSpeaking"].as_bool()==Some(true){"tts.stop"}else{"tts.preview"},cx)))))
            .child(gpui_kit::component::collapsible::Collapsible::new().open(self.custom_voice_open)
                .child(Button::new("custom-voice-disclosure").label("自定义音色 ID").icon(if self.custom_voice_open{IconName::ChevronDown}else{IconName::ChevronRight}).on_click(cx.listener(|this,_,_,cx|{this.custom_voice_open=!this.custom_voice_open;cx.notify();})))
                .content(div().flex().flex_col().gap_2().child(Input::new(&self.inputs[3])).child(div().text_xs().child("填写该服务已有的音色 ID，无需重新上传；账号、模型及服务区域须与创建音色时一致。"))))
            .child(self.dropdown("tts-model","模型","tts","modelID",self.options("tts","models"),cx))
            .child(if self.snapshot["tts"]["credentialConfigured"].as_bool()==Some(true) { "沿用原应用已配置凭据" } else { "该服务尚未配置凭据，请填写后保存" })
            .child(div().flex().flex_wrap().gap_2()
                .child(Button::new("save-tts").label("保存配置").disabled(!valid_model).on_click(cx.listener(|this,_,_,cx|this.tts_action("tts.save",cx)))))
            .child(div().text_xs().child("传输：本机 TCP → Rust → 服务商；录放音留在系统设备层。"))
            .child(div().text_xs().child("Rust 流式合成，开麦停止旧朗读；失败保留文字，不自动切换服务。"))
            .children(self.snapshot["tts"]["notice"].as_str().map(|notice|div().text_xs().child(notice.to_owned()))))
            .child(group("按住说话")
            .child(self.dropdown("asr-provider","服务","asr","providerID",self.options("asr","providers"),cx))
            .child(div().flex().items_center().justify_between().child("API Key").child(div().w(px(280.)).child(Input::new(&self.extra_inputs[1]).aria_label("新的 ASR API Key"))))
            .child(self.dropdown("asr-model","模型","asr","modelID",self.options("asr","models"),cx))
            .child(Button::new("save-asr").label("保存配置").disabled(!self.snapshot["asr"]["models"].as_array().is_some_and(|models|models.iter().any(|model|model["id"]==self.draft["asr"]["modelID"]))).on_click(cx.listener(|this,_,_,cx|{
                let mut value=this.draft["asr"].clone();value["op"]=json!("asr.save");value["apiKey"]=json!(this.extra_inputs[1].read(cx).value().to_string());this.commands.push(value);
            })))
            .child("在空间或 Live Cam 按住麦克风录音，松开后将完整转写交给当前 Agent。没有双向实时通话。")
            .children(self.snapshot["asr"]["notice"].as_str().map(|notice|div().text_xs().child(notice.to_owned()))));
        form.into_any_element()
    }
}

impl AgentSettingsPane {
    fn command_button(
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
    fn basic_form(&self, cx: &mut Context<Self>) -> AnyElement {
        let mut form = div().flex().flex_col().gap_3();
        let border = cx.theme().border;
        let group = |title: &'static str| SettingsGroup::new(title, border);
        match self.page {
            0 => {
                let mut roles = group("角色");
                for package in self.snapshot["presence"]["packages"]
                    .as_array()
                    .into_iter()
                    .flatten()
                {
                    let id = package["id"].clone();
                    let mut row = div()
                        .flex()
                        .items_center()
                        .gap(px(12.))
                        .py(px(3.))
                        .child(presence_preview(package))
                        .child(
                            div()
                                .flex_1()
                                .min_w(px(0.))
                                .flex()
                                .flex_col()
                                .gap(px(3.))
                                .child(package["name"].as_str().unwrap_or("").to_owned())
                                .child(
                                    div()
                                        .text_xs()
                                        .text_color(cx.theme().muted_foreground)
                                        .child(avatar_detail(package)),
                                ),
                        );
                    if package["isActive"].as_bool() == Some(true) {
                        row = row.child(
                            div()
                                .flex()
                                .items_center()
                                .gap_1()
                                .text_xs()
                                .child(Icon::new(IconName::CircleCheck).size(px(14.)))
                                .child("当前角色"),
                        );
                    } else if package["rendererAvailable"].as_bool() == Some(false) {
                        row = row.child(div().text_xs().child(format!(
                            "等待 {} 渲染",
                            package["engine"].as_str().unwrap_or("当前引擎")
                        )));
                    } else {
                        row =
                            row.child(Button::new(format!("avatar-{id}")).label("选择").on_click(
                                cx.listener({
                                    let id = id.clone();
                                    move |this, _, _, cx| {
                                        this.commands
                                            .push(json!({"op":"presence.activate","id":id}));
                                        cx.notify();
                                    }
                                }),
                            ));
                    }
                    if package["isBuiltIn"].as_bool() == Some(false) {
                        row = row.child(self.remove_menu(
                            format!("remove-avatar-{id}"),
                            "移除角色",
                            json!({"op":"presence.remove","id":id}),
                            cx,
                        ));
                    }
                    roles = roles.child(row);
                }
                form = form.child(roles);
                let mut motions = group("动作");
                let categories = self.options("presence", "categories");
                let weak = cx.entity().downgrade();
                let category_values: Vec<_> = std::iter::once((json!(""), "全部".to_owned()))
                    .chain(categories)
                    .collect();
                let selected = category_values
                    .iter()
                    .position(|(id, _)| id.as_str() == Some(&self.motion_category))
                    .unwrap_or(0);
                motions = motions.child(
                    gpui_kit::component::tab::TabBar::new("motion-category")
                        .segmented()
                        .small()
                        .w(px(235.))
                        .h(px(24.))
                        .max_width(px(44.))
                        .selected_index(selected)
                        .children(category_values.iter().map(|(_, name)| {
                            gpui_kit::component::tab::Tab::new().flex_1().min_w(px(0.)).aria_label(name.clone())
                                .child(div().text_xs().min_w(px(0.)).whitespace_nowrap().child(name.clone()))
                        }))
                        .on_click(move |index, _, cx| {
                            _ = weak.update(cx, |this, cx| {
                                this.motion_category =
                                    category_values[*index].0.as_str().unwrap_or("").to_owned();
                                cx.notify();
                            });
                        }),
                );
                if let Some(notice) = self.snapshot["presence"]["motionNotice"].as_str() {
                    motions = motions.child(div().text_xs().child(notice.to_owned()));
                }
                for motion in self.snapshot["presence"]["motions"]
                    .as_array()
                    .into_iter()
                    .flatten()
                {
                    if !self.motion_category.is_empty()
                        && motion["category"].as_str() != Some(&self.motion_category)
                    {
                        continue;
                    }
                    let id = motion["id"].clone();
                    let compatible = motion["compatible"].as_bool().unwrap_or(false);
                    let active = motion["active"].as_bool().unwrap_or(false);
                    let mut row = div()
                        .flex()
                        .items_center()
                        .gap(px(12.))
                        .py(px(3.))
                        .child(
                            div()
                                .size(px(40.))
                                .flex_shrink_0()
                                .flex()
                                .items_center()
                                .justify_center()
                                .rounded_lg()
                                .bg(cx.theme().muted)
                                .child(Icon::new(IconName::Activity).size(px(20.))),
                        )
                        .child(
                            div()
                                .flex_1()
                                .min_w(px(0.))
                                .flex()
                                .flex_col()
                                .gap(px(3.))
                                .child(motion["name"].as_str().unwrap_or("").to_owned())
                                .child(
                                    div()
                                        .text_xs()
                                        .text_color(cx.theme().muted_foreground)
                                        .child(format!(
                                            "{}{}",
                                            motion_format(motion["format"].as_str().unwrap_or("")),
                                            motion["reason"]
                                                .as_str()
                                                .filter(|s| !s.is_empty())
                                                .map(|s| format!(" · {s}"))
                                                .unwrap_or_default()
                                        )),
                                ),
                        );
                    if active && compatible {
                        row = row.child(
                            div()
                                .flex()
                                .items_center()
                                .gap_1()
                                .text_xs()
                                .child(Icon::new(IconName::CircleCheck).size(px(14.)))
                                .child("当前动作"),
                        );
                    } else {
                        row = row.child(
                            Button::new(format!("motion-{id}"))
                                .label("选择")
                                .disabled(!compatible)
                                .on_click(cx.listener({
                                    let id = id.clone();
                                    move |this, _, _, _| {
                                        this.commands.push(json!({"op":"presence.motion","id":id}))
                                    }
                                })),
                        );
                    }
                    if motion["isBuiltIn"].as_bool() == Some(false) {
                        row = row.child(self.remove_menu(
                            format!("remove-motion-{id}"),
                            "移除动作",
                            json!({"op":"presence.motion.remove","id":id}),
                            cx,
                        ));
                    }
                    motions = motions.child(row);
                }
                form = form.child(motions).child(
                    div()
                        .text_xs()
                        .child("两种角色各有自己的动作列表，切换时会分别记住你选的。"),
                );
                let mut catalog=group("动作库").child(div().flex().items_center().gap(px(10.)).child(div().flex_1().min_w(px(0.)).child(Input::new(&self.extra_inputs[3])))
                    .child(Button::new("catalog-refresh").label("获取动作列表").disabled(self.snapshot["presence"]["working"].as_bool()==Some(true)||self.extra_inputs[3].read(cx).value().trim().is_empty()).on_click(cx.listener(|this,_,_,cx|this.commands.push(json!({"op":"presence.catalog","url":this.extra_inputs[3].read(cx).value().to_string()}))))));
                for motion in self.snapshot["presence"]["publishedMotions"]
                    .as_array()
                    .into_iter()
                    .flatten()
                {
                    let id = motion["id"].clone();
                    let mut row = div()
                        .flex()
                        .items_center()
                        .gap(px(12.))
                        .child(
                            div().size(px(28.)).flex_shrink_0().child(
                                Icon::new(if motion["loop"].as_bool() == Some(true) {
                                    IconName::Repeat
                                } else {
                                    IconName::Activity
                                })
                                .size(px(20.)),
                            ),
                        )
                        .child(
                            div()
                                .flex_1()
                                .min_w(px(0.))
                                .flex()
                                .flex_col()
                                .gap(px(3.))
                                .child(motion["name"].as_str().unwrap_or("").to_owned())
                                .child(
                                    div()
                                        .text_xs()
                                        .text_color(cx.theme().muted_foreground)
                                        .child(format!(
                                            "版本 {} · {:.1} 秒",
                                            motion["version"].as_str().unwrap_or(""),
                                            motion["duration"].as_f64().unwrap_or(0.)
                                        )),
                                ),
                        );
                    if motion["installLabel"].as_str() == Some("已安装") {
                        row = row.child(
                            div()
                                .flex()
                                .items_center()
                                .gap_1()
                                .text_xs()
                                .child(Icon::new(IconName::CircleCheck).size(px(14.)))
                                .child("已安装"),
                        );
                    } else {
                        row = row.child(
                            Button::new(format!("install-motion-{id}"))
                                .label(motion["installLabel"].as_str().unwrap_or("安装").to_owned())
                                .disabled(
                                    self.snapshot["presence"]["working"].as_bool() == Some(true),
                                )
                                .on_click(cx.listener(move |this, _, _, _| {
                                    this.commands
                                        .push(json!({"op":"presence.motion.install","id":id}))
                                })),
                        );
                    }
                    catalog = catalog.child(row);
                }
                form = form.child(catalog);
                if self.snapshot["presence"]["activeEngine"].as_str() == Some("orb") {
                    form = form.child(
                        group("呼吸球样式")
                            .child(ColorPicker::new(&self.orb_color).label("流光颜色"))
                            .child(
                                div()
                                    .flex()
                                    .items_center()
                                    .gap_3()
                                    .child("流光强度")
                                    .child(div().flex_1().child(Slider::new(&self.orb_intensity)))
                                    .child(div().w(px(42.)).child(format!(
                                        "{}%",
                                        (self.orb_intensity.read(cx).value().start() * 100.) as u32
                                    ))),
                            ),
                    );
                }
            }
            1 => {
                let mut services = group("音乐服务").row_gap(px(0.));
                for (index, provider) in self.snapshot["music"]["providers"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .enumerate()
                {
                    if index > 0 {
                        services = services.child(div().h(px(1.)).bg(border));
                    }
                    let id = provider["id"].clone();
                    let connected = provider["connected"].as_bool().unwrap_or(false);
                    let working = self.snapshot["music"]["working"].as_bool().unwrap_or(false);
                    let (icon, tint) = match id.as_str() {
                        Some("qq-music") => (IconName::ListMusic, rgb(0x34c759)),
                        Some("apple-music") => (IconName::Apple, rgb(0xff2d55)),
                        _ => (IconName::Music, rgb(0xff3b30)),
                    };
                    let mut row = div()
                        .flex()
                        .items_center()
                        .gap(px(12.))
                        .h(px(51.)).flex_shrink_0()
                        .py(px(4.))
                        .child(
                            div()
                                .size(px(32.))
                                .flex_shrink_0()
                                .rounded_lg()
                                .bg(tint.opacity(0.1))
                                .text_color(tint)
                                .flex()
                                .items_center()
                                .justify_center()
                                .child(Icon::new(icon).size(px(20.))),
                        )
                        .child(
                            div()
                                .flex_1()
                                .min_w(px(0.))
                                .flex()
                                .flex_col()
                                .gap(px(2.))
                                .child(provider["name"].as_str().unwrap_or("").to_owned())
                                .child(
                                    div()
                                        .text_xs()
                                        .text_color(cx.theme().muted_foreground)
                                        .child(match provider["status"].as_str() {
                                            Some("connected") => "已连接",
                                            Some("authorizing") => "正在连接",
                                            Some("expired") => "登录已过期",
                                            Some("denied") => "未授权",
                                            Some("unavailable") => "当前不可用",
                                            _ => "未连接",
                                        }),
                                ),
                        );
                    if provider["status"].as_str() == Some("authorizing") {
                        row = row.child("正在连接…");
                    } else {
                        let mut buttons = div().flex().items_center().gap_2().flex_shrink_0();
                        if connected {
                            buttons = buttons.child(
                                Button::new(format!("sync-{id}"))
                                    .ghost().small()
                                    .label("同步")
                                    .disabled(working)
                                    .on_click(cx.listener({
                                        let id = id.clone();
                                        move |this, _, _, _| {
                                            this.commands.push(json!({"op":"music.sync","id":id}))
                                        }
                                    })),
                            );
                        }
                        buttons=buttons.child(Button::new(format!("account-{id}")).small().when(connected,|button|button.ghost()).label(if connected{"断开"}else{"连接"}).disabled(working).on_click(cx.listener({let id=id.clone();move|this,_,_,_|this.commands.push(json!({"op":if connected{"music.disconnect"}else{"music.connect"},"id":id}))})));
                        row = row.child(buttons);
                    }
                    services = services.child(row);
                }
                form = form.child(services);
            }
            2 => {
                let configured =
                    self.snapshot["space"]["credentialConfigured"].as_bool() == Some(true);
                let detail = self.snapshot["space"]["options"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .find(|value| value["id"] == self.draft["space"]["defaultSpace"])
                    .and_then(|value| value["detail"].as_str())
                    .unwrap_or("");
                form=form.child(group("默认空间").child(self.dropdown("default-space","启动时进入","space","defaultSpace",self.options("space","options"),cx))
                    .child(div().text_xs().child(detail.to_owned())).child(div().text_xs().child("修改后下次启动生效。")))
                    .child(group("Marble 空间")
                        .child(div().flex().items_center().gap(px(12.)).child(div().w(px(28.)).flex_shrink_0().child(Icon::new(IconName::Box).size(px(22.))))
                            .child(div().flex_1().flex().flex_col().gap(px(2.)).child("World Labs Marble").child(div().text_xs().child("用于同步和生成可探索的 3D 空间")))
                            .child(div().text_sm().child(if configured{"已配置"}else{"未配置"})))
                        .child(div().flex().items_center().gap_3().child("API Key").child(div().flex_1().min_w(px(0.)).child(Input::new(&self.extra_inputs[2]))))
                        .child(div().flex().items_center().gap_2().child(div().flex_1().text_xs().child("只保存在本机，不使用钥匙串。"))
                            .when(configured,|row|row.child(self.command_button("marble-clear","清除",json!({"op":"space.key.clear"}),cx)))
                            .child(Button::new("marble-save").label("保存 Key").disabled(self.extra_inputs[2].read(cx).value().trim().is_empty()).on_click(cx.listener(|this,_,_,cx|this.commands.push(json!({"op":"space.key.save","apiKey":this.extra_inputs[2].read(cx).value().to_string()})))))))
                    .child(group("许愿机").child(Input::new(&self.extra_inputs[5])).child(Input::new(&self.extra_inputs[6]))
                    .child(div().flex().items_center().gap_2()
                        .child(div().flex_1().text_sm().child(if self.snapshot["space"]["propCredentialConfigured"].as_bool()==Some(true){"已配置"}else{"未配置"}))
                        .child(Button::new("prop-check").label(if self.snapshot["space"]["propChecking"].as_bool()==Some(true){"检测中…"}else{"检测连接"}).disabled(self.snapshot["space"]["propCredentialConfigured"].as_bool()!=Some(true)||self.snapshot["space"]["propChecking"].as_bool()==Some(true)||!self.extra_inputs[6].read(cx).value().is_empty()).on_click(cx.listener(|this,_,_,_|this.commands.push(json!({"op":"space.prop.check"})))))
                        .child(Button::new("prop-save").label("保存").disabled(self.extra_inputs[5].read(cx).value().trim().is_empty()).on_click(cx.listener(|this,_,_,cx|this.commands.push(json!({"op":"space.prop.save","endpoint":this.extra_inputs[5].read(cx).value().to_string(),"apiKey":this.extra_inputs[6].read(cx).value().to_string()}))))))
                    .child(div().text_xs().child("地址和密钥只存在这台电脑上，保存后不会立刻开始生成。")));
            }
            3 => {
                let mut shortcuts = group("")
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap(px(16.))
                            .text_xs()
                            .child(div().flex_1().child("功能"))
                            .child(div().w(px(136.)).child("应用内"))
                            .child(div().w(px(136.)).child("全局")),
                    )
                    .child(div().h(px(1.)).bg(border));
                for item in self.snapshot["shortcuts"]["assignments"]
                    .as_array()
                    .into_iter()
                    .flatten()
                {
                    let id = item["id"].clone();
                    let mut row = div().flex().items_center().gap(px(16.)).h(px(38.)).child(
                        div()
                            .flex_1()
                            .min_w(px(0.))
                            .child(item["title"].as_str().unwrap_or("").to_owned()),
                    );
                    for scope in ["local", "global"] {
                        let recording = self.snapshot["shortcuts"]["recordingID"] == id
                            && self.snapshot["shortcuts"]["recordingScope"].as_str() == Some(scope);
                        row=row.child(div().w(px(136.)).flex_shrink_0().child(Button::new(format!("shortcut-{id}-{scope}")).w(px(136.)).label(if recording{"请按快捷键"}else{item[scope].as_str().unwrap_or("未设置")}.to_owned()).on_click(cx.listener({let id=id.clone();move|this,_,_,_|this.commands.push(json!({"op":"shortcuts.record","id":id,"scope":scope}))}))));
                    }
                    shortcuts = shortcuts.child(row);
                }
                form = form
                    .child(shortcuts)
                    .child(
                        group("")
                            .child(
                                Switch::new("global-shortcuts")
                                    .label("启用全局快捷键")
                                    .checked(
                                        self.snapshot["shortcuts"]["globalEnabled"]
                                            .as_bool()
                                            .unwrap_or(false),
                                    )
                                    .on_change(cx.listener(|this, value: &bool, _, _| {
                                        this.commands
                                            .push(json!({"op":"shortcuts.global","value":value}))
                                    })),
                            )
                            .child(div().text_xs().child("gmgn radio 在后台时也能响应。"))
                            .child(
                                Switch::new("media-shortcuts")
                                    .label("使用系统媒体快捷键")
                                    .checked(
                                        self.snapshot["shortcuts"]["mediaKeysEnabled"]
                                            .as_bool()
                                            .unwrap_or(false),
                                    )
                                    .on_change(cx.listener(|this, value: &bool, _, _| {
                                        this.commands
                                            .push(json!({"op":"shortcuts.media","value":value}))
                                    })),
                            )
                            .child(
                                div()
                                    .text_xs()
                                    .child("响应键盘上的播放、暂停、上一首和下一首。"),
                            ),
                    )
                    .child(
                        group("").child(div().flex().justify_end().child(self.command_button(
                            "shortcuts-reset",
                            "恢复默认",
                            json!({"op":"shortcuts.reset"}),
                            cx,
                        ))),
                    );
            }
            _ => {}
        }
        form.into_any_element()
    }
}

impl Render for AgentSettingsPane {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        use gpui_kit::component::tab::{Tab, TabBar};
        let titles = ["角色", "音乐", "空间", "快捷键", "DJ"];
        let (title, subtitle) = match self.page {
            0 => ("角色与动作", "选择 DJ 的形象与表演动作"),
            1 => ("音乐", "DJ 可以使用的账号"),
            2 => ("空间", "选择默认空间，并管理空间生成服务"),
            3 => ("快捷键", "点击按键框，再按下新的组合键"),
            _ => ("Agent 与语音", "文字和语音共用同一会话，回答后再朗读"),
        };
        let content = if self.page == 4 {
            self.dj_form(cx)
        } else {
            self.basic_form(cx)
        };
        let mut header = div()
            .px(px(20.))
            .py(px(if self.page == 4 { 14. } else { 18. }))
            .flex_shrink_0()
            .flex()
            .items_center()
            .justify_between()
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(3.))
                    .child(div().text_lg().child(title))
                    .child(div().text_sm().child(subtitle)),
            );
        if self.page == 0 {
            let weak = cx.entity().downgrade();
            header = header.child(
                Button::new("presence-import")
                    .label("导入")
                    .dropdown_caret(true)
                    .dropdown_menu(move |menu, _, _| {
                        let a = weak.clone();
                        let b = weak.clone();
                        let c = weak.clone();
                        menu.item(PopupMenuItem::new("角色模型…").on_click(move |_, _, cx| {
                            _ = a.update(cx, |this, cx| {
                                this.commands.push(json!({"op":"presence.import"}));
                                cx.notify();
                            });
                        }))
                        .item(PopupMenuItem::new("动作文件…").on_click(move |_, _, cx| {
                            _ = b.update(cx, |this, cx| {
                                this.commands.push(json!({"op":"presence.motion.import"}));
                                cx.notify();
                            });
                        }))
                        .item(
                            PopupMenuItem::new("从链接导入角色…").on_click(move |_, window, cx| {
                                _ = c.update(cx, |this, cx| this.open_import_link(window, cx));
                            }),
                        )
                    }),
            );
        }
        let mut root = div()
            .size_full()
            .flex()
            .flex_col()
            .bg(cx.theme().tokens.background)
            .text_color(cx.theme().foreground)
            .child(
                div()
                    .flex()
                    .justify_center()
                    .pt(px(14.))
                    .pb(px(8.))
                    .flex_shrink_0()
                    .child(
                        TabBar::new("settings-tabs")
                            .segmented()
                            .small()
                            .w(px(330.))
                            .h(px(24.))
                            .selected_index(self.page)
                            .children(titles.map(|title| Tab::new().flex_1().min_w(px(0.)).text_xs().label(title)))
                            .on_click(cx.listener(|this, index: &usize, _, cx| {
                                if this.page == 3 && *index != 3 {
                                    this.commands.push(json!({"op":"shortcuts.cancel"}));
                                }
                                this.page = *index;
                                if *index == 0 {
                                    this.commands.push(json!({"op":"presence.load"}));
                                }
                                cx.notify();
                            })),
                    ),
            )
            .child(header)
            .child(
                div()
                    .id(("settings-form", self.page))
                    .flex_1()
                    .min_h(px(0.))
                    .overflow_y_scroll()
                    .px(px(20.))
                    .pb(px(14.))
                    .child(content),
            );
        if let Some(notice) = self.snapshot
            [["presence", "music", "space", "shortcuts", "agent"][self.page]]["notice"]
            .as_str()
        {
            root = root.child(
                div()
                    .flex_shrink_0()
                    .px(px(20.))
                    .pb(px(14.))
                    .max_h(px(42.))
                    .overflow_hidden()
                    .text_xs()
                    .child(notice.to_owned()),
            );
        }
        root
    }
}

#[cfg(test)]
mod settings_display_tests {
    use super::{avatar_detail, motion_format};
    use serde_json::json;
    #[test]
    fn built_in_character_detail_matches_original_display() {
        assert_eq!(
            avatar_detail(&json!({"engine":"orb","isBuiltIn":true,"detail":"orb · 1.0.0"})),
            "内置 · 呼吸球"
        );
        assert_eq!(
            avatar_detail(&json!({"engine":"pmx","isBuiltIn":false,"detail":"pmx · 4.14.0"})),
            "PMX · 4.14.0"
        );
    }
    #[test]
    fn real_display_detail_preserves_package_author() {
        assert_eq!(
            avatar_detail(
                &json!({"engine":"vrm","isBuiltIn":false,"displayDetail":"原作者 · 2.0"})
            ),
            "原作者 · 2.0"
        );
    }
    #[test]
    fn original_motion_names_do_not_show_protocol_identifiers() {
        assert_eq!(motion_format("procedural"), "内置动态");
        assert_eq!(motion_format("vmd"), "VMD");
        assert_eq!(motion_format("vrma"), "VRMA");
    }
}
