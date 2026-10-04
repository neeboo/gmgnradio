//! Lossless indexed wire encoding. Does not simplify, weld, transform or reorder geometry.
use serde::{Deserialize, Deserializer};

pub(crate) const MAX_TRIANGLES: usize = 1_000_000;
pub(crate) const MAX_VERTICES: usize = 1_000_000;
type Vertex = [f32; 3];
type Triangle = [Vertex; 3];

#[derive(Deserialize)]
#[serde(untagged)]
enum GeometryWire {
    Legacy(Vec<Triangle>),
    Indexed(IndexedGeometry),
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct IndexedGeometry {
    vertices: Vec<Vertex>,
    indices: Vec<[u32; 3]>,
}

fn expand(
    wire: GeometryWire,
    triangle_budget: usize,
    vertex_budget: usize,
) -> Result<Vec<Triangle>, &'static str> {
    match wire {
        GeometryWire::Legacy(triangles) => {
            if triangles.len() > triangle_budget {
                return Err("placement_geometry_triangle_budget");
            }
            if triangles.iter().flatten().flatten().any(|n| !n.is_finite()) {
                return Err("placement_geometry_nonfinite_vertex");
            }
            Ok(triangles)
        }
        GeometryWire::Indexed(mesh) => {
            if mesh.indices.len() > triangle_budget {
                return Err("placement_geometry_triangle_budget");
            }
            if mesh.vertices.len() > vertex_budget {
                return Err("placement_geometry_vertex_budget");
            }
            // Validate all vertices, including unreferenced values. Reject malformed input rather than silently discarding it.
            if mesh.vertices.iter().flatten().any(|n| !n.is_finite()) {
                return Err("placement_geometry_nonfinite_vertex");
            }
            if mesh
                .indices
                .iter()
                .flatten()
                .any(|i| *i as usize >= mesh.vertices.len())
            {
                return Err("placement_geometry_index_out_of_bounds");
            }
            Ok(mesh
                .indices
                .into_iter()
                .map(|indices| indices.map(|i| mesh.vertices[i as usize]))
                .collect())
        }
    }
}

pub(crate) fn deserialize_triangles<'de, D: Deserializer<'de>>(
    deserializer: D,
) -> Result<Vec<Triangle>, D::Error> {
    let wire = GeometryWire::deserialize(deserializer)?;
    expand(wire, MAX_TRIANGLES, MAX_VERTICES).map_err(serde::de::Error::custom)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[derive(Deserialize)]
    struct Payload {
        #[serde(deserialize_with = "deserialize_triangles")]
        triangles: Vec<Triangle>,
    }
    #[test]
    fn indexed_and_legacy_exact_equivalence() {
        let indexed:r#Payload=serde_json::from_str(r#"{"triangles":{"vertices":[[0,0,0],[1,0,0],[1,0,1],[0,0,1]],"indices":[[0,1,2],[0,2,3],[2,1,0]]}}"#).unwrap();
        let legacy:Payload=serde_json::from_str(r#"{"triangles":[[[0,0,0],[1,0,0],[1,0,1]],[[0,0,0],[1,0,1],[0,0,1]],[[1,0,1],[1,0,0],[0,0,0]]]}"#).unwrap();
        assert_eq!(indexed.triangles, legacy.triangles);
    }
    #[test]
    fn bounds_negative_fractional_indices_rejected() {
        for value in [
            r#"{"vertices":[[0,0,0]],"indices":[[0,1,0]]}"#,
            r#"{"vertices":[[0,0,0]],"indices":[[0,-1,0]]}"#,
            r#"{"vertices":[[0,0,0]],"indices":[[0,0.5,0]]}"#,
        ] {
            assert!(
                serde_json::from_str::<Payload>(&format!("{{\"triangles\":{value}}}")).is_err()
            );
        }
    }
    #[test]
    fn nonfinite_overflow_rejected() {
        assert!(serde_json::from_str::<Payload>(
            r#"{"triangles":{"vertices":[[1e40,0,0]],"indices":[[0,0,0]]}}"#
        )
        .is_err());
    }
    #[test]
    fn nonfinite_internal_values_rejected() {
        for value in [f32::NAN, f32::INFINITY, f32::NEG_INFINITY] {
            assert!(expand(
                GeometryWire::Indexed(IndexedGeometry {
                    vertices: vec![[value, 0., 0.]],
                    indices: vec![]
                }),
                1,
                1
            )
            .is_err());
            assert!(expand(GeometryWire::Legacy(vec![[[value, 0., 0.]; 3]]), 1, 1).is_err());
        }
    }
    #[test]
    fn budgets_apply_before_expansion() {
        let vertices = vec![[0.; 3]; 3];
        assert!(expand(
            GeometryWire::Indexed(IndexedGeometry {
                vertices: vertices.clone(),
                indices: vec![[0, 1, 2]; 2]
            }),
            1,
            3
        )
        .is_err());
        assert!(expand(
            GeometryWire::Indexed(IndexedGeometry {
                vertices,
                indices: vec![[0, 1, 2]]
            }),
            1,
            2
        )
        .is_err());
        assert!(expand(GeometryWire::Legacy(vec![[[0.; 3]; 3]; 2]), 1, 3).is_err());
    }
    #[test]
    fn malformed_shape_rejected() {
        for value in [
            r#"{"vertices":[],"indices":[],"simplify":true}"#,
            r#"{"vertices":[[0,0]],"indices":[]}"#,
            r#"{"vertices":[],"indices":[[0,0]]}"#,
        ] {
            assert!(
                serde_json::from_str::<Payload>(&format!("{{\"triangles\":{value}}}")).is_err()
            );
        }
    }
    #[test]
    fn empty_geometry_preserved() {
        let p: Payload =
            serde_json::from_str(r#"{"triangles":{"vertices":[],"indices":[]}}"#).unwrap();
        assert!(p.triangles.is_empty());
    }
}
