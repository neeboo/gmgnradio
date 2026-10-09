//! RPC wiring regression for the music-account and generation-configuration
//! method families.
//!
//! These nine methods are sent by real clients (`RustMusicAccountClient.swift`,
//! `RustGenerationConfigurationClient.swift`) but used to fall through the
//! `Service::request` table to `unknown_method`, because `music_account.rs` and
//! `generation_configuration.rs` were never declared in `main.rs` and therefore
//! were not compiled into the daemon at all.
//!
//! Every test here drives the real dispatch entry point (`Service::request`) on a
//! real `Database`, so removing either the `mod` declaration or a dispatch arm
//! turns them red. `unknown_method` must keep meaning "this method does not
//! exist": a typo must not look like a working endpoint.

use crate::daemon::Service;
use crate::model::Result;
use crate::store::Database;
use serde_json::{json, Value};
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;

struct Fixture {
    service: Service,
    base: PathBuf,
}

impl Fixture {
    /// The daemon root is `base/TaskService`; `base` is where the generation
    /// configuration authority puts its `secrets/` directory, exactly like a real
    /// install (`.../Application Support/gmgn/TaskService` next to `.../secrets`).
    fn new() -> Self {
        let base = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("gmgn-rpc-wiring-{}", uuid::Uuid::new_v4()));
        let root = base.join("TaskService");
        std::fs::create_dir_all(&root).unwrap();
        let service = Service::new(Database::open(root, None).unwrap()).unwrap();
        Self { service, base }
    }

    async fn call(&self, method: &str, params: Value) -> Result<Value> {
        self.service.request(method, params).await
    }

    /// Stages a token leaf the way the client does: a private file named after
    /// the reference it then passes as `tokenRef`.
    fn stage_token(&self, token: &str) -> String {
        let directory = self.base.join("secrets");
        std::fs::create_dir_all(&directory).unwrap();
        let reference = uuid::Uuid::new_v4().to_string();
        let leaf = directory.join(format!("generation-{reference}.secret"));
        std::fs::write(&leaf, token).unwrap();
        // unix: `generation_configuration::read_leaf` refuses a leaf that group
        // or other can touch, so the staged leaf has to be 0600 like the client's
        // own. Windows has no mode bits — there the reader relies on the
        // protected DACL plus the reparse-point/link-count checks in
        // `files::read`, and the ACL a plain `fs::write` leaves is accepted.
        #[cfg(unix)]
        std::fs::set_permissions(&leaf, std::fs::Permissions::from_mode(0o600)).unwrap();
        reference
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.base);
    }
}

/// A misspelled method is still a misspelled method.
#[tokio::test]
async fn unknown_methods_still_return_unknown_method() {
    let fixture = Fixture::new();
    for method in [
        "music_account_not_a_method",
        "generation_configuration_not_a_method",
    ] {
        assert_eq!(
            fixture.call(method, json!({})).await,
            Err("unknown_method"),
            "`{method}` 不该被静默当成已知方法"
        );
    }
}

/// The two storage steps behind `music_account_connect` are functions, and the
/// account snapshot is `music_account_session_state`. None of the three names may
/// come back as an RPC method: `connect` owns the provider round-trip, so a
/// published `begin`/`finish` would let any local caller attest its own
/// validation result.
#[tokio::test]
async fn music_account_internal_steps_are_not_rpc_methods() {
    let fixture = Fixture::new();
    for method in [
        "music_account_read",
        "music_account_begin",
        "music_account_finish",
    ] {
        assert_eq!(
            fixture.call(method, json!({"providerID": "netease"})).await,
            Err("unknown_method"),
            "`{method}` 是 connect 的内部步骤，不该在 daemon 上可调用"
        );
    }
}

#[tokio::test]
async fn music_account_session_state_reaches_the_implementation() {
    let fixture = Fixture::new();
    let reply = fixture
        .call("music_account_session_state", json!({"providerID": "netease"}))
        .await
        .unwrap();
    assert_eq!(
        reply,
        json!({"providerID": "netease", "revision": 0, "state": "disconnected",
               "overridden": false, "disabled": false})
    );
}

