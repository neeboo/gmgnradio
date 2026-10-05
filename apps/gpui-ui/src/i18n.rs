//! Shared settings navigation copy. Locale never changes route/capability keys.
use serde_json::Value;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum UiLocale { #[default] ZhCn, En, Ja }
impl UiLocale {
    pub const ALL: [Self; 3] = [Self::ZhCn, Self::En, Self::Ja];
    pub fn parse(value: &str) -> Option<Self> {
        match value { "zh-CN" => Some(Self::ZhCn), "en" => Some(Self::En), "ja" => Some(Self::Ja), _ => None }
    }
    pub fn id(self) -> &'static str { match self { Self::ZhCn => "zh-CN", Self::En => "en", Self::Ja => "ja" } }
    pub fn name(self) -> &'static str { match self { Self::ZhCn => "简体中文", Self::En => "English", Self::Ja => "日本語" } }
    pub fn from_settings(snapshot: &Value) -> Self {
        snapshot["locale"].as_str().and_then(Self::parse).unwrap_or_default()
    }
    pub fn language_label(self) -> &'static str { match self { Self::ZhCn => "语言", Self::En => "Language", Self::Ja => "言語" } }
}

// Chinese keys are existing internal routes, separate from translated labels.
const NAVIGATION: &[(&str, &str, &str)] = &[
    ("播放器", "Player", "プレーヤー"),
    ("空间", "Spaces", "空間"),
    ("角色", "Character", "キャラクター"),
    ("音乐", "Music", "音楽"),
    ("对话与语音", "Chat & Voice", "チャットと音声"),
    ("应用", "App", "アプリ"),
    ("歌词", "Lyrics", "歌詞"),
    ("视觉效果", "Visual Effects", "ビジュアルエフェクト"),
    ("视频", "Video", "動画"),
    ("我的空间", "My Spaces", "マイ空間"),
    ("生成服务", "Generation Services", "生成サービス"),
    ("角色管理", "Characters", "キャラクター管理"),
    ("动作管理", "Motions", "モーション管理"),
    ("自主行动", "Autonomy", "自律行動"),
    ("音乐账号与歌单同步", "Music Accounts & Playlist Sync", "音楽アカウントとプレイリスト同期"),
    ("Agent 连接", "Agent Connection", "エージェント接続"),
    ("语音播放", "Voice Playback", "音声再生"),
    ("按住说话", "Push to Talk", "押して話す"),
    ("快捷键", "Keyboard Shortcuts", "キーボードショートカット"),
];

pub fn settings_navigation_label<'a>(locale: UiLocale, route: &'a str) -> &'a str {
    let Some((_, english, japanese)) = NAVIGATION.iter().find(|(key, _, _)| *key == route) else { return route };
    match locale { UiLocale::ZhCn => route, UiLocale::En => english, UiLocale::Ja => japanese }
}
pub fn language_command(locale: UiLocale) -> Value {
    serde_json::json!({"op":"app.language","locale":locale.id()})
}

