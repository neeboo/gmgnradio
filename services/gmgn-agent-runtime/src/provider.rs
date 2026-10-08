//! Explicit, memory-only configuration for aimux's real streaming providers.
//! No environment credential lookup, backend fallback, or independent loop.
use aimux_core::{
    options::CallOptions,
    result::{GenerateResult, StreamResult},
    stream_part::StreamPart,
    AiMuxError, LanguageModel,
};
use aimux_providers::ProviderOptions;
use async_trait::async_trait;
use futures::StreamExt;
use std::{fmt, sync::Arc, time::Duration};

pub const SUPPORTED_BACKENDS: &[&str] = &["openai", "deepseek", "alibaba"];

/// Not serializable. Debug intentionally omits endpoint, model and API key.
pub struct ProviderConfig {
    backend: String,
    endpoint: String,
    model: String,
    api_key: String,
    pub request_timeout: Duration,
    pub max_stream_bytes: usize,
    /// Trusted host model capability declaration; never inferred by backend.
    pub image_input: bool,
}
impl fmt::Debug for ProviderConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ProviderConfig")
            .field("configuration", &"redacted")
            .finish()
    }
}
impl ProviderConfig {
    /// Endpoint is an API base URL (for example https://host/v1), not the
    /// /chat/completions URL. A nonempty explicit key is always required,
    /// including local providers; no existing environment keys are read.
    pub fn new(backend: String, endpoint: String, model: String, api_key: String) -> Self {
        Self {
            backend,
            endpoint,
            model,
            api_key,
            request_timeout: Duration::from_secs(120),
            max_stream_bytes: 4 * 1024 * 1024,
            image_input: false,
        }
    }
    pub fn validate(&self) -> Result<(), ProviderConfigError> {
        if !SUPPORTED_BACKENDS.contains(&self.backend.as_str()) {
            return Err(ProviderConfigError::UnsupportedBackend);
        }
        let url =
            url::Url::parse(&self.endpoint).map_err(|_| ProviderConfigError::InvalidEndpoint)?;
        let local = match url.host() {
            Some(url::Host::Domain("localhost")) => true,
            Some(url::Host::Ipv4(ip)) => ip.is_loopback(),
            Some(url::Host::Ipv6(ip)) => ip.is_loopback(),
            _ => false,
        };
        if !(url.scheme() == "https" || url.scheme() == "http" && local)
            || url.host().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
            || url
                .path()
                .trim_end_matches('/')
                .ends_with("/chat/completions")
        {
            return Err(ProviderConfigError::InvalidEndpoint);
        }
        if self.model.trim().is_empty() || self.model.chars().any(char::is_control) {
            return Err(ProviderConfigError::InvalidModel);
        }
        if self.api_key.trim().is_empty() || self.api_key.chars().any(char::is_control) {
            return Err(ProviderConfigError::InvalidApiKey);
        }
        if self.request_timeout.is_zero()
            || self.request_timeout > Duration::from_secs(3600)
            || self.max_stream_bytes == 0
        {
            return Err(ProviderConfigError::InvalidLimit);
        }
        Ok(())
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProviderConfigError {
    UnsupportedBackend,
    InvalidEndpoint,
    InvalidModel,
    InvalidApiKey,
    InvalidLimit,
    FactoryFailed,
}
impl fmt::Display for ProviderConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{}",
            match self {
                Self::UnsupportedBackend => "unsupported_provider_backend",
                Self::InvalidEndpoint => "invalid_provider_endpoint",
                Self::InvalidModel => "invalid_provider_model",
                Self::InvalidApiKey => "invalid_provider_api_key",
                Self::InvalidLimit => "invalid_provider_limit",
                Self::FactoryFailed => "provider_factory_failed",
            }
        )
    }
}
impl std::error::Error for ProviderConfigError {}

