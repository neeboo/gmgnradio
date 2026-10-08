//! Connection-scoped speech RPC. Credentials never enter database state.
use crate::{
    daemon::{write, Writer},
    model::Result,
    speech_delivery::{Identity, SpeechDeliveryService},
};
use base64::{engine::general_purpose::STANDARD, Engine};
use gmgn_protocol::failure;
use gmgn_voice_core::{
    providers::{self, AudioEvent, ElevenLabsConfig, FishAudioConfig},
    tts_stream::{TtsStream, TtsStreamEvent},
    BailianConfig,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use tokio::{sync::mpsc, task::JoinHandle};

const PACKET: usize = 32_768;

// Explicit constructor-only provider seam. EOF is represented by channel closure;
// failures remain errors and still pass through the real delivery lifecycle.
#[cfg(test)]
pub(crate) type TestTtsFactory = Arc<dyn Fn(String) -> mpsc::Receiver<Result<Vec<u8>>> + Send + Sync>;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct List {
    provider: String,
    #[serde(default)]
    api_key: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Start {
    #[serde(rename = "sessionID")]
    session_id: String,
    provider: String,
    api_key: String,
    #[serde(rename = "voiceID", default)]
    voice_id: String,
    #[serde(default)]
    text: String,
    #[serde(default)]
    model: Option<String>,
    #[serde(default)]
    delivery: Option<Identity>,
}
enum Command {
    Audio(Vec<u8>),
    Commit,
}
struct Active {
    id: String,
    commands: Option<mpsc::Sender<Command>>,
    task: JoinHandle<()>,
    ready: Arc<AtomicBool>,
}
impl Drop for Active {
    fn drop(&mut self) {
        self.task.abort();
    }
}
#[derive(Default)]
pub struct Connection {
    active: Option<Active>,
    delivery: Option<Arc<SpeechDeliveryService>>,
    #[cfg(test)]
    test_tts_factory: Option<TestTtsFactory>,
}

pub fn capabilities() -> Value {
    let mut value = json!({"version":1,"providers":[
        {"id":"bailian","ttsStreaming":true,"asrStreaming":true,"voiceCatalog":true},
        {"id":"elevenlabs","ttsStreaming":true,"asrStreaming":true,"voiceCatalog":true},
        {"id":"fish","ttsStreaming":true,"asrStreaming":false,"voiceCatalog":true}],
        "voiceCatalogMaxResults":100,
        "asrRequiresReady":true,
        "audio":{"encoding":"pcm16le","channels":1,"asrSampleRate":16000,"ttsSampleRate":24000,"maxPacketBytes":PACKET}});
    for provider in value["providers"].as_array_mut().unwrap() {
        let id = provider["id"].as_str().unwrap().to_owned();
        provider["ttsModels"] = gmgn_voice_core::model_catalog::describe(&id, false);
        provider["asrModels"] = gmgn_voice_core::model_catalog::describe(&id, true);
        provider["defaultTTSModel"] =
            json!(gmgn_voice_core::model_catalog::default_model(&id, false));
        provider["defaultASRModel"] =
            json!(gmgn_voice_core::model_catalog::default_model(&id, true));
    }
    value
}
fn validate(start: &Start, asr: bool) -> Result<()> {
    if start.session_id.is_empty()
        || start.session_id.len() > 200
        || start.api_key.is_empty()
        || start.api_key.len() > 8192
    {
        return Err("invalid_voice_input");
    }
    if !matches!(start.provider.as_str(), "bailian" | "elevenlabs" | "fish") {
        return Err("unsupported_voice_provider");
    }
    if asr && start.provider == "fish" {
        return Err("unsupported_voice_provider");
    }
    if !asr && (start.text.trim().is_empty() || start.text.len() > 16384) {
        return Err("invalid_voice_input");
    }
    if !asr
        && start.provider == "bailian"
        && !gmgn_voice_core::model_catalog::bailian_voice_supported(
            start
                .model
                .as_deref()
                .unwrap_or(gmgn_voice_core::model_catalog::BAILIAN_TTS),
            if start.voice_id.is_empty() {
                "Cherry"
            } else {
                &start.voice_id
            },
        )
    {
        return Err("invalid_voice_input");
    }
    if !asr && start.provider != "bailian" && start.voice_id.is_empty() {
        return Err("invalid_voice_input");
    }
    if start.voice_id.len() > 200
        || start
            .model
            .as_ref()
            .is_some_and(|m| m.is_empty() || m.len() > 128)
    {
        return Err("invalid_voice_input");
    }
    if let Some(model) = start.model.as_deref() {
        if !gmgn_voice_core::model_catalog::supports(&start.provider, asr, model) {
            return Err("invalid_voice_input");
        }
    }
    Ok(())
}
impl Connection {
    #[cfg(test)]
    pub(crate) fn with_test_tts_factory(delivery: Arc<SpeechDeliveryService>, factory: TestTtsFactory) -> Self {
        let mut connection = Self::with_delivery(delivery);
        connection.test_tts_factory = Some(factory);
        connection
    }
    pub fn with_delivery(delivery: Arc<SpeechDeliveryService>) -> Self {
        Self {
            active: None,
            delivery: Some(delivery),
            #[cfg(test)]
            test_tts_factory: None,
        }
    }
    pub async fn handle(
        &mut self,
        method: &str,
        params: Value,
        id: Value,
        writer: &Writer,
    ) -> Result<()> {
        let outcome = self.request(method, params, id.clone(), writer).await;
        if let Err(code) = outcome {
            write(writer, &failure(id, code)).await?;
        }
        Ok(())
    }
    async fn request(
        &mut self,
        method: &str,
        params: Value,
        id: Value,
        writer: &Writer,
    ) -> Result<()> {
        match method {
            "voice_list" => {
                let list: List =
                    serde_json::from_value(params).map_err(|_| "invalid_voice_input")?;
                if !matches!(list.provider.as_str(), "bailian" | "elevenlabs" | "fish") {
                    return Err("unsupported_voice_provider");
                }
                if list.api_key.len() > 8192
                    || (list.provider != "bailian" && list.api_key.trim().is_empty())
                {
                    return Err("invalid_voice_input");
                }
                let result = gmgn_voice_core::voice_catalog::list(&list.provider, &list.api_key)
                    .await
                    .map_err(|_| "voice_provider_error")?;
                write(writer, &json!({"id":id,"result":result})).await
            }
            "voice_capabilities" => write(writer, &json!({"id":id,"result":capabilities()})).await,
            "voice_tts_start" | "voice_asr_start" => {
                let start: Start =
                    serde_json::from_value(params).map_err(|_| "invalid_voice_input")?;
                let asr = method == "voice_asr_start";
                validate(&start, asr)?;
                if asr && start.delivery.is_some() {
                    return Err("invalid_voice_input");
                }
                if self
                    .active
                    .as_ref()
                    .is_some_and(|s| s.id == start.session_id)
                {
                    return Err("invalid_voice_input");
                }
                let delivery = if let Some(identity) = &start.delivery {
                    if self.active.is_some() {
                        return Err("speech_delivery_start_rejected");
                    }
                    let service = self.delivery.clone().ok_or("speech_delivery_unavailable")?;
                    service.bind(identity, &start.text).await?;
                    Some(service)
                } else {
                    None
                };
                let delivery_guard = DeliveryGuard {
                    service: delivery.clone(),
                    identity: start.delivery.clone(),
                };
                // Abort the previous generation before acknowledging this one.
                self.active.take();
                write(
                    writer,
                    &json!({"id":id,"result":{"started":true,"sessionID":start.session_id}}),
                )
                .await?;
                let session_id = start.session_id.clone();
                let writer = writer.clone();
                if asr {
                    let (commands, rx) = mpsc::channel(8);
                    let ready = Arc::new(AtomicBool::new(false));
                    let task_ready = ready.clone();
                    let task = tokio::spawn(async move {
                        run_asr(start, rx, writer, task_ready).await;
                    });
                    self.active = Some(Active {
                        id: session_id,
                        commands: Some(commands),
                        task,
                        ready,
                    });
                } else {
                    #[cfg(test)]
                    let test_tts_factory = self.test_tts_factory.clone();
                    let task = tokio::spawn(async move {
                        let _delivery_guard = delivery_guard;
                        run_tts(start, writer, delivery, #[cfg(test)] test_tts_factory).await;
                    });
                    self.active = Some(Active {
                        id: session_id,
                        commands: None,
                        task,
                        ready: Arc::new(AtomicBool::new(true)),
                    });
                }
                Ok(())
            }
            "voice_cancel" => {
                let sid = params["sessionID"].as_str().ok_or("invalid_voice_input")?;
                if self.active.as_ref().is_some_and(|s| s.id == sid) {
                    self.active.take();
                } else {
                    return Err("voice_session_not_found");
                }
                write(
                    writer,
                    &json!({"id":id,"result":{"cancelled":true,"sessionID":sid}}),
                )
                .await
            }
            "voice_audio_append" | "voice_asr_commit" => {
                let sid = params["sessionID"].as_str().ok_or("invalid_voice_input")?;
                let active = self
                    .active
                    .as_ref()
                    .filter(|s| s.id == sid && !s.task.is_finished())
                    .ok_or("voice_session_not_found")?;
                let sender = active.commands.as_ref().ok_or("invalid_voice_input")?;
                if !active.ready.load(Ordering::Acquire) {
                    return Err("voice_not_ready");
                }
                let command = if method == "voice_audio_append" {
                    let encoded = params["audioBase64"]
                        .as_str()
                        .ok_or("invalid_voice_input")?;
                    if encoded.len() > ((PACKET + 2) / 3) * 4 {
                        return Err("invalid_voice_input");
                    }
                    let pcm = STANDARD
                        .decode(encoded)
                        .map_err(|_| "invalid_voice_input")?;
                    if pcm.is_empty() || pcm.len() > PACKET || pcm.len() % 2 != 0 {
                        return Err("invalid_voice_input");
                    }
                    Command::Audio(pcm)
                } else {
                    Command::Commit
                };
                sender.try_send(command).map_err(|_| "voice_backpressure")?;
                write(
                    writer,
                    &json!({"id":id,"result":{"accepted":true,"sessionID":sid}}),
                )
                .await
            }
            _ => Err("unknown_method"),
        }
    }
}
async fn event(writer: &Writer, sid: &str, fields: Value) -> Result<()> {
    let mut fields = fields.as_object().cloned().ok_or("invalid_voice_input")?;
    fields.insert("sessionID".into(), json!(sid));
    write(writer, &json!({"voice_event":fields})).await
}
async fn audio(writer: &Writer, sid: &str, bytes: &[u8], sample_rate: u32) -> Result<()> {
    for bytes in bytes.chunks(PACKET) {
        event(writer,sid,json!({"type":"audio","audioBase64":STANDARD.encode(bytes),"sampleRate":sample_rate,"channels":1,"encoding":"pcm16le"})).await?;
    }
    Ok(())
}
async fn run_tts(start: Start, writer: Writer, delivery: Option<Arc<SpeechDeliveryService>>, #[cfg(test)] test_tts_factory: Option<TestTtsFactory>) {
    let sid = start.session_id.clone();
    let identity = start.delivery.clone();
    let mut emitter = DeliveryEmitter {
        service: delivery,
        identity,
        trailing: None,
    };
    let result = async {
        #[cfg(test)]
        if let Some(factory) = test_tts_factory {
            let mut source = factory(start.text.clone());
            while let Some(packet) = source.recv().await {
                emitter.audio(&writer, &sid, &packet?, 24_000).await?;
            }
            return emitter.finish(&writer, &sid).await;
        }
        if start.provider == "bailian" {
            let model = start
                .model
                .as_deref()
                .unwrap_or(gmgn_voice_core::model_catalog::BAILIAN_TTS);
            let voice = if start.voice_id.is_empty() {
                "Cherry"
            } else {
                &start.voice_id
            };
            let config = BailianConfig::with_model_voice(start.api_key, model, voice)
                .map_err(|_| "voice_provider_error")?;
            let mut stream = TtsStream::connect(config)
                .await
                .map_err(|_| "voice_provider_error")?;
            stream
                .append_text(start.text)
                .await
                .map_err(|_| "voice_provider_error")?;
            stream
                .finish_input()
                .await
                .map_err(|_| "voice_provider_error")?;
            while let Some(next) = stream.next_event().await {
                match next.map_err(|_| "voice_provider_error")? {
                    TtsStreamEvent::Audio {
                        pcm, sample_rate, ..
                    } => emitter.audio(&writer, &sid, &pcm, sample_rate).await?,
                    TtsStreamEvent::Finished { .. } => return emitter.finish(&writer, &sid).await,
                }
            }
        } else {
            let mut stream = if start.provider == "elevenlabs" {
                let mut config = ElevenLabsConfig::new(start.api_key, start.voice_id)
                    .map_err(|_| "voice_provider_error")?;
                if let Some(model) = start.model {
                    config.model_id = model;
                }
                providers::elevenlabs_tts(&config, &start.text)
                    .await
                    .map_err(|_| "voice_provider_error")?
            } else {
                let mut config = FishAudioConfig::new(start.api_key, start.voice_id)
                    .map_err(|_| "voice_provider_error")?;
                if let Some(model) = start.model {
                    config.model = model;
                }
                providers::fish_audio_tts(&config, &start.text)
                    .await
                    .map_err(|_| "voice_provider_error")?
            };
            while let Some(next) = stream.next().await {
                match next.map_err(|_| "voice_provider_error")? {
                    AudioEvent::Chunk {
                        bytes, sample_rate, ..
                    } => emitter.audio(&writer, &sid, &bytes, sample_rate).await?,
                    AudioEvent::Finished { .. } => return emitter.finish(&writer, &sid).await,
                }
            }
        }
        Err("voice_provider_error")
    }
    .await;
    if let Err(code) = result {
        if let (Some(service), Some(identity)) = (&emitter.service, &emitter.identity) {
            let _ = service
                .request(
                    "speech_delivery_receipt",
                    json!({"identity":identity,"kind":"failed"}),
                )
                .await;
        }
        let _ = event(&writer, &sid, json!({"type":"error","code":code})).await;
    }
}

struct DeliveryEmitter {
    service: Option<Arc<SpeechDeliveryService>>,
    identity: Option<Identity>,
    trailing: Option<u8>,
}
// Connection loss/cancellation must fence pending device output, even while a
// provider is blocked on the Rust PCM window. A terminal delivery is unchanged.
struct DeliveryGuard {
    service: Option<Arc<SpeechDeliveryService>>,
    identity: Option<Identity>,
}
impl Drop for DeliveryGuard {
    fn drop(&mut self) {
        if let (Some(service), Some(identity)) = (self.service.take(), self.identity.take()) {
            if let Ok(runtime) = tokio::runtime::Handle::try_current() {
                runtime.spawn(async move {
                    let _ = service
                        .request(
                            "speech_delivery_receipt",
                            json!({"identity":identity,"kind":"failed"}),
                        )
                        .await;
                });
            }
        }
    }
}
impl DeliveryEmitter {
    async fn audio(&mut self, writer: &Writer, sid: &str, bytes: &[u8], rate: u32) -> Result<()> {
        let (Some(service), Some(id)) = (&self.service, &self.identity) else {
            return audio(writer, sid, bytes, rate).await;
        };
        let mut pcm = Vec::with_capacity(bytes.len() + 1);
        if let Some(byte) = self.trailing.take() {
            pcm.push(byte);
        }
        pcm.extend_from_slice(bytes);
        if pcm.len() % 2 != 0 {
            self.trailing = pcm.pop();
        }
        for packet in pcm.chunks(4096 * 2) {
            let frames = (packet.len() / 2) as u64;
            let sequence = service.packet(id, frames).await?;
            event(writer,sid,json!({"type":"audio","audioBase64":STANDARD.encode(packet),"sampleRate":rate,"channels":1,"encoding":"pcm16le","delivery":id,"sequence":sequence,"frameCount":frames})).await?;
        }
        Ok(())
    }
    async fn finish(&self, writer: &Writer, sid: &str) -> Result<()> {
        let (Some(service), Some(id)) = (&self.service, &self.identity) else {
            return event(writer, sid, json!({"type":"finished"})).await;
        };
        if self.trailing.is_some() {
            return Err("voice_protocol_error");
        }
        service.eof(id).await?;
        event(writer, sid, json!({"type":"input_finished","delivery":id})).await?;
        service.delivered(id).await?;
        event(writer, sid, json!({"type":"delivered","delivery":id})).await
    }
}
async fn run_asr(
    start: Start,
    mut commands: mpsc::Receiver<Command>,
    writer: Writer,
    ready: Arc<AtomicBool>,
) {
    use gmgn_voice_core::asr_stream::{AsrConfig, AsrProvider, AsrStream, AsrStreamEvent};
    let sid = start.session_id.clone();
    let result=async {
        let provider=match start.provider.as_str(){"bailian"=>AsrProvider::Bailian,"elevenlabs"=>AsrProvider::ElevenLabs,_=>return Err("unsupported_voice_provider")};
        let config=AsrConfig::new(provider,start.api_key).map_err(asr_error)?;
        let mut stream=AsrStream::connect(config).await.map_err(asr_error)?;
        ready.store(true,Ordering::Release);
        event(&writer,&sid,json!({"type":"ready"})).await?;
        loop {
            tokio::select! {
                command=commands.recv()=>match command {
                    Some(Command::Audio(pcm))=>stream.append_pcm(pcm).await.map_err(asr_error)?,
                    Some(Command::Commit)=>stream.commit().await.map_err(asr_error)?,
                    None=>return Ok(()),
                },
                next=stream.next_event()=>match next.ok_or("voice_session_not_found")?.map_err(asr_error)? {
                    AsrStreamEvent::Partial{text,..}=>event(&writer,&sid,json!({"type":"partial","text":text})).await?,
                    AsrStreamEvent::Final{text,..}=>{
                        event(&writer,&sid,json!({"type":"final","text":text})).await?;
                        return event(&writer,&sid,json!({"type":"finished"})).await;
                    }
                }
            }
        }
    }.await;
    if let Err(code) = result {
        let _ = event(&writer, &sid, json!({"type":"error","code":code})).await;
    }
}

fn asr_error(error: gmgn_voice_core::asr_stream::AsrStreamError) -> &'static str {
    use gmgn_voice_core::asr_stream::AsrStreamError::*;
    match error {
        MissingKey | InvalidPcm | EmptyInput => "invalid_voice_input",
        Closed => "voice_session_not_found",
        Transport => "voice_transport_error",
        Protocol => "voice_protocol_error",
        Provider => "voice_provider_error",
        Timeout => "voice_timeout",
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    pub(crate) fn active_asr(id: &str) -> (Connection, tokio::sync::oneshot::Receiver<()>) {
        let (sender, receiver) = mpsc::channel(8);
        let (dropped, observed) = tokio::sync::oneshot::channel();
        let task = tokio::spawn(async move {
            let _receiver = receiver;
            let _dropped = dropped;
            std::future::pending::<()>().await;
        });
        (
            Connection {
                delivery: None,
                test_tts_factory: None,
                active: Some(Active {
                    id: id.into(),
                    commands: Some(sender),
                    task,
                    ready: Arc::new(AtomicBool::new(true)),
                }),
            },
            observed,
        )
    }
    #[test]
    fn ready_contract_and_asr_errors_are_explicit_and_sanitized() {
        use gmgn_voice_core::asr_stream::AsrStreamError::*;
        assert_eq!(capabilities()["asrRequiresReady"], true);
        assert_eq!(asr_error(Transport), "voice_transport_error");
        assert_eq!(asr_error(Protocol), "voice_protocol_error");
        assert_eq!(asr_error(Timeout), "voice_timeout");
        assert_eq!(asr_error(Provider), "voice_provider_error");
    }
    #[tokio::test]
    async fn input_is_bounded_cancel_discards_queue_and_stale_ids_are_rejected() {
        let (writer, mut frames) = crate::daemon::response_queue(false);
        let _drain = tokio::spawn(async move {
            while let Some(frame) = frames.recv().await {
                let _ = frame.completion.send(Ok(()));
            }
        });
        let (sender, receiver) = mpsc::channel(8);
        let (dropped, mut observed) = tokio::sync::oneshot::channel::<()>();
        let task = tokio::spawn(async move {
            let _receiver = receiver;
            let _dropped = dropped;
            std::future::pending::<()>().await;
        });
        tokio::task::yield_now().await;
        let mut connection = Connection {
            delivery: None,
            test_tts_factory: None,
            active: Some(Active {
                id: "current".into(),
                commands: Some(sender.clone()),
                task,
                ready: Arc::new(AtomicBool::new(false)),
            }),
        };
        assert_eq!(
            connection
                .request(
                    "voice_audio_append",
                    json!({"sessionID":"current","audioBase64":"AAA="}),
                    json!("before-ready"),
                    &writer
                )
                .await,
            Err("voice_not_ready")
        );
        assert_eq!(
            connection
                .request(
                    "voice_asr_commit",
                    json!({"sessionID":"current"}),
                    json!("before-ready-commit"),
                    &writer
                )
                .await,
            Err("voice_not_ready")
        );
        connection
            .active
            .as_ref()
            .unwrap()
            .ready
            .store(true, Ordering::Release);
        for _ in 0..8 {
            sender.try_send(Command::Audio(vec![0, 0])).unwrap();
        }
        assert_eq!(
            connection
                .request(
                    "voice_audio_append",
                    json!({"sessionID":"current","audioBase64":"AAA="}),
                    json!("1"),
                    &writer
                )
                .await,
            Err("voice_backpressure")
        );
        assert_eq!(
            connection
                .request(
                    "voice_asr_commit",
                    json!({"sessionID":"old"}),
                    json!("2"),
                    &writer
                )
                .await,
            Err("voice_session_not_found")
        );
        assert_eq!(
            connection
                .request(
                    "voice_audio_append",
                    json!({"sessionID":"current","audioBase64":STANDARD.encode(vec![0;PACKET+2])}),
                    json!("3"),
                    &writer
                )
                .await,
            Err("invalid_voice_input")
        );
        connection
            .request(
                "voice_cancel",
                json!({"sessionID":"current"}),
                json!("4"),
                &writer,
            )
            .await
            .unwrap();
        assert!(
            tokio::time::timeout(std::time::Duration::from_secs(1), &mut observed)
                .await
                .unwrap()
                .is_err()
        );
        assert!(sender.is_closed());
        assert!(connection.active.is_none());
    }
}
