use gpui_kit::component::button::*;
use gpui_kit::*;
use serde_json::{Value, json};

#[derive(Debug)]
struct CardProjection {
    width: f32,
    height: f32,
    opacity: f32,
    offset: f32,
}
fn project_card(card: &Value) -> CardProjection {
    let focused = card["isFocused"]
        .as_bool()
        .unwrap_or(card["isCurrent"].as_bool() == Some(true));
    // Swift applies scale/3D rotation after layout, not by shrinking the
    // measured card. GPUI's 2D div cannot faithfully reproduce that projection.
    CardProjection {
        width: 294.,
        height: 76.,
        opacity: if focused {
            1.
        } else {
            card["opacity"].as_f64().unwrap_or(1.) as f32
        },
        offset: card["horizontalOffset"].as_f64().unwrap_or(0.) as f32,
    }
}
fn energy_height(energy: f32, index: usize) -> f32 {
    5. + 13. * energy * (0.36 + ((index + 1) as f32 * 1.7).sin().abs() * 0.64)
}

pub struct StageProgramRailPane {
    snapshot: Value,
    commands: Vec<Value>,
    scroll: ScrollHandle,
    center_active: bool,
}
impl StageProgramRailPane {
    pub fn new(_window: &mut Window, _cx: &mut Context<Self>) -> Self {
        Self {
            snapshot: Value::Null,
            commands: vec![json!({"op":"stage.program.load"})],
            scroll: ScrollHandle::new(),
            center_active: true,
        }
    }
    pub fn update_snapshot(
        &mut self,
        snapshot: Value,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.snapshot != snapshot {
            let active = |state: &Value| {
                state["tracks"]
                    .as_array()
                    .and_then(|cards| {
                        cards
                            .iter()
                            .find(|card| card["isCurrent"].as_bool() == Some(true))
                    })
                    .map(|card| card["slotIndex"].clone())
            };
            if self.snapshot["route"] != snapshot["route"]
                || active(&self.snapshot) != active(&snapshot)
            {
                self.center_active = true;
            }
            self.snapshot = snapshot;
            cx.notify();
        }
    }
    pub fn take_commands(&mut self) -> Vec<Value> {
        std::mem::take(&mut self.commands)
    }
    fn button(
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
    fn icon_button(
        &self,
        id: impl Into<ElementId>,
        icon: gpui_kit::assets::IconName,
        tooltip: &'static str,
        command: Value,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        Button::new(id)
            .icon(icon)
            .tooltip(tooltip)
            .w(px(26.))
            .h(px(26.))
            .rounded_full()
            .on_click(cx.listener(move |this, _, _, cx| {
                this.commands.push(command.clone());
                cx.notify();
            }))
            .into_any_element()
    }
}
impl Render for StageProgramRailPane {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let tracks = self.snapshot["route"]
            .as_str()
            .is_some_and(|r| r != "programs");
        let mut content = div()
            .flex()
            .flex_col()
            .items_end()
            .gap(px(if tracks { -7. } else { 8. }))
            .py(px(18.));
        let mut header = div()
            .flex()
            .items_center()
            .gap(px(10.))
            .px(px(14.))
            .w_full();
        if tracks {
            header = header
                .child(self.icon_button(
                    "program-back",
                    gpui_kit::assets::IconName::ChevronLeft,
                    "返回节目单",
                    json!({"op":"stage.program.back"}),
                    cx,
                ))
                .child(div().flex_1())
                .child(self.snapshot["title"].as_str().unwrap_or("").to_uppercase());
            if self.snapshot["isPlaylist"].as_bool() != Some(true) {
                header = header.child(self.icon_button(
                    "program-replan",
                    gpui_kit::assets::IconName::RefreshCw,
                    "重新编排",
                    json!({"op":"stage.program.replan"}),
                    cx,
                ));
            }
            if self.center_active {
                if let Some(index) = self.snapshot["tracks"].as_array().and_then(|cards| {
                    cards
                        .iter()
                        .position(|card| card["isCurrent"].as_bool() == Some(true))
                }) {
                    let scroll = self.scroll.clone();
                    window.on_next_frame(move |window, _| {
                        let viewport: f32 = scroll.bounds().size.height.into();
                        let maximum: f32 = scroll.max_offset().y.into();
                        scroll.set_offset(point(
                            px(0.),
                            px(active_center_offset(index, viewport, maximum.abs())),
                        ));
                        window.refresh();
                    });
                }
                self.center_active = false;
            }
            for card in self.snapshot["tracks"].as_array().into_iter().flatten() {
                let index = card["slotIndex"].clone();
                let projection = project_card(card);
                let current = card["isCurrent"].as_bool() == Some(true);
                let command = json!({"op":"stage.program.play","slotIndex":index});
                let mut icon = div()
                    .w(px(44.))
                    .h(px(44.))
                    .rounded_full()
                    .bg(if current {
                        rgba(0x00ffff38)
                    } else {
                        rgba(0xffffff0f)
                    })
                    .flex()
                    .items_center()
                    .justify_center();
                if current {
                    let audio = &self.snapshot["audioFeatures"];
                    let mut bars = div()
                        .w(px(24.))
                        .h(px(25.))
                        .flex()
                        .items_center()
                        .gap(px(2.));
                    for i in 0..5 {
                        let sample = audio["waveform"][i].as_f64().unwrap_or(0.).abs() as f32;
                        let band = audio[if i < 2 {
                            "low"
                        } else if i == 2 {
                            "mid"
                        } else {
                            "high"
                        }]
                        .as_f64()
                        .unwrap_or(0.) as f32;
                        let amplitude = audio["amplitude"].as_f64().unwrap_or(0.) as f32;
                        let height = 5. + 18. * sample.max(band * 0.72).max(amplitude * 0.56);
                        bars = bars.child(
                            div()
                                .w(px(2.4))
                                .h(px(height))
                                .rounded_full()
                                .bg(rgb(0x7af2ff)),
                        );
                    }
                    icon = icon.child(bars);
                } else {
                    icon = icon.child("♫");
                }
                let mut trace = div()
                    .w(px(28.))
                    .h(px(22.))
                    .flex()
                    .items_center()
                    .gap(px(2.));
                for i in 0..7 {
                    trace = trace.child(
                        div()
                            .w(px(2.))
                            .h(px(energy_height(
                                card["energy"].as_f64().unwrap_or(0.) as f32,
                                i,
                            )))
                            .rounded_full()
                            .bg(rgba(0x00ffff6b)),
                    );
                }
                let mut row = div()
                    .id(format!("track-{index}"))
                    .w(px(projection.width))
                    .h(px(projection.height))
                    .relative()
                    .left(px(projection.offset))
                    .flex_shrink_0()
                    .opacity(projection.opacity)
                    .px(px(14.))
                    .rounded(px(23.))
                    .border_1()
                    .border_color(if card["isCurrent"].as_bool() == Some(true) {
                        rgb(0x68d6e8)
                    } else {
                        rgb(0x3d454c)
                    })
                    .bg(rgb(0x1c252d))
                    .flex()
                    .items_center()
                    .gap(px(13.))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.commands.push(command.clone());
                        cx.notify();
                    }))
                    .child(icon)
                    .child(
                        div()
                            .flex_1()
                            .flex()
                            .flex_col()
                            .gap(px(5.))
                            .child(
                                div()
                                    .text_size(px(if current { 17. } else { 16. }))
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .child(card["title"].as_str().unwrap_or("").to_owned()),
                            )
                            .child(
                                div()
                                    .flex()
                                    .items_center()
                                    .gap(px(12.))
                                    .child(
                                        div()
                                            .flex_1()
                                            .text_size(px(14.))
                                            .text_color(rgba(0xffffff7a))
                                            .child(
                                                card["artist"].as_str().unwrap_or("").to_owned(),
                                            ),
                                    )
                                    .child(trace),
                            ),
                    );
                if card["hasBoundVideo"].as_bool() == Some(true)
                    && card["isCurrent"].as_bool() == Some(true)
                {
                    row = row.child(
                        div()
                            .absolute()
                            .right(px(9.))
                            .top(px(8.))
                            .w(px(26.))
                            .h(px(26.))
                            .child(self.icon_button(
                                format!("track-video-{index}"),
                                gpui_kit::assets::IconName::Video,
                                "播放这首歌绑定的视频",
                                json!({"op":"stage.program.video","trackID":card["trackID"]}),
                                cx,
                            )),
                    );
                }
                content = content.child(row);
            }
            if self.snapshot["hasMore"].as_bool() == Some(true) {
                content = content.child(self.button(
                    "program-load-more",
                    "加载更多",
                    json!({"op":"stage.program.more"}),
                    cx,
                ));
            }
            if self.snapshot["tracks"]
                .as_array()
                .is_none_or(|a| a.is_empty())
            {
                content = content.child(
                    self.snapshot["emptyMessage"]
                        .as_str()
                        .unwrap_or("正在加载歌曲…")
                        .to_owned(),
                );
            }
        } else {
            header = header
                .child(self.icon_button(
                    "program-replan",
                    gpui_kit::assets::IconName::RefreshCw,
                    "重新编排",
                    json!({"op":"stage.program.replan"}),
                    cx,
                ))
                .child(div().flex_1())
                .child("歌单");
            for (key, op) in [
                ("programs", "stage.program.open"),
                ("playlists", "stage.playlist.open"),
            ] {
                for item in self.snapshot[key].as_array().into_iter().flatten() {
                    let id = item["id"].as_str().unwrap_or("");
                    content = content.child(
                        div()
                            .w(px(306.))
                            .h(px(74.))
                            .flex_shrink_0()
                            .px(px(14.))
                            .rounded(px(22.))
                            .bg(rgb(0x1c252d))
                            .border_1()
                            .border_color(rgb(0x3d454c))
                            .child(self.button(
                                format!("{key}-{id}"),
                                item["title"].as_str().unwrap_or("").to_owned(),
                                json!({"op":op,"id":id}),
                                cx,
                            ))
                            .child(
                                div()
                                    .text_xs()
                                    .child(item["subtitle"].as_str().unwrap_or("").to_owned()),
                            ),
                    );
                }
            }
            if self.snapshot["programs"]
                .as_array()
                .is_none_or(|a| a.is_empty())
                && self.snapshot["playlists"]
                    .as_array()
                    .is_none_or(|a| a.is_empty())
            {
                content = content.child(
                    self.snapshot["emptyMessage"]
                        .as_str()
                        .unwrap_or("暂无歌单")
                        .to_owned(),
                );
            }
        }
        div()
            .w(px(350.))
            .h(px(430.))
            .pt(px(42.))
            .pr(px(10.))
            .flex()
            .flex_col()
            .gap(px(8.))
            .text_color(rgb(0xe5e7ea))
            .child(header)
            .child(
                div()
                    .id("stage-program-scroll")
                    .w_full()
                    .flex_1()
                    .min_h(px(0.))
                    .overflow_y_scroll()
                    .track_scroll(&self.scroll)
                    .child(content),
            )
    }
}

