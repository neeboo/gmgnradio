//! Product settings controls. Catalogs and all side effects come from ProductHost.
use crate::ui_tokens as ui;
use crate::i18n::{UiLocale, language_command, settings_copy, settings_navigation_label, settings_notice};
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

// macOS virtual key codes used by the original shortcut authority. GPUI lives
// in another process, so key recording must cross the settings transport.
fn shortcut_capture_command(key: &str, modifiers: u64) -> Option<Value> {
    let key = key.to_ascii_lowercase();
    if key == "escape" { return Some(json!({"op":"shortcuts.cancel"})); }
    let (code, label) = match key.as_str() {
        "space" => (49, "Space".to_owned()),
        "left" => (123, "←".to_owned()), "right" => (124, "→".to_owned()),
        "down" => (125, "↓".to_owned()), "up" => (126, "↑".to_owned()),
        "enter" => (36, "Return".to_owned()), "tab" => (48, "Tab".to_owned()),
        "backspace" => (51, "Delete".to_owned()),
        other => {
            let codes = [("a",0),("s",1),("d",2),("f",3),("h",4),("g",5),("z",6),("x",7),("c",8),("v",9),("b",11),
                ("q",12),("w",13),("e",14),("r",15),("y",16),("t",17),("1",18),("2",19),("3",20),("4",21),("6",22),("5",23),
                ("=",24),("9",25),("7",26),("-",27),("8",28),("0",29),("]",30),("o",31),("u",32),("[",33),("i",34),("p",35),
                ("l",37),("j",38),("'",39),("k",40),(";",41),("\\",42),(",",43),("/",44),("n",45),("m",46),(".",47),("`",50),
                ("f1",122),("f2",120),("f3",99),("f4",118),("f5",96),("f6",97),("f7",98),("f8",100),("f9",101),("f10",109),("f11",103),("f12",111)];
            let (_, code) = codes.iter().find(|(name,_)|*name==other)?;
            (*code, other.to_uppercase())
        }
    };
    Some(json!({"op":"shortcuts.capture","keyCode":code,"keyLabel":label,"modifiers":modifiers}))
}

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

fn tts_draft_change_requires_stop(section:&str,field:&str,previous:&Value,current:&Value)->bool {
    section=="tts"&&matches!(field,"voiceID"|"modelID")&&previous!=current
}
fn save_ack_clear(revision:u64,ack:u64,submitted:&str,current:&str)->bool{
    ack>revision&&submitted==current
}
fn presence_more_accessibility(action:&str,name:&str)->(Role,String){
    (Role::Button,format!("{}「{name}」的更多操作",action.trim_start_matches("移除")))
}
fn music_sync_command(provider:&Value,working:bool)->Option<Value>{
    if working||provider["syncing"].as_bool()==Some(true)||provider["connected"].as_bool()!=Some(true){return None;}
    Some(json!({"op":"music.sync","id":provider["id"]}))
}
fn unity_section_available(snapshot: &Value, section: &str) -> bool {
    snapshot["unity"]["availableSections"].as_array().is_some_and(|sections| sections.iter().any(|value| value.as_str() == Some(section)))
}
fn unity_agent_group_available(snapshot: &Value, title: &str) -> bool {
    snapshot["unity"]["availableAgentGroups"].as_array().is_some_and(|groups| groups.iter().any(|value| value.as_str() == Some(title)))
}
fn marble_command(library: &Value, op: &str, value: &str) -> Option<Value> {
    let working = library["marbleWorking"].as_bool() == Some(true);
    let pending = library["marbleOperationID"].as_str().is_some_and(|id| !id.is_empty());
    if op == "space.marble.cancel" {
        return working.then(|| json!({"op": op}));
    }
    if library["generationSupported"].as_bool() != Some(true) || working { return None; }
    match op {
        "space.marble.generate" if !pending && library["marblePresets"].as_array()
            .is_some_and(|presets| presets.iter().any(|preset| preset["id"].as_str() == Some(value))) =>
            Some(json!({"op": op, "presetID": value})),
        "space.marble.resume" if pending => Some(json!({"op": op})),
        "space.marble.import" if !pending && !value.trim().is_empty() => Some(json!({"op": op, "worldID": value.trim()})),
        _ => None,
    }
}
fn marble_phase_label(phase: &str) -> &'static str {
    match phase {
        "generating" => "正在生成空间",
        "downloading" => "正在下载空间资产",
        "validating" => "正在校验空间运行包",
        "registering" => "正在注册空间",
        "registered" => "空间已导入",
        "resume_available" => "已有待恢复的生成任务",
        "cancelled" => "本机任务已取消",
        "cancelled_remote_operation_may_continue" => "本机等待已取消，远端生成可能继续；可恢复原任务。",
        "failed" => "空间任务失败",
        _ => "",
    }
}

