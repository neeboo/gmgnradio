//! Exact distance primitives ported from TriangleMeshCollisionWorld.swift.
use super::{cross, dot, point_inside, sub, valid_box, Obstacle, V};
fn add(a: V, b: V) -> V {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}
fn scale(a: V, s: f32) -> V {
    a.map(|x| x * s)
}
fn norm(a: V) -> f32 {
    dot(a, a)
}
fn point_triangle(p: V, t: [V; 3]) -> f32 {
    let [a, b, c] = t;
    let ab = sub(b, a);
    let ac = sub(c, a);
    let ap = sub(p, a);
    let d1 = dot(ab, ap);
    let d2 = dot(ac, ap);
    if d1 <= 0. && d2 <= 0. {
        return norm(ap);
    }
    let bp = sub(p, b);
    let d3 = dot(ab, bp);
    let d4 = dot(ac, bp);
    if d3 >= 0. && d4 <= d3 {
        return norm(bp);
    }
    let vc = d1 * d4 - d3 * d2;
    if vc <= 0. && d1 >= 0. && d3 <= 0. {
        return norm(sub(p, add(a, scale(ab, d1 / (d1 - d3)))));
    }
    let cp = sub(p, c);
    let d5 = dot(ab, cp);
    let d6 = dot(ac, cp);
    if d6 >= 0. && d5 <= d6 {
        return norm(cp);
    }
    let vb = d5 * d2 - d1 * d6;
    if vb <= 0. && d2 >= 0. && d6 <= 0. {
        return norm(sub(p, add(a, scale(ac, d2 / (d2 - d6)))));
    }
    let va = d3 * d6 - d5 * d4;
    if va <= 0. && d4 - d3 >= 0. && d5 - d6 >= 0. {
        return norm(sub(
            p,
            add(b, scale(sub(c, b), (d4 - d3) / ((d4 - d3) + (d5 - d6)))),
        ));
    }
    let denom = 1. / (va + vb + vc);
    norm(sub(
        p,
        add(a, add(scale(ab, vb * denom), scale(ac, vc * denom))),
    ))
}
fn segments(a0: V, a1: V, b0: V, b1: V) -> f32 {
    let d1 = sub(a1, a0);
    let d2 = sub(b1, b0);
    let r = sub(a0, b0);
    let a = dot(d1, d1);
    let e = dot(d2, d2);
    let mut s = 0.;
    let t;
    if a <= 1e-6 && e <= 1e-6 {
        return norm(r);
    } else if a <= 1e-6 {
        t = (dot(d2, r) / e).clamp(0., 1.)
    } else {
        let c = dot(d1, r);
        if e <= 1e-6 {
            s = (-c / a).clamp(0., 1.);
            t = 0.
        } else {
            let b = dot(d1, d2);
            let denom = a * e - b * b;
            if denom.abs() > 1e-6 {
                s = ((b * dot(d2, r) - c * e) / denom).clamp(0., 1.)
            }
            let trial = (b * s + dot(d2, r)) / e;
            if trial < 0. {
                t = 0.;
                s = (-c / a).clamp(0., 1.)
            } else if trial > 1. {
                t = 1.;
                s = ((b - c) / a).clamp(0., 1.)
            } else {
                t = trial
            }
        }
    }
    norm(sub(add(a0, scale(d1, s)), add(b0, scale(d2, t))))
}
fn segment_triangle(start: V, end: V, t: [V; 3]) -> f32 {
    let direction = sub(end, start);
    let e1 = sub(t[1], t[0]);
    let e2 = sub(t[2], t[0]);
    let p = cross(direction, e2);
    let det = dot(e1, p);
    if det.abs() > 1e-6 {
        let inverse = 1. / det;
        let offset = sub(start, t[0]);
        let u = dot(offset, p) * inverse;
        let q = cross(offset, e1);
        let v = dot(direction, q) * inverse;
        let distance = dot(e2, q) * inverse;
        if (0. ..=1.).contains(&u) && v >= 0. && u + v <= 1. && (0. ..=1.).contains(&distance) {
            return 0.;
        }
    }
    point_triangle(start, t)
        .min(point_triangle(end, t))
        .min(segments(start, end, t[0], t[1]))
        .min(segments(start, end, t[1], t[2]))
        .min(segments(start, end, t[2], t[0]))
}
pub fn capsule_can_occupy(
    triangles: &[[V; 3]],
    obstacles: &[Obstacle],
    position: V,
    radius: f32,
    height: f32,
) -> bool {
    if !radius.is_finite()
        || radius <= 0.
        || !height.is_finite()
        || height < 2. * radius
        || position.iter().any(|v| !v.is_finite())
    {
        return false;
    }
    let bottom = add(position, [0., radius, 0.]);
    let top = add(position, [0., height - radius, 0.]);
    let r2 = radius * radius;
    for t in triangles {
        if t.iter().flatten().any(|v| !v.is_finite()) {
            return false;
        }
        let normal = cross(sub(t[1], t[0]), sub(t[2], t[0]));
        if norm(normal) > 0.00000001
            && normal[1] * normal[1] >= norm(normal) * 0.5
            && t.iter().map(|v| v[1]).fold(f32::NEG_INFINITY, f32::max)
                <= position[1] + radius + 0.01
        {
            continue;
        }
        let distance = segment_triangle(bottom, top, *t);
        if !distance.is_finite() || distance < r2 - 1e-6 {
            return false;
        }
    }
    for o in obstacles {
        match o {
            Obstacle::Box { volume, .. } => {
                if !valid_box(volume) {
                    return false;
                }
                // Yaw leaves the upright capsule axis parallel to local Y: exact segment/AABB distance.
                let (s, c) = volume.yaw.sin_cos();
                let d = sub(position, volume.center);
                let x = c * d[0] - s * d[2];
                let z = s * d[0] + c * d[2];
                let dx = (x.abs() - volume.half_extents[0]).max(0.);
                let dz = (z.abs() - volume.half_extents[2]).max(0.);
                let ymin = d[1] + radius;
                let ymax = d[1] + height - radius;
                let dy = (ymin - volume.half_extents[1])
                    .max(-volume.half_extents[1] - ymax)
                    .max(0.);
                if dx * dx + dy * dy + dz * dz < r2 - 1e-6 {
                    return false;
                }
            }
            Obstacle::Mesh {
                triangles,
                is_closed,
                ..
            } => {
                if triangles.is_empty()
                    || triangles.iter().flatten().flatten().any(|v| !v.is_finite())
                {
                    return false;
                }
                if *is_closed
                    && (0..=4).any(|i| {
                        point_inside(
                            add(bottom, scale(sub(top, bottom), i as f32 / 4.)),
                            triangles,
                        )
                    })
                {
                    return false;
                }
                if triangles.iter().any(|t| {
                    let d = segment_triangle(bottom, top, *t);
                    !d.is_finite() || d < r2 - 1e-6
                }) {
                    return false;
                }
            }
        }
    }
    true
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn floor_contact_and_wall_penetration() {
        let floor = [[[-2., 0., -2.], [2., 0., -2.], [0., 0., 2.]]];
        assert!(capsule_can_occupy(&floor, &[], [0., 0., 0.], 0.2, 1.8));
        let wall = [[[0.1, 0., -2.], [0.1, 2., -2.], [0.1, 0., 2.]]];
        assert!(!capsule_can_occupy(&wall, &[], [0., 0., 0.], 0.2, 1.8));
    }
    #[test]
    fn point_triangle_and_segment_surface_distance() {
        let t = [[0., 0., 0.], [1., 0., 0.], [0., 0., 1.]];
        assert_eq!(point_triangle([0.25, 2., 0.25], t), 4.);
        assert_eq!(segment_triangle([0.25, -1., 0.25], [0.25, 1., 0.25], t), 0.);
    }
}
