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
    ("生活", "Daily life", "日常"),
    ("工作", "Work", "仕事"),
    ("运动", "Exercise", "運動"),
    ("戏剧", "Drama", "演技"),
    ("自然待机", "Natural idle", "自然な待機"),
    ("活动", "Activities", "活動"),
    ("角色与动作", "Character and motions", "キャラクターとモーション"),
    ("Agent 与语音", "Agent and voice", "エージェントと音声"),
    ("导入视频", "Import video", "動画を読み込む"),
    ("选择并播放", "Select and play", "選択して再生"),
    ("播放", "Play", "再生"),
    ("暂停", "Pause", "一時停止"),
    ("停止", "Stop", "停止"),
    ("单次", "Once", "1 回"),
    ("循环", "Loop", "ループ"),
    ("随机拼接", "Random sequence", "ランダム連結"),
    ("使用中", "Active", "使用中"),
    ("该页面尚未完成 Unity 运行时接线。", "This page is not connected to the Unity runtime yet.", "このページはまだ Unity ランタイムに未接続です。"),
    ("Codex 账号用于选择 Codex 后端；当前聊天后端以下方选择为准。", "The Codex account is used by the Codex backend. The selection below determines the current chat backend.", "Codex アカウントは Codex バックエンドで使用します。現在のチャットは下の選択に従います。"),
    ("播放 / 暂停", "Play / Pause", "再生 / 一時停止"),
    ("上一首", "Previous track", "前の曲"),
    ("下一首", "Next track", "次の曲"),
    ("音量增加", "Volume up", "音量を上げる"),
    ("音量降低", "Volume down", "音量を下げる"),
    ("开麦 / 关麦", "Microphone on / off", "マイク オン / オフ"),
    ("显示 / 隐藏舞台", "Show / hide stage", "ステージを表示 / 非表示"),
    ("切换歌词视觉", "Cycle lyric style", "歌詞スタイルを切り替え"),
    ("全局快捷键至少需要一个修饰键。", "Global shortcuts require at least one modifier key.", "グローバルショートカットには修飾キーが必要です。"),
    ("Codex CLI 不可用", "Codex CLI unavailable", "Codex CLI が利用できません"),
    ("Codex 未登录", "Codex signed out", "Codex は未ログインです"),
    ("账号操作失败，请检查 Codex CLI 后重试。", "Account operation failed. Check Codex CLI and retry.", "アカウント操作に失敗しました。Codex CLI を確認して再試行してください。"),
    ("角色或动作加载失败，已恢复原选择。", "Character or motion failed to load. Previous selection restored.", "キャラクターまたはモーションの読み込みに失敗しました。以前の選択に戻しました。"),
    ("Unity 设置连接不可用，请从 Unity 重新打开。", "Unity settings connection unavailable. Reopen settings from Unity.", "Unity 設定接続が利用できません。Unity から設定を開き直してください。"),
    ("请从 Unity 播放器打开设置。", "Open settings from the Unity player.", "Unity プレーヤーから設定を開いてください。"),
    ("版本", "Version", "バージョン"),
    ("秒", "s", "秒"),
    ("等待渲染", "Waiting for rendering", "描画待ち"),
    ("按住麦克风录音，松开后将完整转写交给当前角色。没有双向实时通话。", "Hold the microphone to record. Release to send the complete transcript to the current character. This is not a two-way live call.", "マイクを押して録音します。離すと全文の文字起こしを現在のキャラクターに送信します。双方向のリアルタイム通話ではありません。"),
    ("内置动态", "Built-in motion", "組み込みモーション"),
    ("内置", "Built-in", "組み込み"),
    ("更多操作", "More actions", "その他の操作"),
    ("公开空间 · 无需生成", "Public space · No generation needed", "公開空間 · 生成不要"),
    ("公开空间", "Public spaces", "公開空間"),
    ("生成场景", "Generated scenes", "生成シーン"),
    ("人物位置", "Character position", "キャラクターの位置"),
    ("移动到坐标", "Move to coordinates", "指定座標へ移動"),
    ("坐标以米计；人物会沿可通行地面移动，Y 必须贴合目标地面。", "Coordinates are in meters. The character follows walkable ground; Y must match the destination ground.", "座標はメートル単位です。キャラクターは通行可能な地面を移動します。Y は目的地の地面と一致させてください。"),
    ("请输入有效的 X、Y、Z 坐标。", "Enter valid X, Y and Z coordinates.", "有効な X、Y、Z 座標を入力してください。"),
    ("人物正在移动，等待空间与画面确认。", "Moving the character; waiting for world and rendered-frame confirmation.", "キャラクターを移動中です。空間と描画の確認を待っています。"),
    ("人物位置已更新。", "Character position updated.", "キャラクターの位置を更新しました。"),
    ("人物坐标请求无效。", "Invalid character-coordinate request.", "キャラクター座標の要求が無効です。"),
    ("空间状态已变化，请重新读取坐标。", "World state changed. Reload the coordinates.", "空間の状態が変わりました。座標を再取得してください。"),
    ("空间布局已变化，请重新读取坐标。", "World layout changed. Reload the coordinates.", "空間の配置が変わりました。座標を再取得してください。"),
    ("人物位置尚未完成空间持久确认。", "The character position has not been confirmed in durable world state.", "キャラクター位置の永続的な空間状態での確認が完了していません。"),
    ("人物移动或画面确认超时，请重试。", "Character movement or rendered-frame confirmation timed out. Retry.", "移動または描画の確認がタイムアウトしました。再試行してください。"),
    ("人物移动已被新的请求替换。", "Character movement was replaced by a new request.", "キャラクターの移動が新しい要求に置き換えられました。"),
    ("人物未到达指定位置。", "The character did not reach the requested position.", "キャラクターが指定した位置に到着していません。"),
    ("空间未确认合法的地面目标。", "The world did not confirm a valid grounded destination.", "空間が有効な接地先を確認できませんでした。"),
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
    ("当前歌曲", "Current track", "現在の曲"),
    ("当前歌曲有绑定视频", "This track has a linked video", "この曲には関連付けられた動画があります"),
    ("播放绑定视频", "Play linked video", "関連付けられた動画を再生"),
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
    ("Marble World ID", "Marble World ID", "Marble World ID"),
    ("生成与导入空间", "Generate and import spaces", "空間の生成とインポート"),
    ("生成会调用付费 Marble API；仅点击生成按钮时提交。", "Generation uses the paid Marble API and is submitted only when you click Generate.", "生成は有料の Marble API を使用し、生成ボタンを押した時だけ送信します。"),
    ("当前运行时不支持 Marble 空间生成与导入。", "This runtime does not support Marble space generation or import.", "現在のランタイムは Marble 空間の生成とインポートに対応していません。"),
    ("生成任务 ID", "Generation operation ID", "生成タスク ID"),
    ("已有生成回执，请恢复原任务；不会重复提交付费生成。", "A generation receipt exists. Resume the original task without submitting another paid generation.", "生成タスクの記録があります。元のタスクを再開し、有料生成を重複送信しません。"),
    ("生成（付费）", "Generate (paid)", "生成（有料）"),
    ("按 World ID 导入", "Import by World ID", "World ID でインポート"),
    ("恢复原任务", "Resume original task", "元のタスクを再開"),
    ("取消本机等待", "Cancel local waiting", "ローカルの待機を中止"),
    ("取消仅停止本机等待，远端生成可能继续并计费。", "Cancellation stops local waiting only. Remote generation may continue and incur charges.", "中止はローカルの待機だけを停止します。リモート生成は継続し、料金が発生する場合があります。"),
    ("正在生成空间", "Generating space", "空間を生成中"),
    ("正在下载空间资产", "Downloading space assets", "空間アセットをダウンロード中"),
    ("正在校验空间运行包", "Validating space package", "空間パッケージを検証中"),
    ("正在注册空间", "Registering space", "空間を登録中"),
    ("空间已导入", "Space imported", "空間をインポートしました"),
    ("已有待恢复的生成任务", "Generation task available to resume", "再開できる生成タスクがあります"),
    ("本机任务已取消", "Local task cancelled", "ローカルタスクを中止しました"),
    ("本机等待已取消，远端生成可能继续；可恢复原任务。", "Local waiting cancelled. Remote generation may continue; you can resume the original task.", "ローカルの待機を中止しました。リモート生成は継続する場合があります。元のタスクを再開できます。"),
    ("空间任务失败", "Space task failed", "空間タスクに失敗しました"),
    ("生成进度", "Generation progress", "生成の進捗"),
    ("用于同步和生成可探索的 3D 空间", "Sync and generate explorable 3D spaces", "探索できる 3D 空間の同期と生成"),
    ("已配置", "Configured", "設定済み"),
    ("加载中…", "Loading…", "読み込み中…"),
    ("高级设置", "Advanced", "詳細設定"),
    ("复刻音色请选择创建时使用的模型。", "For a cloned voice, select its original model.", "複製音声には作成時のモデルを選択してください。"),
    ("麦克风", "Microphone", "マイク"),
    ("系统默认", "System default", "システム既定"),
    ("所选麦克风已断开，请重新选择。", "The selected microphone disconnected. Choose another.", "選択したマイクが切断されました。選び直してください。"),
    ("已保存。", "Saved.", "保存しました。"),
    ("请先填写 API Key，再刷新声音。", "Enter an API key, then refresh voices.", "API キーを入力して音声を更新してください。"),
    ("该账号暂无可用声音，可填写自定义音色 ID。", "No voices are available. You can enter a custom voice ID.", "利用できる音声がありません。カスタム音声 ID を入力できます。"),
    ("同步完成后，音乐库会显示最新歌单。", "Playlists appear after sync completes.", "同期後に最新のプレイリストが表示されます。"),
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
    ("居民人格保存后下一轮聊天生效。", "Saved persona applies to the next chat turn.", "保存した人格は次の会話から適用されます。"),
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
    for (prefix, suffix, english, japanese) in [
        ("已切换为 ", "。", "Switched to", "切り替えました"),
        ("正在加载 ", "…", "Loading", "読み込み中"),
    ] {
        if let Some(name) = source.strip_prefix(prefix).and_then(|s| s.strip_suffix(suffix)).filter(|s| !s.is_empty()) {
            return match locale {
                UiLocale::ZhCn => source.to_owned(),
                UiLocale::En => format!("{english} {name}."),
                UiLocale::Ja => format!("{name}：{japanese}。"),
            };
        }
    }
    const SPACE_NOTICES: &[(&str, &str, &str, &str)] = &[
        ("space_library_loaded", "空间库已读取", "Space library loaded", "空間ライブラリを読み込みました"),
        ("space_library_switching", "正在切换空间…", "Switching space…", "空間を切り替えています…"),
        ("space_library_switch_failed", "空间切换未完成，保留当前空间", "Space switch failed. Current space retained.", "空間を切り替えられませんでした。現在の空間を保持します"),
        ("space_library_selected", "空间已切换", "Space switched", "空間を切り替えました"),
        ("space_library_invalid_packages", "部分空间包无效，未加入可用列表", "Invalid space packages were excluded.", "無効な空間パッケージを一覧から除外しました"),
        ("space_marble_requires_package", "Marble 空间需要发布完整运行包后才能切换", "Marble spaces require a complete runtime package before switching.", "Marble 空間を切り替えるには完全な実行パッケージの公開が必要です"),
        ("space_marble_read_failed", "Marble 空间库读取失败，请检查服务配置", "Could not load Marble spaces. Check service configuration.", "Marble 空間を読み込めませんでした。サービス設定を確認してください"),
    ];
    if let Some((_, zh, en, ja)) = SPACE_NOTICES.iter().find(|(code, _, _, _)| *code == source) {
        return match locale { UiLocale::ZhCn => zh, UiLocale::En => en, UiLocale::Ja => ja }.to_string();
    }
    const GENERATION_NOTICES: &[(&str, &str, &str, &str)] = &[
        ("generation_not_configured", "尚未配置生成服务", "Generation service is not configured", "生成サービスが未設定です"),
        ("generation_configuration_loaded", "已读取生成服务配置", "Generation configuration loaded", "生成サービスの設定を読み込みました"),
        ("generation_configuration_unreadable", "无法读取生成配置，请检查本机文件权限", "Could not read generation configuration. Check local file permissions.", "生成設定を読み込めません。ローカルファイルの権限を確認してください"),
        ("generation_configuration_saved", "生成服务配置已保存", "Generation configuration saved", "生成サービスの設定を保存しました"),
        ("generation_configuration_save_failed", "配置保存失败，请检查地址和密钥", "Could not save configuration. Check the URL and key.", "設定を保存できませんでした。URL とキーを確認してください"),
        ("generation_endpoint_requires_token", "修改服务地址时需要填写新密钥", "Enter a new key when changing the service URL.", "サービス URL を変更する場合は新しいキーを入力してください"),
        ("generation_connection_ok", "生成服务连接正常", "Generation service connection verified", "生成サービスへの接続を確認しました"),
        ("generation_connection_failed", "生成服务连接失败，请检查地址和密钥", "Generation connection failed. Check the URL and key.", "生成サービスに接続できませんでした。URL とキーを確認してください"),
    ];
    if let Some((_, zh, en, ja)) = GENERATION_NOTICES.iter().find(|(code, _, _, _)| *code == source) {
        return match locale { UiLocale::ZhCn => zh, UiLocale::En => en, UiLocale::Ja => ja }.to_string();
    }
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
    fn generation_bridge_status_codes_have_three_translations() {
        for code in ["generation_not_configured", "generation_configuration_loaded", "generation_configuration_unreadable", "generation_configuration_saved", "generation_configuration_save_failed", "generation_endpoint_requires_token", "generation_connection_ok", "generation_connection_failed"] {
            for locale in [UiLocale::ZhCn, UiLocale::En, UiLocale::Ja] {
                let translated = settings_notice(locale, code);
                assert!(!translated.is_empty());
                assert_ne!(translated, code);
            }
        }
    }

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
            "按住说话", "新的 ASR API Key", "按住麦克风录音，松开后将完整转写交给当前角色。没有双向实时通话。",
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
        assert_eq!(settings_notice(UiLocale::En, "已切换为 I Love Slap Bass。"), "Switched to I Love Slap Bass.");
        assert_eq!(settings_notice(UiLocale::Ja, "已切换为 私のダンス。"), "私のダンス：切り替えました。");
        for key in ["生活", "工作", "运动", "戏剧", "自然待机", "角色与动作", "Agent 与语音"] {
            assert_ne!(settings_copy(UiLocale::En, key), key);
            assert!(!settings_copy(UiLocale::Ja, key).is_empty());
        }
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
