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

#[cfg(test)]
mod tests {
    use super::StallWatch;
    use serde_json::json;
    use std::time::Duration;

    /// 回归：看门狗判的是**没进展**，不是**没跑够快**。
    ///
    /// 2026-10-09 的修法（`media.rs` / `agent_chat.rs` / `agent_cli.rs` /
    /// `agent_dsh.rs` 的等待）只做过重复跑验证，没有常驻测试。旧写法是固定墙钟
    /// 上限（6s / 5s / 10s），比被测作业自己的契约（解析 90s、下载 600s）还紧，
    /// 并行跑满时作业健康、测试先超时。这里把新语义用**常数时间**钉住：
    ///
    /// * 只要观测到的状态在变，就永远不算卡住——不管机器上的作业跑得多慢；
    /// * 只有状态在 `stall` 窗口内**一动不动**才返回 false。
    #[test]
    fn progress_resets_the_stall_window_and_a_still_state_does_not() {
        let mut moving = StallWatch::new("测试作业", Duration::from_secs(30));
        for tick in 0..40 {
            // 40 × 5ms = 200ms 的观测跨度，窗口是 30s：一直在动就必须一直 true。
            std::thread::sleep(Duration::from_millis(5));
            assert!(
                moving.observe(&json!({"state": "running", "tick": tick})),
                "a changing state is progress, however slow the machine is"
            );
        }

        let mut still = StallWatch::new("静止作业", Duration::from_millis(40));
        let frozen = json!({"state": "downloading", "bytes": 1024});
        assert!(still.observe(&frozen), "the first observation is always progress");
        std::thread::sleep(Duration::from_millis(5));
        assert!(
            still.observe(&frozen),
            "inside the window an unchanged state is not yet a stall"
        );
        std::thread::sleep(Duration::from_millis(60));
        assert!(
            !still.observe(&frozen),
            "an unchanging state past the stall window must report no progress"
        );
        let message = still.stalled();
        assert!(
            message.contains("静止作业") && message.contains("1024"),
            "the failure message must name the job and the last state it saw: {message}"
        );
    }

    /// 回归：窗口重置必须是**真重置**——停滞窗口从最后一次变化算起，而不是从构造
    /// 时刻算起。否则「动不动地跑了很久才停」会被误判成一开始就卡住。
    #[test]
    fn a_change_moves_the_window_start_forward() {
        let mut watch = StallWatch::new("测试作业", Duration::from_millis(80));
        assert!(watch.observe(&json!({"state": "a"})));
        // 先让首个窗口几乎走完。
        std::thread::sleep(Duration::from_millis(70));
        // 变化把窗口起点推到现在（而不是留在构造时刻）。
        assert!(watch.observe(&json!({"state": "b"})));
        std::thread::sleep(Duration::from_millis(40));
        assert!(
            watch.observe(&json!({"state": "b"})),
            "40ms after the last change is still inside the 80ms window"
        );
    }
}
