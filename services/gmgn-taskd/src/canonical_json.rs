//! Stable Value encoding independent of serde_json's preserve_order feature.
//! Typed structs are deliberately not converted here: their field order is part
//! of their existing wire format.
use serde_json::Value;

pub fn sorted(value: &Value) -> Value {
    let mut value = value.clone();
    value.sort_all_objects();
    value
}

pub fn to_string(value: &Value) -> serde_json::Result<String> {
    serde_json::to_string(&sorted(value))
}

pub fn to_vec(value: &Value) -> serde_json::Result<Vec<u8>> {
    serde_json::to_vec(&sorted(value))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nested_objects_have_stable_bytes_without_reordering_arrays() {
        let first: Value = serde_json::from_str(r#"{"z":[{"b":2,"a":1},3],"a":{"y":2,"x":1}}"#).unwrap();
        let second: Value = serde_json::from_str(r#"{"a":{"x":1,"y":2},"z":[{"a":1,"b":2},3]}"#).unwrap();
        let original = serde_json::to_string(&first).unwrap();
        assert_eq!(to_vec(&first).unwrap(), to_vec(&second).unwrap());
        assert_eq!(to_string(&first).unwrap(), r#"{"a":{"x":1,"y":2},"z":[{"a":1,"b":2},3]}"#);
        assert_eq!(serde_json::to_string(&first).unwrap(), original);
    }
}
