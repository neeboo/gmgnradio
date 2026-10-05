using System.Collections.Generic;

namespace GMGN.UnityPlayer.Editor
{
    public static class LocalizationTableSeed
    {
        public static readonly Dictionary<string, string[]> Strings = new()
        {
            ["chat"] = new[] { "与角色聊天", "Chat with character", "キャラクターとチャット" },
            ["placeholder"] = new[] { "和角色聊聊…", "Talk to your character…", "キャラクターに話しかける…" },
            ["empty"] = new[] { "可以聊音乐，也可以说说今天的事。", "Talk about music or how your day went.", "音楽や今日の出来事を話しましょう。" },
            ["hint"] = new[] { "Enter 发送 · Shift+Enter 换行", "Enter to send · Shift+Enter for a new line", "Enter で送信 · Shift+Enter で改行" },
            ["new"] = new[] { "查看新消息", "View new messages", "新しいメッセージを見る" },
            ["send"] = new[] { "发送消息", "Send message", "メッセージを送信" },
            ["cancel"] = new[] { "停止回复", "Stop response", "応答を停止" },
            ["close"] = new[] { "收起聊天", "Close chat", "チャットを閉じる" },
            ["settings"] = new[] { "设置", "Settings", "設定" },
            ["settingsTip"] = new[] { "打开统一设置", "Open settings", "設定を開く" },
            ["player"] = new[] { "播放器", "Player", "プレイヤー" },
            ["space"] = new[] { "空间", "Space", "空間" },
            ["mode"] = new[] { "切换播放器与空间", "Switch player and space", "プレイヤーと空間を切り替え" },
            ["noSpace"] = new[] { "尚未指定空间备份", "No space backup selected", "空間のバックアップが未選択です" },
            ["music"] = new[] { "打开音乐库", "Open music library", "音楽ライブラリを開く" },
            ["previous"] = new[] { "上一首", "Previous track", "前の曲" },
            ["noPrevious"] = new[] { "当前队列没有上一首", "No previous track in queue", "キューに前の曲がありません" },
            ["next"] = new[] { "下一首", "Next track", "次の曲" },
            ["noNext"] = new[] { "当前队列没有下一首", "No next track in queue", "キューに次の曲がありません" },
            ["play"] = new[] { "播放", "Play", "再生" },
            ["pause"] = new[] { "暂停", "Pause", "一時停止" },
            ["volume"] = new[] { "音量", "Volume", "音量" },
            ["fullscreen"] = new[] { "切换全屏", "Toggle fullscreen", "全画面を切り替え" },
            ["microphone"] = new[] { "按住说话尚未迁移", "Push-to-talk is not available yet", "プッシュ・トゥ・トークは未対応です" },
            ["inbox"] = new[] { "通知尚未迁移", "Notifications are not available yet", "通知は未対応です" },
            ["props"] = new[] { "物件与摆放尚未迁移", "Object placement is not available yet", "オブジェクト配置は未対応です" },
            ["screen"] = new[] { "空间播放器尚未迁移", "Space player is not available yet", "空間プレイヤーは未対応です" },
            ["retry"] = new[] { "重新编辑并发送", "Edit and resend", "編集して再送信" },
            ["inboxTitle"] = new[] { "通知", "Notifications", "通知" },
            ["inboxEmpty"] = new[] { "暂无通知", "No notifications", "通知はありません" },
            ["inboxRefresh"] = new[] { "刷新通知", "Refresh notifications", "通知を更新" },
            ["inboxClose"] = new[] { "关闭通知", "Close notifications", "通知を閉じる" },
            ["inboxBack"] = new[] { "返回通知列表", "Back to notifications", "通知一覧に戻る" },
            ["inboxUnread"] = new[] { "未读", "Unread", "未読" },
            ["inboxRead"] = new[] { "已读", "Read", "既読" },
            ["inboxReading"] = new[] { "正在标记已读…", "Marking as read…", "既読にしています…" },
            ["inboxLoading"] = new[] { "正在读取通知…", "Loading notifications…", "通知を読み込んでいます…" },
            ["inboxReadError"] = new[] { "暂时无法标记已读，请重试。", "Could not mark as read. Please retry.", "既読にできませんでした。もう一度お試しください。" },
            ["inboxUpdated"] = new[] { "通知已更新", "Notifications updated", "通知を更新しました" },
            ["inboxNotConnected"] = new[] { "通知服务未连接", "Notification service is disconnected", "通知サービスに接続されていません" }
        };

    }
}