fn active_center_offset(index: usize, viewport: f32, maximum: f32) -> f32 {
    -(18. + index as f32 * (76. - 7.) + 38. - viewport / 2.).clamp(0., maximum)
}

#[cfg(test)]
mod tests {
    use super::{active_center_offset, energy_height, project_card};
    use serde_json::json;
    #[test]
    fn visual_depth_does_not_change_original_card_layout() {
        let current = project_card(&json!({"isCurrent":true,"scale":1.,"depth":0,"opacity":1.}));
        let distant = project_card(
            &json!({"isCurrent":false,"scale":0.89,"depth":-144,"opacity":0.68,"relativeIndex":2}),
        );
        assert_eq!(distant.width, 294.);
        assert_eq!(current.width, 294.);
        assert_eq!(distant.height, 76.);
        assert_eq!(current.height, 76.);
        assert_eq!(distant.opacity, 0.68);
    }
    #[test]
    fn active_card_centers_using_original_overlap_and_margins() {
        assert_eq!(active_center_offset(0, 300., 900.), 0.);
        assert_eq!(active_center_offset(4, 300., 900.), -182.);
        assert_eq!(active_center_offset(30, 300., 900.), -900.);
    }
    #[test]
    fn focus_restores_visibility_without_mutating_host_card() {
        let card = json!({"isFocused":true,"scale":0.89,"depth":-144,"opacity":0.68});
        assert_eq!(project_card(&card).opacity, 1.);
        assert_eq!(card["opacity"], 0.68);
    }
    #[test]
    fn energy_trace_uses_real_track_energy() {
        for i in 0..7 {
            assert_eq!(energy_height(0., i), 5.);
            assert!(energy_height(1., i) > 5.);
            assert!(energy_height(1., i) <= 18.);
        }
    }
}
