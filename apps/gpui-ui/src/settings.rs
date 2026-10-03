//! Product settings controls. Catalogs and all side effects come from ProductHost.
use gpui_kit::*;
use gpui_kit::component::{button::*, input::*, menu::*, switch::Switch, *};
use serde_json::{Value, json};

pub struct AgentSettingsPane {
    snapshot: Value,
    draft: Value,
    inputs: Vec<Entity<InputState>>,
    personas: Vec<Entity<TextareaState>>,
    commands: Vec<Value>,
    initialized: bool,
}
impl AgentSettingsPane {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let inputs = ["居民人格", "DJ 人格与偏好", "策划模型（留空使用原默认）", "自定义音色 ID"]
            .into_iter().enumerate().map(|(i,label)| cx.new(|cx| {
                let input=InputState::new(window,cx).placeholder(label);
                let _=i;
                input
            })).collect();
        let personas=["居民人格","DJ 人格与偏好"].map(|label|cx.new(|cx|TextareaState::new(window,cx).placeholder(label).rows(4))).to_vec();
        Self { snapshot: Value::Null, draft: Value::Null, inputs, personas, commands: vec![json!({"op":"settings.load"})], initialized: false }
    }
    pub fn take_commands(&mut self) -> Vec<Value> { std::mem::take(&mut self.commands) }
    pub fn update_snapshot(&mut self, snapshot: Value, window: &mut Window, cx: &mut Context<Self>) {
        if snapshot.is_null() || self.snapshot == snapshot { return; }
        if !self.initialized {
            self.draft = snapshot.clone();
            for (i, section, field) in [(0,"agent","residentPersona"),(1,"agent","hostPrompt"),(2,"agent","planningModel"),(3,"tts","voiceID")] {
                let text = snapshot[section][field].as_str().unwrap_or("").to_owned();
                if i<2 { self.personas[i].update(cx,|input,cx|input.set_value(text,window,cx)); }
                else { self.inputs[i].update(cx, |input,cx| input.set_value(text,window,cx)); }
            }
            self.initialized = true;
        } else if self.snapshot["tts"]["providerID"] != snapshot["tts"]["providerID"] {
            self.draft["tts"] = snapshot["tts"].clone();
            let voice = snapshot["tts"]["voiceID"].as_str().unwrap_or("").to_owned();
            self.inputs[3].update(cx, |input,cx| input.set_value(voice,window,cx));
        } else if self.draft["tts"]["modelID"].as_str().unwrap_or("").is_empty() {
            self.draft["tts"]["modelID"] = snapshot["tts"]["modelID"].clone();
        }
        self.snapshot = snapshot;
        cx.notify();
    }
    fn selection(&mut self, section: &str, field: &str, value: Value, window: &mut Window, cx: &mut Context<Self>) {
        self.draft[section][field] = value.clone();
        if section == "tts" && field == "providerID" {
            self.commands.push(json!({"op":"tts.provider","id":value}));
        }
        if section == "tts" && field == "voiceID" {
            self.inputs[3].update(cx, |input,cx| input.set_value(value.as_str().unwrap_or(""),window,cx));
        }
        cx.notify();
    }
    fn options(&self, section: &str, key: &str) -> Vec<(Value,String)> {
        self.snapshot[section][key].as_array().into_iter().flatten().filter_map(|v| {
            if let Some(n) = v.as_u64() { Some((json!(n), format!("{n} 轮"))) }
            else { let mut name=v.get("name")?.as_str()?.to_owned();
                if v.get("installed").and_then(Value::as_bool)==Some(false) {name.push_str("（未安装）");}
                Some((v.get("id")?.clone(),name)) }
        }).collect()
    }
    fn dropdown(&self, id: &'static str, label: &'static str, section: &'static str, field: &'static str, items: Vec<(Value,String)>, cx: &mut Context<Self>) -> AnyElement {
        let value = self.draft[section][field].clone();
        let selected = items.iter().find(|(id,_)| *id == value).map(|(_,name)|name.clone())
            .unwrap_or_else(||value.as_str().filter(|s|!s.is_empty()).unwrap_or("请选择").into());
        let weak = cx.entity().downgrade();
        div().flex().flex_col().gap_1().child(label).child(Button::new(id).label(selected).dropdown_caret(true)
            .disabled(items.is_empty()).dropdown_menu(move |mut menu,_,_| {
                for (value,name) in &items {
                    let weak = weak.clone(); let value = value.clone();
                    menu = menu.item(PopupMenuItem::new(name.clone()).on_click(move |_,window,cx| {
                        _ = weak.update(cx, |this,cx| this.selection(section,field,value.clone(),window,cx));
                    }));
                }
                menu
            })).into_any_element()
    }
    fn toggle(&self, id: &'static str, label: &'static str, field: &'static str, cx: &mut Context<Self>) -> AnyElement {
        Switch::new(id).label(label).checked(self.draft["agent"][field].as_bool().unwrap_or(false))
            .on_change(cx.listener(move |this,value:&bool,_,cx| { this.draft["agent"][field]=json!(*value);cx.notify(); })).into_any_element()
    }
    fn agent_save(&mut self,cx:&mut Context<Self>) {
        let mut agent = self.draft["agent"].clone();
        for (i,field) in [(0,"residentPersona"),(1,"hostPrompt"),(2,"planningModel")] {
            agent[field]=json!(if i<2 {self.personas[i].read(cx).value().to_string()} else {self.inputs[i].read(cx).value().to_string()});
        }
        agent["op"]=json!("agent.save");self.commands.push(agent);
    }
    fn tts_action(&mut self,op:&str,cx:&mut Context<Self>) {
        let mut tts=self.draft["tts"].clone();
        tts["voiceID"]=json!(self.inputs[3].read(cx).value().to_string());
        tts["op"]=json!(op);self.commands.push(tts);
    }
}
impl Render for AgentSettingsPane {
    fn render(&mut self,_:&mut Window,cx:&mut Context<Self>)->impl IntoElement {
        let theme=cx.theme();
        let valid_model=self.snapshot["tts"]["models"].as_array().is_some_and(|models|models.iter().any(|model|model["id"]==self.draft["tts"]["modelID"]));
        let mut form=div().id("agent-settings-form").size_full().overflow_y_scroll().p_4().flex().flex_col().gap_3()
            .bg(theme.tokens.background).text_color(theme.foreground).child(div().text_lg().child("Agent 与回复语音"));
        if !self.initialized { return form.child("正在读取原应用配置与 Rust 服务能力…").into_any_element(); }
        form=form.child(self.dropdown("backend","聊天后端","agent","backendID",self.options("agent","backends"),cx))
            .child("居民人格").child(div().h(px(128.)).min_h(px(128.)).flex_shrink_0()
                .child(Textarea::new(&self.personas[0]).h(px(128.)).aria_label("居民人格").accessibility_id("resident-persona")))
            .child("DJ 人格与偏好").child(div().h(px(128.)).min_h(px(128.)).flex_shrink_0()
                .child(Textarea::new(&self.personas[1]).h(px(128.)).aria_label("DJ 人格与偏好").accessibility_id("dj-host-prompt")))
            .child("策划模型").child(Input::new(&self.inputs[2]))
            .child(self.toggle("takeover","允许 DJ 自动接管","takeoverEnabled",cx))
            .child(self.toggle("autonomy","允许居民自主安排活动","autonomyEnabled",cx))
            .child(self.dropdown("budget","每小时后台思考预算","agent","backgroundTurnsPerHour",self.options("agent","budgetOptions"),cx))
            .child(Button::new("save-agent").label("保存 Agent 配置").on_click(cx.listener(|this,_,_,cx|this.agent_save(cx))))
            .child(self.toggle("auto-speak","自动朗读 Agent 回复","autoSpeak",cx))
            .child(div().text_lg().child("回复语音 · Rust 流式合成"))
            .child(self.dropdown("tts-provider","服务","tts","providerID",self.options("tts","providers"),cx))
            .child(self.dropdown("tts-model","模型","tts","modelID",self.options("tts","models"),cx))
            .child(self.dropdown("tts-voice","声音","tts","voiceID",self.options("tts","voices"),cx))
            .child("自定义音色 ID（使用该服务已有音色，无需重新上传）").child(Input::new(&self.inputs[3]))
            .child(if self.snapshot["tts"]["credentialConfigured"].as_bool()==Some(true) { "沿用原应用已配置凭据" } else { "该服务尚未配置凭据；可使用原设置页配置" })
            .child(div().flex().flex_wrap().gap_2()
                .child(Button::new("refresh-voices").label("刷新声音").on_click(cx.listener(|this,_,_,cx|this.tts_action("tts.refresh",cx))))
                .child(Button::new("save-tts").label("保存语音配置").disabled(!valid_model).on_click(cx.listener(|this,_,_,cx|this.tts_action("tts.save",cx))))
                .child(Button::new("preview-tts").label("试听声音").disabled(!valid_model).on_click(cx.listener(|this,_,_,cx|this.tts_action("tts.preview",cx))))
                .child(Button::new("stop-tts").label("停止试听").on_click(cx.listener(|this,_,_,cx|this.tts_action("tts.stop",cx)))));
        if let Some(notice)=self.snapshot["agent"]["notice"].as_str() { form=form.child(notice.to_owned()); }
        if let Some(notice)=self.snapshot["tts"]["notice"].as_str() { form=form.child(notice.to_owned()); }
        form.into_any_element()
    }
}
