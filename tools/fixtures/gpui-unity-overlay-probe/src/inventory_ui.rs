//! Inventory UI consumes Unity's recovery projection. It never infers model
//! readiness from durable metadata or creates a second placement authority.
use gpui_kit::*;
use gpui_kit::component::{button::Button, ActiveTheme, Disableable, scroll::ScrollableElement};
use serde_json::{Value, json};
use std::{cell::RefCell, collections::VecDeque, rc::Rc};

pub struct InventoryPane {
    snapshot: Value,
    commands: Rc<RefCell<VecDeque<Value>>>,
    confirm_delete: Option<String>,
    notice: String,
}

impl InventoryPane {
    pub fn new(_: &mut Window, _: &mut Context<Self>, commands: Rc<RefCell<VecDeque<Value>>>) -> Self {
        Self { snapshot: Value::Null, commands, confirm_delete: None, notice: String::new() }
    }

    pub fn update_snapshot(&mut self, snapshot: &Value, cx: &mut Context<Self>) {
        self.snapshot = snapshot.clone();
        let mutation = &snapshot["inventoryMutation"];
        if mutation["status"] == "failed" {
            self.notice = mutation["message"].as_str().unwrap_or("删除失败，请查看空间状态").into();
        }
        let receipt=&snapshot["unityUICommandResult"];
        if matches!(receipt["op"].as_str(),Some("ui.inventory.place"|"ui.device.place")) {
            if receipt["status"]=="rejected" {
                self.notice="当前无法开始摆放，请等待模型与场景准备完成后重试。".into();
            } else if receipt["status"]=="started" {
                self.notice="已进入摆放预览；请在场景中确认位置。".into();
            }
        }
        cx.notify();
    }

    fn enqueue(&mut self, command: Value, cx: &mut Context<Self>) {
        let mut queue = self.commands.borrow_mut();
        if queue.len() >= 32 { self.notice = "操作队列已满，请稍后重试".into(); }
        else { queue.push_back(command); self.notice = "请求已发送，等待空间回执".into(); }
        cx.notify();
    }
}

impl Render for InventoryPane {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let templates = self.snapshot["builtinDevices"]["templates"].as_array().cloned().unwrap_or_default();
        // C# must publish the very same InventoryUpdated payload used by the
        // existing catalog, including actual loaded-model readiness.
        let inventory = self.snapshot["unityInventory"].as_array().cloned();
        let mut rows = vec![div().text_color(cx.theme().muted_foreground).child("基本设备 · 保留").into_any_element()];
        for template in templates {
            let Some(id) = template["id"].as_str().filter(|id| !id.is_empty()).map(str::to_owned) else { continue };
            let title = match template["renderer"].as_str() {
                Some("builtin.jukebox") => "音乐播放器",
                Some("builtin.wish_machine") => "许愿机",
                _ => continue,
            };
            let key = SharedString::from(format!("device-place-{id}"));
            rows.push(div().flex().items_center().gap_3().p_3().rounded_md().bg(cx.theme().group_box)
                .child(div().flex_1().child(title))
                .child(Button::new(key).label("摆放").on_click(cx.listener(move |this, _, _, cx| {
                    this.enqueue(json!({"op":"ui.device.place", "templateID":id}), cx);
                }))).into_any_element());
        }
        rows.push(div().mt_3().text_color(cx.theme().muted_foreground).child("我的物品").into_any_element());
        match inventory {
            None => rows.push(div().child("等待空间物品载入状态").into_any_element()),
            Some(items) if items.is_empty() => rows.push(div().child("还没有物品，生成的物品会收在这里。").into_any_element()),
            Some(items) => for item in items {
                let Some(id) = item["objectID"].as_str().filter(|id| !id.is_empty()).map(str::to_owned) else { continue };
                let name = item["name"].as_str().unwrap_or(&id).to_owned();
                let held = item["held"].as_bool() == Some(true);
                let placed = item["placed"].as_bool() == Some(true);
                let ready = item["modelReady"].as_bool() == Some(true);
                let state = if held { "手持中" } else if placed { "已摆放" } else { "未摆放" };
                let detail = if held { "让角色放下后，再移动或删除" } else if !ready { "模型正在载入，物品已保留" } else { "选择位置即可摆放；旋转与落地由空间操作处理" };
                let place_id = id.clone();
                let delete_id = id.clone();
                let world_id = self.snapshot["unityWorldAuthority"]["state"]["worldID"].clone();
                let revision = self.snapshot["unityWorldAuthority"]["state"]["layoutRevision"].clone();
                let confirmed = self.confirm_delete.as_deref() == Some(id.as_str());
                rows.push(div().flex().flex_col().gap_2().p_3().rounded_md().bg(cx.theme().group_box)
                    .child(div().flex().gap_2().child(div().flex_1().child(name)).child(state))
                    .child(div().text_sm().text_color(cx.theme().muted_foreground).child(detail))
                    .child(div().flex().gap_2()
                        .child(Button::new(SharedString::from(format!("place-{id}"))).label(if placed { "重新摆放" } else { "摆放" }).disabled(held || !ready)
                            .on_click(cx.listener(move |this, _, _, cx| this.enqueue(json!({"op":"ui.inventory.place", "objectID":place_id}), cx))))
                        .child(Button::new(SharedString::from(format!("delete-{id}"))).label(if confirmed { "确认删除" } else { "删除" })
                            .disabled(held || !world_id.is_string() || !revision.is_u64())
                            .on_click(cx.listener(move |this, _, _, cx| {
                                if this.confirm_delete.as_deref() != Some(delete_id.as_str()) {
                                    this.confirm_delete = Some(delete_id.clone()); cx.notify(); return;
                                }
                                this.confirm_delete = None;
                                this.enqueue(json!({"op":"inventory.delete", "objectID":delete_id,
                                    "worldID":world_id,"layoutRevision":revision}), cx);
                            }))))
                    .into_any_element());
            },
        }
        div().flex().flex_col().size_full().min_h_0().p_4().gap_3().text_color(cx.theme().foreground)
            .child("物品")
            .child(div().id("inventory-scroll").flex_1().min_h_0().overflow_y_scrollbar().flex().flex_col().gap_2().children(rows))
            .child(div().text_sm().child(self.notice.clone()))
    }
}
