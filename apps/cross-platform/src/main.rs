use bevy::{
    app::AppExit, input::mouse::AccumulatedMouseMotion, prelude::*,
    render::renderer::RenderAdapterInfo,
};
use serde::Serialize;
use std::{path::PathBuf, time::Instant};

#[derive(Resource, Default)]
struct Options {
    headless: bool,
    benchmark: Option<f64>,
    report: Option<PathBuf>,
    scene: Option<String>,
}
impl Options {
    fn parse() -> Result<Self, String> {
        let mut result = Self::default();
        let mut args = std::env::args().skip(1);
        while let Some(arg) = args.next() {
            match arg.as_str() {
                "--headless-smoke" => result.headless = true,
                "--benchmark-seconds" => {
                    let seconds: f64 = args.next().ok_or("missing duration")?.parse().map_err(|_| "invalid duration")?;
                    if !seconds.is_finite() || seconds <= 0.0 { return Err("duration must be positive and finite".into()); }
                    result.benchmark = Some(seconds);
                }
                "--report" => result.report = Some(args.next().ok_or("missing report path")?.into()),
                "--scene" => result.scene = Some(args.next().ok_or("missing GLB path")?),
                "--help" => return Err("Usage: gmgn-cross-platform [--headless-smoke] [--benchmark-seconds N --report PATH] [--scene GLB_PATH]\nWASD: resident movement; Space: grounded action; right drag: camera orbit; arrows: camera orbit; Escape: quit".into()),
                _ => return Err(format!("unknown option: {arg}")),
            }
        }
        Ok(result)
    }
}

#[derive(Component)]
struct Resident;
#[derive(Component)]
struct OrbitCamera;
#[derive(Resource)]
struct Orbit {
    yaw: f32,
    pitch: f32,
    radius: f32,
}
impl Default for Orbit {
    fn default() -> Self {
        Self {
            yaw: 0.5,
            pitch: 0.35,
            radius: 8.0,
        }
    }
}
#[derive(Resource)]
struct Metrics {
    started: Instant,
    previous: Instant,
    samples: Vec<f64>,
    adapter: Option<String>,
}
impl Default for Metrics {
    fn default() -> Self {
        let now = Instant::now();
        Self {
            started: now,
            previous: now,
            samples: vec![],
            adapter: None,
        }
    }
}

fn main() {
    let options = match Options::parse() {
        Ok(value) => value,
        Err(message) => {
            eprintln!("{message}");
            std::process::exit(if std::env::args().any(|arg| arg == "--help") {
                0
            } else {
                2
            });
        }
    };
    if options.headless {
        headless_smoke();
        return;
    }
    let mut app = App::new();
    app.insert_resource(options)
        .insert_resource(ClearColor(Color::srgb(0.045, 0.055, 0.075)))
        .init_resource::<Orbit>()
        .init_resource::<Metrics>()
        .add_plugins(DefaultPlugins.set(WindowPlugin {
            primary_window: Some(Window {
                title: "GMGN · Cross-platform fixture".into(),
                resolution: (1280, 800).into(),
                ..default()
            }),
            ..default()
        }))
        .add_systems(Startup, (setup, reset_metrics).chain())
        .add_systems(Update, (controls, measure));
    app.run();
}

fn setup(
    mut commands: Commands,
    mut meshes: ResMut<Assets<Mesh>>,
    mut materials: ResMut<Assets<StandardMaterial>>,
    assets: Res<AssetServer>,
    options: Res<Options>,
) {
    let floor = materials.add(Color::srgb(0.22, 0.25, 0.30));
    let wall = materials.add(Color::srgb(0.38, 0.43, 0.49));
    let body = materials.add(Color::srgb(0.90, 0.49, 0.23));
    let frame = materials.add(Color::srgb(0.035, 0.04, 0.05));
    let screen = materials.add(StandardMaterial {
        base_color: Color::srgb(0.12, 0.23, 0.30),
        unlit: true,
        ..default()
    });
    for (size, position, material) in [
        (
            Vec3::new(10.0, 0.1, 10.0),
            Vec3::new(0.0, -0.05, 0.0),
            floor,
        ),
        (
            Vec3::new(10.0, 3.0, 0.1),
            Vec3::new(0.0, 1.5, -5.0),
            wall.clone(),
        ),
        (Vec3::new(0.1, 3.0, 10.0), Vec3::new(-5.0, 1.5, 0.0), wall),
        (Vec3::new(3.2, 1.9, 0.20), Vec3::new(0.0, 1.7, -3.0), frame),
        (
            Vec3::new(3.0, 1.7, 0.01),
            Vec3::new(0.0, 1.7, -2.89),
            screen,
        ),
    ] {
        commands.spawn((
            Mesh3d(meshes.add(Cuboid::from_size(size))),
            MeshMaterial3d(material),
            Transform::from_translation(position),
        ));
    }
    commands.spawn((
        Resident,
        Mesh3d(meshes.add(Capsule3d::new(0.3, 0.8))),
        MeshMaterial3d(body),
        Transform::from_xyz(0.0, 0.7, 0.0),
    ));
    commands.spawn((
        DirectionalLight {
            illuminance: 7000.0,
            ..default()
        },
        Transform::from_xyz(2.0, 6.0, 3.0).looking_at(Vec3::ZERO, Vec3::Y),
    ));
    commands.spawn((
        OrbitCamera,
        Camera3d::default(),
        Transform::from_xyz(4.0, 4.0, 7.0).looking_at(Vec3::Y, Vec3::Y),
    ));
    commands.spawn((Text::new("FIXTURE · no authority / no media playback\nWASD move · Space grounded action · Right-drag / arrows orbit · Esc exit"), TextFont { font_size: FontSize::Px(18.0), ..default() }, Node { position_type: PositionType::Absolute, top: px(16), left: px(16), ..default() }));
    if let Some(path) = &options.scene {
        commands.spawn((
            WorldAssetRoot(assets.load(GltfAssetLabel::Scene(0).from_asset(path.clone()))),
            Transform::from_xyz(2.0, 0.0, 0.0),
        ));
    }
}