#[tokio::test]
async fn music_account_session_reaches_the_implementation() {
    let fixture = Fixture::new();
    let reply = fixture
        .call("music_account_session", json!({"providerID": "netease"}))
        .await
        .unwrap();
    assert_eq!(reply["useLegacy"], true);
    assert_eq!(reply["session"], Value::Null);
    assert_eq!(reply["account"]["state"], "disconnected");
}

#[tokio::test]
async fn music_account_import_reaches_the_implementation() {
    let fixture = Fixture::new();
    let reply = fixture
        .call(
            "music_account_import",
            json!({"providerID": "netease", "session": null, "disabled": false}),
        )
        .await
        .unwrap();
    assert_eq!(reply["revision"], 1);
    assert_eq!(reply["state"], "disconnected");
    assert_eq!(reply["overridden"], true);
}

/// `music_account_connect` is the only async, provider-facing arm. A cookie that
/// cannot be normalized is rejected by the module's own validator **before** any
/// network call, so this pins the wiring without touching a provider.
#[tokio::test]
async fn music_account_connect_reaches_the_implementation() {
    let fixture = Fixture::new();
    assert_eq!(
        fixture
            .call(
                "music_account_connect",
                json!({"providerID": "netease", "cookie": "MUSIC_U=",
                       "hostSessionID": "host", "requestID": uuid::Uuid::new_v4().to_string()})
            )
            .await,
        Err("music_account_missing_required_cookie")
    );
    assert_eq!(
        fixture
            .call(
                "music_account_connect",
                json!({"providerID": "spotify", "cookie": "MUSIC_U=real",
                       "hostSessionID": "host", "requestID": uuid::Uuid::new_v4().to_string()})
            )
            .await,
        Err("music_account_unsupported_provider")
    );
}

#[tokio::test]
async fn music_account_disconnect_reaches_the_implementation() {
    let fixture = Fixture::new();
    let reply = fixture
        .call(
            "music_account_disconnect",
            json!({"providerID": "netease", "hostSessionID": "host",
                   "requestID": "disconnect-1", "expectedRevision": 0}),
        )
        .await
        .unwrap();
    assert_eq!(reply["revision"], 1);
    assert_eq!(reply["state"], "disconnected");
    assert_eq!(reply["disabled"], true);
}

#[tokio::test]
async fn music_account_apple_authorization_reaches_the_implementation() {
    let fixture = Fixture::new();
    let reply = fixture
        .call(
            "music_account_apple_authorization",
            json!({"providerID": "apple-music", "hostSessionID": "host",
                   "requestID": "apple-1", "expectedRevision": 0,
                   "authorization": "denied", "hasPlayableSubscription": null,
                   "reconnect": false}),
        )
        .await
        .unwrap();
    assert_eq!(reply["revision"], 1);
    assert_eq!(reply["state"], "denied");
}

#[tokio::test]
async fn generation_configuration_read_reaches_the_implementation() {
    let fixture = Fixture::new();
    let reply = fixture
        .call("generation_configuration_read", json!({}))
        .await
        .unwrap();
    assert_eq!(
        reply,
        json!({"revision": 0, "endpoint": null, "secretRef": null,
               "imported": false, "configured": false})
    );
}

#[tokio::test]
async fn generation_configuration_import_reaches_the_implementation() {
    let fixture = Fixture::new();
    let reply = fixture
        .call(
            "generation_configuration_import",
            json!({"requestID": uuid::Uuid::new_v4().to_string(), "expectedRevision": 0,
                   "currentExists": false}),
        )
        .await
        .unwrap();
    assert_eq!(reply["revision"], 1);
    assert_eq!(reply["imported"], true);
    assert_eq!(reply["configured"], false);
}

#[tokio::test]
async fn generation_configuration_save_reaches_the_implementation() {
    let fixture = Fixture::new();
    let reference = fixture.stage_token("synthetic-dispatched-token");
    let saved = fixture
        .call(
            "generation_configuration_save",
            json!({"requestID": uuid::Uuid::new_v4().to_string(), "expectedRevision": 0,
                   "endpoint": "https://EXAMPLE.test:443/", "tokenRef": reference}),
        )
        .await
        .unwrap();
    assert_eq!(saved["endpoint"], "https://example.test");
    assert_eq!(saved["configured"], true);
    assert_eq!(saved["imported"], true);
}