#[cfg(test)]
mod unity_settings_capability_tests {
    use super::{unity_agent_group_available, unity_section_available};
    use serde_json::{Value, json};
    #[test]
    fn host_capabilities_enable_real_groups_and_keep_missing_groups_explicit() {
        let snapshot = json!({"unity":{"availableSections":["歌词","视觉效果","语音播放","自主行动"],"availableAgentGroups":["回复语音","居民人格"]}});
        assert!(unity_section_available(&snapshot, "视觉效果"));
        assert!(unity_agent_group_available(&snapshot, "居民人格"));
        assert!(!unity_agent_group_available(&snapshot, "自主行动"));
        assert!(!unity_section_available(&snapshot, "音乐账号与歌单同步"));
        assert!(!unity_section_available(&Value::Null, "歌词"));
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
    visible: bool,
}
impl SettingsGroup {
    fn visible(mut self, visible:bool)->Self{self.visible=visible;self}
    fn row_gap(mut self,gap:Pixels)->Self{self.content=self.content.gap(gap);self}
    fn new(title: &'static str, border: Hsla) -> Self {
        Self {
            title,
            visible:true,
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
        if !self.visible{return div().into_any_element();}
        let mut group = div().flex().flex_col().gap(px(ui::SPACING_8));
        if !self.title.is_empty() {
            group = group.child(
                div()
                    .pl(px(ui::SPACING_12))
                    .text_size(px(ui::CAPTION))
                    .text_color(cx.theme().muted_foreground)
                    .child(self.title),
            );
        }
        group.child(self.content).into_any_element()
    }
}

pub struct AgentSettingsPane {
    snapshot: Value,
    draft: Value,
    inputs: Vec<Entity<InputState>>,
    personas: Vec<Entity<TextareaState>>,
    commands: Vec<Value>,
    initialized: bool,
    unity_external: bool,
    page: usize,
    section: String,
    stage_pane: Option<Entity<crate::stage_panels::StagePanelsPane>>,
    extra_inputs: Vec<Entity<InputState>>,
    motion_category: String,
    orb_color: Entity<ColorPickerState>,
    orb_intensity: Entity<SliderState>,
    position_inputs: Vec<Entity<InputState>>,
    position_dirty: bool,
    syncing_position: bool,
    position_world: String,
    position_revision: u64,
    position_layout_revision: u64,
    position_notice: Option<String>,
    video_brightness: Entity<SliderState>,
    syncing_video: bool,
    _subscriptions: Vec<Subscription>,
    import_link_open: bool,
    custom_voice_open: bool,
    import_link_window: Option<AnyWindowHandle>,
    import_link_pending: bool,
    import_link_revision: u64,
    pending_marble:Option<(u64,String)>,
    pending_prop:Option<(u64,String,String)>,
}
impl AgentSettingsPane {
    fn open_import_link(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let locale = UiLocale::from_settings(&self.snapshot);
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
                .child(div().text_sm().child(settings_copy(locale, "支持 HTTPS 地址指向 VRM、ZIP 或 gmgnpet 模型包。")))
                .child(Input::new(&input));
            if let Some(notice)=notice{body=body.child(div().flex().items_center().gap_1().text_xs().text_color(cx.theme().danger).child(Icon::new(IconName::CircleAlert).size(px(14.))).child(notice));}
            dialog.w(px(460.)).h(px(230.)).p(px(24.)).title(settings_copy(locale, "从链接导入角色")).close_button(false).overlay_closable(false).child(body)
                .footer(div().flex().justify_end().items_center().gap_2().capture_key_down(move|event,window,cx|{
                    if event.keystroke.key=="escape"{_=escape_footer.update(cx,|this,cx|{this.import_link_open=false;cx.notify();});window.close_dialog(cx);cx.stop_propagation();}
                })
                    .child(Button::new("cancel-link").label(settings_copy(locale, "取消")).on_click(move|_,window,cx|{_=cancel.update(cx,|this,cx|{this.import_link_open=false;cx.notify();});window.close_dialog(cx);} ))
                    .child(Button::new("import-link").label(settings_copy(locale, if working{"正在下载…"}else{"下载并安装"})).disabled(disabled).on_click(move|_,_,cx|{_=submit.update(cx,|this,cx|{
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
        asset_name:&str,
        command: Value,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let weak = cx.entity().downgrade();
        let locale = UiLocale::from_settings(&self.snapshot);
        let (role, mut name)=presence_more_accessibility(label,asset_name);
        if locale != UiLocale::ZhCn { name = format!("{}: {asset_name}", settings_copy(locale, "更多操作")); }
        let label = settings_copy(locale, label);
        Button::new(id)
            .role(role).accessibility_label(name)
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
            "角色人格与偏好",
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
        let personas = ["居民人格", "角色人格与偏好"]
            .map(|label| cx.new(|cx| TextareaState::new(window, cx).placeholder(label).rows(4)))
            .to_vec();
        let extra_inputs:Vec<Entity<InputState>> = [
            "新的 TTS API Key",
            "新的 ASR API Key",
            "新的 Marble API Key",
            "https://…/catalog.json",
            "https://…/avatar.vrm",
            "生成服务地址",
            "生成服务密钥",
            "Marble World ID",
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
        let position_inputs: Vec<_> = ["X", "Y", "Z"].into_iter()
            .map(|axis| cx.new(|cx| InputState::new(window, cx).placeholder(axis))).collect();
        let video_brightness = cx.new(|_| SliderState::new().min(0.).max(1.).step(0.01));
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
        let mut subscriptions=vec![escape_subscription,cx.subscribe(&inputs[3],|this,input,event:&InputEvent,cx|{
            if matches!(event,InputEvent::Change)&&this.initialized{
                let current=json!(input.read(cx).value().to_string());
                if tts_draft_change_requires_stop("tts","voiceID",&this.draft["tts"]["voiceID"],&current){
                    this.commands.push(json!({"op":"tts.stop"}));this.draft["tts"]["voiceID"]=current;cx.notify();
                }
            }
        }),cx.subscribe(&extra_inputs[0],|this,_,event:&InputEvent,cx|{
            if matches!(event,InputEvent::Change)&&this.initialized{this.commands.push(json!({"op":"speech.settings.cancel","clearVoices":true,"cancelCapabilities":false}));cx.notify();}
        }),cx.subscribe(&extra_inputs[3],|this,input,event:&InputEvent,cx|{
            if matches!(event,InputEvent::PressEnter{..})&&this.snapshot["presence"]["working"].as_bool()!=Some(true){
                let url=input.read(cx).value().to_string();if !url.trim().is_empty(){this.commands.push(json!({"op":"presence.catalog","url":url}));cx.notify();}
            }
        }),cx.subscribe(&extra_inputs[5],|this,_,event:&InputEvent,cx|{
            if matches!(event,InputEvent::Change)&&this.initialized&&!this.unity_external{this.commands.push(json!({"op":"space.prop.cancel","clearNotice":true}));cx.notify();}
        }),cx.subscribe(&extra_inputs[6],|this,_,event:&InputEvent,cx|{
            if matches!(event,InputEvent::Change)&&this.initialized&&!this.unity_external{this.commands.push(json!({"op":"space.prop.cancel","clearNotice":true}));cx.notify();}
        }),cx.subscribe(&extra_inputs[7],|_,_,event:&InputEvent,cx|{
            if matches!(event,InputEvent::Change){cx.notify();}
        }),cx.subscribe(&inputs[2],|this,input,event:&InputEvent,cx|{
            if matches!(event,InputEvent::Change) && this.initialized {this.commands.push(json!({"op":"agent.save","planningModel":input.read(cx).value().to_string()}));}
        }),cx.subscribe(&orb_color,|this,_,event:&ColorPickerEvent,cx|{
            if let ColorPickerEvent::Change(Some(color))=event{let color=color.to_rgb();this.commands.push(json!({"op":"presence.orb.color","red":color.r,"green":color.g,"blue":color.b}));cx.notify();}
        }),cx.subscribe(&orb_intensity,|this,_,event:&SliderEvent,cx|{
            if let SliderEvent::Change(value)=event{this.commands.push(json!({"op":"presence.orb.intensity","value":value.start()}));cx.notify();}
        }),cx.subscribe(&video_brightness,|this,_,event:&SliderEvent,cx|{
            if !this.syncing_video { if let SliderEvent::Change(value)=event { this.commands.push(json!({"op":"video.brightness","value":value.start()}));cx.notify(); } }
        })];
        for input in &position_inputs {
            subscriptions.push(cx.subscribe(input, |this, _, event: &InputEvent, cx| {
                if matches!(event, InputEvent::Change) && !this.syncing_position {
                    this.position_dirty = true; this.position_notice = None; cx.notify();
                }
            }));
        }
        Self {
            snapshot: Value::Null,
            draft: Value::Null,
            inputs,
            personas,
            commands: vec![json!({"op":"settings.load"})],
            initialized: false,
            unity_external: false,
            page: 0,
            section: "角色管理".into(),
            stage_pane: None,
            extra_inputs,
            motion_category: String::new(),
            orb_color,
            orb_intensity,
            position_inputs,
            position_dirty: false,
            syncing_position: false,
            position_world: String::new(),
            position_revision: 0,
            position_layout_revision: 0,
            position_notice: None,
            _subscriptions: subscriptions,
            video_brightness,
            syncing_video: false,
            import_link_open: false,
            custom_voice_open: false,
            import_link_window: None,
            import_link_pending: false,
            import_link_revision: 0,
            pending_marble:None,
            pending_prop:None,
        }
    }
    pub fn take_commands(&mut self) -> Vec<Value> {
        std::mem::take(&mut self.commands)
    }
    pub fn select_page(&mut self, page: &str, cx: &mut Context<Self>) {
        if self.page==4&&!matches!(page,"agent"|"dj"){self.commands.push(json!({"op":"speech.settings.cancel"}));}
        if self.page==2&&!self.unity_external{self.commands.push(json!({"op":"space.prop.cancel"}));}
        if self.page == 3 {
            self.commands.push(json!({"op":"shortcuts.cancel"}));
        }
        self.page = match page {
            "music" => 1,
            "space-preferences" => 2,
            "space" => 6,
            "player" => 5,
            "activities" => 7,
            "shortcuts" => 3,
            "agent" | "dj" => 4,
            _ => 0,
        };
        if self.unity_external && self.page == 6 { self.commands.push(json!({"op":"space.library.load"})); }
        let valid=match self.page {0=>matches!(self.section.as_str(),"角色管理"|"动作管理"),1=>self.section=="音乐账号与歌单同步",2=>self.section=="生成服务",3=>self.section=="快捷键",4=>matches!(self.section.as_str(),"Agent 连接"|"语音播放"|"按住说话"|"自主行动"),5=>matches!(self.section.as_str(),"歌词"|"视觉效果"|"视频"),6=>self.section=="我的空间",_=>true};
        if !valid{self.section=match self.page{0=>"角色管理",1=>"音乐账号与歌单同步",2=>"生成服务",3=>"快捷键",4=>"Agent 连接",5=>"歌词",6=>"我的空间",_=>"活动"}.into();}
        if self.page == 0 {
            self.commands.push(json!({"op":"presence.load"}));
        }
        if self.page==4{self.commands.push(json!({"op":"speech.settings.load"}));}
        if let Some(stage) = &self.stage_pane {
            let tab = match self.page {5=>Some("player"),6=>Some("space"),7=>Some("activities"),_=>None};
            if let Some(tab)=tab {stage.update(cx, |stage,cx| {stage.select_tab(tab,cx);stage.select_section(&self.section,cx);});}
        }
        cx.notify();
    }
    pub fn set_stage_pane(&mut self, pane: Entity<crate::stage_panels::StagePanelsPane>, cx: &mut Context<Self>) {
        pane.update(cx, |stage,cx| stage.set_embedded(true,cx));
        self.stage_pane = Some(pane);
        cx.notify();
    }
    pub fn set_unity_external(&mut self, enabled: bool, cx: &mut Context<Self>) {
        self.unity_external = enabled;
        cx.notify();
    }
    pub fn select_section(&mut self,page:&str,section:&str,cx:&mut Context<Self>){
        self.section=section.into();self.select_page(page,cx);
        if self.unity_external && section == "视频" { self.commands.push(json!({"op":"video.load"})); }
        if let Some(stage)=&self.stage_pane{stage.update(cx,|stage,cx|stage.select_section(section,cx));}
    }
    pub fn dismissed(&mut self, cx: &mut Context<Self>) {
        if !self.unity_external { self.commands.push(json!({"op":"space.prop.cancel"})); }
        self.commands.push(json!({"op":"shortcuts.cancel"}));
        self.commands.push(json!({"op":"speech.settings.cancel"}));
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
        let locale = UiLocale::from_settings(&snapshot);
        for (index, source) in [(0, "新的 TTS API Key"), (1, "新的 ASR API Key")] {
            self.extra_inputs[index].update(cx, |input, cx| input.set_placeholder(settings_copy(locale, source), window, cx));
        }
        self.inputs[3].update(cx, |input, cx| input.set_placeholder(settings_copy(locale, "自定义音色 ID"), window, cx));
        for (index, source) in [(0, "居民人格"), (1, "角色人格与偏好")] {
            self.personas[index].update(cx, |input, cx| input.set_placeholder(settings_copy(locale, source), window, cx));
        }
        self.inputs[2].update(cx,|input,cx|input.set_placeholder(settings_copy(locale, "使用 Codex 默认模型"),window,cx));
        self.extra_inputs[5].update(cx,|input,cx|input.set_placeholder(settings_copy(locale, "生成服务地址"),window,cx));
        self.extra_inputs[7].update(cx,|input,cx|input.set_placeholder(settings_copy(locale, "Marble World ID"),window,cx));
        self.extra_inputs[2].update(cx,|input,cx|input.set_placeholder(settings_copy(locale, if snapshot["space"]["credentialConfigured"].as_bool()==Some(true){"粘贴新的 API Key 可覆盖现有配置"}else{"粘贴 API Key"}),window,cx));
        self.extra_inputs[6].update(cx,|input,cx|input.set_placeholder(settings_copy(locale, if snapshot["space"]["propCredentialConfigured"].as_bool()==Some(true){"填写新密钥可替换；留空保留现有密钥"}else{"生成服务密钥"}),window,cx));
        if self.unity_external {
            self.extra_inputs[6].update(cx, |input, cx| input.set_placeholder(settings_copy(locale, if snapshot["generation"]["configured"].as_bool() == Some(true) { "填写新密钥可替换；留空保留现有密钥" } else { "生成服务密钥" }), window, cx));
        }
        if let Some((revision,submitted))=&self.pending_marble{
            if snapshot["space"]["marbleMutationRevision"].as_u64().is_some_and(|ack|ack>*revision){
                if save_ack_clear(*revision,snapshot["space"]["marbleMutationRevision"].as_u64().unwrap_or(0),submitted,self.extra_inputs[2].read(cx).value().as_str()){self.extra_inputs[2].update(cx,|input,cx|input.set_value("",window,cx));}
                self.pending_marble=None;
            }
        }
        if let Some((revision,endpoint,key))=&self.pending_prop{
            if snapshot["space"]["propSaveRevision"].as_u64().is_some_and(|ack|ack>*revision){
                if self.extra_inputs[5].read(cx).value().as_str()==endpoint{let normalized=snapshot["space"]["propEndpoint"].as_str().unwrap_or(endpoint).to_owned();self.extra_inputs[5].update(cx,|input,cx|input.set_value(normalized,window,cx));}
                if save_ack_clear(*revision,snapshot["space"]["propSaveRevision"].as_u64().unwrap_or(0),key,self.extra_inputs[6].read(cx).value().as_str()){self.extra_inputs[6].update(cx,|input,cx|input.set_value("",window,cx));}
                self.pending_prop=None;
            }
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
                let value = if self.unity_external && index == 5 { snapshot["generation"]["endpoint"].as_str() } else { snapshot[section][field].as_str() }.unwrap_or("").to_owned();
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
        if let Some(value) = snapshot["video"]["brightness"].as_f64().filter(|value| value.is_finite()) {
            self.syncing_video = true;
            self.video_brightness.update(cx, |slider, cx| slider.set_value(value as f32, window, cx));
            self.syncing_video = false;
        }
        let position = &snapshot["characterPosition"];
        let world = position["worldID"].as_str().unwrap_or("");
        if world != self.position_world || !self.position_dirty {
            self.syncing_position = true;
            for (index, input) in self.position_inputs.iter().enumerate() {
                let value = position["position"][index].as_f64().map(|v| format!("{v:.3}")).unwrap_or_default();
                input.update(cx, |input, cx| input.set_value(value, window, cx));
            }
            self.syncing_position = false; self.position_dirty = false;
            self.position_world = world.to_owned();
            self.position_revision = position["revision"].as_u64().unwrap_or(0);
            self.position_layout_revision = position["layoutRevision"].as_u64().unwrap_or(0);
            self.position_notice = None;
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
        if tts_draft_change_requires_stop(section,field,&self.draft[section][field],&value){self.commands.push(json!({"op":"tts.stop"}));}
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
                            settings_copy(UiLocale::from_settings(&self.snapshot), "0 轮（不再新起）").to_owned()
                        } else {
                            format!("{n} {}", settings_copy(UiLocale::from_settings(&self.snapshot), "轮"))
                        },
                    ))
                } else {
                    let raw = v.get("name")?.as_str()?;
                    let mut name = if (section == "presence" && key == "categories") || (section == "asr" && key == "microphoneDevices") {
                        settings_copy(UiLocale::from_settings(&self.snapshot), raw).to_owned()
                    } else { raw.to_owned() };
                    if key=="models"&&v["id"]==self.snapshot[section]["defaultModelID"]{name.push_str(settings_copy(UiLocale::from_settings(&self.snapshot), "（默认）"));}
                    if v.get("installed").and_then(Value::as_bool) == Some(false) {
                        name.push_str(settings_copy(UiLocale::from_settings(&self.snapshot), "（未安装）"));
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
        let locale = UiLocale::from_settings(&self.snapshot);
        let t = |source: &'static str| settings_copy(locale, source);
        let value = self.draft[section][field].clone();
        let selected = items
            .iter()
            .find(|(id, _)| *id == value)
            .map(|(_, name)| name.clone())
            .unwrap_or_else(|| {
                value
                    .as_str()
                    .filter(|s| !s.is_empty())
                    .map(|raw|if field=="modelID"{t("旧模型不受支持，请重新选择").to_owned()}else if field=="voiceID"{format!("{} ({raw})", t("当前声音"))}else{raw.to_owned()})
                    .unwrap_or_else(||if field=="modelID"{t("正在加载模型选项").to_owned()}else{t("请选择").to_owned()})
            });
        let weak = cx.entity().downgrade();
        div()
            .flex()
            .items_center()
            .justify_between()
            .gap_3()
            .child(t(label))
            .child(
                Button::new(id)
                    .label(selected)
                    .dropdown_caret(true)
                    .disabled(items.is_empty()||(section=="tts"&&field=="voiceID"&&self.snapshot["tts"]["loading"].as_bool()==Some(true)))
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
            .label(settings_copy(UiLocale::from_settings(&self.snapshot), label))
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
        let locale = UiLocale::from_settings(&self.snapshot);
        let t = |source: &'static str| settings_copy(locale, source);
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
            .gap(px(ui::SPACING_12))
            .text_size(px(ui::BODY)).line_height(px(ui::BODY_LINE_HEIGHT))
            .bg(theme.tokens.background)
            .text_color(theme.foreground);
        if !self.initialized {
            return form
                .child(t("加载中…"))
                .into_any_element();
        }
        let group = |title: &'static str| SettingsGroup::new(t(title), border).visible((!self.unity_external || unity_agent_group_available(&self.snapshot, title)) && match self.section.as_str(){"语音播放"=>title=="回复语音","按住说话"=>title=="按住说话","自主行动"=>matches!(title,"角色人格与偏好"|"居民人格"|"自主行动"),_=>matches!(title,"角色内核"|"聊天模型")});
        form=form.child(group("角色内核")
            .child(div().flex().items_center().gap(px(12.)).child(div().size(px(32.)).rounded_lg().bg(cx.theme().muted).flex().items_center().justify_center().child(Icon::new(IconName::Terminal).size(px(20.))))
                .child(div().flex_1().flex().flex_col().child(settings_copy(locale, "gmgn 角色")).child(settings_notice(locale, self.snapshot["agent"]["codexStatus"].as_str().unwrap_or("策划引擎未登录"))))
                .child(Button::new("codex-login").label(t(if self.snapshot["agent"]["codexState"].as_str()==Some("signedIn"){"退出登录"}else{"登录"}))
                    .disabled(self.snapshot["agent"]["working"].as_bool()==Some(true)||self.snapshot["agent"]["codexState"].as_str()==Some("unavailable"))
                    .on_click(cx.listener(|this,_,_,_|this.commands.push(json!({"op":if this.snapshot["agent"]["codexState"].as_str()==Some("signedIn"){"agent.logout"}else{"agent.login"}}))))))
            .child(div().text_size(px(ui::CAPTION)).line_height(px(ui::CAPTION_LINE_HEIGHT)).child(settings_copy(locale, if self.unity_external { "Codex 账号用于选择 Codex 后端；当前聊天后端以下方选择为准。" } else { "Codex 提供策划和推理能力；它与下面的声音共同属于同一个角色。" })))
            .when(!self.unity_external || self.snapshot["unity"]["planningSupported"].as_bool()==Some(true), |group| group
            .child(self.toggle("takeover","允许角色自动接管","takeoverEnabled",cx))
            .child(div().text_size(px(ui::CAPTION)).line_height(px(ui::CAPTION_LINE_HEIGHT)).child(settings_copy(locale, "可以自主切歌、暂停、继续、重排节目和调整视觉。")))
            .child(div().flex().justify_between().items_center().child(settings_copy(locale, "策划模型")).child(div().w(px(220.)).child(Input::new(&self.inputs[2]))))))
            .child(group("角色人格与偏好").child(div().h(px(150.)).min_h(px(150.)).flex_shrink_0()
                .child(Textarea::new(&self.personas[1]).h(px(150.)).aria_label(t("角色人格与偏好")).accessibility_id("dj-host-prompt")))
            .child(div().flex().justify_between().items_center().gap(px(ui::SPACING_12)).child(div().flex_1().min_w(px(0.)).text_size(px(ui::BODY)).line_height(px(ui::BODY_LINE_HEIGHT)).child(t("用自然语言告诉角色怎么策划和主持。")))
                .child(Button::new("save-dj").flex_shrink_0().primary().label(t("保存")).on_click(cx.listener(|this,_,_,cx|this.commands.push(json!({"op":"agent.save","hostPrompt":this.personas[1].read(cx).value().to_string()})))))))
            .child(group("居民人格").child(div().h(px(120.)).min_h(px(120.)).flex_shrink_0()
                .child(Textarea::new(&self.personas[0]).h(px(120.)).aria_label(t("居民人格")).accessibility_id("resident-persona")))
            .child(div().flex().justify_between().items_center().gap(px(ui::SPACING_12)).child(div().flex_1().min_w(px(0.)).text_size(px(ui::BODY)).line_height(px(ui::BODY_LINE_HEIGHT)).child(t("只影响居民，和上面的角色偏好分开。人格只改语气和关注点，不改变它能做什么。")))
                .child(Button::new("save-resident").flex_shrink_0().primary().label(t("保存")).on_click(cx.listener(|this,_,_,cx|this.commands.push(json!({"op":"agent.save","residentPersona":this.personas[0].read(cx).value().to_string()})))))))
            .child(group("聊天模型")
            .child(self.dropdown("backend","模型","agent","backendID",self.options("agent","backends"),cx))
            .children(self.snapshot["agent"]["backendStatus"].as_str().map(|status|div().text_size(px(ui::CAPTION)).line_height(px(ui::CAPTION_LINE_HEIGHT)).child(settings_notice(locale, status))))
            .child(div().text_size(px(ui::CAPTION)).line_height(px(ui::CAPTION_LINE_HEIGHT)).child(settings_copy(locale, "空间和 Live Cam 共用这里选定的 Agent；文字和语音转写进入同一个会话。"))))
            .child(group("自主行动")
            .child(self.toggle("autonomy","允许居民自主安排活动","autonomyEnabled",cx))
            .child(div().text_size(px(ui::CAPTION)).line_height(px(ui::CAPTION_LINE_HEIGHT)).child(settings_copy(locale, "打开后，居民会自己观察和行动，会消耗模型额度。设为 0 就不再新起一轮，要先停下请按停止。")))
            .child(self.dropdown("budget","每小时后台思考预算","agent","backgroundTurnsPerHour",self.options("agent","budgetOptions"),cx))
            .child(div().text_size(px(ui::CAPTION)).line_height(px(ui::CAPTION_LINE_HEIGHT)).child(settings_copy(locale, "按最近一小时算，默认 6。这只数后台思考的次数，不等于请求次数或费用。"))))
            .child(group("回复语音")
            .children((!self.unity_external || self.snapshot["unity"]["autoSpeakSupported"].as_bool() == Some(true)).then(||self.toggle("auto-speak","自动朗读 Agent 回复","autoSpeak",cx)))
            .child(self.dropdown("tts-provider","服务","tts","providerID",self.options("tts","providers"),cx))
            .child(div().flex().items_center().justify_between().child("API Key").child(div().w(px(280.)).child(Input::new(&self.extra_inputs[0]).aria_label(t("新的 TTS API Key")))))
            .child(div().flex().items_center().gap(px(ui::SPACING_8))
                .child(div().flex_1().child(self.dropdown("tts-voice","声音","tts","voiceID",self.options("tts","voices"),cx)))
                .child(Button::new("refresh-voices").icon(IconName::RefreshCw).accessibility_label(t("刷新声音")).disabled(self.snapshot["tts"]["loading"].as_bool()==Some(true)).on_click(cx.listener(|this,_,_,cx|this.tts_action("tts.refresh",cx))))
                .child(Button::new("preview-tts").label(if self.snapshot["tts"]["isSpeaking"].as_bool()==Some(true){t("停止试听")}else{t("试听声音")}).disabled(!valid_model||self.inputs[3].read(cx).value().trim().is_empty()).on_click(cx.listener(|this,_,_,cx|this.tts_action(if this.snapshot["tts"]["isSpeaking"].as_bool()==Some(true){"tts.stop"}else{"tts.preview"},cx)))))
            .child(gpui_kit::component::collapsible::Collapsible::new().open(self.custom_voice_open)
                .child(Button::new("custom-voice-disclosure").label(t("高级设置")).icon(if self.custom_voice_open{IconName::ChevronDown}else{IconName::ChevronRight}).on_click(cx.listener(|this,_,_,cx|{this.custom_voice_open=!this.custom_voice_open;cx.notify();})))
                .content(div().flex().flex_col().gap(px(ui::SPACING_8))
                    .child(self.dropdown("tts-model","模型","tts","modelID",self.options("tts","models"),cx))
                    .child(div().text_size(px(ui::CAPTION)).line_height(px(ui::CAPTION_LINE_HEIGHT)).child(if self.draft["tts"]["providerID"].as_str()==Some("fish"){t("自定义 Reference ID")}else{t("自定义 Voice ID")}))
                    .child(Input::new(&self.inputs[3])).child(div().text_size(px(ui::CAPTION)).line_height(px(ui::CAPTION_LINE_HEIGHT)).child(t("填写该服务已有的音色 ID，无需重新上传；账号、模型及服务区域须与创建音色时一致。")))
                    .children((self.draft["tts"]["providerID"].as_str()==Some("bailian")).then(||div().text_size(px(ui::CAPTION)).line_height(px(ui::CAPTION_LINE_HEIGHT)).child(t("复刻音色请选择创建时使用的模型。"))))))
            .children((self.snapshot["tts"]["catalogLoaded"].as_bool()==Some(true)&&!valid_model).then(||div().text_size(px(ui::CAPTION)).line_height(px(ui::CAPTION_LINE_HEIGHT)).child(t("原配置模型不在当前支持列表中，请选择后保存；不会自动改用其他模型。"))))
            .child(if self.snapshot["tts"]["credentialConfigured"].as_bool()==Some(true) { t("已配置") } else { t("该服务尚未配置凭据，请填写后保存") })
            .child(div().flex().flex_wrap().gap(px(ui::SPACING_8))
                .child(Button::new("save-tts").label(t("保存配置")).disabled(!valid_model).on_click(cx.listener(|this,_,_,cx|this.tts_action("tts.save",cx)))))
            .children(self.snapshot["tts"]["notice"].as_str().map(|notice|div().text_size(px(ui::CAPTION)).line_height(px(ui::CAPTION_LINE_HEIGHT)).child(settings_notice(locale, notice)))))
            .child(group("按住说话")
            .child(self.dropdown("asr-microphone","麦克风","asr","microphoneDeviceID",self.options("asr","microphoneDevices"),cx))
            .child(self.dropdown("asr-provider","服务","asr","providerID",self.options("asr","providers"),cx))
            .child(div().flex().items_center().justify_between().child("API Key").child(div().w(px(280.)).child(Input::new(&self.extra_inputs[1]).aria_label(t("新的 ASR API Key")))))
            .child(self.dropdown("asr-model","模型","asr","modelID",self.options("asr","models"),cx))
            .children((self.snapshot["asr"]["catalogLoaded"].as_bool()==Some(true)&&!self.snapshot["asr"]["models"].as_array().is_some_and(|models|models.iter().any(|model|model["id"]==self.draft["asr"]["modelID"]))).then(||div().text_size(px(ui::CAPTION)).line_height(px(ui::CAPTION_LINE_HEIGHT)).child(t("原配置模型不在当前支持列表中，请选择后保存；不会自动改用其他模型。"))))
            .child(Button::new("save-asr").label(t("保存配置")).disabled(!self.snapshot["asr"]["models"].as_array().is_some_and(|models|models.iter().any(|model|model["id"]==self.draft["asr"]["modelID"]))).on_click(cx.listener(|this,_,_,cx|{
                let mut value=this.draft["asr"].clone();value["op"]=json!("asr.save");value["apiKey"]=json!(this.extra_inputs[1].read(cx).value().to_string());this.commands.push(value);
            })))
            .children(self.snapshot["asr"]["notice"].as_str().map(|notice|div().text_size(px(ui::CAPTION)).line_height(px(ui::CAPTION_LINE_HEIGHT)).child(settings_notice(locale, notice)))));
        form.into_any_element()
    }
}

impl AgentSettingsPane {
    fn character_position_form(&self, cx: &mut Context<Self>) -> AnyElement {
        let locale = UiLocale::from_settings(&self.snapshot);
        let position = &self.snapshot["characterPosition"];
        let unavailable = position["available"].as_bool() != Some(true);
        let working = position["working"].as_bool() == Some(true);
        let mut coordinates = div().flex().items_center().gap_2();
        for (index, axis) in ["X", "Y", "Z"].into_iter().enumerate() {
            coordinates = coordinates.child(axis).child(div().flex_1().min_w(px(0.))
                .child(Input::new(&self.position_inputs[index]).disabled(unavailable || working)
                    .aria_label(format!("{} {axis}", settings_copy(locale, "人物位置")))));
        }
        let mut group = SettingsGroup::new(settings_copy(locale, "人物位置"), cx.theme().border)
            .child(coordinates)
            .child(div().text_size(px(ui::CAPTION)).child(settings_copy(locale, "坐标以米计；人物会沿可通行地面移动，Y 必须贴合目标地面。")))
            .child(div().flex().items_center().gap_2()
                .child(Button::new("character-position-apply").label(settings_copy(locale, "移动到坐标"))
                    .disabled(unavailable || working).on_click(cx.listener(|this, _, _, cx| {
                        let values: Option<Vec<f64>> = this.position_inputs.iter()
                            .map(|input| input.read(cx).value().trim().parse::<f64>().ok().filter(|v| v.is_finite())).collect();
                        if let Some(values) = values {
                            let id = format!("position-{}", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_nanos());
                            this.commands.push(json!({"op":"presence.position", "worldID":this.position_world,
                                "expectedRevision":this.position_revision, "expectedLayoutRevision":this.position_layout_revision,
                                "requestID":id, "position":values}));
                            this.position_dirty = false; this.position_notice = None;
                        } else { this.position_notice = Some("请输入有效的 X、Y、Z 坐标。".into()); }
                        cx.notify();
                    })))
                .child(Button::new("character-position-reset").label(settings_copy(locale, "重置"))
                    .disabled(unavailable || working).on_click(cx.listener(|this, _, _, cx| {
                        let id = format!("position-reset-{}", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_nanos());
                        this.commands.push(json!({"op":"presence.position.reset", "worldID":this.snapshot["characterPosition"]["worldID"],
                            "expectedRevision":this.snapshot["characterPosition"]["revision"],
                            "expectedLayoutRevision":this.snapshot["characterPosition"]["layoutRevision"], "requestID":id}));
                        this.position_dirty = false; this.position_notice = None; cx.notify();
                    }))));
        if let Some(notice) = self.position_notice.as_deref().or_else(|| position["notice"].as_str()) {
            group = group.child(div().text_size(px(ui::CAPTION)).child(settings_notice(locale, notice)));
        }
        group.into_any_element()
    }
    fn command_button(
        &self,
        id: impl Into<ElementId>,
        label: impl Into<SharedString>,
        command: Value,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let label: SharedString = label.into();
        let label = settings_copy(UiLocale::from_settings(&self.snapshot), label.as_ref()).to_owned();
        Button::new(id)
            .label(label)
            .when(command["op"]=="space.key.clear",|button|button.danger())
            .on_click(cx.listener(move |this, _, _, cx| {
                if command["op"]=="space.key.clear"{this.pending_marble=Some((this.snapshot["space"]["marbleMutationRevision"].as_u64().unwrap_or(0),this.extra_inputs[2].read(cx).value().to_string()));}
                this.commands.push(command.clone());
                cx.notify();
            }))
            .into_any_element()
    }
    fn basic_form(&self, cx: &mut Context<Self>) -> AnyElement {
        let locale = UiLocale::from_settings(&self.snapshot);
        let t = |source: &'static str| settings_copy(locale, source);
        let mut form = div().flex().flex_col().gap(px(ui::SPACING_12))
            .text_size(px(ui::BODY)).line_height(px(ui::BODY_LINE_HEIGHT));
        let border = cx.theme().border;
        let group = |title: &'static str| SettingsGroup::new(t(title), border).visible(match self.section.as_str(){"角色管理"=>matches!(title,"角色"|"呼吸球样式"),"动作管理"=>matches!(title,"动作"|"动作库"),"我的空间"=>title=="默认空间","生成服务"=>title!="默认空间",_=>true});
        match self.page {
            0 => {
                if self.unity_external && self.section == "角色管理" {
                    form = form.child(self.character_position_form(cx));
                }
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
                                        .child(if package["isBuiltIn"].as_bool()==Some(true) {
                                            format!("{} · {}", t("内置"), t(match package["engine"].as_str(){Some("orb")=>"呼吸球",Some("pmx")=>"PMX",Some("vrm")=>"VRM",Some("live2D"|"live2d")=>"Live2D",_=>""}))
                                        } else { avatar_detail(package) }),
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
                                .child(settings_copy(locale, "当前角色")),
                        );
                    } else if package["rendererAvailable"].as_bool() == Some(false) {
                        row = row.child(div().text_xs().child(format!(
                            "{} · {}", t("等待渲染"),
                            t(match package["engine"].as_str(){Some("orb")=>"呼吸球",Some("pmx")=>"PMX",Some("vrm")=>"VRM",Some("live2d")=>"Live2D",_=>"当前引擎"})
                        )));
                    } else {
                        row =
                            row.child(Button::new(format!("avatar-{id}")).label(settings_copy(locale, "选择")).on_click(
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
                            package["name"].as_str().unwrap_or(settings_copy(locale, "未命名角色")),
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
                let category_values: Vec<_> = std::iter::once((json!(""), t("全部").to_owned()))
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
                        .w(px(360.))
                        .h(px(28.))
                        .max_width(px(80.))
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
                    motions = motions.child(div().text_xs().child(settings_notice(locale, notice)));
                }
                if !self.motion_category.is_empty()&&self.snapshot["presence"]["motionNotice"].is_null()
                    &&!self.snapshot["presence"]["motions"].as_array().into_iter().flatten().any(|m|m["category"].as_str()==Some(&self.motion_category)){
                    motions=motions.child(div().text_xs().child(settings_copy(locale, "这个分类下暂无当前角色可用的动作。")));
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
                                .text_color(if compatible{cx.theme().primary}else{cx.theme().muted_foreground})
                                .child(Icon::new(IconName::Activity).size(px(20.))),
                        )
                        .child(
                            div()
                                .flex_1()
                                .min_w(px(0.))
                                .flex()
                                .flex_col()
                                .gap(px(3.))
                                .child(if motion["id"].as_str() == Some("builtin.motion.natural-idle") {
                                    t("自然待机").to_owned()
                                } else { motion["name"].as_str().unwrap_or("").to_owned() })
                                .child(
                                    div()
                                        .text_xs()
                                        .text_color(if compatible{cx.theme().muted_foreground}else{cx.theme().warning})
                                        .child(format!(
                                            "{}{}",
                                            settings_copy(locale, motion_format(motion["format"].as_str().unwrap_or(""))),
                                            motion["reason"]
                                                .as_str()
                                                .filter(|s| !s.is_empty())
                                                .map(|s| format!(" · {}", settings_notice(locale, s)))
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
                                .child(settings_copy(locale, "当前动作")),
                        );
                    } else {
                        row = row.child(
                            Button::new(format!("motion-{id}"))
                                .label(settings_copy(locale, "选择"))
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
                            motion["name"].as_str().unwrap_or(settings_copy(locale, "未命名动作")),
                            json!({"op":"presence.motion.remove","id":id}),
                            cx,
                        ));
                    }
                    motions = motions.child(row);
                }
                form = form.child(motions).child(
                    div()
                        .text_xs()
                        .child(settings_copy(locale, "两种角色各有自己的动作列表，切换时会分别记住你选的。")),
                );
                let mut catalog=group("动作库").child(div().flex().items_center().gap(px(10.)).child(div().flex_1().min_w(px(0.)).child(Input::new(&self.extra_inputs[3])))
                    .child(Button::new("catalog-refresh").label(settings_copy(locale, "获取动作列表")).disabled(self.snapshot["presence"]["working"].as_bool()==Some(true)||self.extra_inputs[3].read(cx).value().trim().is_empty()).on_click(cx.listener(|this,_,_,cx|this.commands.push(json!({"op":"presence.catalog","url":this.extra_inputs[3].read(cx).value().to_string()}))))));
                for motion in self.snapshot["presence"]["publishedMotions"]
                    .as_array()
                    .into_iter()
                    .flatten()
                {
                    let identity=motion["catalogIdentity"].clone();
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
                                            "{} {} · {:.1} {}", t("版本"),
                                            motion["version"].as_str().unwrap_or(""),
                                            motion["duration"].as_f64().unwrap_or(0.), t("秒")
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
                                .child(settings_copy(locale, "已安装")),
                        );
                    } else {
                        row = row.child(
                            Button::new(format!("install-motion-{identity}"))
                                .label(settings_copy(locale, motion["installLabel"].as_str().unwrap_or("安装")).to_owned())
                                .disabled(
                                    self.snapshot["presence"]["working"].as_bool() == Some(true),
                                )
                                .on_click(cx.listener(move |this, _, _, _| {
                                    this.commands
                                        .push(json!({"op":"presence.motion.install","catalogIdentity":identity}))
                                })),
                        );
                    }
                    catalog = catalog.child(row);
                }
                form = form.child(catalog);
                if self.snapshot["presence"]["activeEngine"].as_str() == Some("orb") {
                    form = form.child(
                        group("呼吸球样式")
                            .child(ColorPicker::new(&self.orb_color).label(settings_copy(locale, "流光颜色")))
                            .child(
                                div()
                                    .flex()
                                    .items_center()
                                    .gap_3()
                                    .child(settings_copy(locale, "流光强度"))
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
                    let syncing=provider["syncing"].as_bool()==Some(true);
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
                                        .text_size(px(ui::CAPTION)).line_height(px(ui::CAPTION_LINE_HEIGHT))
                                        .text_color(cx.theme().muted_foreground)
                                        .child(match provider["status"].as_str() {
                                            Some("connected") => t("已连接"),
                                            Some("authorizing") => t("正在连接"),
                                            Some("expired") => t("登录已过期"),
                                            Some("denied") => t("未授权"),
                                            Some("unavailable") => t("当前不可用"),
                                            _ => t("未连接"),
                                        }),
                                ),
                        );
                    if provider["status"].as_str() == Some("authorizing") {
                        row = row.child(t("正在连接…"));
                    } else {
                        let mut buttons = div().flex().items_center().gap(px(ui::SPACING_8)).flex_shrink_0();
                        if connected {
                            buttons = buttons.child(
                                Button::new(format!("sync-{id}"))
                                    .ghost().small()
                                    .label(if syncing{t("正在同步…")}else{t("同步")})
                                    .disabled(working||syncing)
                                    .on_click(cx.listener({
                                        let id = id.clone();
                                        move |this, _, _, cx| {
                                            if let Some(provider)=this.snapshot["music"]["providers"].as_array().into_iter().flatten().find(|provider|provider["id"]==id){
                                                if let Some(command)=music_sync_command(provider,this.snapshot["music"]["working"].as_bool()==Some(true)){this.commands.push(command);cx.notify();}
                                            }
                                        }
                                    })),
                            );
                        }
                        buttons=buttons.child(Button::new(format!("account-{id}")).small().when(connected,|button|button.ghost()).label(if connected{t("断开")}else{t("连接")}).disabled(working).on_click(cx.listener({let id=id.clone();move|this,_,_,_|this.commands.push(json!({"op":if connected{"music.disconnect"}else{"music.connect"},"id":id}))})));
                        row = row.child(buttons);
                    }
                    services = services.child(row);
                }
                if self.unity_external {
                    services = services.child(div().text_size(px(ui::CAPTION)).line_height(px(ui::CAPTION_LINE_HEIGHT)).child(t("同步完成后，音乐库会显示最新歌单。")));
                }
                form = form.child(services);
            }
            2 if self.unity_external => {
                let generation = &self.snapshot["generation"];
                let configured = generation["configured"].as_bool() == Some(true);
                let checking = generation["checking"].as_bool() == Some(true);
                form = form.child(group("许愿机")
                    .child(Input::new(&self.extra_inputs[5])).child(Input::new(&self.extra_inputs[6]))
                    .child(div().flex().items_center().gap_2()
                        .child(div().flex_1().child(t(if configured { "已配置" } else { "未配置" })))
                        .child(Button::new("generation-check").small().label(t(if checking { "检测中…" } else { "检测连接" })).disabled(!configured || checking || !self.extra_inputs[6].read(cx).value().is_empty()).on_click(cx.listener(|this, _, _, cx| { this.commands.push(json!({"op":"generation.check"})); cx.notify(); })))
                        .child(Button::new("generation-save").small().primary().label(t("保存")).disabled(checking || self.extra_inputs[5].read(cx).value().trim().is_empty()).on_click(cx.listener(|this, _, _, cx| {
                            this.commands.push(json!({"op":"generation.save","endpoint":this.extra_inputs[5].read(cx).value().to_string(),"token":this.extra_inputs[6].read(cx).value().to_string()})); cx.notify();
                        }))))
                    .children(generation["noticeCode"].as_str().map(|code| div().text_size(px(ui::CAPTION)).line_height(px(ui::CAPTION_LINE_HEIGHT)).child(settings_notice(locale, code))))
                    .child(div().text_size(px(ui::CAPTION)).line_height(px(ui::CAPTION_LINE_HEIGHT)).child(t("地址和密钥只存在这台电脑上，保存后不会立刻开始生成。"))));
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
                    .child(div().text_xs().child(detail.to_owned())).child(div().text_xs().child(settings_copy(locale, "修改后下次启动生效。"))))
                    .child(group("Marble 空间")
                        .child(div().flex().items_center().gap(px(12.)).child(div().w(px(28.)).flex_shrink_0().child(Icon::new(IconName::Box).size(px(22.))))
                            .child(div().flex_1().flex().flex_col().gap(px(2.)).child("World Labs Marble").child(div().text_xs().child(settings_copy(locale, "用于同步和生成可探索的 3D 空间"))))
                            .child(div().flex().items_center().gap_1().text_sm().text_color(if configured{cx.theme().success}else{cx.theme().muted_foreground})
                                .child(Icon::new(if configured{IconName::CircleCheck}else{IconName::Circle}).size(px(14.))).child(t(if configured{"已配置"}else{"未配置"}))))
                        .child(div().flex().items_center().gap_3().child("API Key").child(div().flex_1().min_w(px(0.)).child(Input::new(&self.extra_inputs[2]))))
                        .child(div().flex().items_center().justify_end().gap_2()
                            .when(configured,|row|row.child(self.command_button("marble-clear","清除",json!({"op":"space.key.clear"}),cx)))
                            .child(Button::new("marble-save").primary().label(settings_copy(locale, "保存 Key")).disabled(self.extra_inputs[2].read(cx).value().trim().is_empty()).on_click(cx.listener(|this,_,_,cx|{
                                let key=this.extra_inputs[2].read(cx).value().to_string();this.pending_marble=Some((this.snapshot["space"]["marbleMutationRevision"].as_u64().unwrap_or(0),key.clone()));this.commands.push(json!({"op":"space.key.save","apiKey":key}));
                            })))))
                    .child(group("许愿机").child(Input::new(&self.extra_inputs[5])).child(Input::new(&self.extra_inputs[6]))
                    .child(div().flex().items_center().gap_2()
                        .child(div().flex_1().flex().items_center().gap_1().text_sm().text_color(cx.theme().muted_foreground)
                            .child(Icon::new(if self.snapshot["space"]["propCredentialConfigured"].as_bool()==Some(true){IconName::CircleCheck}else{IconName::Circle}).size(px(14.)))
                            .child(t(if self.snapshot["space"]["propCredentialConfigured"].as_bool()==Some(true){"已配置"}else{"未配置"})))
                        .child(Button::new("prop-check").label(t(if self.snapshot["space"]["propChecking"].as_bool()==Some(true){"检测中…"}else{"检测连接"})).disabled(self.snapshot["space"]["propCredentialConfigured"].as_bool()!=Some(true)||self.snapshot["space"]["propChecking"].as_bool()==Some(true)||!self.extra_inputs[6].read(cx).value().is_empty()).on_click(cx.listener(|this,_,_,cx|this.commands.push(json!({"op":"space.prop.check","endpoint":this.extra_inputs[5].read(cx).value().to_string()})))))
                        .child(Button::new("prop-save").primary().label(settings_copy(locale, "保存")).disabled(self.extra_inputs[5].read(cx).value().trim().is_empty()).on_click(cx.listener(|this,_,_,cx|{
                            let endpoint=this.extra_inputs[5].read(cx).value().to_string();let key=this.extra_inputs[6].read(cx).value().to_string();this.pending_prop=Some((this.snapshot["space"]["propSaveRevision"].as_u64().unwrap_or(0),endpoint.clone(),key.clone()));this.commands.push(json!({"op":"space.prop.save","endpoint":endpoint,"apiKey":key}));
                        })))))
                    .child(div().text_xs().child(settings_copy(locale, "地址和密钥只存在这台电脑上，保存后不会立刻开始生成。")));
            }
            3 => {
                let mut shortcuts = group("")
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap(px(16.))
                            .text_xs()
                            .child(div().flex_1().child(settings_copy(locale, "功能")))
                            .child(div().w(px(136.)).child(settings_copy(locale, "应用内")))
                            .child(div().w(px(136.)).child(settings_copy(locale, "全局"))),
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
                            .child(settings_copy(locale, item["title"].as_str().unwrap_or("")).to_owned()),
                    );
                    for scope in ["local", "global"] {
                        let recording = self.snapshot["shortcuts"]["recordingID"] == id
                            && self.snapshot["shortcuts"]["recordingScope"].as_str() == Some(scope);
                        let label=if recording{t("请按快捷键")}else{item[scope].as_str().unwrap_or(t("未设置"))}.to_owned();
                        let tint=gpui_kit::component::button::ButtonCustomVariant::new(cx).color(rgb(0x32d3e8).opacity(0.14).into())
                            .foreground(rgb(0x32d3e8).into()).hover(rgb(0x32d3e8).opacity(0.22).into()).active(rgb(0x32d3e8).opacity(0.3).into());
                        row=row.child(div().w(px(136.)).flex_shrink_0().child(Button::new(format!("shortcut-{id}-{scope}")).w(px(136.)).px(px(12.))
                            .when(recording,|button|button.custom(tint)).accessibility_label(label.clone())
                            .child(div().w(px(112.)).font_family("Menlo").text_size(px(13.)).child(label))
                            .on_click(cx.listener({let id=id.clone();move|this,_,_,_|this.commands.push(json!({"op":"shortcuts.record","id":id,"scope":scope}))}))));
                    }
                    shortcuts = shortcuts.child(row);
                }
                form = form
                    .child(shortcuts)
                    .child(
                        group("")
                            .child(
                                Switch::new("global-shortcuts")
                                    .label(settings_copy(locale, "启用全局快捷键"))
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
                            .child(div().text_xs().child(settings_copy(locale, "gmgn radio 在后台时也能响应。")))
                            .child(
                                Switch::new("media-shortcuts")
                                    .label(settings_copy(locale, "使用系统媒体快捷键"))
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
                                    .child(settings_copy(locale, "响应键盘上的播放、暂停、上一首和下一首。")),
                            ),
                    )
                    .child(
                        group("").child(div().flex().items_center().gap_3()
                            .children(self.snapshot["shortcuts"]["validationMessage"].as_str().map(|message|div().min_w(px(0.)).text_xs().text_color(rgb(0xff9f0a)).child(settings_notice(locale, message))))
                            .child(div().flex_1().min_w(px(0.)))
                            .child(self.command_button(
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
        let locale = UiLocale::from_settings(&self.snapshot);
        use gpui_kit::component::sidebar::{Sidebar, SidebarMenu, SidebarMenuItem};
        let (_title, subtitle) = match self.page {
            0 => ("角色与动作", "选择角色的形象与表演动作"),
            1 => ("音乐", "角色可以使用的账号"),
            2 => ("空间", "选择默认空间，并管理空间生成服务"),
            3 => ("快捷键", "点击按键框，再按下新的组合键"),
            5 => ("播放器", "字幕、3D 点阵与视频效果"),
            6 => ("空间", "选择生活空间，调整空间功能"),
            7 => ("活动", "选择与控制空间生活活动"),
            _ => ("Agent 与语音", "文字和语音共用同一会话，回答后再朗读"),
        };
        let content = if self.unity_external && !unity_section_available(&self.snapshot, &self.section) {
            div().px(px(20.)).py(px(16.)).text_size(px(ui::BODY))
                .text_color(cx.theme().muted_foreground)
                .child(settings_copy(locale, "加载中…"))
                .into_any_element()
        } else if self.unity_external && self.page == 5 && self.section == "视频" {
            let video = &self.snapshot["video"];
            let mut videos = SettingsGroup::new(settings_copy(locale, "视频"), cx.theme().border)
                .child(div().flex().gap_2()
                    .child(self.command_button("unity-video-choose", "导入视频", json!({"op":"video.choose"}), cx))
                    .child(Button::new("unity-video-play").small().label(settings_copy(locale, if video["playing"].as_bool()==Some(true) { "暂停" } else { "播放" })).disabled(video["selectedID"].is_null() && video["activeID"].is_null()).on_click(cx.listener(|this,_,_,cx|{this.commands.push(json!({"op":if this.snapshot["video"]["playing"].as_bool()==Some(true) { "video.pause" } else { "video.play" }}));cx.notify();})))
                    .child(self.command_button("unity-video-stop", "停止", json!({"op":"video.stop"}), cx)));
            if let Some(notice)=video["notice"].as_str().filter(|s|!s.trim().is_empty()) {
                videos=videos.child(div().id("unity-video-authority-notice").text_xs()
                    .text_color(cx.theme().danger).child(notice.to_owned()));
            }
            if video["canRecoverStop"].as_bool()==Some(true) {
                videos=videos.child(self.command_button("unity-video-recover-stop","停止并核验",json!({"op":"video.recoverStop"}),cx));
            }
            if let Some(title) = video["currentTrackTitle"].as_str() {
                videos = videos.child(div().text_color(cx.theme().muted_foreground)
                    .child(format!("{}: {}", settings_copy(locale, "当前歌曲"), title)));
            }
            for asset in video["assets"].as_array().into_iter().flatten() {
                let Some(id) = asset["id"].as_str() else { continue };
                let selected = video["selectedID"].as_str()==Some(id);
                let mut row = div().flex().items_center().gap_2()
                    .child(div().flex_1().child(asset["name"].as_str().unwrap_or(id).to_owned()))
                    .child(Button::new(format!("unity-video-select-{id}")).small().label(settings_copy(locale, if selected { "使用中" } else { "选择并播放" })).disabled(selected).on_click(cx.listener({let id=id.to_owned();move|this,_,_,cx|{this.commands.push(json!({"op":"video.select","id":id}));cx.notify();}})))
                    .child(self.remove_menu(format!("unity-video-remove-{id}"), "移出素材库", asset["name"].as_str().unwrap_or(id), json!({"op":"video.remove","id":id}), cx));
                if let Some(track_id) = video["currentTrackID"].as_str() {
                    let bound = video["boundAssetID"].as_str() == Some(id);
                    row = row.child(self.command_button(format!("unity-video-bind-{id}"),
                        if bound { "解除当前歌曲绑定" } else { "绑定到当前歌曲" },
                        json!({"op": if bound { "video.unbind" } else { "video.bind" }, "id": id, "trackID": track_id}), cx));
                }
                videos = videos.child(row);
            }
            if let Some(prompt_id) = video["pendingBoundVideo"]["id"].as_str() {
                videos = videos.child(div().flex().items_center().gap_2()
                    .child(div().flex_1().child(settings_copy(locale, "当前歌曲有绑定视频")))
                    .child(self.command_button("unity-video-bound-play", "播放绑定视频", json!({"op":"video.bound.play","id":prompt_id}), cx))
                    .child(self.command_button("unity-video-bound-dismiss", "关闭", json!({"op":"video.bound.dismiss","id":prompt_id}), cx)));
            }
            let mut modes = div().flex().gap_2();
            for (id, label) in [("once", "单次"), ("loop", "循环"), ("randomSequence", "随机拼接")] {
                modes = modes.child(Button::new(format!("unity-video-mode-{id}")).small().label(settings_copy(locale, label)).disabled(video["mode"].as_str()==Some(id)).on_click(cx.listener(move|this,_,_,cx|{this.commands.push(json!({"op":"video.mode","value":id}));cx.notify();})));
            }
            videos.child(modes)
                .child(div().flex().items_center().gap_2().child(settings_copy(locale, "视频亮度")).child(div().flex_1().child(Slider::new(&self.video_brightness))))
                .into_any_element()
        } else if self.unity_external && self.page == 6 {
            let library = &self.snapshot["spaceLibrary"];
            let working = library["working"].as_bool() == Some(true);
            let mut spaces = SettingsGroup::new(settings_copy(locale, "我的空间"), cx.theme().border)
                .child(self.command_button("space-library-refresh", "刷新", json!({"op":"space.library.load"}), cx));
            for world in library["worlds"].as_array().into_iter().flatten() {
                let Some(id) = world["id"].as_str() else { continue };
                let selected = world["selected"].as_bool() == Some(true);
                let id = id.to_owned();
                spaces = spaces.child(div().flex().items_center().gap_2()
                    .child(div().flex_1().text_size(px(ui::BODY)).child(world["name"].as_str().unwrap_or(&id).to_owned()))
                    .child(Button::new(format!("space-library-{id}")).small().label(settings_copy(locale, if selected { "使用中" } else { "选择" })).disabled(working || selected).on_click(cx.listener(move |this, _, _, cx| {
                        this.commands.push(json!({"op":"space.library.select","id":id})); cx.notify();
                    }))));
            }
            if let Some(code) = library["noticeCode"].as_str() {
                spaces = spaces.child(div().text_size(px(ui::CAPTION)).line_height(px(ui::CAPTION_LINE_HEIGHT)).child(settings_notice(locale, code)));
            }
            for world in library["marbleWorlds"].as_array().into_iter().flatten() {
                spaces = spaces.child(div().text_size(px(ui::BODY)).child(world["name"].as_str().unwrap_or("").to_owned()));
            }
            if let Some(code) = library["marbleNoticeCode"].as_str() {
                spaces = spaces.child(div().text_size(px(ui::CAPTION)).line_height(px(ui::CAPTION_LINE_HEIGHT)).child(settings_notice(locale, code)));
            }
            let configured = self.snapshot["space"]["credentialConfigured"].as_bool() == Some(true);
            let default_space = SettingsGroup::new(settings_copy(locale, "默认空间"), cx.theme().border)
                .child(self.dropdown("unity-default-space", "启动时进入", "space", "defaultSpace", self.options("space", "options"), cx))
                .child(div().text_xs().child(self.snapshot["space"]["options"].as_array().into_iter().flatten()
                    .find(|value| value["id"] == self.draft["space"]["defaultSpace"])
                    .and_then(|value| value["detail"].as_str()).unwrap_or("").to_owned()))
                .child(div().text_xs().child(settings_copy(locale, "修改后下次启动生效。")));
            let mut credential = SettingsGroup::new(settings_copy(locale, "Marble 空间"), cx.theme().border)
                .child(div().flex().items_center().justify_between().child("World Labs Marble")
                    .child(settings_copy(locale, if configured { "已配置" } else { "未配置" })))
                .child(div().flex().items_center().gap_3().child("API Key")
                    .child(div().flex_1().min_w(px(0.)).child(Input::new(&self.extra_inputs[2]))))
                .child(div().flex().items_center().justify_end().gap_2()
                    .when(configured, |row| row.child(self.command_button("unity-marble-clear", "清除", json!({"op":"space.key.clear"}), cx)))
                    .child(Button::new("unity-marble-save").primary().label(settings_copy(locale, "保存 Key"))
                        .disabled(self.extra_inputs[2].read(cx).value().trim().is_empty())
                        .on_click(cx.listener(|this, _, _, cx| {
                            let key = this.extra_inputs[2].read(cx).value().to_string();
                            this.pending_marble = Some((this.snapshot["space"]["marbleMutationRevision"].as_u64().unwrap_or(0), key.clone()));
                            this.commands.push(json!({"op":"space.key.save","apiKey":key}));
                            cx.notify();
                        }))));
            if let Some(message) = self.snapshot["space"]["marbleMessage"].as_str() {
                credential = credential.child(div().text_xs().text_color(
                    if self.snapshot["space"]["marbleHasError"].as_bool() == Some(true) { cx.theme().danger } else { cx.theme().muted_foreground })
                    .child(message.to_owned()));
            }
            let supported = library["generationSupported"].as_bool() == Some(true);
            let marble_working = library["marbleWorking"].as_bool() == Some(true);
            let pending = library["marbleOperationID"].as_str().filter(|id| !id.is_empty());
            let mut marble = SettingsGroup::new(settings_copy(locale, "生成与导入空间"), cx.theme().border)
                .child(div().text_xs().text_color(cx.theme().muted_foreground)
                    .child(settings_copy(locale, "生成会调用付费 Marble API；仅点击生成按钮时提交。")));
            if !supported {
                marble = marble.child(div().text_xs().child(settings_copy(locale, "当前运行时不支持 Marble 空间生成与导入。")));
            }
            if let Some(id) = pending {
                marble = marble.child(div().text_xs().child(format!("{}: {id}", settings_copy(locale, "生成任务 ID"))))
                    .child(div().text_xs().child(settings_copy(locale, "已有生成回执，请恢复原任务；不会重复提交付费生成。")));
            }
            for preset in library["marblePresets"].as_array().into_iter().flatten() {
                let Some(id) = preset["id"].as_str() else { continue };
                let enabled = configured && marble_command(library, "space.marble.generate", id).is_some();
                let id = id.to_owned();
                marble = marble.child(div().flex().items_center().gap_2()
                    .child(div().flex_1().child(preset["name"].as_str().unwrap_or(&id).to_owned()))
                    .child(Button::new(format!("unity-marble-generate-{id}")).small()
                        .label(settings_copy(locale, "生成（付费）")).disabled(!enabled)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if let Some(command) = marble_command(&this.snapshot["spaceLibrary"], "space.marble.generate", &id) {
                                this.commands.push(command); cx.notify();
                            }
                        }))));
            }
            marble = marble.child(div().flex().items_center().gap_2()
                .child(div().flex_1().min_w(px(0.)).child(Input::new(&self.extra_inputs[7])))
                .child(Button::new("unity-marble-import").label(settings_copy(locale, "按 World ID 导入"))
                    .disabled(!configured || marble_command(library, "space.marble.import", self.extra_inputs[7].read(cx).value().as_str()).is_none())
                    .on_click(cx.listener(|this, _, _, cx| {
                        let id = this.extra_inputs[7].read(cx).value().to_string();
                        if let Some(command) = marble_command(&this.snapshot["spaceLibrary"], "space.marble.import", &id) {
                            this.commands.push(command); cx.notify();
                        }
                    }))));
            let mut controls = div().flex().gap_2();
            if pending.is_some() {
                controls = controls.child(Button::new("unity-marble-resume").label(settings_copy(locale, "恢复原任务"))
                    .disabled(!configured || marble_command(library, "space.marble.resume", "").is_none())
                    .on_click(cx.listener(|this, _, _, cx| {
                        if let Some(command) = marble_command(&this.snapshot["spaceLibrary"], "space.marble.resume", "") {
                            this.commands.push(command); cx.notify();
                        }
                    })));
            }
            if marble_working {
                controls = controls.child(Button::new("unity-marble-cancel").label(settings_copy(locale, "取消本机等待"))
                    .on_click(cx.listener(|this, _, _, cx| {
                        if let Some(command) = marble_command(&this.snapshot["spaceLibrary"], "space.marble.cancel", "") {
                            this.commands.push(command); cx.notify();
                        }
                    })));
                marble = marble.child(div().text_xs().child(settings_copy(locale, "取消仅停止本机等待，远端生成可能继续并计费。")));
            }
            marble = marble.child(controls);
            let phase = marble_phase_label(library["marblePhase"].as_str().unwrap_or(""));
            if !phase.is_empty() {
                marble = marble.child(div().text_xs().child(settings_copy(locale, phase)));
            }
            if let Some(progress) = library["marbleProgress"].as_f64().filter(|value| value.is_finite()) {
                marble = marble.child(div().text_xs().child(format!("{}: {:.0}%", settings_copy(locale, "生成进度"), progress.clamp(0., 100.))));
            }
            if let Some(id) = library["marbleWorldID"].as_str().filter(|id| !id.is_empty()) {
                marble = marble.child(div().text_xs().child(format!("World ID: {id}")));
            }
            if let Some(error) = library["marbleError"].as_str().filter(|error| !error.is_empty()) {
                marble = marble.child(div().text_xs().text_color(cx.theme().danger).child(error.to_owned()));
            }
            div().flex().flex_col().gap_4().child(default_space).child(credential).child(marble).child(spaces).into_any_element()
        } else if self.page>=5 {
            self.stage_pane.as_ref().map(|pane| {
                let mut content=div().flex().flex_col().gap_4().child(div().h(px(380.)).child(pane.clone()));
                if self.page==6{content=content.child(SettingsGroup::new(settings_copy(locale, "默认空间"),cx.theme().border)
                    .child(self.dropdown("default-space","启动时进入","space","defaultSpace",self.options("space","options"),cx))
                    .child(div().text_xs().child(self.snapshot["space"]["options"].as_array().into_iter().flatten().find(|value|value["id"]==self.draft["space"]["defaultSpace"]).and_then(|value|value["detail"].as_str()).unwrap_or("").to_owned()))
                    .child(div().text_xs().child(settings_copy(locale, "修改后下次启动生效。"))));}
                content.into_any_element()
            })
                .unwrap_or_else(|| div().into_any_element())
        } else if self.page == 4 {
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
                    .child(div().text_size(px(ui::TITLE)).font_weight(FontWeight::SEMIBOLD).child(settings_navigation_label(locale, &self.section).to_owned()))
                    .child(div().text_size(px(ui::CAPTION)).line_height(px(ui::CAPTION_LINE_HEIGHT)).child(settings_copy(locale, subtitle))),
            );
        if self.page == 0 && (!self.unity_external || unity_section_available(&self.snapshot, &self.section)) {
            let weak = cx.entity().downgrade();
            header = header.child(
                Button::new("presence-import")
                    .label(settings_copy(locale, "导入"))
                    .dropdown_caret(true)
                    .dropdown_menu(move |menu, _, _| {
                        let a = weak.clone();
                        let b = weak.clone();
                        let c = weak.clone();
                        menu.item(PopupMenuItem::new(settings_copy(locale, "角色模型…")).on_click(move |_, _, cx| {
                            _ = a.update(cx, |this, cx| {
                                this.commands.push(json!({"op":"presence.import"}));
                                cx.notify();
                            });
                        }))
                        .item(PopupMenuItem::new(settings_copy(locale, "动作文件…")).on_click(move |_, _, cx| {
                            _ = b.update(cx, |this, cx| {
                                this.commands.push(json!({"op":"presence.motion.import"}));
                                cx.notify();
                            });
                        }))
                        .item(
                            PopupMenuItem::new(settings_copy(locale, "从链接导入角色…")).on_click(move |_, window, cx| {
                                _ = c.update(cx, |this, cx| this.open_import_link(window, cx));
                            }),
                        )
                    }),
            );
        }
        let mut root = div()
            .size_full()
            .font_family(cx.theme().font_family.clone())
            .text_size(px(ui::BODY))
            .line_height(px(ui::BODY_LINE_HEIGHT))
            .flex()
            .flex_col()
            .bg(cx.theme().tokens.background)
            .text_color(cx.theme().foreground)
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
        let notice_key=["presence", "music", "space", "shortcuts", "agent"].get(self.page).copied().unwrap_or("stage");
        if let Some(notice) = self.snapshot
            [notice_key]["notice"]
            .as_str()
            .filter(|_|self.page!=3)
        {
            let error=self.snapshot[notice_key]["hasError"].as_bool()==Some(true);
            root = root.child(
                div()
                    .flex().items_center().gap(px(7.))
                    .flex_shrink_0()
                    .px(px(20.))
                    .pb(px(14.))
                    .max_h(px(42.))
                    .overflow_hidden()
                    .text_xs()
                    .text_color(if error{cx.theme().danger}else{cx.theme().muted_foreground})
                    .child(Icon::new(if error{IconName::CircleAlert}else{IconName::CircleCheck}).size(px(14.)))
                    .child(settings_notice(locale, notice)),
            );
        }
        let mut menu=SidebarMenu::new();
        for (label,items) in [
            ("播放器",vec![("player","歌词"),("player","视觉效果"),("player","视频")]),
            ("空间",vec![("space","我的空间"),("space-preferences","生成服务")]),
            ("角色",vec![("presence","角色管理"),("presence","动作管理"),("agent","自主行动")]),
            ("音乐",vec![("music","音乐账号与歌单同步")]),
            ("对话与语音",vec![("agent","Agent 连接"),("agent","语音播放"),("agent","按住说话")]),
            ("应用",vec![("shortcuts","快捷键")]),
        ] {
            let active=items.iter().any(|(_,section)|*section==self.section);
            let children=items.into_iter().map(|(key,section)|SidebarMenuItem::new(settings_navigation_label(locale, section)).active(self.section==section)
                .on_click(cx.listener(move|this,_,_,cx|this.select_section(key,section,cx)))).collect::<Vec<_>>();
            menu=menu.child(SidebarMenuItem::new(settings_navigation_label(locale, label)).active(active)
                .default_open(active).click_to_toggle(true).children(children));
        }
        let weak = cx.entity().downgrade();
        // Sidebar supplies the same horizontal inset as its navigation content.
        let language = div().w_full().pb(px(ui::SPACING_8)).flex().flex_col().gap(px(ui::SPACING_4))
            .child(div().text_size(px(ui::CAPTION)).line_height(px(ui::CAPTION_LINE_HEIGHT))
                .text_color(cx.theme().muted_foreground).child(locale.language_label()))
            .child(Button::new("settings-language").small().w_full().h(px(32.))
                .text_size(px(ui::BODY)).line_height(px(ui::BODY_LINE_HEIGHT))
                .label(locale.name()).dropdown_caret(true)
                .disabled(self.snapshot["locale"].as_str().and_then(UiLocale::parse).is_none())
                .dropdown_menu(move |mut menu, _, _| {
                    for language in UiLocale::ALL {
                        let weak = weak.clone();
                        menu = menu.item(PopupMenuItem::new(language.name()).on_click(move |_, _, cx| {
                            _ = weak.update(cx, |this, cx| {
                                // Readback owns the visible locale. A rejected
                                // command must not optimistically switch copy.
                                this.commands.push(language_command(language));
                                cx.notify();
                            });
                        }));
                    }
                    menu
                }));
        div().id("settings-root").size_full().flex().bg(cx.theme().background).text_color(cx.theme().foreground)
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, _, cx| {
                if this.snapshot["shortcuts"]["recordingID"].as_str().is_none() { return; }
                let modifiers = event.keystroke.modifiers;
                let flags = u64::from(modifiers.platform) | (u64::from(modifiers.alt)<<1)
                    | (u64::from(modifiers.control)<<2) | (u64::from(modifiers.shift)<<3);
                if let Some(command) = shortcut_capture_command(&event.keystroke.key, flags) {
                    this.commands.push(command); cx.stop_propagation(); cx.notify();
                }
            }))
            .child(Sidebar::new("settings-sidebar").w(px(200.)).header(language).child(menu))
            .child(div().flex_1().min_w(px(0.)).h_full().child(root))
    }
}

#[cfg(test)]
mod settings_display_tests {
    use super::{avatar_detail, motion_format, tts_draft_change_requires_stop,save_ack_clear,presence_more_accessibility,music_sync_command};
    use serde_json::json;
    #[test]
    fn marble_commands_require_runtime_and_preserve_paid_receipts() {
        let ready = json!({"generationSupported":true,"marbleWorking":false,"marblePresets":[{"id":"room","name":"Room"}]});
        assert_eq!(super::marble_command(&ready, "space.marble.generate", "room"), Some(json!({"op":"space.marble.generate","presetID":"room"})));
        assert_eq!(super::marble_command(&ready, "space.marble.import", " world-1 "), Some(json!({"op":"space.marble.import","worldID":"world-1"})));
        assert!(super::marble_command(&ready, "space.marble.generate", "unknown").is_none());
        assert!(super::marble_command(&ready, "space.marble.import", " ").is_none());
        assert!(super::marble_command(&ready, "space.marble.resume", "").is_none());
        let mut unsupported = ready.clone(); unsupported["generationSupported"] = json!(false);
        assert!(super::marble_command(&unsupported, "space.marble.generate", "room").is_none());
        assert!(super::marble_command(&unsupported, "space.marble.import", "world-1").is_none());
        let mut pending = ready.clone(); pending["marbleOperationID"] = json!("operation-1");
        assert!(super::marble_command(&pending, "space.marble.generate", "room").is_none());
        assert!(super::marble_command(&pending, "space.marble.import", "world-2").is_none());
        assert_eq!(super::marble_command(&pending, "space.marble.resume", ""), Some(json!({"op":"space.marble.resume"})));
        pending["marbleWorking"] = json!(true);
        assert!(super::marble_command(&pending, "space.marble.resume", "").is_none());
        assert_eq!(super::marble_command(&pending, "space.marble.cancel", ""), Some(json!({"op":"space.marble.cancel"})));
        pending["generationSupported"] = json!(false);
        assert!(super::marble_command(&pending, "space.marble.generate", "room").is_none());
        assert_eq!(super::marble_command(&pending, "space.marble.cancel", ""), Some(json!({"op":"space.marble.cancel"})));
        pending["marbleWorking"] = json!(false);
        assert!(super::marble_command(&pending, "space.marble.resume", "").is_none());
        assert!(super::marble_command(&pending, "space.marble.import", "world-2").is_none());
    }
    #[test]
    fn shortcut_capture_preserves_native_codes_and_modifiers() {
        assert_eq!(super::shortcut_capture_command("space", 1), Some(json!({"op":"shortcuts.capture","keyCode":49,"keyLabel":"Space","modifiers":1})));
        assert_eq!(super::shortcut_capture_command("K", 9).unwrap()["keyCode"], 40);
        assert_eq!(super::shortcut_capture_command("right", 7).unwrap()["modifiers"], 7);
        assert_eq!(super::shortcut_capture_command("escape", 0), Some(json!({"op":"shortcuts.cancel"})));
        assert!(super::shortcut_capture_command("unsupported-key", 0).is_none());
    }
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
    #[test]
    fn changing_tts_voice_or_model_stops_old_preview_without_other_draft_changes() {
        for field in ["voiceID", "modelID"] {
            assert!(tts_draft_change_requires_stop("tts", field, &json!("old"), &json!("new")));
            assert!(!tts_draft_change_requires_stop("tts", field, &json!("same"), &json!("same")));
        }
        assert!(!tts_draft_change_requires_stop("asr", "modelID", &json!("old"), &json!("new")));
        assert!(!tts_draft_change_requires_stop("tts", "apiKey", &json!("old"), &json!("new")));
    }
    #[test]
    fn successful_save_ack_clears_only_the_submitted_unchanged_draft(){
        assert!(save_ack_clear(3,4,"submitted","submitted"));
        assert!(!save_ack_clear(3,3,"submitted","submitted"));
        assert!(!save_ack_clear(3,4,"submitted","new edit"));
        assert!(!save_ack_clear(3,2,"submitted","submitted"));
    }
    #[test]
    fn presence_more_buttons_have_button_role_and_named_asset(){
        let(role,label)=presence_more_accessibility("移除角色","2B");
        assert!(matches!(role,gpui_kit::Role::Button));
        assert_eq!(label,"角色「2B」的更多操作");
        let(role,label)=presence_more_accessibility("移除动作","优雅挥手");
        assert!(matches!(role,gpui_kit::Role::Button));
        assert_eq!(label,"动作「优雅挥手」的更多操作");
    }
    #[test]
    fn provider_sync_busy_blocks_only_that_provider_without_disconnect(){
        let busy=json!({"id":"netease","connected":true,"syncing":true});
        let ready=json!({"id":"qq-music","connected":true,"syncing":false});
        assert!(music_sync_command(&busy,false).is_none());
        assert_eq!(music_sync_command(&ready,false),Some(json!({"op":"music.sync","id":"qq-music"})));
        assert!(music_sync_command(&ready,true).is_none());
        assert!(music_sync_command(&json!({"id":"netease","connected":false}),false).is_none());
    }
    #[test]
    fn sync_failure_keeps_connected_provider_retry_as_sync_not_disconnect(){
        let failed=json!({"id":"netease","connected":true,"syncing":false,"hasError":true});
        assert_eq!(music_sync_command(&failed,false),Some(json!({"op":"music.sync","id":"netease"})));
    }
    #[test]
    fn category_rows_enable_whole_row_expansion() {
        let source = include_str!("settings.rs");
        let navigation = source.split("let mut menu=SidebarMenu::new();").nth(1).unwrap()
            .split("div().size_full()").next().unwrap();
        assert!(navigation.contains(".click_to_toggle(true)"), "category rows must expand on label clicks");
        assert!(navigation.contains(".default_open(active)"), "current category starts expanded");
    }
}
