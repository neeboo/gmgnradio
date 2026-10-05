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
    ("Unity 设置连接不可用，请从 Unity 重新打开。", "Unity settings connection unavailable. Reopen settings from Unity.", "Unity 設定接続が利用できません。Unity から設定を開き直してください。"),
    ("请从 Unity 播放器打开设置。", "Open settings from the Unity player.", "Unity プレーヤーから設定を開いてください。"),
    ("版本", "Version", "バージョン"),
    ("秒", "s", "秒"),
    ("等待渲染", "Waiting for rendering", "描画待ち"),
    ("当前可管理语音配置、试听与回复朗读；Unity 按住说话尚未接入。", "Voice configuration, preview and reply reading are connected. Unity push-to-talk is not connected yet.", "音声設定、試聴、返信読み上げは接続済みです。Unity の押して話す機能はまだ未接続です。"),
    ("内置动态", "Built-in motion", "組み込みモーション"),
    ("内置", "Built-in", "組み込み"),
    ("更多操作", "More actions", "その他の操作"),
    ("公开空间 · 无需生成", "Public space · No generation needed", "公開空間 · 生成不要"),
    ("公开空间", "Public spaces", "公開空間"),
    ("生成场景", "Generated scenes", "生成シーン"),
    ("人物位置", "Character position", "キャラクターの位置"),
    ("人物位置会按当前空间保存", "Character position is saved per space", "キャラクターの位置は空間ごとに保存されます"),
    ("重置", "Reset", "リセット"),
    ("W/S 沿视线前后移动，A/D 左右移动", "W/S moves forward/back along the view; A/D moves sideways", "W/S で視線方向に前後移動、A/D で左右移動"),
    ("镜头复位", "Reset camera", "カメラをリセット"),
    ("尚未选择角色", "No character selected", "キャラクター未選択"),
    ("刷新", "Refresh", "更新"),
    ("选择已安装动作；自然待机可结束当前表演。", "Choose an installed motion; natural idle ends the current performance.", "インストール済みモーションを選択。自然な待機で現在の演技を終了します。"),
    ("暂无可用动作，请在资产管理中安装。", "No motions available. Install them in asset management.", "利用できるモーションがありません。アセット管理でインストールしてください。"),
    ("管理角色与动作…", "Manage characters and motions…", "キャラクターとモーションを管理…"),
    ("活动来自当前空间，角色会走到对应位置再开始。", "Activities belong to this space. The character walks to the location before starting.", "活動は現在の空間に属します。キャラクターは指定位置に移動してから開始します。"),
    ("这个空间还没有配置生活活动。", "No activities configured for this space.", "この空間には活動が設定されていません。"),
    ("停止活动", "Stop activity", "活動を停止"),
    ("空间载入完成后可选择活动。", "Choose an activity after the space loads.", "空間の読み込み後に活動を選択できます。"),
    ("进入空间后可选择生活活动。", "Enter a space to choose activities.", "空間に入ると活動を選択できます。"),
    ("导入 MP4", "Import MP4", "MP4 をインポート"),
    ("关闭", "Close", "閉じる"),
    ("视频亮度", "Video brightness", "動画の明るさ"),
    ("未加载视频", "No video loaded", "動画未読み込み"),
    ("已加载", "Loaded", "読み込み済み"),
    ("段", "clips", "本"),
    ("取消加载", "Unload", "読み込み解除"),
    ("加载", "Load", "読み込み"),
    ("解除当前歌曲绑定", "Unbind from current track", "現在の曲との関連付けを解除"),
    ("绑定到当前歌曲", "Bind to current track", "現在の曲に関連付け"),
    ("移出素材库", "Remove from library", "ライブラリから削除"),
    ("设置 · Unity 播放器", "Settings · Unity Player", "設定 · Unity プレーヤー"),
    ("字幕、3D 点阵与视频效果", "Lyrics, 3D particles and video effects", "歌詞、3D パーティクルと動画効果"),
    ("字幕特效", "Lyric effects", "歌詞エフェクト"),
    ("3D 点阵", "3D particles", "3D パーティクル"),
    ("MV 场景", "Music video scene", "ミュージックビデオのシーン"),
    ("颗粒大小", "Particle size", "粒子サイズ"),
    ("这些效果用于播放器画面，切回播放器后可查看", "These effects apply to the player view. Switch back to see them.", "効果はプレーヤー画面に適用されます。プレーヤーに戻ると確認できます。"),
    ("已选择", "Selected", "選択済み"),
    ("角色内核", "Character engine", "キャラクターエンジン"),
    ("聊天模型", "Chat model", "チャットモデル"),
    ("自主行动", "Autonomy", "自律行動"),
    ("gmgn 角色", "gmgn character", "gmgn キャラクター"),
    ("策划引擎未登录", "Planning engine signed out", "企画エンジンは未ログインです"),
    ("退出登录", "Sign out", "ログアウト"),
    ("登录", "Sign in", "ログイン"),
    ("Codex 提供策划和推理能力；它与下面的声音共同属于同一个角色。", "Codex provides planning and reasoning, paired with the voice below as one character.", "Codex は企画と推論を担当し、下の音声と同じキャラクターを構成します。"),
    ("允许角色自动接管", "Allow character control", "キャラクターの自動操作を許可"),
    ("可以自主切歌、暂停、继续、重排节目和调整视觉。", "May change tracks, pause, resume, reorder programs and adjust visuals.", "曲の変更、一時停止、再開、番組の並べ替え、ビジュアルの調整を行えます。"),
    ("策划模型", "Planning model", "企画モデル"),
    ("空间和 Live Cam 共用这里选定的 Agent；文字和语音转写进入同一个会话。", "Spaces and Live Cam share this Agent. Text and voice transcripts enter the same conversation.", "空間と Live Cam はこの Agent を共有します。文字と音声の文字起こしは同じ会話に入ります。"),
    ("允许居民自主安排活动", "Allow resident autonomous activities", "住人の自律的な活動を許可"),
    ("打开后，居民会自己观察和行动，会消耗模型额度。设为 0 就不再新起一轮，要先停下请按停止。", "When enabled, the resident observes and acts independently, using model quota. Set 0 to prevent new turns; use Stop to halt the current turn.", "有効にすると住人は自ら観察して行動し、モデルの利用枠を消費します。0 で新しい思考を止め、現在の思考は停止ボタンで止めます。"),
    ("每小时后台思考预算", "Background thinking budget per hour", "1 時間あたりのバックグラウンド思考枠"),
    ("按最近一小时算，默认 6。这只数后台思考的次数，不等于请求次数或费用。", "Counts background thinking turns over the last hour; default 6. This is not a request count or cost estimate.", "直近 1 時間のバックグラウンド思考回数です。既定値は 6。リクエスト数や料金とは異なります。"),
    ("自动朗读 Agent 回复", "Read Agent replies aloud", "Agent の返信を自動読み上げ"),
    ("0 轮（不再新起）", "0 turns (no new turns)", "0 回（新規思考なし）"),
    ("轮", "turns", "回"),
    ("支持 HTTPS 地址指向 VRM、ZIP 或 gmgnpet 模型包。", "Use an HTTPS URL to a VRM, ZIP or gmgnpet model package.", "VRM、ZIP、gmgnpet モデルパッケージの HTTPS URL を指定してください。"),
    ("从链接导入角色", "Import character from URL", "URL からキャラクターをインポート"),
    ("从链接导入角色…", "Import character from URL…", "URL からキャラクターをインポート…"),
    ("取消", "Cancel", "キャンセル"),
    ("正在下载…", "Downloading…", "ダウンロード中…"),
    ("下载并安装", "Download and install", "ダウンロードしてインストール"),
    ("使用 Codex 默认模型", "Use the default Codex model", "Codex の既定モデルを使用"),
    ("新的 Marble API Key", "New Marble API Key", "新しい Marble API Key"),
    ("生成服务地址", "Generation service URL", "生成サービスの URL"),
    ("生成服务密钥", "Generation service key", "生成サービスのキー"),
    ("粘贴新的 API Key 可覆盖现有配置", "Paste a new API Key to replace the saved one", "新しい API Key を貼り付けて置き換え"),
    ("粘贴 API Key", "Paste API Key", "API Key を貼り付け"),
    ("填写新密钥可替换；留空保留现有密钥", "Enter a new key to replace it; leave blank to keep the saved key", "新しいキーで置き換え。空欄なら既存キーを保持"),
    ("角色", "Character", "キャラクター"),
    ("呼吸球样式", "Breathing orb style", "呼吸オーブのスタイル"),
    ("动作", "Motions", "モーション"),
    ("动作库", "Motion library", "モーションライブラリ"),
    ("默认空间", "Default space", "既定の空間"),
    ("当前角色", "Current character", "現在のキャラクター"),
    ("呼吸球", "Breathing orb", "呼吸オーブ"),
    ("当前引擎", "Current engine", "現在のエンジン"),
    ("选择", "Select", "選択"),
    ("移除角色", "Remove character", "キャラクターを削除"),
    ("未命名角色", "Untitled character", "名前のないキャラクター"),
    ("全部", "All", "すべて"),
    ("这个分类下暂无当前角色可用的动作。", "No motions for this character in this category.", "このカテゴリには現在のキャラクターで使えるモーションがありません。"),
    ("当前动作", "Current motion", "現在のモーション"),
    ("移除动作", "Remove motion", "モーションを削除"),
    ("未命名动作", "Untitled motion", "名前のないモーション"),
    ("两种角色各有自己的动作列表，切换时会分别记住你选的。", "Each character type has its own motion list and remembers its selection.", "キャラクターの種類ごとにモーション一覧があり、それぞれの選択を保持します。"),
    ("获取动作列表", "Fetch motions", "モーション一覧を取得"),
    ("已安装", "Installed", "インストール済み"),
    ("安装", "Install", "インストール"),
    ("流光颜色", "Glow color", "発光色"),
    ("流光强度", "Glow intensity", "発光の強さ"),
    ("启动时进入", "Open on startup", "起動時に開く"),
    ("修改后下次启动生效。", "Changes apply on the next launch.", "変更は次回起動時に適用されます。"),
    ("Marble 空间", "Marble spaces", "Marble の空間"),
    ("用于同步和生成可探索的 3D 空间", "Sync and generate explorable 3D spaces", "探索できる 3D 空間の同期と生成"),
    ("已配置", "Configured", "設定済み"),
    ("未配置", "Not configured", "未設定"),
    ("只保存在本机，不使用钥匙串。", "Stored locally without Keychain.", "ローカル保存のみ。キーチェーンは使用しません。"),
    ("清除", "Clear", "消去"),
    ("保存 Key", "Save Key", "キーを保存"),
    ("许愿机", "Wish generator", "願いの生成サービス"),
    ("检测中…", "Checking…", "確認中…"),
    ("检测连接", "Check connection", "接続を確認"),
    ("地址和密钥只存在这台电脑上，保存后不会立刻开始生成。", "URL and key are stored only on this computer. Saving does not start generation.", "URL とキーはこのコンピュータだけに保存されます。保存しても生成は始まりません。"),
    ("功能", "Action", "機能"),
    ("应用内", "In app", "アプリ内"),
    ("全局", "Global", "グローバル"),
    ("请按快捷键", "Press a shortcut", "ショートカットを押してください"),
    ("未设置", "Not set", "未設定"),
    ("启用全局快捷键", "Enable global shortcuts", "グローバルショートカットを有効化"),
    ("gmgn radio 在后台时也能响应。", "Works while gmgn radio is in the background.", "gmgn radio がバックグラウンドでも反応します。"),
    ("使用系统媒体快捷键", "Use system media keys", "システムのメディアキーを使用"),
    ("响应键盘上的播放、暂停、上一首和下一首。", "Respond to keyboard play, pause, previous and next keys.", "キーボードの再生、一時停止、前の曲、次の曲キーに反応します。"),
    ("恢复默认", "Restore defaults", "既定値に戻す"),
    ("选择角色的形象与表演动作", "Choose character appearance and motions", "キャラクターの外見とモーションを選択"),
    ("选择默认空间，并管理空间生成服务", "Choose the default space and manage generation services", "既定の空間を選び、空間生成サービスを管理"),
    ("点击按键框，再按下新的组合键", "Click a key field, then press a new shortcut", "キー欄をクリックして新しい組み合わせを押してください"),
    ("选择生活空间，调整空间功能", "Choose a living space and adjust its features", "生活空間を選び、機能を調整"),
    ("选择与控制空间生活活动", "Choose and control activities in the space", "空間での活動を選択・操作"),
    ("正在读取 Unity 设置能力…", "Loading Unity settings capabilities…", "Unity の設定機能を読み込み中…"),
    ("导入", "Import", "インポート"),
    ("角色模型…", "Character model…", "キャラクターモデル…"),
    ("动作文件…", "Motion file…", "モーションファイル…"),
    ("此设置尚未接入 Unity；角色、快捷键、视频与空间活动仍由原应用管理。", "This setting is not connected to Unity yet. Characters, shortcuts, video and space activities are still managed by the original app.", "この設定はまだ Unity に未接続です。キャラクター、ショートカット、動画、空間の活動は元のアプリで管理します。"),
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