/// Constructs only; never makes a model request. Unsupported names fail closed.
pub fn build_provider(
    config: ProviderConfig,
) -> Result<Arc<dyn LanguageModel>, ProviderConfigError> {
    config.validate()?;
    // aimux's registry excludes the native "openai" name. Use its native
    // constructor explicitly; registry-backed names use the registry factory.
    let inner: Arc<dyn LanguageModel> = if config.backend == "openai" {
        let mut native =
            aimux_providers::OpenAIConfig::new(config.api_key).with_base_url(config.endpoint);
        native.retry_config.max_retries = 0;
        Arc::new(aimux_providers::OpenAIProvider::new(native).model(&config.model))
    } else {
        let options = ProviderOptions {
            base_url: Some(config.endpoint),
            max_retries: Some(0),
            ..Default::default()
        };
        Arc::from(
            aimux_providers::provider(
                &config.backend,
                Some(config.api_key),
                &config.model,
                Some(options),
            )
            .map_err(|_| ProviderConfigError::FactoryFailed)?,
        )
    };
    Ok(Arc::new(SafeProvider {
        inner,
        timeout: config.request_timeout,
        limit: config.max_stream_bytes,
        image_input: config.image_input,
    }))
}
struct SafeProvider {
    inner: Arc<dyn LanguageModel>,
    timeout: Duration,
    limit: usize,
    image_input: bool,
}
fn safe_error(code: &str) -> AiMuxError {
    AiMuxError::Other(code.into())
}
#[async_trait]
impl LanguageModel for SafeProvider {
    fn provider(&self) -> &str {
        self.inner.provider()
    }
    fn model_id(&self) -> &str {
        self.inner.model_id()
    }
    async fn do_generate(&self, options: &CallOptions) -> Result<GenerateResult, AiMuxError> {
        if !self.image_input
            && options.prompt.iter().any(|m| {
                m.content
                    .iter()
                    .any(|p| matches!(p, aimux_core::content::ContentPart::Image { .. }))
            })
        {
            return Err(safe_error("provider_image_input_unsupported"));
        }
        let mut result = tokio::time::timeout(self.timeout, self.inner.do_generate(options))
            .await
            .map_err(|_| safe_error("provider_timeout"))?
            .map_err(|_| safe_error("provider_request_failed"))?;
        result.request_body = None;
        result.response_headers = None;
        Ok(result)
    }
    async fn do_stream(&self, options: &CallOptions) -> Result<StreamResult, AiMuxError> {
        if !self.image_input
            && options.prompt.iter().any(|m| {
                m.content
                    .iter()
                    .any(|p| matches!(p, aimux_core::content::ContentPart::Image { .. }))
            })
        {
            return Err(safe_error("provider_image_input_unsupported"));
        }
        let deadline = tokio::time::Instant::now() + self.timeout;
        let mut result = tokio::time::timeout_at(deadline, self.inner.do_stream(options))
            .await
            .map_err(|_| safe_error("provider_timeout"))?
            .map_err(|_| safe_error("provider_request_failed"))?;
        let limit = self.limit;
        result.stream = Box::pin(futures::stream::unfold(
            (Some(result.stream), 0usize),
            move |(stream, used)| async move {
                let mut stream = stream?;
                let part = match tokio::time::timeout_at(deadline, stream.next()).await {
                    Err(_) => return Some((Err(safe_error("provider_timeout")), (None, used))),
                    Ok(None) => return None,
                    Ok(Some(Err(_))) | Ok(Some(Ok(StreamPart::Error { .. }))) => {
                        return Some((Err(safe_error("provider_stream_failed")), (None, used)))
                    }
                    Ok(Some(Ok(part))) => part,
                };
                // aimux 0.3 synthesizes Stop/raw=None on transport EOF. It cannot
                // stand in for a server completion signal, especially after tools.
                if matches!(&part, StreamPart::Finish { finish_reason, .. } if !matches!(finish_reason.raw.as_deref(), Some("stop" | "tool_calls")))
                {
                    return Some((Err(safe_error("provider_incomplete_finish")), (None, used)));
                }
                let bytes = serde_json::to_vec(&part)
                    .map(|b| b.len())
                    .unwrap_or(limit.saturating_add(1));
                if bytes > limit.saturating_sub(used) {
                    return Some((Err(safe_error("provider_stream_limit")), (None, used)));
                }
                Some((Ok(part), (Some(stream), used + bytes)))
            },
        ));
        result.request_body = None;
        result.response_headers = None;
        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn config() -> ProviderConfig {
        ProviderConfig::new(
            "deepseek".into(),
            "https://provider.example/v1".into(),
            "deepseek-chat".into(),
            "fake-sensitive-key".into(),
        )
    }
    #[test]
    fn debug_and_errors_never_include_configuration() {
        let mut c = config();
        assert!(!format!("{c:?}").contains("fake-sensitive-key"));
        assert!(!format!("{c:?}").contains("provider.example"));
        c.endpoint = "https://user:fake-sensitive-key@provider.example/v1".into();
        assert_eq!(
            c.validate().unwrap_err().to_string(),
            "invalid_provider_endpoint"
        );
    }
    #[test]
    fn unsupported_and_insecure_configuration_fail_closed() {
        let mut c = config();
        c.backend = "anthropic".into();
        assert_eq!(c.validate(), Err(ProviderConfigError::UnsupportedBackend));
        c.backend = "deepseek".into();
        c.endpoint = "http://provider.example/v1".into();
        assert_eq!(c.validate(), Err(ProviderConfigError::InvalidEndpoint));
        c.endpoint = "http://127.0.0.1:9999/v1".into();
        assert!(c.validate().is_ok());
        c.api_key.clear();
        assert_eq!(c.validate(), Err(ProviderConfigError::InvalidApiKey));
    }
    #[test]
    fn actual_factory_constructs_supported_models_without_requests() {
        for backend in SUPPORTED_BACKENDS {
            let mut c = config();
            c.backend = (*backend).into();
            let model = build_provider(c).unwrap();
            assert_eq!(model.provider(), *backend);
            assert_eq!(model.model_id(), "deepseek-chat");
            let snapshot = format!("{:?}", model.config_snapshot());
            assert!(!snapshot.contains("fake-sensitive-key"));
            assert!(!snapshot.contains("provider.example"));
        }
    }
}
