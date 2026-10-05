//! Native stage panels. Catalogs, availability and every mutation belong to the host.
use crate::ui_tokens as ui;
use crate::i18n::{UiLocale, settings_copy, player_choice_label};
use gpui_kit::component::{
    button::*,
    menu::*,
    slider::{Slider, SliderEvent, SliderState},
    *,
};
use gpui_kit::*;
use serde_json::{Value, json};

mod program;
mod props;
pub use program::{StageProgramRailPane, ProgramMaterialFrame, ProgramMaterialCard};
pub use props::ResidentPropEditorPane;

pub const STAGE_PANEL_WIDTH: f32 = 590.;
pub const STAGE_PANEL_HEIGHT: f32 = 458.;

pub(crate) fn style_choice_accessibility(title: &str, name: &str, selected: bool) -> (Role, String) {
    (Role::Button, format!("{title}：{name}{}", if selected { "，已选择" } else { "" }))
}
pub(crate) fn player_section_includes(section:&str,key:&str)->bool{
    match section{"歌词"=>key=="lyrics","视觉效果"=>key=="clouds","视频"=>key=="videoModes",_=>true}
}

fn video_asset_actions(player:&Value,asset:&Value)->Vec<(&'static str,Value,bool)>{
    let id=asset["id"].clone();
    let active=player["videoActive"].as_bool()==Some(true)&&player["videoAssetID"]==id;
    let mut actions=vec![(if active{"取消加载"}else{"加载"},json!({"op":"stage.video.toggle","id":id}),false)];
    if player["trackID"].as_str().is_some_and(|s|!s.is_empty()){
        let bound=player["boundVideoID"]==id;
        actions.push((if bound{"解除当前歌曲绑定"}else{"绑定到当前歌曲"},json!({"op":if bound{"stage.video.unbind"}else{"stage.video.bind"},"id":id}),false));
    }
    actions.push(("移出素材库",json!({"op":"stage.video.remove","id":id}),true));
    actions
}
#[cfg(test)]
mod video_menu_tests{
    use super::video_asset_actions;
    use serde_json::json;
    #[test]
    fn asset_submenu_preserves_active_toggle_and_bound_track_commands(){
        let actions=video_asset_actions(&json!({"videoActive":true,"videoAssetID":"asset","trackID":"track","boundVideoID":"asset"}),&json!({"id":"asset"}));
        assert_eq!(actions[0].0,"取消加载");
        assert_eq!(actions[0].1,json!({"op":"stage.video.toggle","id":"asset"}));
        assert_eq!(actions[1].0,"解除当前歌曲绑定");
        assert_eq!(actions[1].1["op"],"stage.video.unbind");
        assert_eq!(actions[2].0,"移出素材库");assert!(actions[2].2);
    }
    #[test]
    fn no_track_omits_binding_and_inactive_asset_loads(){
        let actions=video_asset_actions(&json!({"videoActive":false}),&json!({"id":"asset"}));
        assert_eq!(actions.len(),2);assert_eq!(actions[0].0,"加载");
        assert_eq!(actions[1].1,json!({"op":"stage.video.remove","id":"asset"}));
        let actions=video_asset_actions(&json!({"trackID":"track","boundVideoID":"other"}),&json!({"id":"asset"}));
        assert_eq!(actions[1].0,"绑定到当前歌曲");assert_eq!(actions[1].1["op"],"stage.video.bind");
    }
}

pub struct StagePanelsPane {
    snapshot: Value,
    commands: Vec<Value>,
    tab: usize,
    embedded: bool,
    section: String,
    initialized: bool,
    motion_category: String,
    sliders: Vec<Entity<SliderState>>,
    syncing: bool,
    _subscriptions: Vec<Subscription>,
}