const PLAYER_CHOICES: &[(&str, &str, &str, &str, &str)] = &[
    ("lyrics", "automatic", "自动", "Automatic", "自動"),
    ("lyrics", "luminous", "流光", "Luminous", "流光"),
    ("lyrics", "mindscape", "心象", "Mindscape", "心象"),
    ("lyrics", "cloud_steps", "云阶", "Cloud Steps", "雲の階段"),
    ("lyrics", "article", "浮名", "Editorial", "浮名"),
    ("lyrics", "chorus_chat", "群唱", "Chorus", "合唱"),
    ("lyrics", "confession", "倾诉", "Confession", "語り"),
    ("lyrics", "claddagh", "回环", "Orbit", "巡り"),
    ("lyrics", "monet_poster", "莫奈", "Monet", "モネ"),
    ("lyrics", "pendulum", "时计", "Pendulum", "時計"),
    ("lyrics", "diorama", "镜台", "Diorama", "鏡台"),
    ("lyrics", "folding_verse", "折章", "Folding Verse", "折り詩"),
    ("clouds", "automatic", "自动", "Automatic", "自動"),
    ("clouds", "flowingCanvas", "流幕", "Flowing Canvas", "流れる幕"),
    ("clouds", "orbitalShell", "星球", "Orbital Shell", "惑星"),
    ("clouds", "openRibbon", "光带", "Light Ribbon", "光の帯"),
    ("clouds", "vinylRecord", "封面", "Album Cover", "ジャケット"),
    ("clouds", "galaxyField", "星河", "Galaxy", "銀河"),
    ("clouds", "tunnel", "滚筒", "Tunnel", "トンネル"),
    ("clouds", "void", "留白", "Void", "余白"),
    ("videoModes", "once", "单次", "Once", "1 回"),
    ("videoModes", "loop", "循环", "Loop", "ループ"),
    ("videoModes", "randomSequence", "随机拼接", "Random Sequence", "ランダム連結"),
];

