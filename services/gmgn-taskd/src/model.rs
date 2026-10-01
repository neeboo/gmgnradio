use base64::Engine;
use reqwest::Url;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};

pub type Result<T> = std::result::Result<T, &'static str>;
pub const PNG_LIMIT: usize = 8 * 1024 * 1024;
pub const MODEL_LIMIT: usize = 32 * 1024 * 1024;
pub const FRAME_LIMIT: usize = 12 * 1024 * 1024;
/// 碰撞代理的文件上限。代理只用来做"胶囊 × 三角形"的实时判定，它**必须**是小规模的：
/// 4 MiB 已经远超一个几千面凸包的需要，再大就说明生成侧导出的是完整网格而不是代理。
pub const COLLIDER_LIMIT: usize = 4 * 1024 * 1024;
/// 碰撞代理允许声明的三角形上限。app 侧一次 `canOccupy` 要遍历代理的三角形，
/// 所以这个数字是"性能有界"这条要求的**契约**部分：超过就拒收回执，而不是让 app 卡住。
/// 4096 个三角形在真机上是微秒量级（实测见 `tools/test-resident-prop-collision-proxy.swift`）。
pub const COLLIDER_TRIANGLE_LIMIT: u64 = 4096;
/// 允许的代理格式。两个都是 GLB（app 用同一个 `GLBColliderDecoder` 解），区别在导出方式：
/// `glb-hull` = 凸包，`glb-decimated` = 降面到目标面数。这一位进审计，也告诉 app 该代理
/// 是否**保证凸**（凸包可以用凸特有的快速路径）。
pub const COLLISION_FORMATS: [&str; 2] = ["glb-hull", "glb-decimated"];
/// 权威尺寸只接受米。世界本身就是米，收别的单位就必须在 app 里做换算，那是第二处口径。
pub const AUTHORITATIVE_SIZE_UNITS: &str = "m";
pub const UP_AXES: [&str; 2] = ["+Y", "-Y"];
pub const FORWARD_AXES: [&str; 4] = ["+Z", "-Z", "+X", "-X"];

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Source {
    pub author: String,
    pub license: String,
}

#[derive(Clone, Serialize, Deserialize, PartialEq)]
pub struct Context {
    #[serde(rename = "worldID")]
    pub world_id: String,
    #[serde(rename = "residentScope")]
    pub resident_scope: String,
}

/// 尺寸意图允许的米数。与 `height_meters` **同一条范围**：两个数字都能过关却互相矛盾，
/// 才是真正会伤到用户的那种契约。
pub const SIZE_INTENT_MIN_METERS: f64 = 0.01;
pub const SIZE_INTENT_MAX_METERS: f64 = 3.0;

/// 三轴尺寸意图允许的毫米数：与 `0.01–3 m` **同一条边界**，只是换成用户报规格时用的单位。
///
/// 为什么三轴单开一个单位（而不是"米数的三元组"）：用户嘴里和商品页上写的就是毫米
/// （真机 2026-10-01「平面电视」的规格原话就是 `1443 x 862 x 302mm`）。契约记**他说的那个数**、
/// 单位换算只发生一次、而且写在键名上，就没有"少乘/多乘 1000"的余地 ——
/// 1443 × 862 × 302 mm 落库就是 `1443`、`862`、`302` 三个整数，用户能在面板上逐字核对。
pub const SIZE_INTENT_MIN_MILLIMETERS: f64 = 10.0;
pub const SIZE_INTENT_MAX_MILLIMETERS: f64 = 3000.0;

/// 提交时声明的**尺寸意图**。提交时就说清楚，而不是让 app 事后从网格猜。
///
/// 两种形状，**二选一**（同时给是 `size_intent_shape_conflict`）：
///
/// 1. `{axis, meters, source}` —— **一根轴 + 一个米数**（改造前就有的那一份，逐字节不变）。
///    为什么需要它（真机 2026-10-01「2B 白色长剑（外形摆件）」）：`height_meters` 只有一根
///    轴（高度），而生成回来的网格**不保证立着** —— 那把剑实测 1.005 × 0.133 × 0.057 m，
///    Y 那 0.133 m 是**厚度**，请求高度 1.1 m 于是被算成"厚度 1.1 m"，场景里变成
///    8.28 × 1.10 × 0.47 m（比 7 × 8 × 3.2 m 的舱室还长）⇒ 没有任何落点能过摆放判定
///    ⇒ 被拒、退回库存。用户说的是"一把 1.1 米的剑"，他要的是**最长边 1.1 m**；
///    这句话必须在提交那一刻随任务落盘，事后再靠界面自动缩放只是兜底。
///
/// 2. `{mode:"dimensions", millimeters:{x,y,z}, source}` —— **完整三维**。
///    为什么需要它（真机 2026-10-01「平面电视」）：用户的规格是 `1443 x 862 x 302 mm`，
///    三根轴都说死了。旧形状只能上报**一根轴**，另外两维**在契约里没有位置**
///    ⇒ agent 挑一根报上来，剩下两维就地丢掉 ⇒ 生成器给出一个大立方体。
///    三根轴必须都能落进契约，否则"照实填"这件事根本写不出来。
///
/// **轴序与朝向**（与回执 `authoritative_size` 的 `up_axis`/`forward_axis` 同一套约定，
/// 本仓把 up 钉死在 `±Y`）：`x` = 宽（左右，`±X`）、**`y` = 高（上下，`±Y`）**、
/// `z` = 深（前后，正面朝 `+Z` 时就是从正面往后的进深）。
/// 于是「1443 x 862 x 302 mm」= `x:1443`（宽）、`y:862`（高）、`z:302`（深）。
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum SizeIntent {
    /// 一根轴 + 一个米数（旧形状）。
    Axis(AxisSizeIntent),
    /// 完整三维（毫米）。
    Dimensions(DimensionsSizeIntent),
}

/// 旧形状：一根轴 + 一个米数。`axis == "height"` 时与 `height_meters` **语义完全相同**
/// （数值也必须相同，由 `Submit::validate` 强制）—— 于是"高 1.1 米"这种要求仍然表达得出来，
/// 而且不可能出现两份互相矛盾的高度。
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AxisSizeIntent {
    pub axis: SizeIntentAxis,
    pub meters: f64,
    /// 谁说的这个尺寸：用户原话（`user`）／服务建议（`suggested`）／兜底默认（`default`）。
    /// 没有默认值：缺了就是 `invalid_size_intent`，绝不替调用方编一个出处。
    pub source: SizeIntentSource,
}

