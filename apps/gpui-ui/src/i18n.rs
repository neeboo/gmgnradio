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

#[cfg(test)]
mod tests {
    use super::{NAVIGATION, UiLocale, language_command, settings_navigation_label};
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
}