// Product-owned UI copy only. Provider/model/voice names and service errors
// remain original data and are never passed through this catalog.
const SETTINGS_COPY: &[(&str, &str, &str)] = &[
    ("音乐服务", "Music services", "音楽サービス"),
    ("居民人格", "Resident persona", "住人の人格"),
    ("角色人格与偏好", "Character persona & preferences", "キャラクターの人格と好み"),
    ("回复语音", "Reply voice", "返信音声"),
    ("按住说话", "Push to Talk", "押して話す"),
    ("保存", "Save", "保存"),
    ("服务", "Provider", "サービス"),
    ("声音", "Voice", "音声"),
    ("模型", "Model", "モデル"),
    ("新的 TTS API Key", "New TTS API Key", "新しい TTS API Key"),
    ("新的 ASR API Key", "New ASR API Key", "新しい ASR API Key"),
    ("自定义音色 ID", "Custom voice ID", "カスタム音声 ID"),
    ("自定义 Reference ID", "Custom Reference ID", "カスタム Reference ID"),
    ("自定义 Voice ID", "Custom Voice ID", "カスタム Voice ID"),
    ("刷新声音", "Refresh voices", "音声を更新"),
    ("停止试听", "Stop preview", "試聴を停止"),
    ("试听声音", "Preview voice", "音声を試聴"),
    ("保存配置", "Save configuration", "設定を保存"),
    ("已连接", "Connected", "接続済み"),
    ("正在连接", "Connecting", "接続中"),
    ("正在连接…", "Connecting…", "接続中…"),
    ("登录已过期", "Login expired", "ログイン期限切れ"),
    ("未授权", "Not authorized", "未承認"),
    ("当前不可用", "Unavailable", "利用不可"),
    ("未连接", "Disconnected", "未接続"),
    ("正在同步…", "Syncing…", "同期中…"),
    ("同步", "Sync", "同期"),
    ("断开", "Disconnect", "切断"),
    ("连接", "Connect", "接続"),
    ("（默认）", " (default)", "（デフォルト）"),
    ("（未安装）", " (not installed)", "（未インストール）"),
    ("旧模型不受支持，请重新选择", "Unsupported saved model; select again", "保存済みモデルは未対応です。再選択してください"),
    ("当前声音", "Current voice", "現在の音声"),
    ("正在加载模型选项", "Loading models", "モデルを読み込み中"),
    ("请选择", "Select", "選択してください"),
    ("正在读取原应用配置与 Rust 服务能力…", "Loading settings and Rust service capabilities…", "設定と Rust サービス機能を読み込み中…"),
    ("用自然语言告诉角色怎么策划和主持。", "Describe how the character should plan and host in natural language.", "企画や司会の方針を自然な言葉で伝えてください。"),
    ("只影响居民，和上面的角色偏好分开。人格只改语气和关注点，不改变它能做什么。", "Only affects the resident, separately from character preferences. Persona changes tone and interests, not capabilities.", "住人だけに適用され、キャラクターの好みとは別です。人格は口調や関心を変えますが、機能は変えません。"),
    ("填写该服务已有的音色 ID，无需重新上传；账号、模型及服务区域须与创建音色时一致。", "Use an existing voice ID without uploading again. Account, model and service region must match those used to create the voice.", "既存の音声 ID を入力してください。再アップロードは不要です。アカウント、モデル、リージョンは音声作成時と一致させてください。"),
    ("百炼复刻音色需要在模型列表选择对应的 VC Realtime 快照；创建音色时的 target_model 必须匹配。", "For Bailian cloned voices, select the matching VC Realtime snapshot. It must match the target_model used to create the voice.", "Bailian の複製音声は対応する VC Realtime スナップショットを選択してください。音声作成時の target_model と一致させてください。"),
    ("原配置模型不在当前支持列表中，请选择后保存；不会自动改用其他模型。", "The saved model is not supported. Select a model and save; no automatic fallback is applied.", "保存済みモデルは未対応です。モデルを選択して保存してください。別モデルへの自動切替は行いません。"),
    ("已配置 Unity 会话凭据", "Unity session credentials configured", "Unity セッションの認証情報を設定済み"),
    ("沿用原应用已配置凭据", "Using existing app credentials", "既存アプリの認証情報を使用中"),
    ("该服务尚未配置凭据，请填写后保存", "Credentials are not configured. Enter them and save.", "認証情報が未設定です。入力して保存してください。"),
    ("传输：本机 TCP → Rust → 服务商；录放音留在系统设备层。", "Transport: local TCP → Rust → provider. Recording and playback use system devices.", "通信経路：ローカル TCP → Rust → サービス。録音と再生はシステムのデバイスを使用します。"),
    ("Rust 流式合成，开麦停止旧朗读；失败保留文字，不自动切换服务。", "Rust streams synthesis. Opening the microphone stops prior speech. Failures preserve text without switching providers.", "Rust が音声をストリーミング合成します。マイク開始時に前の読み上げを停止します。失敗時も文字は残り、サービスは自動切替しません。"),
    ("当前可管理语音配置和试听；Unity 按住说话及回复朗读尚未接入。", "Voice configuration and preview are available. Unity push-to-talk and reply reading are not connected yet.", "音声設定と試聴を利用できます。Unity の押して話す機能と返信読み上げはまだ未接続です。"),
    ("在空间或 Live Cam 按住麦克风录音，松开后将完整转写交给当前 Agent。没有双向实时通话。", "Hold the microphone in Spaces or Live Cam to record. Releasing sends the complete transcript to the current Agent. This is not a two-way live call.", "空間または Live Cam でマイクを押して録音します。離すと全文の文字起こしを現在の Agent に送信します。双方向のリアルタイム通話ではありません。"),
    ("账号操作只影响当前 Unity 会话；同步完成后，音乐库会显示最新歌单。", "Account changes affect only this Unity session. After sync, the library shows the latest playlists.", "アカウント操作は現在の Unity セッションだけに適用されます。同期後、ライブラリに最新のプレイリストが表示されます。"),
    ("角色可以使用的账号", "Accounts available to the character", "キャラクターが利用できるアカウント"),
    ("文字和语音共用同一会话，回答后再朗读", "Text and voice share one conversation; replies can be read aloud", "文字と音声は同じ会話を使用し、返信を読み上げます"),
    ("居民人格保存后下一轮聊天生效。按住说话与自主行动尚未接入 Unity。", "Saved persona applies to the next chat turn. Push-to-talk and autonomous actions are not connected to Unity yet.", "保存した人格は次の会話から適用されます。押して話す機能と自律行動はまだ Unity に未接続です。"),
    ("可保存语音识别配置；Unity 按住说话尚未接入。", "Speech recognition settings can be saved. Unity push-to-talk is not connected yet.", "音声認識設定を保存できます。Unity の押して話す機能はまだ未接続です。"),
    ("已保存 Unity 语音配置。", "Unity voice settings saved.", "Unity の音声設定を保存しました。"),
    ("请先加载模型列表并选择有效模型。", "Load the model list and select a supported model first.", "モデル一覧を読み込み、対応モデルを選択してください。"),
    ("模型列表暂时无法加载，已有配置已保留。", "Unable to load models. Existing settings are preserved.", "モデル一覧を読み込めません。既存設定は保持されています。"),
    ("声音列表已加载。", "Voice list loaded.", "音声一覧を読み込みました。"),
    ("声音列表暂时无法加载，请检查服务配置后刷新。", "Unable to load voices. Check provider settings and refresh.", "音声一覧を読み込めません。サービス設定を確認して更新してください。"),
    ("已断开 Unity 会话中的音乐账号。", "Music account disconnected in this Unity session.", "この Unity セッションの音楽アカウントを切断しました。"),
    ("请在官方页面完成登录。", "Complete login on the official page.", "公式ページでログインを完了してください。"),
    ("正在同步歌单…", "Syncing playlists…", "プレイリストを同期中…"),
    ("已取消登录。", "Login cancelled.", "ログインをキャンセルしました。"),
    ("音乐账号操作未完成，请检查登录状态与网络后重试。", "Music account operation failed. Check login and network, then retry.", "音楽アカウントの操作を完了できませんでした。ログイン状態とネットワークを確認して再試行してください。"),
];