/// 三轴形状：`{mode:"dimensions", millimeters:{x,y,z}, source}`。
///
/// `mode` 是**显式的形状标签**而不是可有可无的装饰：没有它，"两种形状同时给了"
/// 就只能退化成一个笼统的 `invalid_size_intent`（未知键），说不清是"写错了"还是
/// "说了两遍尺寸"。有了它，同时给 ⇒ `size_intent_shape_conflict` 这个具名错误。
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DimensionsSizeIntent {
    pub mode: SizeIntentMode,
    pub millimeters: SizeIntentMillimeters,
    pub source: SizeIntentSource,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SizeIntentMode {
    Dimensions,
}

/// 三轴尺寸（毫米），**轴序与朝向写死在这里**：`x` 宽、`y` 高、`z` 深。
///
/// 三个分量都必给：缺一个就是 `invalid_size_intent`。缺的那一维如果"默认成 0 或者
/// 最长边"，就又回到了"契约里没有这一维"的老问题 —— 只不过这次是静默的。
///
/// `Deserialize` 是**手写**的，只收 JSON 对象：serde 派生对结构体同时接受"映射"和
/// "序列"两种输入，`{"x":1443,"y":862,"z":302}` 与 `[1443,862,302]` 会解析成同一个值 ——
/// 那条路绕过了键名想表达的"哪一根轴"，不是本契约的形式。与 `Submit::parsed_size_intent`
/// 显式要求对象是同一条纪律。
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SizeIntentMillimeters {
    pub x: f64,
    pub y: f64,
    pub z: f64,
}

impl<'de> Deserialize<'de> for SizeIntentMillimeters {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        struct OnlyNamedEdges;

        impl<'de> serde::de::Visitor<'de> for OnlyNamedEdges {
            type Value = SizeIntentMillimeters;

            fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
                formatter.write_str("三轴尺寸对象 {x, y, z}（按名字给，不接受序列）")
            }

            fn visit_map<A>(self, mut map: A) -> std::result::Result<Self::Value, A::Error>
            where
                A: serde::de::MapAccess<'de>,
            {
                let (mut x, mut y, mut z) = (None, None, None);
                while let Some(key) = map.next_key::<String>()? {
                    match key.as_str() {
                        "x" => {
                            if x.is_some() {
                                return Err(serde::de::Error::duplicate_field("x"));
                            }
                            x = Some(map.next_value::<f64>()?);
                        }
                        "y" => {
                            if y.is_some() {
                                return Err(serde::de::Error::duplicate_field("y"));
                            }
                            y = Some(map.next_value::<f64>()?);
                        }
                        "z" => {
                            if z.is_some() {
                                return Err(serde::de::Error::duplicate_field("z"));
                            }
                            z = Some(map.next_value::<f64>()?);
                        }
                        other => {
                            return Err(serde::de::Error::unknown_field(other, &["x", "y", "z"]))
                        }
                    }
                }
                Ok(SizeIntentMillimeters {
                    x: x.ok_or_else(|| serde::de::Error::missing_field("x"))?,
                    y: y.ok_or_else(|| serde::de::Error::missing_field("y"))?,
                    z: z.ok_or_else(|| serde::de::Error::missing_field("z"))?,
                })
            }
        }

        deserializer.deserialize_map(OnlyNamedEdges)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SizeIntentAxis {
    Longest,
    Height,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SizeIntentSource {
    User,
    Suggested,
    Default,
}

impl SizeIntent {
    pub fn validate(&self) -> Result<()> {
        match self {
            SizeIntent::Axis(intent) => intent.validate(),
            SizeIntent::Dimensions(intent) => intent.validate(),
        }
    }

    /// 旧形状的轴；三轴形状没有"一根轴"，返回 `None`。
    pub fn axis(&self) -> Option<SizeIntentAxis> {
        match self {
            SizeIntent::Axis(intent) => Some(intent.axis),
            SizeIntent::Dimensions(_) => None,
        }
    }

    /// 三轴形状的毫米三元组（顺序 `[x, y, z]`）；旧形状返回 `None`。
    pub fn millimeters(&self) -> Option<[f64; 3]> {
        match self {
            SizeIntent::Axis(_) => None,
            SizeIntent::Dimensions(intent) => Some([
                intent.millimeters.x,
                intent.millimeters.y,
                intent.millimeters.z,
            ]),
        }
    }

    pub fn source(&self) -> SizeIntentSource {
        match self {
            SizeIntent::Axis(intent) => intent.source,
            SizeIntent::Dimensions(intent) => intent.source,
        }
    }

    /// 提交里的 `height_meters` **必须**等于的那个数；`None` = 这一份意图不管 `height_meters`。
    ///
    /// 为什么三轴形状也要管：三轴的 `y` 就是"高"，而 `height_meters` 是生成请求的高度，
    /// 两者是同一件事的两个写法。让它们各自为政，就又是两份高度 —— 与旧形状
    /// `axis == height` 那条判据同一个道理。
    pub fn required_height_meters(&self) -> Option<f64> {
        match self {
            SizeIntent::Axis(intent) if intent.axis == SizeIntentAxis::Height => Some(intent.meters),
            SizeIntent::Axis(_) => None,
            SizeIntent::Dimensions(intent) => Some(intent.millimeters.y / 1000.0),
        }
    }
}

impl AxisSizeIntent {
    pub fn validate(&self) -> Result<()> {
        if !self.meters.is_finite()
            || !(SIZE_INTENT_MIN_METERS..=SIZE_INTENT_MAX_METERS).contains(&self.meters)
        {
            return Err("invalid_size_intent");
        }
        Ok(())
    }
}

impl DimensionsSizeIntent {
    pub fn validate(&self) -> Result<()> {
        for edge in [self.millimeters.x, self.millimeters.y, self.millimeters.z] {
            if !edge.is_finite()
                || !(SIZE_INTENT_MIN_MILLIMETERS..=SIZE_INTENT_MAX_MILLIMETERS).contains(&edge)
            {
                return Err("invalid_size_intent");
            }
        }
        Ok(())
    }
}

/// 比较意图米数与权威尺寸时用的绝对容差（米）。1e-4 m = 0.1 mm：GLB 顶点本来就只有
/// float32 精度，服务端把三维尺寸四舍五入到毫米也落在这个范围内；相对容差另取 1e-3，
/// 于是 1.1 m 这种尺寸允许 1.1 mm 的往返误差。取严的理由：这一条比的是"同一件事"，
/// 宽松到能把 1.0 和 1.1 混为一谈就失去意义了。
pub const SIZE_INTENT_SIZE_TOLERANCE: f64 = 1e-4;

/// 生成服务在 `/health` 的 `provider` 块里**自报**的「收得下尺寸意图」能力。
///
/// 为什么必须先协商再发（2026-10-02 只读勘察 `/home/spark/gmgn-prop-service/prop_service.py`）：
/// 服务端 `validate_request` 第一句就是 `set(data) != allowed ⇒ invalid_fields`，即**严格拒绝
/// 未知键**。所以"我们多带一个键、老服务忽略它"这条最省事的路在真机上会**当场打断全链路**
/// （每个任务 400 ⇒ `request_rejected`）。于是：**只有服务端自己声明收得下，我们才发**；
/// 声明缺失、探测失败、声明不合法，一律按"收不下"处理（fail-closed）—— 宁可这一件仍按
/// 老办法（app 自己缩放），也不能让提交本身失败。
///
/// 与 `provider` 块里其它字段同一条口径：**块或这个键缺失 ⇒ `None` ⇒ 提交字节与今天逐位
/// 相同**；键在但不合法 ⇒ `invalid_provider_capabilities`（那一份声明整块不可信）。
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SizeIntentSupport {
    /// 收得下的轴。空数组合法，但等于一根都不收。
    pub axes: Vec<SizeIntentAxis>,
    /// 收得下的米数闭区间。
    pub min_meters: f64,
    pub max_meters: f64,
    /// 收到轴之后**做**什么：`normalize` = 服务端自己按轴把导出归一到米数；
    /// `echo` = 只接受并原样回显，缩放仍由 app 负责。
    ///
    /// **必须明写**：缺这个字段就是"收不下"。不允许我们替服务端假设它归一了
    /// —— 把"只回显"当成"已归一"会让 app 不再缩放，产物直接错尺寸。
    pub applies: SizeIntentApplies,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SizeIntentApplies {
    Normalize,
    Echo,
}

impl SizeIntentSupport {
    /// 这一条意图现在能不能发。三条全过才行：轴在清单里、区间自身合法、米数落在闭区间里。
    ///
    /// 区间不合法（非有限、上下颠倒）时**不**发：一份自相矛盾的声明不能当成"随便发"。
    ///
    /// **三轴形状恒定不发**：线上那个键只有"一根轴 + 一个米数"这一种形式，而远端
    /// `validate_request` 的第一句就是严格拒绝未知键（见本类型的文档）。发过去就是
    /// 400 ⇒ 整件任务失败。三轴意图的归一发生在 **app 侧**，远端拿到的仍然只有
    /// `height_meters`（= 三轴的 `y`）那一个数 —— 与"服务声明读不到"时的方向一致：
    /// fail-closed 的方向是"这一条不发"，不是"提交不发"。
    pub fn accepts(&self, intent: &SizeIntent) -> bool {
        let SizeIntent::Axis(intent) = intent else {
            return false;
        };
        self.axes.contains(&intent.axis)
            && self.min_meters.is_finite()
            && self.max_meters.is_finite()
            && self.min_meters <= self.max_meters
            && (self.min_meters..=self.max_meters).contains(&intent.meters)
    }
}

#[derive(Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Job {
    pub id: String,
    pub name: String,
    pub endpoint: String,
    pub image_path: String,
    #[serde(rename = "imageSHA256")]
    pub image_sha256: String,
    /// 生成请求的高度（**老路径，语义一位不变**）。远端服务收到的还是这一个数字。
    pub height_meters: f64,
    /// 提交时声明的尺寸意图。**可选且纯增量**：缺失时整个键都不序列化（旧客户端看到的
    /// job JSON 与今天逐字节一致），`effectiveSize` 于是仍然只按 `height_meters` 推断。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub size_intent: Option<SizeIntent>,
    pub source: Source,
    pub idempotency_key: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub receipt: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub local_model_path: Option<String>,
    /// 已核验并落盘的碰撞代理路径（`<id>.collider.glb`）。
    ///
    /// **可选且纯增量**：回执里没有碰撞字段时这一位恒为 `None`，序列化时整个键都不出现，
    /// 于是旧客户端看到的 job JSON 与今天逐字节一致。出现它只说明"生成侧给了代理，
    /// 而且我们已经把它核验并落盘" —— app 侧据此用代理而不是 yaw 盒子做碰撞。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub local_collision_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_error: Option<String>,
    #[serde(default = "interrupted")]
    pub backend_stage: String,
    #[serde(default)]
    pub cancel_requested: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context: Option<Context>,
    /// Artifact identity owned by the caller: one wish, one prop. Optional and
    /// additive so payloads that predate it keep parsing; when present the
    /// store refuses a second *active* job for the same id.
    #[serde(default, skip_serializing_if = "Option::is_none", rename = "sourceWishID")]
    pub source_wish_id: Option<String>,
    /// Fingerprint of the generation parameters that determine the mesh
    /// silhouette (and therefore the collision box). Mandatory for a fallback
    /// retry: the retry either carries the same fingerprint or is refused.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workflow_profile: Option<String>,
}
fn interrupted() -> String {
    "interrupted".into()
}

/// The generation parameters that decide the mesh silhouette. These are the
/// numbers a fallback retry must reproduce: changing any of them changes the
/// geometry, so it also changes the collision box and every downstream anchor.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GenerationProfile {
    pub resolution: u32,
    pub decimation: u32,
    pub texture_size: u32,
    pub remesh: bool,
}

pub const PROFILE_TAG: &str = "gmgn-mesh-v1";

impl GenerationProfile {
    pub fn validate(&self) -> Result<()> {
        if !(64..=4096).contains(&self.resolution)
            || !(1_000..=5_000_000).contains(&self.decimation)
            || !(64..=8192).contains(&self.texture_size)
        {
            return Err("invalid_generation_profile");
        }
        Ok(())
    }
    /// The audit string stored in `workflow_profile`. It spells out every
    /// silhouette-determining parameter, so the receipt alone documents what
    /// geometry the artifact was generated with.
    pub fn fingerprint(&self) -> String {
        format!(
            "{PROFILE_TAG};resolution={};decimation={};texture_size={};remesh={}",
            self.resolution, self.decimation, self.texture_size, self.remesh
        )
    }
    /// Reads back a fingerprint produced by [`Self::fingerprint`]. Used to
    /// canonicalise a recorded profile before comparing it with a retry.
    pub fn parse(value: &str) -> Result<Self> {
        let mut parts = value.split(';');
        if parts.next() != Some(PROFILE_TAG) {
            return Err("invalid_workflow_profile");
        }
        let mut resolution = None;
        let mut decimation = None;
        let mut texture_size = None;
        let mut remesh = None;
        for part in parts {
            let (key, value) = part.split_once('=').ok_or("invalid_workflow_profile")?;
            let duplicate = match key {
                "resolution" => resolution
                    .replace(value.parse().map_err(|_| "invalid_workflow_profile")?)
                    .is_some(),
                "decimation" => decimation
                    .replace(value.parse().map_err(|_| "invalid_workflow_profile")?)
                    .is_some(),
                "texture_size" => texture_size
                    .replace(value.parse().map_err(|_| "invalid_workflow_profile")?)
                    .is_some(),
                "remesh" => remesh
                    .replace(match value {
                        "true" => true,
                        "false" => false,
                        _ => return Err("invalid_workflow_profile"),
                    })
                    .is_some(),
                _ => return Err("invalid_workflow_profile"),
            };
            if duplicate {
                return Err("invalid_workflow_profile");
            }
        }
        let profile = Self {
            resolution: resolution.ok_or("invalid_workflow_profile")?,
            decimation: decimation.ok_or("invalid_workflow_profile")?,
            texture_size: texture_size.ok_or("invalid_workflow_profile")?,
            remesh: remesh.ok_or("invalid_workflow_profile")?,
        };
        profile
            .validate()
            .map_err(|_| "invalid_workflow_profile")?;
        Ok(profile)
    }
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Stored {
    pub job: Job,
    pub attempted: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Submit {
    pub id: String,
    pub endpoint: String,
    pub name: String,
    pub png_base64: String,
    pub source: Source,
    pub height_meters: f64,
    /// 尺寸意图（`sizeIntent`，兼容别名 `size_intent`）。**可选且纯增量**：老调用方不带它，
    /// 行为与今天逐字节一致（app 仍按 `height_meters` 自动推断）。
    ///
    /// 这里刻意收成 `Option<Value>` 而不是直接 `Option<SizeIntent>`：`Submit` 的
    /// `deny_unknown_fields` + serde 解析失败只会得到一个笼统的 `invalid_input`，而
    /// "轴名/出处/米数非法"必须给出**明确的错误码**（`invalid_size_intent`），
    /// 所以解析放在 `validate()` 里，与其它字段校验同一条路。
    #[serde(default, rename = "sizeIntent", alias = "size_intent")]
    pub size_intent: Option<Value>,
    #[serde(default)]
    pub context: Option<Context>,
    /// Additive: callers that predate the field simply omit it.
    #[serde(default, rename = "sourceWishID")]
    pub source_wish_id: Option<String>,
    #[serde(default)]
    pub generation_profile: Option<GenerationProfile>,
}

pub fn identity(s: &str) -> Result<String> {
    uuid::Uuid::parse_str(s)
        .map(|u| u.hyphenated().to_string().to_uppercase())
        .map_err(|_| "invalid_id")
}
pub fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
pub fn endpoint(s: &str) -> Result<String> {
    let u = Url::parse(s).map_err(|_| "invalid_endpoint")?;
    let authority_and_path = s
        .split_once("://")
        .map(|(_, rest)| rest)
        .ok_or("invalid_endpoint")?;
    let raw_path = authority_and_path
        .find('/')
        .map(|at| &authority_and_path[at..]);
    if raw_path.is_some_and(|p| p != "/")
        || authority_and_path.contains('@')
        || s.chars().any(char::is_control)
    {
        return Err("invalid_endpoint");
    }
    let host = u.host_str().unwrap_or("").trim_matches(['[', ']']);
    let local = host == "localhost"
        || host
            .parse::<std::net::IpAddr>()
            .is_ok_and(|ip| ip.is_loopback());
    if !(u.scheme() == "https" || (u.scheme() == "http" && local))
        || u.host().is_none()
        || !u.username().is_empty()
        || u.password().is_some()
        || u.path() != "/"
        || u.query().is_some()
        || u.fragment().is_some()
        || s.contains('\\')
        || s.trim() != s
    {
        return Err("invalid_endpoint");
    }
    Ok(u.origin().ascii_serialization())
}

pub fn validate_png(bytes: &[u8]) -> Result<()> {
    if bytes.len() > PNG_LIMIT || bytes.len() < 24 || &bytes[..8] != b"\x89PNG\r\n\x1a\n" {
        return Err("invalid_png");
    }
    for off in [16, 20] {
        let size = u32::from_be_bytes(bytes[off..off + 4].try_into().unwrap());
        if !(1..=2048).contains(&size) {
            return Err("invalid_png");
        }
    }
    let mut decoder = png::Decoder::new(std::io::Cursor::new(bytes));
    decoder.set_limits(png::Limits {
        bytes: 40 * 1024 * 1024,
    });
    let mut reader = decoder.read_info().map_err(|_| "invalid_png")?;
    let size = reader.output_buffer_size();
    if size > 40 * 1024 * 1024 {
        return Err("invalid_png");
    }
    reader
        .next_frame(&mut vec![0; size])
        .map_err(|_| "invalid_png")?;
    reader.finish().map_err(|_| "invalid_png")?;
    Ok(())
}

impl Submit {
    pub fn validate(&mut self) -> Result<Vec<u8>> {
        self.id = identity(&self.id)?;
        self.endpoint = endpoint(&self.endpoint)?;
        if self.context.as_ref().is_some_and(|c| {
            [&c.world_id, &c.resident_scope]
                .iter()
                .any(|s| s.trim().is_empty() || s.len() > 200)
        }) {
            return Err("invalid_context");
        }
        if self.source_wish_id.as_ref().is_some_and(|id| {
            id.trim().is_empty() || id.len() > 200 || id.chars().any(char::is_control)
        }) {
            return Err("invalid_source_wish_id");
        }
        if let Some(profile) = &self.generation_profile {
            profile.validate()?;
        }
        if !(1..=100).contains(&self.name.chars().count())
            || self.name.chars().any(|c| "/\\\0".contains(c))
            || [&self.source.author, &self.source.license]
                .iter()
                .any(|s| s.trim().is_empty() || s.chars().count() > 200)
            || !self.height_meters.is_finite()
            || !(SIZE_INTENT_MIN_METERS..=SIZE_INTENT_MAX_METERS).contains(&self.height_meters)
            || self.png_base64.len() > PNG_LIMIT.div_ceil(3) * 4
        {
            return Err("invalid_input");
        }
        if let Some(intent) = self.parsed_size_intent()? {
            intent.validate()?;
            // 意图里"高"这一位与 `height_meters` 说的是同一件事 ⇒ 两个数字必须相同
            // （旧形状的 `axis == "height"`、三轴形状的 `y` 都算在内）。
            // 不相同就拒绝（`size_intent_conflict`），而不是让 app 自己挑一个信 ——
            // 那就是两份真相，而"用户看到太大/消失"正是从两份真相长出来的。
            if let Some(required) = intent.required_height_meters() {
                if required != self.height_meters {
                    return Err("size_intent_conflict");
                }
            }
        }
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(&self.png_base64)
            .map_err(|_| "invalid_png")?;
        validate_png(&bytes)?;
        Ok(bytes)
    }

    /// 把提交上来的 `sizeIntent` 解析成强类型。缺失/null ⇒ `Ok(None)`（老路径）。
    ///
    /// 形状**二选一**，靠 `mode` 这个显式标签分派（没有它，"两种形状同时给"就只是一个
    /// 笼统的 `invalid_size_intent`，说不清是写错了还是说了两遍尺寸）：
    ///
    /// - 有 `mode`：三轴形状。**同时给了 `axis`/`meters` ⇒ `size_intent_shape_conflict`**
    ///   （具名，不猜哪一份才算数）；`mode` 值不是 `dimensions`、缺 `millimeters`、
    ///   三个分量缺一个、多了未知键、毫米数不是数或越界 ⇒ `invalid_size_intent`。
    /// - 没有 `mode`：旧形状，行为与改造前逐字节一致。
    ///
    /// 任何一条不过都是**明确错误码，不静默**：静默按"没有意图"处理，就等于又回到了
    /// "让 app 猜这件东西该多大"。
    ///
    /// 必须显式要求 JSON 对象：serde 的派生 `Deserialize` 对结构体同时接受"映射"和
    /// "序列"两种输入，`["longest", 1.1, "user"]` 也会被它按字段顺序吃下去 ——
    /// 那条路绕过了 `deny_unknown_fields` 想守的边界，不是本契约的形式。
    pub fn parsed_size_intent(&self) -> Result<Option<SizeIntent>> {
        let Some(value) = &self.size_intent else {
            return Ok(None);
        };
        if value.is_null() {
            return Ok(None);
        }
        let object = value.as_object().ok_or("invalid_size_intent")?;
        let has_mode = object.contains_key("mode");
        let has_axis_shape = object.contains_key("axis") || object.contains_key("meters");
        if has_mode {
            // 两种形状同时给：这个对象说不清自己是哪一种，**具名拒绝**（不是未知键）。
            if has_axis_shape {
                return Err("size_intent_shape_conflict");
            }
            return serde_json::from_value::<DimensionsSizeIntent>(value.clone())
                .map(|intent| Some(SizeIntent::Dimensions(intent)))
                .map_err(|_| "invalid_size_intent");
        }
        // 没有 `mode` 却带了三轴的字段：形状不完整（三轴意图**必须**声明 `mode`）。
        if object.contains_key("millimeters") {
            return Err("invalid_size_intent");
        }
        serde_json::from_value::<AxisSizeIntent>(value.clone())
            .map(|intent| Some(SizeIntent::Axis(intent)))
            .map_err(|_| "invalid_size_intent")
    }
}

pub fn remote_id(value: &Value) -> Result<&str> {
    let id = value["id"].as_str().ok_or("invalid_response")?;
    if id.len() != 32
        || !id
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err("invalid_response");
    }
    Ok(id)
}

pub fn receipt(value: &Value, job: &Job) -> Result<()> {
    let id = remote_id(value)?;
    if let Some(previous) = &job.receipt {
        if remote_id(previous)? != id {
            return Err("remote_id_mismatch");
        }
    }
    let state = value["state"].as_str().ok_or("invalid_response")?;
    if ![
        "queued",
        "preflight",
        "waiting_resources",
        "submitting",
        "remote_pending",
        "running",
        "cancel_requested",
        "completed",
        "failed",
        "cancelled",
        "interrupted",
    ]
    .contains(&state)
        || value["name"].as_str() != Some(&job.name)
        || value["source"] != serde_json::to_value(&job.source).map_err(|_| "invalid_response")?
        || value["height_meters"].as_f64() != Some(job.height_meters)
        || value["compute_may_continue"].as_bool().is_none()
        || value["created_at"].as_f64().is_none()
        || value["updated_at"].as_f64().is_none()
        || (!value["reason"].is_null() && !value["reason"].is_string())
    {
        return Err("invalid_response");
    }
    // 回执**回显**的尺寸意图（服务端把我们发出去的那一份原样带回来）。它要么不在、
    // 要么与任务上那一份**逐字段相同**：不同就说明服务端记下的不是我们要的，收下就等于
    // 两套尺寸。缺失**不算**冲突（不是每个服务端都回显），所以老服务照常工作。
    //
    // 比较用**解析后的字段**而不是 JSON 值：`serde_json` 里 `Number(1) != Number(1.0)`，
    // 而调用方完全可能把 1 米写成 `1`、服务端（Python）又会把整数原样带回来 —— 按值比较
    // 会把"同一个 1 米"判成冲突。解析还顺带强制了恰好三个键的形状。
    if !value["size_intent"].is_null() {
        let echoed = serde_json::from_value::<SizeIntent>(value["size_intent"].clone())
            .map_err(|_| "size_intent_echo_conflict")?;
        if Some(echoed) != job.size_intent {
            return Err("size_intent_echo_conflict");
        }
    }
    if state == "completed" || !value["result"].is_null() {
        let r = &value["result"];
        for key in ["model_url", "interaction_status", "workflow_profile"] {
            if !r[key].is_string() {
                return Err("invalid_response");
            }
        }
        if r["suggested_height_meters"].as_f64().is_none()
            || !r["scale_requires_confirmation"].is_boolean()
            || r["source"] != value["source"]
        {
            return Err("invalid_response");
        }
        for key in ["affordance_candidates", "interaction_bindings"] {
            if !r[key]
                .as_array()
                .is_some_and(|a| a.iter().all(Value::is_string))
            {
                return Err("invalid_response");
            }
        }
        let i = &r["inspection"];
        for key in [
            "bytes",
            "triangles",
            "primitives",
            "materials",
            "accessors",
            "scene_transform_count",
        ] {
            if i[key].as_u64().is_none_or(|n| n > i64::MAX as u64) {
                return Err("invalid_response");
            }
        }
        if !i["sha256"]
            .as_str()
            .is_some_and(|s| s.len() == 64 && s.bytes().all(|c| c.is_ascii_hexdigit()))
            || !i["scale_calibrated"].is_boolean()
            || !i["accessor_bounds"].is_object()
        {
            return Err("invalid_response");
        }
        validate_bounds(&i["bounds"])?;
        for bounds in i["accessor_bounds"]
            .as_object()
            .ok_or("invalid_response")?
            .values()
        {
            validate_bounds(bounds)?;
        }
        if !i["meters_per_model_unit"].is_null() && i["meters_per_model_unit"].as_f64().is_none() {
            return Err("invalid_response");
        }
        // 可选的碰撞代理与权威尺寸。**整块缺失 ⇒ 与今天逐字节一致**（旧服务照常工作）；
        // 出现时做严格的形状+类型校验，任何不合法都返回**专门的错误码**，绝不静默忽略
        // —— 静默忽略会让碰撞形状在用户不知情的情况下从代理退回 yaw 盒子。
        collision_descriptor(r)?;
        authoritative_size(r)?;
        // 意图与权威尺寸并存时不许有两份真相。
        size_intent_agrees_with_authoritative_size(job, r)?;
    }
    Ok(())
}

/// 生成侧给出的**碰撞代理**描述。回执 `result` 上的五个平铺字段。
///
/// 五个字段**要么全在、要么全缺**。部分出现（例如有 `collision_url` 但没
/// `collision_sha256`）是自相矛盾的描述：没有摘要就无法核验下载到的字节，接受它等于
/// 允许一个无法验证的碰撞形状进世界。所以这种情况报 `invalid_collision_descriptor`。
///
/// 类型不合法也报同一个码；`null` 与"键不存在"等价，都算缺失。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CollisionDescriptor {
    pub url: String,
    pub format: String,
    pub sha256: String,
    pub bytes: u64,
    pub triangles: u64,
}

const COLLISION_KEYS: [&str; 5] = [
    "collision_url",
    "collision_format",
    "collision_sha256",
    "collision_bytes",
    "collision_triangles",
];

pub fn collision_descriptor(result: &Value) -> Result<Option<CollisionDescriptor>> {
    let present = COLLISION_KEYS
        .iter()
        .filter(|key| !result[**key].is_null())
        .count();
    if present == 0 {
        return Ok(None);
    }
    if present != COLLISION_KEYS.len() {
        return Err("invalid_collision_descriptor");
    }
    let url = result["collision_url"]
        .as_str()
        .ok_or("invalid_collision_descriptor")?;
    let format = result["collision_format"]
        .as_str()
        .ok_or("invalid_collision_descriptor")?;
    let sha256 = result["collision_sha256"]
        .as_str()
        .ok_or("invalid_collision_descriptor")?;
    let bytes = result["collision_bytes"]
        .as_u64()
        .ok_or("invalid_collision_descriptor")?;
    let triangles = result["collision_triangles"]
        .as_u64()
        .ok_or("invalid_collision_descriptor")?;
    if !COLLISION_FORMATS.contains(&format)
        || sha256.len() != 64
        || !sha256.bytes().all(|c| c.is_ascii_hexdigit())
        || !(1..=COLLIDER_LIMIT as u64).contains(&bytes)
        || !(1..=COLLIDER_TRIANGLE_LIMIT).contains(&triangles)
    {
        return Err("invalid_collision_descriptor");
    }
    Ok(Some(CollisionDescriptor {
        url: url.to_owned(),
        format: format.to_owned(),
        sha256: sha256.to_owned(),
        bytes,
        triangles,
    }))
}

/// 生成侧给出的**权威尺寸与朝向**（回执 `result.authoritative_size`）。
///
/// 存在的意义：app 今天从真实网格量 `size`/`sourceHeight`，于是**换一个生成后端就换一套
/// 轮廓、也就换一套碰撞**。有了这一块，尺寸由生成侧一次说清，app 不再量。
/// 同样是可选的：整块缺失 ⇒ app 继续量（今天的行为）。
#[derive(Clone, Debug, PartialEq)]
pub struct AuthoritativeSize {
    pub dimensions: [f64; 3],
    pub units: String,
    pub up_axis: String,
    pub forward_axis: String,
}

pub fn authoritative_size(result: &Value) -> Result<Option<AuthoritativeSize>> {
    let value = &result["authoritative_size"];
    if value.is_null() {
        return Ok(None);
    }
    let object = value.as_object().ok_or("invalid_authoritative_size")?;
    // 多一个键就是"我们不知道它想要什么"——`deny_unknown_fields` 的等价物。
    if object.len() != 4
        || !["dimensions", "units", "up_axis", "forward_axis"]
            .iter()
            .all(|key| object.contains_key(*key))
    {
        return Err("invalid_authoritative_size");
    }
    let dimensions: Vec<f64> = value["dimensions"]
        .as_array()
        .filter(|a| a.len() == 3)
        .and_then(|a| a.iter().map(|v| v.as_f64()).collect())
        .ok_or("invalid_authoritative_size")?;
    let units = value["units"]
        .as_str()
        .ok_or("invalid_authoritative_size")?;
    let up_axis = value["up_axis"]
        .as_str()
        .ok_or("invalid_authoritative_size")?;
    let forward_axis = value["forward_axis"]
        .as_str()
        .ok_or("invalid_authoritative_size")?;
    if units != AUTHORITATIVE_SIZE_UNITS
        || !UP_AXES.contains(&up_axis)
        || !FORWARD_AXES.contains(&forward_axis)
        || dimensions
            .iter()
            .any(|d| !d.is_finite() || *d <= 0.0 || *d > 100.0)
    {
        return Err("invalid_authoritative_size");
    }
    Ok(Some(AuthoritativeSize {
        dimensions: [dimensions[0], dimensions[1], dimensions[2]],
        units: units.to_owned(),
        up_axis: up_axis.to_owned(),
        forward_axis: forward_axis.to_owned(),
    }))
}

/// 我们发出的**尺寸意图**与生成侧回执里的 `authoritative_size` 必须说同一件事。
///
/// 为什么（app 侧的优先级已经定死：`用户手动 > 尺寸意图 > 工作流权威尺寸 > 自动推断`，
/// 见 `WorldPropLayout.sizeProvenance`/`effectiveSize`）：意图存在时 app 读的是**意图**，
/// 权威尺寸被压到第二。于是两者矛盾时，回执里那个数字**永远不会被任何人看见**，却会被
/// 当成"生成侧确认过"记进资产元数据 —— 那就是两份互相矛盾的真相，而且错的那份是静默的。
/// 所以这里**硬失败**并给出专门的错误码，而不是让 app 自己挑一个信。
///
/// 判据（尺寸与 `up_axis`/`forward_axis` 同一坐标系，单位米）：
/// - `axis == "height"`：上下轴那一维（`up_axis` 只可能是 `±Y` ⇒ `dimensions[1]`）等于意图米数；
/// - `axis == "longest"`：三维里最大的一维等于意图米数。
/// - `mode == "dimensions"`：**逐维**比对 —— `dimensions` 的分量序就是 `[x, y, z]`
///   （与 `millimeters` 的轴序同一套，见 `SizeIntentMillimeters`），每一维都要对上。
///
/// 容差见 [`SIZE_INTENT_SIZE_TOLERANCE`]。
///
/// 老任务（没有意图）与老服务（不发 `authoritative_size`）都不会走到这里 ⇒ 行为不变。
fn size_intent_agrees_with_authoritative_size(job: &Job, result: &Value) -> Result<()> {
    let Some(intent) = job.size_intent else {
        return Ok(());
    };
    let Some(authoritative) = authoritative_size(result)? else {
        return Ok(());
    };
    match intent {
        SizeIntent::Axis(axis) => {
            let measured = match axis.axis {
                SizeIntentAxis::Height => authoritative.dimensions[1],
                SizeIntentAxis::Longest => authoritative
                    .dimensions
                    .iter()
                    .fold(0.0_f64, |longest, edge| longest.max(*edge)),
            };
            if !intent_agrees_with(measured, axis.meters) {
                return Err("authoritative_size_conflicts_with_intent");
            }
        }
        SizeIntent::Dimensions(dimensions) => {
            let millimeters = [
                dimensions.millimeters.x,
                dimensions.millimeters.y,
                dimensions.millimeters.z,
            ];
            for (measured, edge) in authoritative.dimensions.iter().zip(millimeters) {
                if !intent_agrees_with(*measured, edge / 1000.0) {
                    return Err("authoritative_size_conflicts_with_intent");
                }
            }
        }
    }
    Ok(())
}

/// 量到的与说的算不算同一件事。绝对容差兜住 GLB 顶点只有 float32 精度这件事，
/// 相对容差兜住 1.1 m 这种尺寸在毫米级四舍五入后的往返。
fn intent_agrees_with(measured: f64, intended: f64) -> bool {
    (measured - intended).abs() <= SIZE_INTENT_SIZE_TOLERANCE.max(intended.abs() * 1e-3)
}

/// 回执是否**声明**了碰撞代理。调用方用它决定"要不要去下载代理"。
pub fn declares_collision(receipt: &Value) -> Result<bool> {
    Ok(collision_descriptor(&receipt["result"])?.is_some())
}

fn validate_bounds(value: &Value) -> Result<()> {
    for key in ["min", "max"] {
        if !value[key]
            .as_array()
            .is_some_and(|a| a.len() == 3 && a.iter().all(|v| v.as_f64().is_some()))
        {
            return Err("invalid_response");
        }
    }
    if !value["dimensions"].is_null()
        && !value["dimensions"]
            .as_array()
            .is_some_and(|a| a.len() == 3 && a.iter().all(|v| v.as_f64().is_some()))
    {
        return Err("invalid_response");
    }
    for key in ["units", "space"] {
        if !value[key].is_null() && !value[key].is_string() {
            return Err("invalid_response");
        }
    }
    Ok(())
}

/// GLB 容器级核验（magic / version / 声明长度）。`oversized`/`invalid` 由调用方给出，
/// 于是模型与碰撞代理各自保留**原来那套错误码**，不会因为共用一行而改变分类。
fn glb_container(bytes: &[u8], limit: usize, oversized: &'static str, invalid: &'static str) -> Result<()> {
    if bytes.len() > limit {
        return Err(oversized);
    }
    if bytes.len() < 20
        || &bytes[..4] != b"glTF"
        || u32::from_le_bytes(bytes[4..8].try_into().unwrap()) != 2
        || u32::from_le_bytes(bytes[8..12].try_into().unwrap()) as usize != bytes.len()
    {
        return Err(invalid);
    }
    Ok(())
}

pub fn validate_glb(bytes: &[u8], receipt: &Value) -> Result<()> {
    glb_container(bytes, MODEL_LIMIT, "model_too_large", "invalid_glb")?;
    let inspection = &receipt["result"]["inspection"];
    if inspection["bytes"].as_u64() != Some(bytes.len() as u64)
        || inspection["sha256"].as_str() != Some(digest(bytes).as_str())
    {
        return Err("model_integrity_failed");
    }
    Ok(())
}

/// 碰撞代理的核验：**和模型同一条口径**（容器 + 声明 bytes + sha256），只是上限与
/// 审计字段换成 `collision_*` 那一组。回执没声明代理时这里根本不会被调用。
pub fn validate_collider_glb(bytes: &[u8], receipt: &Value) -> Result<()> {
    let collision = collision_descriptor(&receipt["result"])?
        .ok_or("missing_collision_descriptor")?;
    glb_container(
        bytes,
        COLLIDER_LIMIT,
        "collision_too_large",
        "invalid_collision_glb",
    )?;
    if collision.bytes != bytes.len() as u64 || collision.sha256 != digest(bytes) {
        return Err("collision_integrity_failed");
    }
    Ok(())
}
pub fn stage(job: &Job) -> &'static str {
    match job.receipt.as_ref().and_then(|r| r["state"].as_str()) {
        Some("cancelled") => "cancelled",
        Some("failed") => "failed",
        Some("interrupted") => "interrupted",
        Some("completed") if job.cancel_requested => "cancel_requested",
        Some("completed") => "downloading",
        _ if job.cancel_requested => "cancel_requested",
        Some(_) => "running",
        None => "queued",
    }
}

