use gpui_kit::component::{
    button::*,
    slider::{Slider, SliderEvent, SliderState},
    tab::{Tab, TabBar},
    *,
};
use gpui_kit::prelude::FluentBuilder;
use gpui_kit::*;
use serde_json::{Value, json};

fn finish_delete(pending: &mut Option<Value>, confirmed: bool, saving: bool) -> Option<Value> {
    pending.take().filter(|_| confirmed && !saving)
}

pub struct ResidentPropEditorPane {
    snapshot: Value,
    commands: Vec<Value>,
    confirming_delete: Option<Value>,
    size: Entity<SliderState>,
    _subscriptions: Vec<Subscription>,
}
impl ResidentPropEditorPane {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let size = cx.new(|_| SliderState::new().min(0.02).max(3.).step(0.01));
        let subscription = cx.subscribe(&size, |this, _, event: &SliderEvent, cx| {
            if let SliderEvent::Release(value) = event {
                if this.snapshot["isSaving"].as_bool() != Some(true)
                    && !this.snapshot["selected"].is_null()
                    && this.snapshot["selected"]["held"].as_bool() != Some(true)
                {
                    this.commands
                        .push(json!({"op":"stage.props.resize","value":value.start()}));
                    cx.notify();
                }
            }
        });
        let owner=Window::window_handle(window);let weak=cx.entity().downgrade();
        let escape=cx.intercept_keystrokes(move|event,window,cx|{
            if event.keystroke.key=="escape"&&Window::window_handle(window)==owner{
                _=weak.update(cx,|this,cx|{if this.confirming_delete.take().is_some(){window.close_dialog(cx);cx.stop_propagation();cx.notify();}});
            }
        });
        Self {
            snapshot: Value::Null,
            commands: vec![json!({"op":"stage.props.load"})],
            confirming_delete: None,
            size,
            _subscriptions: vec![subscription,escape],
        }
    }
    pub fn update_snapshot(
        &mut self,
        snapshot: Value,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.snapshot != snapshot {
            if self.snapshot["selected"]["objectID"] != snapshot["selected"]["objectID"]
                || self.snapshot["selected"]["longestEdge"] != snapshot["selected"]["longestEdge"]
            {
                if let Some(value) = snapshot["selected"]["longestEdge"].as_f64() {
                    self.size
                        .update(cx, |size, cx| size.set_value(value as f32, window, cx));
                }
            }
            self.snapshot = snapshot;
            cx.notify();
        }
    }
    pub fn take_commands(&mut self) -> Vec<Value> {
        std::mem::take(&mut self.commands)
    }
    fn open_delete(&mut self, command: Value, window: &mut Window, cx: &mut Context<Self>) {
        let id=command["objectID"].clone();
        let name=self.snapshot["sections"].as_array().into_iter().flatten()
            .flat_map(|s|s["rows"].as_array().into_iter().flatten())
            .find(|row|row["objectID"]==id).and_then(|r|r["name"].as_str())
            .or_else(||(self.snapshot["selected"]["objectID"]==id).then(||self.snapshot["selected"]["name"].as_str()).flatten()).unwrap_or("这一件").to_owned();
        self.confirming_delete=Some(command);
        let weak=cx.entity().downgrade();
        window.open_dialog(cx,move|dialog,_,cx|{
            let saving=weak.upgrade().is_none_or(|entity|entity.read(cx).snapshot["isSaving"].as_bool()==Some(true));
            let cancel=weak.clone();let confirm=weak.clone();let closed=weak.clone();
            dialog.title(format!("永久删除「{name}」？")).close_button(false).overlay_closable(false)
                .child("删除后不能恢复，它也不会再出现在「我的物件」里。")
                .footer(div().flex().justify_end().gap_2()
                    .child(Button::new("prop-cancel-delete").label("取消").on_click(move|_,window,cx|{
                        _=cancel.update(cx,|this,cx|{_=finish_delete(&mut this.confirming_delete,false,false);cx.notify();});window.close_dialog(cx);
                    }))
                    .child(Button::new("prop-confirm-delete").danger().disabled(saving).label("永久删除").on_click(move|_,window,cx|{
                        _=confirm.update(cx,|this,cx|{if let Some(command)=finish_delete(&mut this.confirming_delete,true,this.snapshot["isSaving"].as_bool()==Some(true)){this.commands.push(command);}cx.notify();});window.close_dialog(cx);
                    })))
                .on_cancel(move|_,window,cx|{_=closed.update(cx,|this,cx|{this.confirming_delete=None;cx.notify();});window.close_dialog(cx);true})
        });
    }
    fn button(
        &self,
        id: impl Into<ElementId>,
        label: impl Into<SharedString>,
        command: Value,
        disabled: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        Button::new(id)
            .with_size(gpui_kit::component::Size::Small)
            .label(label)
            .disabled(disabled || self.snapshot["isSaving"].as_bool() == Some(true))
            .on_click(cx.listener(move |this, _, window, cx| {
                if command["op"] == "stage.props.delete" {
                    this.open_delete(command.clone(),window,cx);
                } else {
                    this.commands.push(command.clone());
                }
                cx.notify();
            }))
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::finish_delete;
    use serde_json::json;
    #[test]
    fn cancellation_never_emits_delete_and_clears_confirmation() {
        let mut pending=Some(json!({"op":"stage.props.delete","objectID":"test-only"}));
        assert!(finish_delete(&mut pending,false,false).is_none());
        assert!(pending.is_none());
    }
    #[test]
    fn confirm_emits_original_command_once_only_when_not_saving() {
        let command=json!({"op":"stage.props.delete","objectID":"test-only"});
        let mut pending=Some(command.clone());
        assert_eq!(finish_delete(&mut pending,true,false),Some(command));
        assert!(finish_delete(&mut pending,true,false).is_none());
        pending=Some(json!({"op":"stage.props.delete"}));
        assert!(finish_delete(&mut pending,true,true).is_none());
    }
}
impl Render for ResidentPropEditorPane {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let mut content = div()
            .flex()
            .flex_col()
            .gap(px(14.))
            .child(
                div()
                    .flex()
                    .justify_between()
                    .child(
                        div()
                            .text_size(px(14.))
                            .font_weight(FontWeight::SEMIBOLD)
                            .child("摆放"),
                    )
                    .child(self.button(
                        "props-close",
                        "×",
                        json!({"op":"stage.props.close"}),
                        false,
                        cx,
                    )),
            )
            .child(TabBar::new("props-filter").segmented().small().h(px(24.)).w_full()
                .selected_index(usize::from(self.snapshot["placedOnly"].as_bool()==Some(true)))
                .children(["我的物件","房间里"].map(|label|Tab::new().flex_1().min_w(px(0.)).label(label)))
                .on_click(cx.listener(|this,index:&usize,_,cx|{this.commands.push(json!({"op":"stage.props.filter","placedOnly":*index==1}));cx.notify();})));
        let mut list = div().flex().flex_col().gap_2();
        for section in self.snapshot["sections"].as_array().into_iter().flatten() {
            let group = section["group"].as_str().unwrap_or("");
            list=list.child(self.button(format!("props-group-{group}"),section["title"].as_str().unwrap_or("").to_owned(),json!({"op":"stage.props.fold","group":group,"folded":section["isFolded"].as_bool()!=Some(true)}),false,cx));
            for row in section["rows"].as_array().into_iter().flatten() {
                let id = row["id"].as_str().unwrap_or("");
                let object = row["objectID"].clone();
                let mut item = div()
                    .p_2()
                    .rounded(px(8.))
                    .bg(rgb(0x20252b))
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(
                        self.button(
                            format!("props-select-{id}"),
                            row["name"].as_str().unwrap_or("").to_owned(),
                            json!({"op":"stage.props.select","objectID":object}),
                            !row["actions"]
                                .as_array()
                                .is_some_and(|a| a.iter().any(|v| v == "place" || v == "withdraw")),
                            cx,
                        ),
                    )
                    .child(
                        div()
                            .text_xs()
                            .child(row["statusText"].as_str().unwrap_or("").to_owned()),
                    );
                let mut actions = div().flex().flex_wrap().gap_1();
                for action in row["actions"].as_array().into_iter().flatten() {
                    let action = action.as_str().unwrap_or("");
                    let label = match action {
                        "claim" => "领取",
                        "askResidentToFetch" => "让居民去取",
                        "retry" => "重试",
                        "retryInventoryRegistration" => "重试入库",
                        "withdraw" => "收回",
                        "delete" => "删除",
                        _ => continue,
                    };
                    if action == "askResidentToFetch" {
                        actions = actions.child(
                            Button::new(format!("props-{id}-claim-unavailable"))
                                .label("领取")
                                .disabled(true),
                        );
                    }
                    actions=actions.child(self.button(format!("props-{id}-{action}"),label,json!({"op":format!("stage.props.{action}"),"objectID":object,"jobID":row["jobID"]}),false,cx));
                }
                item = item.child(actions);
                list = list.child(item);
            }
        }
        if self.snapshot["rowCount"].as_u64() == Some(0) {
            list = list.child(
                self.snapshot["emptyMessage"]
                    .as_str()
                    .unwrap_or("还没有许愿。对居民说你想要什么，做好后会出现在这里。")
                    .to_owned(),
            );
        }
        if let Some(count) = self.snapshot["remainingCount"].as_u64().filter(|v| *v > 0) {
            list = list.child(format!("还有 {count} 件"));
        }
        content = content.child(
            div()
                .id("props-ownership-scroll")
                .max_h(px(190.))
                .overflow_y_scroll()
                .child(list),
        );
        let selected = self.snapshot["selected"].clone();
        if !selected.is_null() {
            content=content.child(div().h(px(1.)).bg(rgb(0x34373c)));
            let points = self.snapshot["holdPoints"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            let active = points
                .iter()
                .position(|slot| slot["id"] == selected["holdPoint"]);
            let slot_title = points
                .iter()
                .find(|slot| slot["id"] == selected["holdPoint"])
                .and_then(|slot| slot["name"].as_str())
                .unwrap_or("")
                .to_owned();
            let saving = self.snapshot["isSaving"].as_bool() == Some(true);
            let slots = TabBar::new("prop-hold-points")
                .segmented()
                .with_size(gpui_kit::component::Size::Small)
                .w(px(156.))
                .h(px(24.))
                .when_some(active, |bar, index| bar.selected_index(index))
                .children(points.iter().map(|slot| {
                    Tab::new()
                        .label(slot["name"].as_str().unwrap_or("").to_owned())
                        .w(px(48.6667))
                        .disabled(saving)
                }))
                .on_click(cx.listener(move |this, index: &usize, _, cx| {
                    if let Some(point) = points.get(*index) {
                        this.commands
                            .push(json!({"op":"stage.props.hold","point":point["id"]}));
                        cx.notify();
                    }
                }));
            if selected["held"].as_bool() == Some(true) {
                content = content.child(
                    div()
                        .flex()
                        .items_center()
                        .gap(px(8.))
                        .child(format!("{slot_title}展示微调"))
                        .child(div().flex_1())
                        .child(slots),
                );
                let mut nudges = div().flex().gap_1();
                for (label, y, z) in [
                    ("向前", 0., -0.02),
                    ("向后", 0., 0.02),
                    ("向上", 0.02, 0.),
                    ("向下", -0.02, 0.),
                ] {
                    nudges = nudges.child(self.button(
                        format!("prop-nudge-{label}"),
                        label,
                        json!({"op":"stage.props.nudge","y":y,"z":z}),
                        false,
                        cx,
                    ));
                }
                content = content.child(nudges).child(
                    div()
                        .flex()
                        .gap_1()
                        .child(self.button(
                            "prop-left",
                            "左转 15°",
                            json!({"op":"stage.props.rotate","direction":-1}),
                            false,
                            cx,
                        ))
                        .child(self.button(
                            "prop-right",
                            "右转 15°",
                            json!({"op":"stage.props.rotate","direction":1}),
                            false,
                            cx,
                        ))
                        .child(div().flex_1())
                        .child(self.button(
                            "prop-return",
                            "放回",
                            json!({"op":"stage.props.return"}),
                            false,
                            cx,
                        )),
                );
            } else {
                content = content
                    .child(
                        div()
                            .flex()
                            .gap_2()
                            .child(
                                self.button(
                                    "prop-hold",
                                    "拿着看",
                                    json!({"op":"stage.props.hold"}),
                                    selected["holdUnavailableReason"]
                                        .as_str()
                                        .is_some_and(|s| !s.is_empty()),
                                    cx,
                                ),
                            )
                            .child(self.button(
                                "prop-withdraw",
                                "收回",
                                json!({"op":"stage.props.withdraw"}),
                                selected["enabled"].as_bool() != Some(true),
                                cx,
                            ))
                            .child(div().flex_1())
                            .child(slots),
                    );
                if let Some(reason) = selected["holdUnavailableReason"].as_str() {
                    content = content.child(reason.to_owned());
                }
                content=content.child("移动指针选位置，左键放下，右键转 45°，Esc 放回。");
            }
            content = content.child(div().flex().gap(px(8.)).child(self.button(
                "prop-delete",
                "删除",
                json!({"op":"stage.props.delete","objectID":selected["objectID"]}),
                false,
                cx,
            )).child(div().flex_1()));
            if selected["held"].as_bool() != Some(true) {
                let mut sizes = div().flex().items_center().gap(px(6.));
                for (label, delta) in [
                    ("−10 cm", -0.1),
                    ("−1 cm", -0.01),
                    ("+1 cm", 0.01),
                    ("+10 cm", 0.1),
                ] {
                    sizes=sizes.child(self.button(format!("prop-size-{label}"),label,json!({"op":"stage.props.resize","value":selected["longestEdge"].as_f64().unwrap_or(0.)+delta}),false,cx));
                }
                sizes=sizes.child(div().flex_1()).child(div().text_size(px(11.)).child(format!("最长边 {:.2} m",selected["longestEdge"].as_f64().unwrap_or(0.))));
                content = content.child(div().h(px(1.)).bg(rgb(0x34373c)))
                    .child("尺寸")
                    .child(sizes)
                    .child(
                        div().flex().items_center().gap(px(8.)).child(div().flex_1().min_w(px(0.)).child(Slider::new(&self.size)
                            .disabled(self.snapshot["isSaving"].as_bool() == Some(true))))
                            .child(div().w(px(52.)).text_size(px(11.)).child(format!("{:.2} m",selected["longestEdge"].as_f64().unwrap_or(0.)))),
                    );
                for key in ["sizeDescription", "sizeProvenance"] {
                    if let Some(text) = selected[key].as_str() {
                        content = content.child(text.to_owned());
                    }
                }
            }
        }
        let mut legend = div().flex().gap(px(10.));
        for item in self.snapshot["legend"].as_array().into_iter().flatten() {
            if let (Some(r), Some(g), Some(b), Some(label)) = (
                item["red"].as_f64(),
                item["green"].as_f64(),
                item["blue"].as_f64(),
                item["label"].as_str(),
            ) {
                legend = legend.child(
                    div()
                        .flex()
                        .items_center()
                        .gap(px(4.))
                        .child(div().w(px(8.)).h(px(8.)).rounded(px(2.)).bg(Rgba {
                            r: r as f32,
                            g: g as f32,
                            b: b as f32,
                            a: 1.,
                        }))
                        .child(div().text_size(px(10.)).child(label.to_owned())),
                );
            }
        }
        content = content.child(legend);
        for key in ["notice", "wallPlacementText"] {
            if let Some(text) = self.snapshot[key].as_str().filter(|s| !s.is_empty()) {
                content = content.child(div().text_xs().child(text.to_owned()));
            }
        }
        content = content.child(self.button(
            "props-undo",
            "撤销上次",
            json!({"op":"stage.props.undo"}),
            self.snapshot["canUndo"].as_bool() != Some(true),
            cx,
        ));
        div()
            .w(px(340.))
            .max_h(px(390.))
            .rounded(px(16.))
            .bg(rgb(0x13161b))
            .border_1()
            .border_color(rgb(0x34373c))
            .text_color(rgb(0xe5e7ea))
            .text_xs()
            .child(
                div()
                    .id("props-panel-scroll")
                    .max_h(px(390.))
                    .overflow_y_scroll()
                    .p_4()
                    .child(content),
            )
    }
}