pub fn player_choice_label<'a>(locale: UiLocale, kind: &str, id: &str, original: &'a str) -> &'a str {
    let Some((_, _, zh, en, ja)) = PLAYER_CHOICES.iter().find(|(k, i, _, _, _)| *k == kind && *i == id) else { return original };
    // Only known built-in entries are translated, never arbitrary user names.
    match locale { UiLocale::ZhCn => zh, UiLocale::En => en, UiLocale::Ja => ja }
}

#[cfg(test)]
mod tests {
    use super::{NAVIGATION, SETTINGS_COPY, PLAYER_CHOICES, UiLocale, language_command, settings_navigation_label, settings_copy, settings_notice, player_choice_label};
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
    #[test]
    fn player_catalogs_translate_all_builtin_modes_without_touching_custom_names() {
        assert_eq!(PLAYER_CHOICES.iter().filter(|(kind, _, _, _, _)| *kind == "lyrics").count(), 12);
        assert_eq!(PLAYER_CHOICES.iter().filter(|(kind, _, _, _, _)| *kind == "clouds").count(), 8);
        let mut keys = std::collections::HashSet::new();
        for (kind, id, zh, en, ja) in PLAYER_CHOICES {
            assert!(keys.insert((kind, id)));
            assert!(!en.is_empty() && !ja.is_empty());
            assert_eq!(player_choice_label(UiLocale::ZhCn, kind, id, zh), *zh);
            assert_eq!(player_choice_label(UiLocale::En, kind, id, zh), *en);
            assert_eq!(player_choice_label(UiLocale::Ja, kind, id, zh), *ja);
        }
        for locale in UiLocale::ALL {
            assert_eq!(player_choice_label(locale, "lyrics", "user-custom", "我的主题"), "我的主题");
            assert_eq!(settings_navigation_label(locale, "stage.player.lyrics"), "stage.player.lyrics");
        }
        assert_eq!(settings_copy(UiLocale::En, "设置 · Unity 播放器"), "Settings · Unity Player");
        assert_eq!(settings_copy(UiLocale::Ja, "字幕特效"), "歌詞エフェクト");
        assert_ne!(settings_copy(UiLocale::En, "字幕、3D 点阵与视频效果"), "字幕、3D 点阵与视频效果");
    }
}
