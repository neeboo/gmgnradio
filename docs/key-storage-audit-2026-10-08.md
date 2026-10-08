# 应用密钥存储核查

范围为 GMGN 应用源码及服务；未访问其他应用或系统钥匙串条目。

- 语音：`FileSpeechSecretStore` 使用应用 support root 的 `secrets/speech-{provider}.key` 与 `.imported` 文件。只允许 bailian、elevenlabs、fish；目录 0700、文件 0600，同目录临时文件原子 rename。启动不读取密钥或迁移标记，实际配置或播放才读取所选 provider。
- 旧语音 Keychain：没有自动读取、删除或迁移。旧 defaults 密钥只在实际所选 provider 配置需求时导入私有文件；不进入 SQLite、RPC 或日志。
- 音乐：历史文件名 `KeychainMusicProviderSessionStore.swift` 实际实现为 `LocalMusicProviderSessionStore`，已使用本地私有文件，未调用 Keychain。
- Marble：沿用原生应用私有 `secrets/world-labs-api-key` 文件。
- Swift/Rust/ObjC/C# 生产源码未发现 `SecItemCopyMatching/Add/Update/Delete`、shell security password 命令或 keyring 调用。守卫为 `tools/test-no-app-keychain.py`。
- 网易 `SecKeyCreateWithData/GetBlockSize/CreateEncryptedData` 为协议 RSA 加密，不是凭据存储。保留。
- GPUI Cargo.lock 的 security-framework 经 rustls-native-certs / rustls-platform-verifier 用于 TLS 证书信任验证；应用没有调用 GPUI read/write/delete credentials API。保留 TLS 验证，不把证书验证当作应用密钥存储。

验证：私有 Swift 消费者检查初始化零 secret/marker 调用、真实文件权限、覆盖 readback、provider traversal 与符号链接拒绝、原 credential rollback。日志 `/tmp/gmgn-speech-file-preferences-test-2.log`，退出 0。源码守卫、Swift parse 和 diff 检查退出 0。无正式密钥读写、无 Keychain 操作。

v210 角色恢复实际检查：正式 helper 为同一历史 TaskService root，但 presence 表仍为空；Host 设置 authority 原先禁止 helper 启动，首次启动失败后未发角色 bind。修复为 UnityProductSettings 同 root/endpoint 的 transport 明确允许 helper bootstrap；角色仍需在同 authority 确认后恢复。该修复尚待新 Host 构建及真实 renderer ACK 验证，不声明 2B 已恢复。