/// Whether the daemon may still do work for this job. Terminal stages release
/// the artifact identity so a fallback retry can claim the same wish again.
pub fn is_active(job: &Job) -> bool {
    !["ready", "cancelled", "failed", "interrupted"].contains(&job.backend_stage.as_str())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn fixture() -> (Job, Value) {
        let job = Job {
            id: uuid::Uuid::new_v4().to_string().to_uppercase(),
            name: "test".into(),
            endpoint: "https://example.invalid".into(),
            image_path: "/tmp/test.png".into(),
            image_sha256: "0".repeat(64),
            height_meters: 0.5,
            size_intent: None,
            source: Source {
                author: "test".into(),
                license: "CC0".into(),
            },
            idempotency_key: "unused".into(),
            receipt: None,
            local_model_path: None,
            local_collision_path: None,
            last_error: None,
            backend_stage: "running".into(),
            cancel_requested: false,
            context: None,
            source_wish_id: None,
            workflow_profile: None,
        };
        let value = json!({"id":"a".repeat(32),"state":"running","reason":null,"name":job.name,"source":job.source,"height_meters":0.5,"compute_may_continue":false,"created_at":1.0,"updated_at":1.0});
        (job, value)
    }
    #[test]
    fn profile_fingerprint_records_every_silhouette_parameter() {
        let profile = GenerationProfile {
            resolution: 512,
            decimation: 200_000,
            texture_size: 2048,
            remesh: true,
        };
        let fingerprint = profile.fingerprint();
        assert_eq!(
            fingerprint,
            "gmgn-mesh-v1;resolution=512;decimation=200000;texture_size=2048;remesh=true"
        );
        assert_eq!(GenerationProfile::parse(&fingerprint).unwrap(), profile);
        // Every parameter is audible in the fingerprint: changing one changes
        // the geometry the artifact was meshed with, so it must change the
        // fingerprint too.
        for changed in [
            GenerationProfile {
                resolution: 513,
                ..profile
            },
            GenerationProfile {
                decimation: 200_001,
                ..profile
            },
            GenerationProfile {
                texture_size: 2049,
                ..profile
            },
            GenerationProfile {
                remesh: false,
                ..profile
            },
        ] {
            assert_ne!(changed.fingerprint(), fingerprint, "{changed:?}");
        }
        // Re-ordered but equivalent fingerprints are still recognised.
        assert_eq!(
            GenerationProfile::parse(
                "gmgn-mesh-v1;remesh=false;texture_size=1024;decimation=50000;resolution=256"
            )
            .unwrap(),
            GenerationProfile {
                resolution: 256,
                decimation: 50_000,
                texture_size: 1024,
                remesh: false,
            }
        );
        for invalid in [
            "",
            "dgx-mesh-v3;resolution=512",
            "gmgn-mesh-v1;resolution=512",
            "gmgn-mesh-v1;resolution=0;decimation=200000;texture_size=2048;remesh=true",
            "gmgn-mesh-v1;resolution=512;resolution=512;decimation=200000;texture_size=2048;remesh=true",
            "gmgn-mesh-v1;resolution=512;decimation=200000;texture_size=2048;remesh=yes",
        ] {
            assert_eq!(
                GenerationProfile::parse(invalid),
                Err("invalid_workflow_profile"),
                "{invalid}"
            );
        }
        assert_eq!(
            GenerationProfile {
                resolution: 8,
                decimation: 200_000,
                texture_size: 2048,
                remesh: true,
            }
            .validate(),
            Err("invalid_generation_profile")
        );
    }

    #[test]
    fn running_receipt_must_not_contain_a_malformed_optional_result() {
        let (job, mut value) = fixture();
        value["result"] = json!("invalid result");
        assert!(receipt(&value, &job).is_err());
    }
    #[test]
    fn endpoints_reject_paths_even_if_url_normalization_removes_them() {
        for endpoint in [
            "https://example.com/a/..",
            "https://example.com/.",
            "https://@example.com",
            "https://exam\nple.com",
        ] {
            assert!(super::endpoint(endpoint).is_err(), "accepted {endpoint:?}");
        }
        assert_eq!(
            super::endpoint("https://EXAMPLE.com/").unwrap(),
            "https://example.com"
        );
    }
    #[test]
    fn receipt_inspection_fields_remain_decodable_by_the_client() {
        let (job, mut value) = fixture();
        value["state"] = json!("completed");
        value["result"] = json!({"model_url":"/v1/jobs/model.glb","interaction_status":"unbound","workflow_profile":"test","source":job.source,"suggested_height_meters":0.5,"scale_requires_confirmation":true,"affordance_candidates":[],"interaction_bindings":[],"inspection":{"sha256":"a".repeat(64),"bytes":24,"triangles":0,"primitives":0,"materials":0,"accessors":0,"scene_transform_count":0,"scale_calibrated":false,"accessor_bounds":{},"bounds":{"min":[0,0,0],"max":[1,1,1]}}});
        assert!(receipt(&value, &job).is_ok());
        for (pointer, invalid) in [
            (
                "/result/inspection/accessor_bounds/0",
                json!("invalid bounds"),
            ),
            (
                "/result/inspection/meters_per_model_unit",
                json!("invalid units"),
            ),
            ("/result/inspection/triangles", json!(u64::MAX)),
        ] {
            let mut broken = value.clone();
            let (parent, key) = pointer.rsplit_once('/').unwrap();
            broken.pointer_mut(parent).unwrap()[key] = invalid;
            assert!(receipt(&broken, &job).is_err(), "accepted {pointer}");
        }
    }

    // ---------------------------------------------------------------------
    // 碰撞代理 / 权威尺寸：**缺失必须逐字节不变、存在必须被采纳、非法必须报专门错误**
    // ---------------------------------------------------------------------

    /// 录制下来的那份回执（`tests/fixtures/remote_http.json`，DGX 服务真实形状：
    /// `workflow_profile` 还是 `dgx-mesh-v3`，**没有任何碰撞字段**）。
    fn recorded() -> Value {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/remote_http.json");
        serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap()
    }

    fn recorded_job(recorded: &Value) -> Job {
        let (mut job, _) = fixture();
        job.name = recorded["job"]["name"].as_str().unwrap().to_owned();
        job.height_meters = recorded["job"]["height_meters"].as_f64().unwrap();
        job.source = Source {
            author: recorded["job"]["source"]["author"].as_str().unwrap().into(),
            license: recorded["job"]["source"]["license"].as_str().unwrap().into(),
        };
        job
    }

    fn collision_block() -> Value {
        json!({
            "collision_url": "/v1/jobs/0123456789abcdef0123456789abcdef/collider.glb",
            "collision_format": "glb-hull",
            "collision_sha256": "b".repeat(64),
            "collision_bytes": 1024,
            "collision_triangles": 512,
        })
    }

    fn size_block() -> Value {
        json!({
            "dimensions": [0.35069498, 0.42, 0.56627256],
            "units": "m",
            "up_axis": "+Y",
            "forward_axis": "-Z",
        })
    }

    /// 断言 1：**字段缺失 ⇒ 与今天逐字节一致**（用录制 fixture 锁住）。
    #[test]
    fn a_receipt_without_collision_fields_behaves_exactly_as_before() {
        let recorded = recorded();
        let job = recorded_job(&recorded);
        let value = recorded["receipt"].clone();
        // 录制的回执照常通过今天那套校验。
        assert_eq!(receipt(&value, &job), Ok(()));
        // 两处可选块都判为"不存在"，而不是"存在但空"。
        assert_eq!(collision_descriptor(&value["result"]), Ok(None));
        assert_eq!(authoritative_size(&value["result"]), Ok(None));
        assert_eq!(declares_collision(&value), Ok(false));
        // job 的序列化里**不得**出现新键：旧客户端读到的 JSON 与改造前逐字节一致。
        assert!(!serde_json::to_string(&job).unwrap().contains("localCollisionPath"));
        assert!(
            !serde_json::to_string(&value)
                .unwrap()
                .contains("collision_url")
        );
        // 旧 job JSON（没有该键）仍然反序列化成 None —— 缺省就是"没有代理"。
        let restored: Job = serde_json::from_str(&serde_json::to_string(&job).unwrap()).unwrap();
        assert_eq!(restored.local_collision_path, None);
        // 显式 null 与"键不存在"等价。
        let mut nulled = value.clone();
        nulled["result"]["collision_url"] = Value::Null;
        assert_eq!(collision_descriptor(&nulled["result"]), Ok(None));
        assert_eq!(receipt(&nulled, &job), Ok(()));
    }

    /// 断言 2：**字段存在 ⇒ 被采纳**，并且能被独立审计（不是只看有没有报错）。
    #[test]
    fn a_receipt_with_a_collision_proxy_and_authoritative_size_is_adopted() {
        let recorded = recorded();
        let job = recorded_job(&recorded);
        let mut value = recorded["receipt"].clone();
        for (key, item) in collision_block().as_object().unwrap() {
            value["result"][key] = item.clone();
        }
        value["result"]["authoritative_size"] = size_block();
        assert_eq!(receipt(&value, &job), Ok(()));
        assert_eq!(declares_collision(&value), Ok(true));
        let parsed = collision_descriptor(&value["result"]).unwrap().unwrap();
        assert_eq!(
            parsed,
            CollisionDescriptor {
                url: "/v1/jobs/0123456789abcdef0123456789abcdef/collider.glb".into(),
                format: "glb-hull".into(),
                sha256: "b".repeat(64),
                bytes: 1024,
                triangles: 512,
            }
        );
        let size = authoritative_size(&value["result"]).unwrap().unwrap();
        assert_eq!(size.units, "m");
        assert_eq!(size.up_axis, "+Y");
        assert_eq!(size.forward_axis, "-Z");
        assert!((size.dimensions[1] - 0.42).abs() < 1e-9);
        // 两个格式都要接受；`glb-decimated` 与 `glb-hull` 的差别只在审计语义。
        value["result"]["collision_format"] = json!("glb-decimated");
        assert_eq!(receipt(&value, &job), Ok(()));
    }

    /// 断言 3：**字段类型/形状非法 ⇒ 专门的错误码，绝不静默忽略**。
    #[test]
    fn a_malformed_collision_block_is_a_named_error_and_never_ignored() {
        let recorded = recorded();
        let job = recorded_job(&recorded);
        // 部分出现（有 url 没 sha256）是自相矛盾的描述：必须报错，不能当成"没有代理"。
        for missing in COLLISION_KEYS {
            let mut value = recorded["receipt"].clone();
            for (key, item) in collision_block().as_object().unwrap() {
                value["result"][key] = item.clone();
            }
            value["result"][missing] = Value::Null;
            assert_eq!(
                receipt(&value, &job),
                Err("invalid_collision_descriptor"),
                "缺少 {missing} 却被接受了"
            );
        }
        // 类型错：数字写成字符串、字符串写成数字、数组长度不对、摘要不是 64 位十六进制、
        // 字节数超上限、三角形数超上限、格式不在白名单里。
        for (key, invalid) in [
            ("collision_url", json!(17)),
            ("collision_format", json!(0)),
            ("collision_sha256", json!(12345)),
            ("collision_bytes", json!("1024")),
            ("collision_triangles", json!("512")),
            ("collision_format", json!("obj-mesh")),
            ("collision_sha256", json!("b".repeat(63))),
            ("collision_sha256", json!("z".repeat(64))),
            ("collision_bytes", json!(0)),
            ("collision_bytes", json!(COLLIDER_LIMIT as u64 + 1)),
            ("collision_triangles", json!(0)),
            ("collision_triangles", json!(COLLIDER_TRIANGLE_LIMIT + 1)),
        ] {
            let mut value = recorded["receipt"].clone();
            for (entry, item) in collision_block().as_object().unwrap() {
                value["result"][entry] = item.clone();
            }
            value["result"][key] = invalid.clone();
            let outcome = receipt(&value, &job);
            assert!(
                outcome.is_err(),
                "{key} = {invalid} 被静默接受了（结果 {outcome:?}）"
            );
            assert_eq!(
                outcome,
                Err("invalid_collision_descriptor"),
                "{key} = {invalid} 的错误码不对"
            );
        }
    }

    /// 断言 3b：权威尺寸的**单位、轴向、数量、有限性**都必须是明确的。
    #[test]
    fn a_malformed_authoritative_size_is_a_named_error() {
        let recorded = recorded();
        let job = recorded_job(&recorded);
        let cases: [(&str, Value); 9] = [
            ("units", json!("cm")),
            ("units", json!(1)),
            ("up_axis", json!("up")),
            ("up_axis", json!(null)),
            ("forward_axis", json!("-W")),
            ("dimensions", json!([1, 2])),
            ("dimensions", json!([1, 2, "3"])),
            ("dimensions", json!([1, 0, 3])),
            ("dimensions", json!([1, 2, 101])),
        ];
        for (key, invalid) in cases {
            let mut value = recorded["receipt"].clone();
            value["result"]["authoritative_size"] = size_block();
            value["result"]["authoritative_size"][key] = invalid.clone();
            assert_eq!(
                receipt(&value, &job),
                Err("invalid_authoritative_size"),
                "authoritative_size.{key} = {invalid} 被接受了"
            );
        }
        // 不是对象、多一个未知键、少一个键都拒绝。
        for invalid in [
            json!("m"),
            json!([]),
            json!({"dimensions":[1,2,3],"units":"m","up_axis":"+Y","forward_axis":"-Z","extra":1}),
            json!({"dimensions":[1,2,3],"units":"m","up_axis":"+Y"}),
        ] {
            let mut value = recorded["receipt"].clone();
            value["result"]["authoritative_size"] = invalid.clone();
            assert_eq!(
                receipt(&value, &job),
                Err("invalid_authoritative_size"),
                "authoritative_size = {invalid} 被接受了"
            );
        }
    }

    /// 断言 4：代理的字节核验与模型**同一条口径**（容器 + 声明 bytes + sha256）。
    #[test]
    fn collider_bytes_are_verified_against_the_declared_digest() {
        let recorded = recorded();
        let glb = base64::engine::general_purpose::STANDARD
            .decode(recorded["glb_base64"].as_str().unwrap())
            .unwrap();
        let mut value = recorded["receipt"].clone();
        let mut block = collision_block();
        block["collision_bytes"] = json!(glb.len() as u64);
        block["collision_sha256"] = json!(digest(&glb));
        for (key, item) in block.as_object().unwrap() {
            value["result"][key] = item.clone();
        }
        assert_eq!(validate_collider_glb(&glb, &value), Ok(()));
        // 少一个字节 / 摘要不符 ⇒ 完整性失败。
        assert_eq!(
            validate_collider_glb(&glb[..glb.len() - 1], &value),
            Err("invalid_collision_glb")
        );
        let mut wrong = value.clone();
        wrong["result"]["collision_sha256"] = json!("c".repeat(64));
        assert_eq!(
            validate_collider_glb(&glb, &wrong),
            Err("collision_integrity_failed")
        );
        // 非 GLB 且长度对不上 ⇒ 容器级失败。
        let mut short = value.clone();
        short["result"]["collision_bytes"] = json!(20);
        assert_eq!(
            validate_collider_glb(&vec![0u8; 20], &short),
            Err("invalid_collision_glb")
        );
        // 没有声明代理时不许"顺便"核验一个代理 —— 那会让调用方以为存在代理。
        let plain = recorded["receipt"].clone();
        assert_eq!(
            validate_collider_glb(&glb, &plain),
            Err("missing_collision_descriptor")
        );
    }

    fn submission_with_intent(intent: Value, height_meters: f64) -> Submit {
        let mut submit = Submit {
            id: uuid::Uuid::new_v4().to_string(),
            endpoint: "https://primary.invalid".into(),
            name: "sword".into(),
            png_base64: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=".into(),
            source: Source { author: "resident".into(), license: "CC0-1.0".into() },
            height_meters,
            size_intent: Some(intent),
            context: None,
            source_wish_id: None,
            generation_profile: None,
        };
        submit.validate().unwrap();
        submit
    }

    /// 断言 1：`size_intent` 的词汇就是契约里那五个字面量，而且**随任务可回读**。
    #[test]
    fn size_intent_round_trips_with_the_contract_vocabulary() {
        assert_eq!(serde_json::to_value(SizeIntentAxis::Longest).unwrap(), json!("longest"));
        assert_eq!(serde_json::to_value(SizeIntentAxis::Height).unwrap(), json!("height"));
        assert_eq!(serde_json::to_value(SizeIntentSource::User).unwrap(), json!("user"));
        assert_eq!(serde_json::to_value(SizeIntentSource::Suggested).unwrap(), json!("suggested"));
        assert_eq!(serde_json::to_value(SizeIntentSource::Default).unwrap(), json!("default"));

        // 用户说的"一把 1.1 米的剑" = 最长边 1.1 m。
        let submit = submission_with_intent(
            json!({"axis": "longest", "meters": 1.1, "source": "user"}),
            1.1,
        );
        assert_eq!(
            submit.parsed_size_intent().unwrap(),
            Some(SizeIntent::Axis(AxisSizeIntent {
                axis: SizeIntentAxis::Longest,
                meters: 1.1,
                source: SizeIntentSource::User,
            }))
        );
        // 兼容别名：snake_case 也认（契约文档里写作 size_intent）。
        let value: Submit = serde_json::from_value(json!({
            "id": uuid::Uuid::new_v4().to_string(),
            "endpoint": "https://primary.invalid",
            "name": "sword",
            "pngBase64": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=",
            "source": {"author": "resident", "license": "CC0-1.0"},
            "heightMeters": 0.35,
            "size_intent": {"axis": "height", "meters": 0.35, "source": "user"},
        }))
        .unwrap();
        assert_eq!(
            value.parsed_size_intent().unwrap().unwrap().axis(),
            Some(SizeIntentAxis::Height)
        );
    }

    /// 断言 2（兼容）：**缺失**意图时序列化出去与今天逐字节一致 —— 键根本不出现。
    #[test]
    fn absent_size_intent_is_byte_identical_to_today() {
        let submit = Submit {
            id: uuid::Uuid::new_v4().to_string(),
            endpoint: "https://primary.invalid".into(),
            name: "cup".into(),
            png_base64: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=".into(),
            source: Source { author: "resident".into(), license: "CC0-1.0".into() },
            height_meters: 0.5,
            size_intent: None,
            context: None,
            source_wish_id: None,
            generation_profile: None,
        };
        assert_eq!(submit.parsed_size_intent(), Ok(None));
        // 显式 null 与缺失同义（老客户端不会发它，新客户端也可能发 null）。
        let mut null_intent = Submit {
            size_intent: Some(Value::Null),
            ..serde_json::from_value(json!({
                "id": uuid::Uuid::new_v4().to_string(),
                "endpoint": "https://primary.invalid",
                "name": "cup",
                "pngBase64": "a",
                "source": {"author": "resident", "license": "CC0-1.0"},
                "heightMeters": 0.5,
            })).unwrap()
        };
        assert_eq!(null_intent.parsed_size_intent(), Ok(None));
        let job = Job {
            id: "A".repeat(32),
            name: "cup".into(),
            endpoint: "https://primary.invalid".into(),
            image_path: "/tmp/cup.png".into(),
            image_sha256: "0".repeat(64),
            height_meters: 0.5,
            size_intent: None,
            source: Source { author: "resident".into(), license: "CC0-1.0".into() },
            idempotency_key: "A".repeat(32),
            receipt: None,
            local_model_path: None,
            local_collision_path: None,
            last_error: None,
            backend_stage: "queued".into(),
            cancel_requested: false,
            context: None,
            source_wish_id: None,
            workflow_profile: None,
        };
        let text = serde_json::to_string(&job).unwrap();
        assert!(!text.contains("sizeIntent") && !text.contains("size_intent"), "{text}");
    }

    /// 断言 4：非法的意图**明确拒绝**，不静默按"没有意图"处理。
    #[test]
    fn illegal_size_intent_is_rejected_with_its_own_code() {
        for (intent, expected) in [
            (json!({"axis": "width", "meters": 1.1, "source": "user"}), "invalid_size_intent"),
            (json!({"axis": "longest", "meters": 1.1, "source": "guess"}), "invalid_size_intent"),
            (json!({"axis": "longest", "meters": -1.0, "source": "user"}), "invalid_size_intent"),
            (json!({"axis": "longest", "meters": 9.0, "source": "user"}), "invalid_size_intent"),
            (json!({"axis": "longest", "meters": 1.1}), "invalid_size_intent"),
            (json!({"axis": "longest", "meters": 1.1, "source": "user", "unit": "m"}), "invalid_size_intent"),
            (json!(["longest", 1.1, "user"]), "invalid_size_intent"),
        ] {
            let mut submit = Submit {
                id: uuid::Uuid::new_v4().to_string(),
                endpoint: "https://primary.invalid".into(),
                name: "sword".into(),
                png_base64: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=".into(),
                source: Source { author: "resident".into(), license: "CC0-1.0".into() },
                height_meters: 1.1,
                size_intent: Some(intent.clone()),
                context: None,
                source_wish_id: None,
                generation_profile: None,
            };
            assert_eq!(submit.validate(), Err(expected), "size_intent = {intent} 被接受了");
        }
    }

    /// 「高 1.1 米」与 `height_meters` 是同一件事：数值不一致就拒绝，不可能留下两份高度。
    #[test]
    fn height_intent_must_agree_with_height_meters() {
        let mut submit = Submit {
            id: uuid::Uuid::new_v4().to_string(),
            endpoint: "https://primary.invalid".into(),
            name: "machine".into(),
            png_base64: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=".into(),
            source: Source { author: "resident".into(), license: "CC0-1.0".into() },
            height_meters: 0.35,
            size_intent: Some(json!({"axis": "height", "meters": 0.5, "source": "user"})),
            context: None,
            source_wish_id: None,
            generation_profile: None,
        };
        assert_eq!(submit.validate(), Err("size_intent_conflict"));
        // 一致就通过（"高 35 厘米的咖啡机"）。
        submit.height_meters = 0.5;
        submit.validate().unwrap();
        assert_eq!(
            submit.parsed_size_intent().unwrap().unwrap().axis(),
            Some(SizeIntentAxis::Height)
        );
    }

    /// **断言（三轴）**：用户给的 `1443 x 862 x 302 mm` 三根轴都进得来、读得回、
    /// 落库字节就是那三个整数（毫秒不换算、不四舍五入、不丢维）。
    ///
    /// 真机现场：用户给的规格是 `1443 x 862 x 302mm`，旧契约只有"一根轴 + 一个米数"，
    /// agent 只能挑一根上报，另外两维在契约里**没有位置** ⇒ 生成器交回一个大立方体。
    #[test]
    fn three_axis_size_intent_round_trips_and_reads_back() {
        assert_eq!(
            serde_json::to_value(SizeIntentMode::Dimensions).unwrap(),
            json!("dimensions")
        );
        let mut submit = submission_with_intent(
            json!({"mode": "dimensions", "millimeters": {"x": 1443, "y": 862, "z": 302}, "source": "user"}),
            0.862,
        );
        let parsed = submit.parsed_size_intent().unwrap().unwrap();
        // 三根轴**逐位**读回：宽 1443 / 高 862 / 深 302（毫米）。
        assert_eq!(parsed.millimeters(), Some([1443.0, 862.0, 302.0]));
        assert_eq!(parsed.source(), SizeIntentSource::User);
        // 三轴形状没有"一根轴"：旧的那个问题在这里是**没有答案**，不是"随便挑一根"。
        assert_eq!(parsed.axis(), None);
        assert_eq!(parsed.required_height_meters(), Some(0.862));
        // 落库/上线的字节：`mode` 是显式形状标签，三个整数原样带着走。
        assert_eq!(
            serde_json::to_string(&parsed).unwrap(),
            r#"{"mode":"dimensions","millimeters":{"x":1443.0,"y":862.0,"z":302.0},"source":"user"}"#
        );
        // 读回来之后再序列化，还是一个合法的提交形状（幂等，不漂）。
        let mut again: Submit = serde_json::from_value(json!({
            "id": uuid::Uuid::new_v4().to_string(),
            "endpoint": "https://primary.invalid",
            "name": "television",
            "pngBase64": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=",
            "source": {"author": "resident", "license": "CC0-1.0"},
            "heightMeters": 0.862,
            "sizeIntent": serde_json::from_str::<Value>(
                &serde_json::to_string(&parsed).unwrap()
            ).unwrap(),
        }))
        .unwrap();
        assert_eq!(again.validate().map(|_| ()), Ok(()));
        assert_eq!(again.parsed_size_intent().unwrap(), Some(parsed));
        // 旧形状的字节与改造前**逐位相同** —— 这一串就是录制 fixture 里的那一份。
        assert_eq!(
            serde_json::to_string(&intent(SizeIntentAxis::Longest, 1.1)).unwrap(),
            r#"{"axis":"longest","meters":1.1,"source":"user"}"#
        );
    }

    /// **断言（兼容）**：三轴形状的存在**不改变**旧形状与"没有意图"的线上字节。
    #[test]
    fn adding_the_three_axis_shape_moves_no_existing_bytes() {
        // ① 没有意图 ⇒ 键根本不出现（老客户端看到的 job JSON 与今天逐字节一致）。
        let mut bare: Submit = serde_json::from_value(json!({
            "id": uuid::Uuid::new_v4().to_string(),
            "endpoint": "https://primary.invalid",
            "name": "cup",
            "pngBase64": "a",
            "source": {"author": "resident", "license": "CC0-1.0"},
            "heightMeters": 0.5,
        }))
        .unwrap();
        assert_eq!(bare.parsed_size_intent(), Ok(None));
        // ② 旧形状的三种轴/出处组合都还是老字节（多了个 enum 包装，线格式一个字节没动）。
        for (parsed, text) in [
            (
                intent(SizeIntentAxis::Longest, 1.1),
                r#"{"axis":"longest","meters":1.1,"source":"user"}"#,
            ),
            (
                SizeIntent::Axis(AxisSizeIntent {
                    axis: SizeIntentAxis::Height,
                    meters: 0.35,
                    source: SizeIntentSource::Suggested,
                }),
                r#"{"axis":"height","meters":0.35,"source":"suggested"}"#,
            ),
        ] {
            assert_eq!(serde_json::to_string(&parsed).unwrap(), text);
            // 反向也一样：老字节解出来就是那一位，没有"顺手补个 mode"这种事。
            assert_eq!(
                serde_json::from_str::<SizeIntent>(text).unwrap(),
                parsed
            );
        }
        // ③ 三轴形状**不会被**解成旧形状（`deny_unknown_fields` 守住了形状边界）。
        assert!(serde_json::from_str::<AxisSizeIntent>(
            r#"{"mode":"dimensions","millimeters":{"x":1,"y":2,"z":3},"source":"user"}"#
        )
        .is_err());
        // ④ 提交里带了 `size_intent`（旧形状）时，序列化出去的 job JSON 与录制 fixture 一致。
        bare.size_intent = Some(json!({"axis": "longest", "meters": 1.1, "source": "user"}));
        assert_eq!(
            serde_json::to_string(&bare.parsed_size_intent().unwrap().unwrap()).unwrap(),
            r#"{"axis":"longest","meters":1.1,"source":"user"}"#
        );
    }

    /// **断言（冲突）**：两种形状**同时给** ⇒ 具名 `size_intent_shape_conflict`，
    /// 不是笼统的 `invalid_size_intent`，更不是"挑一份信"。
    #[test]
    fn giving_both_size_shapes_is_a_named_conflict() {
        for both in [
            json!({"axis": "longest", "meters": 1.443, "mode": "dimensions",
                   "millimeters": {"x": 1443, "y": 862, "z": 302}, "source": "user"}),
            // 只给 `meters`（轴的伴生字段）也算旧形状出现了一半。
            json!({"meters": 1.443, "mode": "dimensions",
                   "millimeters": {"x": 1443, "y": 862, "z": 302}, "source": "user"}),
        ] {
            let mut submit = Submit {
                id: uuid::Uuid::new_v4().to_string(),
                endpoint: "https://primary.invalid".into(),
                name: "television".into(),
                png_base64: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=".into(),
                source: Source { author: "resident".into(), license: "CC0-1.0".into() },
                height_meters: 0.862,
                size_intent: Some(both.clone()),
                context: None,
                source_wish_id: None,
                generation_profile: None,
            };
            assert_eq!(
                submit.validate(),
                Err("size_intent_shape_conflict"),
                "两种形状同时给没有被具名拒绝：{both}"
            );
            // 解析这一层同样具名（不是"解析失败"）。
            assert_eq!(submit.parsed_size_intent(), Err("size_intent_shape_conflict"));
        }
    }

    /// **断言（越界/畸形）**：三轴里任何一根不是正有限数、或不在 `10–3000 mm`
    /// （= 旧契约 `0.01–3 m` 的同一条边界）⇒ 具名 `invalid_size_intent`，绝不静默、绝不夹取。
    #[test]
    fn illegal_three_axis_intents_are_named_rejections() {
        for illegal in [
            // 缺一根轴：另外两维"默认成什么"都是猜，所以根本不接受。
            json!({"mode": "dimensions", "millimeters": {"x": 1443, "y": 862}, "source": "user"}),
            json!({"mode": "dimensions", "millimeters": {"x": 1443, "z": 302}, "source": "user"}),
            json!({"mode": "dimensions", "millimeters": {"x": 1443, "y": 862, "z": 302}}),
            // 零 / 负 / 非有限。
            json!({"mode": "dimensions", "millimeters": {"x": 0, "y": 862, "z": 302}, "source": "user"}),
            json!({"mode": "dimensions", "millimeters": {"x": 1443, "y": -862, "z": 302}, "source": "user"}),
            json!({"mode": "dimensions", "millimeters": {"x": 1443, "y": 862, "z": "302"}, "source": "user"}),
            json!({"mode": "dimensions", "millimeters": {"x": true, "y": 862, "z": 302}, "source": "user"}),
            // 越界：低于 10 mm / 高于 3000 mm（两端都是**闭**区间的外侧一格）。
            json!({"mode": "dimensions", "millimeters": {"x": 9.999, "y": 862, "z": 302}, "source": "user"}),
            json!({"mode": "dimensions", "millimeters": {"x": 1443, "y": 862, "z": 3000.001}, "source": "user"}),
            // 形状本身不对：mode 值不认识 / 缺 mode / 多未知键 / 不是对象。
            json!({"mode": "axes", "millimeters": {"x": 1443, "y": 862, "z": 302}, "source": "user"}),
            json!({"millimeters": {"x": 1443, "y": 862, "z": 302}, "source": "user"}),
            json!({"mode": "dimensions", "millimeters": {"x": 1443, "y": 862, "z": 302, "w": 1}, "source": "user"}),
            json!({"mode": "dimensions", "millimeters": {"x": 1443, "y": 862, "z": 302}, "source": "user", "unit": "mm"}),
            json!({"mode": "dimensions", "millimeters": [1443, 862, 302], "source": "user"}),
            json!({"mode": "dimensions", "millimeters": {"x": 1443, "y": 862, "z": 302}, "source": "guess"}),
            // 一句话里说不清是哪一种形状：既没有 mode 也没有 axis。
            json!({"x": 1443, "y": 862, "z": 302, "source": "user"}),
        ] {
            let mut submit = Submit {
                id: uuid::Uuid::new_v4().to_string(),
                endpoint: "https://primary.invalid".into(),
                name: "television".into(),
                png_base64: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=".into(),
                source: Source { author: "resident".into(), license: "CC0-1.0".into() },
                height_meters: 0.862,
                size_intent: Some(illegal.clone()),
                context: None,
                source_wish_id: None,
                generation_profile: None,
            };
            assert_eq!(
                submit.validate(),
                Err("invalid_size_intent"),
                "非法三轴意图被接受了：{illegal}"
            );
        }
        // 两个端点（闭区间）都得过 —— 拒绝的边界不能宽到把合法尺寸也扫掉。
        for ok in [
            json!({"mode": "dimensions", "millimeters": {"x": 10, "y": 862, "z": 302}, "source": "user"}),
            json!({"mode": "dimensions", "millimeters": {"x": 1443, "y": 862, "z": 3000}, "source": "user"}),
        ] {
            let mut submit = submission_with_intent(ok.clone(), 0.862);
            assert!(submit.validate().is_ok(), "闭区间端点被拒了：{ok}");
        }
    }

    /// 三轴的 `y`（高）与 `height_meters` 是同一件事 ⇒ 不一致就 `size_intent_conflict`，
    /// 与旧形状 `axis == "height"` 是**同一条**判据。
    #[test]
    fn three_axis_height_must_agree_with_height_meters() {
        let mut submit = submission_with_intent(
            json!({"mode": "dimensions", "millimeters": {"x": 1443, "y": 862, "z": 302}, "source": "user"}),
            0.862,
        );
        submit.validate().unwrap();
        submit.height_meters = 0.86;
        assert_eq!(submit.validate(), Err("size_intent_conflict"));
        submit.height_meters = 0.9;
        assert_eq!(submit.validate(), Err("size_intent_conflict"));
    }

    /// 三轴意图**从不**发给远端：线上那个键只有"一根轴 + 一个米数"这一种形状，
    /// 而服务端严格拒绝未知键 ⇒ 发过去就是 400、整件任务失败。
    /// 归一在 app 侧做，远端拿到的仍然只有 `height_meters`。
    #[test]
    fn a_three_axis_intent_is_never_declared_as_forwardable() {
        let both = support(
            &[SizeIntentAxis::Longest, SizeIntentAxis::Height],
            0.01,
            3.0,
            SizeIntentApplies::Normalize,
        );
        assert!(both.accepts(&intent(SizeIntentAxis::Longest, 1.1)));
        assert!(
            !both.accepts(&SizeIntent::Dimensions(DimensionsSizeIntent {
                mode: SizeIntentMode::Dimensions,
                millimeters: SizeIntentMillimeters { x: 1443.0, y: 862.0, z: 302.0 },
                source: SizeIntentSource::User,
            })),
            "三轴意图被当成可以发给远端的了 —— 那会让整件任务 400"
        );
    }

    /// 生成侧回执的 `authoritative_size` 与三轴意图必须**逐维**说同一件事。
    #[test]
    fn authoritative_size_must_match_all_three_axes() {
        let recorded = recorded();
        let base = recorded_job(&recorded);
        let mut value = recorded["receipt"].clone();
        value["result"]["authoritative_size"] = size_block(); // dims = [0.5?, 0.42, ...]

        let dims = authoritative_size(&value["result"]).unwrap().unwrap().dimensions;
        let millimeters = [
            (dims[0] * 1000.0).round(),
            (dims[1] * 1000.0).round(),
            (dims[2] * 1000.0).round(),
        ];
        // 照实说 ⇒ 通过。
        let mut job = base.clone();
        job.size_intent = Some(SizeIntent::Dimensions(DimensionsSizeIntent {
            mode: SizeIntentMode::Dimensions,
            millimeters: SizeIntentMillimeters {
                x: millimeters[0],
                y: millimeters[1],
                z: millimeters[2],
            },
            source: SizeIntentSource::User,
        }));
        assert_eq!(receipt(&value, &job), Ok(()));
        // 任何**一维**被改掉（其它两维都对）⇒ 硬失败，不给"差不多就算同一件事"的余地。
        for wrong in 0..3 {
            let mut edges = millimeters;
            edges[wrong] += 1.0;
            job.size_intent = Some(SizeIntent::Dimensions(DimensionsSizeIntent {
                mode: SizeIntentMode::Dimensions,
                millimeters: SizeIntentMillimeters { x: edges[0], y: edges[1], z: edges[2] },
                source: SizeIntentSource::User,
            }));
            assert_eq!(
                receipt(&value, &job),
                Err("authoritative_size_conflicts_with_intent"),
                "第 {wrong} 维对不上却没有被判冲突"
            );
        }
        // 没有权威尺寸（老服务）⇒ 三轴意图也不受影响。
        let mut value_without = value.clone();
        value_without["result"]
            .as_object_mut()
            .unwrap()
            .remove("authoritative_size");
        job.size_intent = Some(SizeIntent::Dimensions(DimensionsSizeIntent {
            mode: SizeIntentMode::Dimensions,
            millimeters: SizeIntentMillimeters { x: 1.0, y: 2.0, z: 3.0 },
            source: SizeIntentSource::User,
        }));
        assert_eq!(receipt(&value_without, &job), Ok(()));
    }

    fn intent(axis: SizeIntentAxis, meters: f64) -> SizeIntent {
        SizeIntent::Axis(AxisSizeIntent {
            axis,
            meters,
            source: SizeIntentSource::User,
        })
    }

    fn support(axes: &[SizeIntentAxis], min: f64, max: f64, applies: SizeIntentApplies) -> SizeIntentSupport {
        SizeIntentSupport {
            axes: axes.to_vec(),
            min_meters: min,
            max_meters: max,
            applies,
        }
    }

    /// 能力声明是**唯一的发送闸门**：轴要在清单里、米数要落在闭区间里。任何一条不过就是
    /// "不发这个键"——不是"提交失败"，也不是"照发然后让服务端 400"。
    #[test]
    fn a_declaration_only_accepts_the_axes_and_the_range_it_names() {
        let both = support(
            &[SizeIntentAxis::Longest, SizeIntentAxis::Height],
            0.01,
            3.0,
            SizeIntentApplies::Normalize,
        );
        assert!(both.accepts(&intent(SizeIntentAxis::Longest, 1.1)));
        assert!(both.accepts(&intent(SizeIntentAxis::Height, 0.42)));
        // 区间是闭的：两个端点都算收得下。
        assert!(both.accepts(&intent(SizeIntentAxis::Longest, 0.01)));
        assert!(both.accepts(&intent(SizeIntentAxis::Longest, 3.0)));
        assert!(!both.accepts(&intent(SizeIntentAxis::Longest, 0.009)));
        assert!(!both.accepts(&intent(SizeIntentAxis::Longest, 3.001)));

        // 只声明一根轴：另一根一发就会 400，所以**不能**发。
        let only_height = support(
            &[SizeIntentAxis::Height],
            0.01,
            3.0,
            SizeIntentApplies::Echo,
        );
        assert!(only_height.accepts(&intent(SizeIntentAxis::Height, 1.1)));
        assert!(!only_height.accepts(&intent(SizeIntentAxis::Longest, 1.1)));

        // 窄区间同理：声明 0.2–0.8 就不许发 1.1。
        let narrow = support(
            &[SizeIntentAxis::Longest],
            0.2,
            0.8,
            SizeIntentApplies::Normalize,
        );
        assert!(narrow.accepts(&intent(SizeIntentAxis::Longest, 0.5)));
        assert!(!narrow.accepts(&intent(SizeIntentAxis::Longest, 1.1)));

        // 空清单 / 自相矛盾的区间：一份坏声明不能被当成"随便发"。
        assert!(!support(&[], 0.01, 3.0, SizeIntentApplies::Normalize)
            .accepts(&intent(SizeIntentAxis::Longest, 1.1)));
        assert!(!support(
            &[SizeIntentAxis::Longest],
            0.8,
            0.2,
            SizeIntentApplies::Normalize
        )
        .accepts(&intent(SizeIntentAxis::Longest, 0.5)));
        assert!(!support(
            &[SizeIntentAxis::Longest],
            f64::NAN,
            3.0,
            SizeIntentApplies::Normalize
        )
        .accepts(&intent(SizeIntentAxis::Longest, 0.5)));
    }

    /// 声明本身的形状：`deny_unknown_fields` + 三根轴的词汇 + 语义必写。
    #[test]
    fn the_size_intent_declaration_is_strict_about_its_own_shape() {
        // 完整声明解析成契约里的那一份。
        assert_eq!(
            serde_json::from_value::<SizeIntentSupport>(json!({
                "axes": ["height", "longest"],
                "min_meters": 0.01,
                "max_meters": 3.0,
                "applies": "echo",
            }))
            .unwrap(),
            support(
                &[SizeIntentAxis::Height, SizeIntentAxis::Longest],
                0.01,
                3.0,
                SizeIntentApplies::Echo
            )
        );
        // 未知键、未知轴、未知语义、缺字段、类型错 —— 一律拒收。**绝不**降级成"能力很强"：
        // 把"只回显"读成"已归一"会让 app 不再缩放，产物直接错尺寸。
        for block in [
            json!({"axes": ["height"], "min_meters": 0.01, "max_meters": 3.0, "applies": "echo", "unit": "m"}),
            json!({"axes": ["width"], "min_meters": 0.01, "max_meters": 3.0, "applies": "echo"}),
            json!({"axes": ["height"], "min_meters": 0.01, "max_meters": 3.0, "applies": "maybe"}),
            json!({"axes": ["height"], "min_meters": 0.01, "max_meters": 3.0, "applies": "normalize", "normalizes": true}),
            json!({"axes": ["height"], "min_meters": 0.01, "max_meters": 3.0}),
            json!({"axes": "height", "min_meters": 0.01, "max_meters": 3.0, "applies": "echo"}),
            json!({"axes": [1], "min_meters": 0.01, "max_meters": 3.0, "applies": "echo"}),
            json!("yes"),
            json!(["height"]),
            json!(null),
        ] {
            assert!(
                serde_json::from_value::<SizeIntentSupport>(block.clone()).is_err(),
                "{block} 被接受了"
            );
        }
    }

    /// 断言（任务书第 3 条）：意图与生成侧的 `authoritative_size` **并存时不许有两份真相**。
    ///
    /// app 的优先级是 `手动 > 意图 > 权威 > 自动推断`，意图在时权威尺寸被压到第二 ——
    /// 于是矛盾的那一份永远不会被看见，却会被记进资产元数据。所以这里硬失败。
    #[test]
    fn authoritative_size_must_say_the_same_thing_as_the_intent() {
        let recorded = recorded();
        let base = recorded_job(&recorded);
        let mut value = recorded["receipt"].clone();
        value["result"]["authoritative_size"] = size_block(); // Y=0.42, longest≈0.56627256

        // `axis == "height"`：比上下轴那一维。
        let mut job = base.clone();
        job.size_intent = Some(intent(SizeIntentAxis::Height, 0.42));
        assert_eq!(receipt(&value, &job), Ok(()));
        job.size_intent = Some(intent(SizeIntentAxis::Height, 0.5));
        assert_eq!(
            receipt(&value, &job),
            Err("authoritative_size_conflicts_with_intent")
        );

        // `axis == "longest"`：比三维里最大的一维（0.56627256，不是 0.42）。
        let mut job = base.clone();
        job.size_intent = Some(intent(SizeIntentAxis::Longest, 0.56627256));
        assert_eq!(receipt(&value, &job), Ok(()));
        job.size_intent = Some(intent(SizeIntentAxis::Longest, 0.42));
        assert_eq!(
            receipt(&value, &job),
            Err("authoritative_size_conflicts_with_intent"),
            "最长边不能拿 Y 那一维顶替"
        );

        // 容差：float32 顶点 + 服务端四舍五入到毫米都要过得去，但 1 mm 以上的差不行。
        let mut job = base.clone();
        job.size_intent = Some(intent(SizeIntentAxis::Height, 0.4204));
        assert_eq!(receipt(&value, &job), Ok(()));
        job.size_intent = Some(intent(SizeIntentAxis::Height, 0.4220));
        assert_eq!(
            receipt(&value, &job),
            Err("authoritative_size_conflicts_with_intent")
        );

        // 老任务（没有意图）与老服务（没有权威尺寸）都不受影响。
        let mut job = base.clone();
        job.size_intent = None;
        assert_eq!(receipt(&value, &job), Ok(()));
        let mut value_without = value.clone();
        value_without["result"]
            .as_object_mut()
            .unwrap()
            .remove("authoritative_size");
        job.size_intent = Some(intent(SizeIntentAxis::Height, 0.99));
        assert_eq!(receipt(&value_without, &job), Ok(()));

        // 权威尺寸本身不合法时仍然是它自己的错误码，不会先报冲突。
        value["result"]["authoritative_size"] = json!({"dimensions": [1.0], "units": "m", "up_axis": "+Y", "forward_axis": "-Z"});
        assert_eq!(
            receipt(&value, &job),
            Err("invalid_authoritative_size")
        );
    }

    /// 回执**回显**的意图要么不在，要么逐字段等于我们发出去的那一份。
    #[test]
    fn an_echoed_intent_must_match_what_we_sent() {
        let recorded = recorded();
        let mut job = recorded_job(&recorded);
        let mut value = recorded["receipt"].clone();
        let sent = intent(SizeIntentAxis::Longest, 1.1);
        job.size_intent = Some(sent);

        // 不回显 ⇒ 不是冲突（不是每个服务端都回显，老服务照常工作）。
        assert_eq!(receipt(&value, &job), Ok(()));
        // 原样回显 ⇒ 同一件事，两份数据一个值。
        value["size_intent"] = serde_json::to_value(sent).unwrap();
        assert_eq!(receipt(&value, &job), Ok(()));
        // 整数写法与浮点写法是**同一个米数**：`1` 与 `1.0` 不能被判成冲突
        // （服务端是 Python，会把调用方写的整数原样带回来）。
        job.size_intent = Some(intent(SizeIntentAxis::Longest, 1.0));
        value["size_intent"] = json!({"axis": "longest", "meters": 1, "source": "user"});
        assert_eq!(receipt(&value, &job), Ok(()));
        value["size_intent"] = json!({"axis": "longest", "meters": 1.0, "source": "user"});
        assert_eq!(receipt(&value, &job), Ok(()));
        job.size_intent = Some(sent);
        value["size_intent"] = serde_json::to_value(sent).unwrap();
        // 米数被改 / 轴被改 / 出处被改 ⇒ 服务端记下的不是我们要的，收下就是两套尺寸。
        for wrong in [
            json!({"axis": "longest", "meters": 1.2, "source": "user"}),
            json!({"axis": "height", "meters": 1.1, "source": "user"}),
            json!({"axis": "longest", "meters": 1.1, "source": "default"}),
            json!({"axis": "longest", "meters": 1.1}),
            json!("1.1m"),
        ] {
            value["size_intent"] = wrong.clone();
            assert_eq!(
                receipt(&value, &job),
                Err("size_intent_echo_conflict"),
                "回显 {wrong} 被接受了"
            );
        }
        // 我们**没有**发过意图，服务端却回显了一个 ⇒ 那是它替我们编的，同样不接受。
        value["size_intent"] = serde_json::to_value(sent).unwrap();
        job.size_intent = None;
        assert_eq!(receipt(&value, &job), Err("size_intent_echo_conflict"));
        // 显式 null 与"键不存在"等价。
        value["size_intent"] = Value::Null;
        assert_eq!(receipt(&value, &job), Ok(()));
    }
}