impl StagePanelsPane {
    pub fn new(_window: &mut Window, cx: &mut Context<Self>) -> Self {
        let sliders: Vec<_> = [(-2., 2.), (-2., 2.), (-3., 3.), (0.6, 1.6), (0.15, 1.)]
            .into_iter()
            .map(|(min, max)| cx.new(|_| SliderState::new().min(min).max(max).step(0.01)))
            .collect();
        let subscriptions = sliders.iter().enumerate().map(|(i,slider)|cx.subscribe(slider,move|this,_,event:&SliderEvent,cx| {
            if this.syncing { return; }
            if let SliderEvent::Change(value) = event {
                let command = match i {
                    0..=2=>json!({"op":"stage.avatar.position","axis":(["X","Y","Z"][i]),"value":value.start()}),
                    3=>json!({"op":"stage.player.particles","value":value.start()}),
                    _=>json!({"op":"stage.video.brightness","value":value.start()}),
                };
                this.commands.push(command); cx.notify();
            }
        })).collect();
        Self {
            snapshot: Value::Null,
            commands: vec![json!({"op":"stage.load"})],
            tab: 1,
            embedded: false,
            section: String::new(),
            initialized: false,
            motion_category: String::new(),
            sliders,
            syncing: false,
            _subscriptions: subscriptions,
        }
    }
    pub fn take_commands(&mut self) -> Vec<Value> {
        std::mem::take(&mut self.commands)
    }
    pub fn set_embedded(&mut self, embedded: bool, cx: &mut Context<Self>) {
        self.embedded = embedded;
        cx.notify();
    }
    pub fn select_section(&mut self, section:&str,cx:&mut Context<Self>){self.section=section.into();cx.notify();}
    pub fn select_tab(&mut self, tab: &str, cx: &mut Context<Self>) {
        self.tab = match tab {
            "player" => 0,
            "motions" => 2,
            "activities" => 3,
            _ => 1,
        };
        if self.tab == 2 {
            self.commands.push(json!({"op":"stage.motion.refresh"}));
        }
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
            self.tab = if snapshot["stageRadioPluginEnabled"].as_bool() == Some(true)
                && snapshot["mode"].as_str() == Some("player")
            {
                0
            } else {
                1
            };
            self.initialized = true;
        }
        self.syncing = true;
        for (i, value) in [
            snapshot["space"]["position"]["X"].as_f64(),
            snapshot["space"]["position"]["Y"].as_f64(),
            snapshot["space"]["position"]["Z"].as_f64(),
            snapshot["player"]["particleScale"].as_f64(),
            snapshot["player"]["videoBrightness"].as_f64(),
        ]
        .into_iter()
        .enumerate()
        {
            if let Some(value) = value {
                if value.is_finite() {
                    self.sliders[i]
                        .update(cx, |slider, cx| slider.set_value(value as f32, window, cx));
                }
            }
        }
        self.syncing = false;
        self.snapshot = snapshot;
        cx.notify();
    }
    fn button(
        &self,
        id: impl Into<ElementId>,
        label: impl Into<SharedString>,
        command: Value,
        disabled: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let label: SharedString = label.into();
        let label = settings_copy(UiLocale::from_settings(&self.snapshot), label.as_ref()).to_owned();
        Button::new(id)
            .small()
            .label(label)
            .disabled(disabled)
            .on_click(cx.listener(move |this, _, _, cx| {
                this.commands.push(command.clone());
                cx.notify();
            }))
            .into_any_element()
    }
    fn space(&self, cx: &mut Context<Self>) -> AnyElement {
        let locale = UiLocale::from_settings(&self.snapshot);
        let space = &self.snapshot["space"];
        let weak = cx.entity().downgrade();
        let catalog = space.clone();
        let menu = Button::new("stage-world-menu")
            .w_full()
            .small()
            .rounded(px(12.))
            .label(
                space["worldLabel"]
                    .as_str()
                    .unwrap_or(settings_copy(locale, "公开空间 · 无需生成"))
                    .to_owned(),
            )
            .dropdown_caret(true)
            .dropdown_menu(move |mut menu, _, _| {
                for (key, title, op) in [
                    ("worlds", "公开空间", "stage.world.enter"),
                    ("presets", "生成场景", "stage.scene.activate"),
                ] {
                    menu = menu.item(PopupMenuItem::label(title));
                    for world in catalog[key].as_array().into_iter().flatten() {
                        let id = world["id"].as_str().unwrap_or("").to_owned();
                        if id.is_empty() {
                            continue;
                        }
                        let handle = weak.clone();
                        let command = json!({"op":op,"id":id});
                        let selected = catalog["selectedWorldID"] == world["id"];
                        menu = menu.item(
                            PopupMenuItem::new(format!(
                                "{}{}",
                                if selected { "✓ " } else { "" },
                                world["name"].as_str().unwrap_or("")
                            ))
                            .on_click(move |_, _, cx| {
                                _ = handle.update(cx, |this, cx| {
                                    this.commands.push(command.clone());
                                    cx.notify();
                                });
                            }),
                        );
                    }
                    menu = menu.separator();
                }
                menu
            });
        let mut form = div()
            .flex()
            .flex_col()
            .gap_3()
            .child(div().h(px(36.)).child(menu));
        form = form.child(
            div()
                .text_size(px(14.))
                .font_weight(FontWeight::SEMIBOLD)
                .child(settings_copy(locale, "人物位置")),
        );
        let mut axes = div().flex().flex_col().gap(px(5.));
        for (i, label) in ["X", "Y", "Z"].into_iter().enumerate() {
            axes = axes.child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(9.))
                    .min_h(px(36.))
                    .child(
                        div()
                            .w(px(12.))
                            .font_family("Menlo")
                            .font_weight(FontWeight::BOLD)
                            .text_color(rgba(0xffffff85))
                            .child(label),
                    )
                    .child(div().flex_1().child(Slider::new(&self.sliders[i])))
                    .child(
                        div()
                            .w(px(42.))
                            .text_right()
                            .font_family("Menlo")
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(rgba(0xffffffad))
                            .child(format!(
                                "{:.2}",
                                space["position"][["X", "Y", "Z"][i]].as_f64().unwrap_or(0.)
                            )),
                    ),
            );
        }
        form = form
            .child(axes)
            .child(
                div()
                    .flex()
                    .justify_between()
                    .items_center()
                    .child(settings_copy(locale, "人物位置会按当前空间保存"))
                    .child(self.button(
                        "avatar-reset",
                        "重置",
                        json!({"op":"stage.avatar.reset"}),
                        false,
                        cx,
                    )),
            )
            .child(
                div()
                    .flex()
                    .justify_between()
                    .items_center()
                    .child(settings_copy(locale, "W/S 沿视线前后移动，A/D 左右移动"))
                    .child(self.button(
                        "camera-reset",
                        "镜头复位",
                        json!({"op":"stage.camera.reset"}),
                        false,
                        cx,
                    )),
            );
        if let Some(message) = space["notice"].as_str().filter(|s| !s.is_empty()) {
            form = form.child(div().text_color(rgb(0x80dce4)).child(message.to_owned()));
        }
        form.into_any_element()
    }
    fn motions(&self, cx: &mut Context<Self>) -> AnyElement {
        let locale = UiLocale::from_settings(&self.snapshot);
        let motions = &self.snapshot["motions"];
        let mut form = div()
            .flex()
            .flex_col()
            .gap(px(10.))
            .child(
                div()
                    .flex()
                    .justify_between()
                    .child(
                        motions["avatarName"]
                            .as_str()
                            .unwrap_or(settings_copy(locale, "尚未选择角色"))
                            .to_owned(),
                    )
                    .child(self.button(
                        "motion-refresh",
                        "刷新",
                        json!({"op":"stage.motion.refresh"}),
                        false,
                        cx,
                    )),
            )
            .child(settings_copy(locale, "选择已安装动作；自然待机可结束当前表演。"));
        let mut categories = div().flex().flex_wrap().gap_1();
        categories = categories.child(Button::new("all-motion-categories").small().label(settings_copy(locale, "全部")).on_click(
            cx.listener(|this, _, _, cx| {
                this.motion_category.clear();
                cx.notify();
            }),
        ));
        for category in motions["categories"].as_array().into_iter().flatten() {
            let id = category["id"].as_str().unwrap_or("").to_owned();
            categories = categories.child(
                Button::new(format!("motion-category-{id}"))
                    .small().label(category["name"].as_str().unwrap_or("").to_owned())
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.motion_category = id.clone();
                        cx.notify();
                    })),
            );
        }
        form = form.child(categories);
        let mut count = 0;
        for motion in motions["items"].as_array().into_iter().flatten() {
            if !self.motion_category.is_empty()
                && motion["category"].as_str() != Some(&self.motion_category)
            {
                continue;
            }
            count += 1;
            let id = motion["id"].as_str().unwrap_or("");
            form = form.child(self.button(
                format!("motion-{id}"),
                format!(
                    "{}{}",
                    if motions["activeID"] == motion["id"] {
                        "✓ "
                    } else {
                        ""
                    },
                    motion["name"].as_str().unwrap_or("")
                ),
                json!({"op":"stage.motion.activate","id":id}),
                motion["compatible"].as_bool() != Some(true)
                    || motions["isWorking"].as_bool() == Some(true),
                cx,
            ));
            if let Some(reason) = motion["reason"].as_str().filter(|s| !s.is_empty()) {
                form = form.child(
                    div()
                        .text_xs()
                        .text_color(rgb(0xa1a7b0))
                        .child(reason.to_owned()),
                );
            }
        }
        if count == 0 {
            form = form.child(settings_copy(locale, if self.motion_category.is_empty() {
                "暂无可用动作，请在资产管理中安装。"
            } else {
                "这个分类下暂无当前角色可用的动作。"
            }));
        }
        for key in ["notice", "message"] {
            if let Some(message) = motions[key].as_str().filter(|s| !s.is_empty()) {
                form = form.child(message.to_owned());
            }
        }
        form.child(self.button(
            "manage-motion-assets",
            "管理角色与动作…",
            json!({"op":"stage.assets.manage"}),
            false,
            cx,
        ))
        .into_any_element()
    }
    fn activities(&self, cx: &mut Context<Self>) -> AnyElement {
        let locale = UiLocale::from_settings(&self.snapshot);
        let activity = &self.snapshot["activities"];
        let mut form = div()
            .flex()
            .flex_col()
            .gap(px(10.))
            .child(settings_copy(locale, "活动来自当前空间，角色会走到对应位置再开始。"));
        if activity["canRun"].as_bool() == Some(true) {
            for item in activity["items"].as_array().into_iter().flatten() {
                let id = item["id"].as_str().unwrap_or("");
                form = form.child(self.button(
                    format!("activity-{id}"),
                    format!(
                        "{}{}",
                        if activity["activeID"] == item["id"] {
                            "✓ "
                        } else {
                            ""
                        },
                        item["name"].as_str().unwrap_or("")
                    ),
                    json!({"op":"stage.activity.run","id":id}),
                    false,
                    cx,
                ));
            }
            if activity["items"].as_array().is_none_or(|a| a.is_empty()) {
                form = form.child(settings_copy(locale, "这个空间还没有配置生活活动。"));
            }
            form = form.child(self.button(
                "activity-stop",
                settings_copy(locale, "停止活动"),
                json!({"op":"stage.activity.stop"}),
                activity["activeID"].as_str().is_none_or(|s| s.is_empty()),
                cx,
            ));
        } else {
            form = form.child(
                settings_copy(locale, if self.snapshot["space"]["isVisible"].as_bool() == Some(true) {
                    "这个空间还没有配置生活活动。"
                } else if self.snapshot["space"]["isRequested"].as_bool() == Some(true) {
                    "空间载入完成后可选择活动。"
                } else {
                    "进入空间后可选择生活活动。"
                }),
            );
        }
        if let Some(message) = activity["message"].as_str().filter(|s| !s.is_empty()) {
            form = form.child(message.to_owned());
        }
        form.into_any_element()
    }
    fn player(&self, cx: &mut Context<Self>) -> AnyElement {
        let locale = UiLocale::from_settings(&self.snapshot);
        let player = &self.snapshot["player"];
        let mut form = div().flex().flex_col().gap_3();
        if self.snapshot["space"]["isRequested"].as_bool() == Some(true) {
            form = form.child(settings_copy(locale, "这些效果用于播放器画面，切回播放器后可查看"));
        }
        for (key, title, op, selected) in [
            ("lyrics", "字幕特效", "stage.player.lyrics", "lyricID"),
            ("clouds", "3D 点阵", "stage.player.cloud", "cloudID"),
            ("videoModes", "MV 场景", "stage.video.mode", "videoMode"),
        ] {
            if self.embedded && !player_section_includes(&self.section,key){continue;}
            let columns = if key == "lyrics" { 5 } else { 4 };
            let tile_width = (544. - 6. * (columns as f32 - 1.)) / columns as f32;
            let mut choices = div().flex().flex_wrap().gap(px(6.));
            for item in player[key].as_array().into_iter().flatten() {
                let id = item["id"].as_str().unwrap_or("");
                let is_selected = player[selected] == item["id"];
                let command = json!({"op":op,"id":id});
                let name = player_choice_label(locale, key, id, item["name"].as_str().unwrap_or(""));
                let (role, _) = style_choice_accessibility(title, name, is_selected);
                let label = format!("{}: {name}{}", settings_copy(locale, title),
                    if is_selected { format!(", {}", settings_copy(locale, "已选择")) } else { String::new() });
                let mut tile = div()
                    .id(format!("{key}-{id}"))
                    .role(role)
                    .aria_label(label)
                    .w(px(tile_width))
                    .min_h(px(48.))
                    .rounded(px(13.))
                    .border_1()
                    .border_color(if is_selected {
                        rgba(0x00ffff85)
                    } else {
                        rgba(0xffffff12)
                    })
                    .bg(if is_selected {
                        rgba(0x00ffff29)
                    } else {
                        rgba(0xffffff0b)
                    })
                    .flex()
                    .flex_col()
                    .items_center()
                    .justify_center()
                    .gap(px(5.))
                    .text_sm()
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(if is_selected {
                        rgb(0x7af2ff)
                    } else {
                        rgba(0xffffff9e)
                    })
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.commands.push(command.clone());
                        cx.notify();
                    }));
                let icon = match key {
                    "lyrics" => gpui_kit::assets::IconName::Captions,
                    "clouds" => gpui_kit::assets::IconName::Grid3x3,
                    _ => gpui_kit::assets::IconName::Video,
                };
                tile = tile.child(Icon::new(icon).size(px(14.)));
                choices = choices.child(tile.child(name.to_owned()));
            }
            form = form
                .child(
                    div()
                        .text_size(px(14.))
                        .font_weight(FontWeight::SEMIBOLD)
                        .child(settings_copy(locale, title)),
                )
                .child(choices);
            if key == "clouds" {
                form = form.child(
                    div()
                        .flex()
                        .items_center()
                        .gap_2()
                        .child(settings_copy(locale, "颗粒大小"))
                        .child(div().flex_1().child(Slider::new(&self.sliders[3])))
                        .child(format!(
                            "{}%",
                            (player["particleScale"].as_f64().unwrap_or(1.) * 100.).round()
                        )),
                );
            }
        }
        if !self.embedded || self.section=="视频" {
        form = form.child(
            div()
                .flex()
                .gap_2()
                .child(self.button(
                    "video-import",
                    settings_copy(locale, "导入 MP4"),
                    json!({"op":"stage.video.import"}),
                    false,
                    cx,
                ))
                .child(self.button(
                    "video-stop",
                    settings_copy(locale, "关闭"),
                    json!({"op":"stage.video.stop"}),
                    false,
                    cx,
                )),
        );
        if player["videoAssets"]
            .as_array()
            .is_some_and(|a| !a.is_empty())
        {
            form = form.child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(10.)).px(px(10.)).min_h(px(36.))
                    .child(Icon::new(gpui_kit::assets::IconName::SunDim).size(px(14.)))
                    .child(div().id("video-brightness").role(Role::Slider).aria_label(settings_copy(locale, "视频亮度")).flex_1().min_w(px(0.)).child(Slider::new(&self.sliders[4])))
                    .child(div().w(px(38.)).flex_shrink_0().font_family("Menlo").text_size(px(12.)).child(format!("{}%",(self.sliders[4].read(cx).value().start()*100.)as u32))),
            );
            let assets=player["videoAssets"].as_array().cloned().unwrap_or_default();
            let active=player["videoActive"].as_bool()==Some(true);
            let name=assets.iter().find(|asset|asset["id"]==player["videoAssetID"]).and_then(|asset|asset["name"].as_str()).unwrap_or(settings_copy(locale, "未加载视频")).to_owned();
            let status=if active{settings_copy(locale, "已加载").to_owned()}else{format!("{} {}",assets.len(),settings_copy(locale, "段"))};
            let weak=cx.entity().downgrade();let menu_player=player.clone();
            form=form.child(Button::new("video-assets-menu").ghost().small().w_full().rounded_full()
                .bg(rgba(0xffffff0b)).accessibility_label(format!("{name}，{status}"))
                .child(div().flex().items_center().gap(px(ui::SPACING_8)).w_full().text_sm()
                    .child(Icon::new(if active{gpui_kit::assets::IconName::Video}else{gpui_kit::assets::IconName::VideoOff}).size(px(14.)))
                    .child(div().flex_1().min_w(px(0.)).overflow_hidden().whitespace_nowrap().child(name))
                    .child(div().flex_shrink_0().child(status)))
                .dropdown_menu(move|mut menu,window,cx|{
                    for asset in &assets{
                        let actions=video_asset_actions(&menu_player,asset);let weak=weak.clone();
                        menu=menu.submenu(asset["name"].as_str().unwrap_or("").to_owned(),window,cx,move|mut sub,_,_|{
                            for(label,command,dangerous)in &actions{
                                if *dangerous{sub=sub.separator();}
                                let weak=weak.clone();let command=command.clone();
                                let item=if *dangerous{PopupMenuItem::element(move |_,cx|div().id("video-remove-menu-label").role(Role::MenuItem).aria_label(settings_copy(locale, "移出素材库")).text_color(cx.theme().danger).child(settings_copy(locale, "移出素材库")))}else{PopupMenuItem::new(settings_copy(locale, label))};
                                sub=sub.item(item.on_click(move|_,_,cx|{_=weak.update(cx,|this,cx|{this.commands.push(command.clone());cx.notify();});}));
                            }
                            sub
                        });
                    }
                    menu
                }));
        }
        }
        form.into_any_element()
    }
}
impl Render for StagePanelsPane {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        use gpui_kit::component::tab::{Tab, TabBar};
        let tabs = TabBar::new("stage-tabs")
            .segmented()
            .small()
            .w_full()
            .selected_index(self.tab)
            .children(
                ["播放器", "空间", "角色", "活动"]
                    .map(|label| Tab::new().label(label).flex_1().min_w_0()),
            )
            .on_click(cx.listener(|this, index: &usize, _, cx| {
                this.tab = *index;
                if *index == 2 {
                    this.commands.push(json!({"op":"stage.motion.refresh"}));
                }
                cx.notify();
            }));
        let body = match self.tab {
            0 => self.player(cx),
            2 => self.motions(cx),
            3 => self.activities(cx),
            _ => self.space(cx),
        };
        if self.embedded {
            return div().size_full().min_h(px(0.)).font_family(cx.theme().font_family.clone())
                .text_size(px(ui::BODY)).text_color(cx.theme().foreground)
                .child(div().id("embedded-stage-scroll").size_full().overflow_y_scroll().child(body))
                .into_any_element();
        }
        div()
            .font_family(cx.theme().font_family.clone())
            .text_size(px(ui::BODY))
            .line_height(px(ui::BODY_LINE_HEIGHT))
            .w(px(STAGE_PANEL_WIDTH))
            .h(px(STAGE_PANEL_HEIGHT))
            .p(px(7.))
            .child(
                div()
                    .size_full()
                    .flex()
                    .flex_col()
                    .gap(px(ui::SPACING_12))
                    .p(px(ui::SPACING_16))
                    .rounded(px(18.))
                    .bg(rgb(0x13161b))
                    .border_1()
                    .border_color(rgb(0x34373c))
                    .text_color(rgb(0xe5e7ea))
                    .text_size(px(ui::CAPTION))
                    .child(
                        div()
                            .flex()
                            .justify_between()
                            .child(
                                div()
                                    .text_size(px(ui::SUBTITLE))
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .child("舞台设置"),
                            )
                            .child(div().text_xs().text_color(cx.theme().muted_foreground).child(
                                if self.snapshot["space"]["isRequested"].as_bool() == Some(true) {
                                    "正在空间中"
                                } else {
                                    "正在播放器中"
                                },
                            )),
                    )
                    .child(tabs)
                    .child(
                        div()
                            .id("stage-panel-scroll")
                            .flex_1()
                            .overflow_y_scroll()
                            .child(body),
                    ),
            ).into_any_element()
    }
}