pub fn settings_copy<'a>(locale: UiLocale, source: &'a str) -> &'a str {
    let Some((_, en, ja)) = SETTINGS_COPY.iter().find(|(key, _, _)| *key == source) else { return source };
    match locale { UiLocale::ZhCn => source, UiLocale::En => en, UiLocale::Ja => ja }
}

pub fn settings_notice(locale: UiLocale, source: &str) -> String {
    // This is a known Host-owned status template, not a service error or name.
    if let Some(count) = source.strip_prefix("已同步 ").and_then(|s| s.strip_suffix(" 个歌单。"))
        .filter(|s| !s.is_empty() && s.chars().all(|c| c.is_ascii_digit())) {
        return match locale {
            UiLocale::ZhCn => source.to_owned(),
            UiLocale::En => format!("Synced {count} playlists."),
            UiLocale::Ja => format!("{count} 件のプレイリストを同期しました。"),
        };
    }
    settings_copy(locale, source).to_owned()
}

#[cfg(test)]
mod tests {
    use super::{NAVIGATION, SETTINGS_COPY, UiLocale, language_command, settings_navigation_label, settings_copy, settings_notice};
    use serde_json::json;
    #[test]
    fn all_categories_and_secondary_pages_have_three_languages() {
        assert_eq!(NAVIGATION.len(), 6 + 13);
        let mut keys = std::collections::HashSet::new();
        for (route, english, japanese) in NAVIGATION {
            assert!(keys.insert(route));
            assert!(!english.is_empty() && !japanese.is_empty());
            assert_eq!(settings_navigation_label(UiLocale::ZhCn, route), *route);
            assert_eq!(settings_navigation_label(UiLocale::En, route), *english);
            assert_eq!(settings_navigation_label(UiLocale::Ja, route), *japanese);
        }
    }
    #[test]
    fn host_locale_changes_copy_without_changing_routes() {
        for id in ["zh-CN", "en", "ja"] {
            let locale = UiLocale::from_settings(&json!({"locale":id}));
            assert_eq!(locale.id(), id);
            assert_eq!(settings_navigation_label(locale, "stage.player.lyrics"), "stage.player.lyrics");
            assert_eq!(language_command(locale), json!({"op":"app.language","locale":id}));
        }
        assert_eq!(UiLocale::from_settings(&json!({"locale":"unknown"})), UiLocale::ZhCn);
        assert_eq!(UiLocale::from_settings(&json!({})), UiLocale::ZhCn);
        assert_eq!(settings_navigation_label(UiLocale::En, "歌词"), "Lyrics");
        assert_eq!(settings_navigation_label(UiLocale::Ja, "歌词"), "歌詞");
    }
    #[test]
    fn available_settings_body_copy_has_complete_three_language_catalog() {
        let mut keys = std::collections::HashSet::new();
        for (zh, en, ja) in SETTINGS_COPY {
            assert!(keys.insert(zh), "duplicate copy: {zh}");
            assert!(!en.is_empty() && !ja.is_empty());
            assert_eq!(settings_copy(UiLocale::ZhCn, zh), *zh);
            assert_eq!(settings_copy(UiLocale::En, zh), *en);
            assert_eq!(settings_copy(UiLocale::Ja, zh), *ja);
        }
        // Core controls, help and Host status for each available page.
        for key in ["音乐服务", "连接", "断开", "同步", "账号操作只影响当前 Unity 会话；同步完成后，音乐库会显示最新歌单。",
            "回复语音", "刷新声音", "试听声音", "停止试听", "自定义音色 ID", "保存配置", "服务", "模型", "声音",
            "按住说话", "新的 ASR API Key", "可保存语音识别配置；Unity 按住说话尚未接入。",
            "居民人格", "保存", "只影响居民，和上面的角色偏好分开。人格只改语气和关注点，不改变它能做什么。"] {
            assert!(keys.contains(&key), "missing available-page copy: {key}");
        }
    }
    #[test]
    fn statuses_translate_but_external_identifiers_and_errors_remain_original() {
        for locale in UiLocale::ALL {
            for raw in ["fish", "bailian", "qwen3-tts-vc-realtime", "voiceID_中文_123", "HTTP 401: provider error", "已同步 invalid 个歌单。"] {
                assert_eq!(settings_copy(locale, raw), raw);
                assert_eq!(settings_notice(locale, raw), raw);
            }
        }
        assert_eq!(settings_notice(UiLocale::En, "已同步 12 个歌单。"), "Synced 12 playlists.");
        assert_eq!(settings_notice(UiLocale::Ja, "已同步 12 个歌单。"), "12 件のプレイリストを同期しました。");
        assert_eq!(settings_notice(UiLocale::ZhCn, "已同步 12 个歌单。"), "已同步 12 个歌单。");
    }
}
