use gmgn_gpui_ui::state::TranscriptLine;
use serde_json::Value;

pub struct Event {
    pub id: u64,
    pub kind: String,
    pub text: Option<String>,
    pub message: Option<String>,
}
pub struct Batch {
    pub events: Vec<Event>,
    pub transcript: Vec<TranscriptLine>,
    pub state: Value,
}
pub fn parse(bytes: &[u8]) -> Result<Batch, ()> {
    let value: Value = serde_json::from_slice(bytes).map_err(|_| ())?;
    let state = value.get("state").and_then(Value::as_object).ok_or(())?;
    let mut events = Vec::new();
    for event in value.get("events").and_then(Value::as_array).ok_or(())? {
        let kind = event.get("kind").and_then(Value::as_str).ok_or(())?;
        if !matches!(kind, "accepted" | "reply" | "failure" | "cancelled" | "progress" | "completed") { return Err(()); }
        let text = event.get("text").and_then(Value::as_str).map(str::to_owned);
        if kind == "reply" && text.as_deref().is_none_or(|text| text.trim().is_empty()) { return Err(()); }
        events.push(Event {
            id: event.get("requestID").and_then(Value::as_u64).ok_or(())?,
            kind: kind.into(), text,
            message: event.get("message").and_then(Value::as_str).map(str::to_owned),
        });
    }
    let mut transcript = Vec::new();
    for line in state.get("transcript").and_then(Value::as_array).ok_or(())? {
        let role = line.get("role").and_then(Value::as_str).ok_or(())?;
        // A notice has **no** speaker label; the chat layer recognises it by the
        // empty label plus the warning colour (`chat.rs::speaker_label`,
        // `StageOverlayView.swift:248-263`). Projecting a "系统" label would make
        // the same line render as a labelled person somewhere else.
        let speaker = match role { "user" => "你", "agent" => "居民", "notice" => "", _ => return Err(()) };
        transcript.push(TranscriptLine {
            speaker: speaker.into(),
            text: line.get("text").and_then(Value::as_str).ok_or(())?.into(),
        });
    }
    Ok(Batch { events, transcript, state: value["state"].clone() })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn product_ids_and_actual_transcript_are_preserved() {
        let batch = parse(br#"{"events":[{"kind":"reply","requestID":9007199254740993,"text":"actual"}],"state":{"transcript":[{"role":"agent","text":"actual"}]}}"#).unwrap();
        assert_eq!(batch.events[0].id, 9007199254740993);
        assert_eq!(batch.transcript[0].speaker, "居民");
    }
    #[test]
    fn malformed_state_and_empty_reply_are_not_success() {
        assert!(parse(br#"{"events":[{"kind":"reply","requestID":1,"text":""}],"state":{"transcript":[]}}"#).is_err());
        assert!(parse(br#"{"events":[],"state":{}}"#).is_err());
    }
    #[test]
    fn silent_completion_preserves_real_notice_without_reply() {
        let batch = parse(br#"{"events":[{"kind":"completed","requestID":2}],"state":{"contextID":"world:a","transcript":[{"role":"notice","text":"done"}]}}"#).unwrap();
        assert_eq!(batch.events[0].kind, "completed");
        assert!(batch.events[0].text.is_none());
        // A notice is unlabelled, exactly as `chat.rs::speaker_label` expects.
        assert_eq!(batch.transcript[0].speaker, "");
        assert!(gmgn_gpui_ui::chat::speaker_label(&batch.transcript[0].speaker).notice);
        assert_eq!(gmgn_gpui_ui::chat::plain_text(&batch.transcript), "done");
        assert_eq!(batch.state["contextID"], "world:a");
    }
    #[test]
    fn notice_labels_never_leak_onto_the_other_speakers() {
        let batch = parse(r#"{"events":[],"state":{"transcript":[{"role":"user","text":"问"},{"role":"agent","text":"答"},{"role":"notice","text":"提示"}]}}"#.as_bytes()).unwrap();
        assert_eq!(batch.transcript.iter().map(|line|line.speaker.as_str()).collect::<Vec<_>>(), ["你","居民",""]);
        assert_eq!(gmgn_gpui_ui::chat::plain_text(&batch.transcript), "你：问\n\n居民：答\n\n提示");
    }
}
