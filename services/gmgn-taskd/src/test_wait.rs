//! 测试等待的公共部件：等**进展**，不等墙钟。
//!
//! 这套测试里大量等待形如「轮询状态直到某条件成立」，外面套一个固定的
//! `tokio::time::timeout(5s / 6s / 10s)`。固定上限把「被测作业自己的契约」和
//! 「跑测试这台机器当时的负载」混在一起：
//!
//! * `media::tests::Fixture::terminal` 给 300 × 20ms = 6 s；
//! * `agent_cli::tests::wait` / `agent_dsh::tests::wait` 给 10 s；
//! * `agent_chat::tests` 的两处 `finish` 给 5 s。
//!
//! 而同一套代码的并行执行本身就会把这些阶段的观测延迟放大数倍。实测
//! `media::tests` 的解析阶段（`resolve`，spawn 一个只 `printf` 的 `/bin/sh` 夹具）：
//!
//! ```text
//! --test-threads=1 : spawn p50 0ms / 总耗时 p50  522ms, 峰值 2663ms
//! 默认并行(10)     : spawn p50 1ms / 总耗时 p50 3172ms, 峰值 6277ms
//! ```
//!
//! spawn 稳定在 0–2ms，总耗时却翻了 6 倍——时间花在**等**上，不在做上。生产代码
//! 给这些阶段自己的上限是 90 s（解析）/ 600 s（下载），所以 6 s 的测试上限比被测
//! 系统自己的契约还紧：作业完全健康，测试先超时，报一个没有任何信息的
//! `Elapsed(())`。
//!
//! 这里换成**停滞看门狗**：只要观测到的状态还在变就重置窗口，只有状态在 `stall`
//! 内完全不动才判卡住。它盯的是「没有进展」，不是「没在某台机器上跑够快」；
//! 上限仍然有限（不是无限等），但失败信息会带上作业名和最后一次观测到的状态。
//!
//! 口径不变：没有 `#[ignore]`，没有把测试改成串行，也没有依赖任何外部 flag。

use serde_json::Value;
use std::time::{Duration, Instant};

/// 停滞看门狗：喂它每次观测到的状态，它告诉你作业还在不在动。
pub(crate) struct StallWatch {
    what: &'static str,
    stall: Duration,
    last: Option<Value>,
    last_change: Instant,
}

impl StallWatch {
    pub(crate) fn new(what: &'static str, stall: Duration) -> Self {
        Self { what, stall, last: None, last_change: Instant::now() }
    }

    /// 记一次观测。状态与上次不同就重置停滞窗口并返回 `true`；同一状态连续停留
    /// 超过 `stall` 返回 `false`（调用方据此报 [`StallWatch::stalled`]）。
    pub(crate) fn observe(&mut self, state: &Value) -> bool {
        if self.last.as_ref() != Some(state) {
            self.last = Some(state.clone());
            self.last_change = Instant::now();
            return true;
        }
        self.last_change.elapsed() <= self.stall
    }

    /// 停滞超时的消息：作业名 + 停滞窗口 + 最后一次观测到的状态。
    pub(crate) fn stalled(&self) -> String {
        format!(
            "{} 在 {} 秒内没有任何进展；最后一次观测：{}",
            self.what,
            self.stall.as_secs(),
            self.last.as_ref().unwrap_or(&Value::Null)
        )
    }
}
