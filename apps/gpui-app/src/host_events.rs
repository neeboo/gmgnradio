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
        let speaker = match role { "user" => "你", "agent" => "居民", "notice" => "系统", _ => return Err(()) };
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
        assert_eq!(batch.transcript[0].speaker, "系统");
        assert_eq!(batch.state["contextID"], "world:a");
    }
}