fn reset_metrics(mut metrics: ResMut<Metrics>) {
    let now = Instant::now();
    metrics.started = now;
    metrics.previous = now;
}

fn grounded_move(position: Vec3, direction: Vec3, seconds: f32) -> Vec3 {
    let horizontal = Vec3::new(direction.x, 0.0, direction.z);
    let mut result = position + horizontal.normalize_or_zero() * 2.5 * seconds;
    result.x = result.x.clamp(-4.5, 4.5);
    result.z = result.z.clamp(-4.5, 4.5);
    result.y = 0.7;
    result
}
fn controls(
    keys: Res<ButtonInput<KeyCode>>,
    buttons: Res<ButtonInput<MouseButton>>,
    motion: Res<AccumulatedMouseMotion>,
    time: Res<Time>,
    mut orbit: ResMut<Orbit>,
    mut cameras: Query<&mut Transform, (With<OrbitCamera>, Without<Resident>)>,
    mut residents: Query<&mut Transform, With<Resident>>,
    mut exit: MessageWriter<AppExit>,
) {
    if keys.just_pressed(KeyCode::Escape) {
        exit.write(AppExit::Success);
    }
    let dt = time.delta_secs().min(0.05);
    let axis = |positive, negative| {
        u8::from(keys.pressed(positive)) as f32 - u8::from(keys.pressed(negative)) as f32
    };
    for mut resident in &mut residents {
        resident.translation = grounded_move(
            resident.translation,
            Vec3::new(
                axis(KeyCode::KeyD, KeyCode::KeyA),
                0.0,
                axis(KeyCode::KeyS, KeyCode::KeyW),
            ),
            dt,
        );
        resident.rotation = if keys.pressed(KeyCode::Space) {
            Quat::from_rotation_y(time.elapsed_secs().sin() * 0.5)
        } else {
            Quat::IDENTITY
        };
    }
    orbit.yaw += axis(KeyCode::ArrowRight, KeyCode::ArrowLeft) * dt;
    orbit.pitch += axis(KeyCode::ArrowUp, KeyCode::ArrowDown) * dt;
    if buttons.pressed(MouseButton::Right) {
        orbit.yaw -= motion.delta.x * 0.005;
        orbit.pitch += motion.delta.y * 0.005;
    }
    orbit.pitch = orbit.pitch.clamp(0.1, 1.3);
    for mut camera in &mut cameras {
        *camera = Transform::from_translation(
            Vec3::Y
                + Vec3::new(
                    orbit.yaw.sin() * orbit.pitch.cos(),
                    orbit.pitch.sin(),
                    orbit.yaw.cos() * orbit.pitch.cos(),
                ) * orbit.radius,
        )
        .looking_at(Vec3::Y, Vec3::Y);
    }
}

