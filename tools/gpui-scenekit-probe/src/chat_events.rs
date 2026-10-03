use gmgn_gpui_ui::state::TranscriptLine;
use serde_json::Value;

pub struct Event {
    pub sequence: u64,
    pub request_id: u64,
    pub kind: String,
    pub text: Option<String>,
    pub message: Option<String>,
}
pub struct Batch {
    pub events: Vec<Event>,
    pub transcript: Vec<TranscriptLine>,
}
pub fn parse(bytes: &[u8]) -> Result<Batch, ()> {
    let value: Value = serde_json::from_slice(bytes).map_err(|_| ())?;
    let state = value.get("state").and_then(Value::as_object).ok_or(())?;
    if state.get("deliveryMode").and_then(Value::as_str) != Some("final-response") {
        return Err(());
    }
    let mut events = Vec::new();
    for event in value.get("events").and_then(Value::as_array).ok_or(())? {
        let kind = event.get("kind").and_then(Value::as_str).ok_or(())?;
        if !matches!(
            kind,
            "accepted" | "reply" | "failure" | "cancelled" | "progress"
        ) {
            return Err(());
        }
        let text = event.get("text").and_then(Value::as_str).map(str::to_owned);
        if kind == "reply" && text.as_deref().is_none_or(|text| text.trim().is_empty()) {
            return Err(());
        }
        events.push(Event {
            sequence: event.get("sequence").and_then(Value::as_u64).ok_or(())?,
            request_id: event.get("requestID").and_then(Value::as_u64).ok_or(())?,
            kind: kind.to_owned(),
            text,
            message: event
                .get("message")
                .and_then(Value::as_str)
                .map(str::to_owned),
        });
    }
    let mut transcript = Vec::new();
    for line in state
        .get("transcript")
        .and_then(Value::as_array)
        .ok_or(())?
    {
        let role = line.get("role").and_then(Value::as_str).ok_or(())?;
        let speaker = match role {
            "user" => "你",
            "agent" => "居民",
            _ => return Err(()),
        };
        transcript.push(TranscriptLine {
            speaker: speaker.into(),
            text: line.get("text").and_then(Value::as_str).ok_or(())?.into(),
        });
    }
    Ok(Batch { events, transcript })
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ids_are_exact_u64_and_real_final_text_is_retained() {
        let batch = parse(br#"{"events":[{"sequence":1,"kind":"accepted","requestID":9007199254740993},{"sequence":2,"kind":"reply","requestID":9007199254740993,"text":"actual final response"}],"state":{"deliveryMode":"final-response","transcript":[]}}"#).unwrap();
        assert_eq!(batch.events[1].request_id, 9007199254740993);
        assert_eq!(
            batch.events[1].text.as_deref(),
            Some("actual final response")
        );
    }
    #[test]
    fn missing_reply_is_not_success() {
        assert!(parse(br#"{"events":[{"sequence":1,"kind":"reply","requestID":1}],"state":{"deliveryMode":"final-response","transcript":[]}}"#).is_err());
    }
    #[test]
    fn malformed_or_unexpected_delivery_is_rejected() {
        assert!(parse(b"invalid json").is_err());
        assert!(
            parse(br#"{"events":[],"state":{"deliveryMode":"fake-stream","transcript":[]}}"#)
                .is_err()
        );
    }
    #[test]
    fn empty_batch_and_real_transcript_are_supported() {
        let batch = parse(br#"{"events":[],"state":{"deliveryMode":"final-response","transcript":[{"role":"user","text":"user message"},{"role":"agent","text":"final reply"}]}}"#).unwrap();
        assert!(batch.events.is_empty());
        assert_eq!(batch.transcript[1].speaker, "居民");
    }
}