#[derive(Serialize)]
struct Report {
    schema_version: u32,
    scenario: &'static str,
    backend_adapter: Option<String>,
    frame_count: usize,
    elapsed_seconds: f64,
    warmup_seconds: f64,
    p50_ms: f64,
    p95_ms: f64,
    p99_ms: f64,
    frames_over_33ms: usize,
    frames_over_50ms: usize,
    mesh_entities: usize,
    imported_scene: Option<String>,
    limitations: &'static str,
}
fn percentile(samples: &[f64], quantile: f64) -> f64 {
    if samples.is_empty() {
        return 0.0;
    }
    let mut sorted = samples.to_vec();
    sorted.sort_by(f64::total_cmp);
    sorted[((sorted.len() - 1) as f64 * quantile).round() as usize]
}
fn measure(
    options: Res<Options>,
    adapter: Option<Res<RenderAdapterInfo>>,
    meshes: Query<(), With<Mesh3d>>,
    mut metrics: ResMut<Metrics>,
    mut exit: MessageWriter<AppExit>,
) {
    if metrics.adapter.is_none() {
        if let Some(adapter) = adapter {
            let value = format!(
                "{} / {:?} / {:?}",
                adapter.name, adapter.backend, adapter.device_type
            );
            println!("Actual GPU adapter: {value}");
            metrics.adapter = Some(value);
        }
    }
    let now = Instant::now();
    let elapsed = now.duration_since(metrics.started).as_secs_f64();
    let delta = now.duration_since(metrics.previous).as_secs_f64() * 1000.0;
    metrics.previous = now;
    if elapsed > 2.0 {
        metrics.samples.push(delta);
    }
    if let Some(duration) = options.benchmark {
        if elapsed >= duration + 2.0 {
            let report = Report {
                schema_version: 1,
                scenario: "minimal_room_fixture",
                backend_adapter: metrics.adapter.clone(),
                frame_count: metrics.samples.len(),
                elapsed_seconds: elapsed,
                warmup_seconds: 2.0,
                p50_ms: percentile(&metrics.samples, 0.5),
                p95_ms: percentile(&metrics.samples, 0.95),
                p99_ms: percentile(&metrics.samples, 0.99),
                frames_over_33ms: metrics
                    .samples
                    .iter()
                    .filter(|value| **value > 33.0)
                    .count(),
                frames_over_50ms: metrics
                    .samples
                    .iter()
                    .filter(|value| **value > 50.0)
                    .count(),
                mesh_entities: meshes.iter().count(),
                imported_scene: options.scene.clone(),
                limitations: "CPU app-update cadence, not GPU timestamps or full application performance; media/UI/real avatars absent; imported asset readiness not asserted",
            };
            let json = serde_json::to_string_pretty(&report).expect("serialize report");
            println!("{json}");
            if let Some(path) = &options.report {
                if let Err(error) = std::fs::write(path, json) {
                    eprintln!("report write failed: {error}");
                    exit.write(AppExit::error());
                    return;
                }
            }
            exit.write(AppExit::Success);
        }
    }
}
fn headless_smoke() {
    let mut app = App::new();
    app.add_plugins(MinimalPlugins)
        .init_resource::<ButtonInput<KeyCode>>()
        .init_resource::<ButtonInput<MouseButton>>()
        .init_resource::<AccumulatedMouseMotion>()
        .init_resource::<Orbit>()
        .insert_resource(bevy::time::TimeUpdateStrategy::ManualDuration(
            std::time::Duration::from_millis(16),
        ))
        .add_systems(Update, controls);
    app.world_mut()
        .spawn((Resident, Transform::from_xyz(0.0, -5.0, 0.0)));
    app.world_mut().spawn((OrbitCamera, Transform::default()));
    let mut query = app
        .world_mut()
        .query_filtered::<&mut Transform, With<Resident>>();
    for mut transform in query.iter_mut(app.world_mut()) {
        transform.translation =
            grounded_move(transform.translation, Vec3::new(100.0, -10.0, 100.0), 10.0);
        assert_eq!(transform.translation.y, 0.7);
        assert!(transform.translation.x <= 4.5 && transform.translation.z <= 4.5);
    }
    app.world_mut()
        .resource_mut::<ButtonInput<KeyCode>>()
        .press(KeyCode::KeyA);
    app.world_mut()
        .resource_mut::<ButtonInput<KeyCode>>()
        .press(KeyCode::ArrowRight);
    app.update();
    app.update();
    let orbit = app.world().resource::<Orbit>();
    assert!(orbit.yaw > 0.5);
    let mut residents = app
        .world_mut()
        .query_filtered::<&Transform, With<Resident>>();
    let resident = residents.single(app.world()).expect("fixture resident");
    assert!(resident.translation.x < 4.5);
    assert_eq!(resident.translation.y, 0.7);
    println!(
        "HEADLESS_SMOKE PASS: ECS resident, grounded movement, room bounds; GPU/rendering/media not exercised"
    );
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ecs_controls_without_gpu() {
        headless_smoke();
    }
    #[test]
    fn movement_is_grounded_and_bounded() {
        assert_eq!(
            grounded_move(Vec3::new(4.5, -10.0, 4.5), Vec3::ONE, 10.0),
            Vec3::new(4.5, 0.7, 4.5)
        );
    }
    #[test]
    fn movement_speed_is_normalized() {
        let a = grounded_move(Vec3::ZERO, Vec3::X, 1.0);
        let b = grounded_move(Vec3::ZERO, Vec3::new(1.0, 0.0, 1.0), 1.0);
        assert!((Vec2::new(a.x, a.z).length() - Vec2::new(b.x, b.z).length()).abs() < 0.001);
    }
    #[test]
    fn percentile_is_deterministic() {
        assert_eq!(percentile(&[9.0, 1.0, 5.0], 0.5), 5.0);
        assert_eq!(percentile(&[], 0.99), 0.0);
    }
}
