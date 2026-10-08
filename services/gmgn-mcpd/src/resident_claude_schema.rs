//! The native host's deliberately narrow schema vocabulary. Unknown constraints refuse.
use serde_json::Value;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SchemaError {
    Unsupported,
    Invalid,
}

pub fn supported(schema: &Value, depth: usize) -> Result<(), SchemaError> {
    if depth > 32 {
        return Err(SchemaError::Unsupported);
    }
    let map = schema.as_object().ok_or(SchemaError::Unsupported)?;
    const KEYS: &[&str] = &[
        "type",
        "description",
        "enum",
        "properties",
        "required",
        "additionalProperties",
        "items",
        "minItems",
        "maxItems",
        "minLength",
        "maxLength",
    ];
    if map.keys().any(|key| !KEYS.contains(&key.as_str())) {
        return Err(SchemaError::Unsupported);
    }
    let types = types(schema)?;
    if types.iter().any(|t| {
        ![
            "object", "array", "string", "integer", "number", "boolean", "null",
        ]
        .contains(&t.as_str())
    }) {
        return Err(SchemaError::Unsupported);
    }
    if let Some(values) = schema.get("enum") {
        let values = values.as_array().ok_or(SchemaError::Unsupported)?;
        if values.is_empty()
            || values
                .iter()
                .any(|v| !(v.is_string() || v.is_number() || v.is_boolean()))
        {
            return Err(SchemaError::Unsupported);
        }
    }
    for key in ["minItems", "maxItems", "minLength", "maxLength"] {
        if schema.get(key).is_some_and(|v| v.as_u64().is_none()) {
            return Err(SchemaError::Unsupported);
        }
    }
    if types.iter().any(|t| t == "object") {
        let properties = schema["properties"]
            .as_object()
            .ok_or(SchemaError::Unsupported)?;
        if let Some(required) = schema.get("required") {
            if !required
                .as_array()
                .is_some_and(|a| a.iter().all(Value::is_string))
            {
                return Err(SchemaError::Unsupported);
            }
        }
        if schema
            .get("additionalProperties")
            .is_some_and(|v| !v.is_boolean())
        {
            return Err(SchemaError::Unsupported);
        }
        for child in properties.values() {
            supported(child, depth + 1)?;
        }
    }
    if types.iter().any(|t| t == "array") {
        supported(&schema["items"], depth + 1)?;
    }
    Ok(())
}

fn types(schema: &Value) -> Result<Vec<String>, SchemaError> {
    if let Some(t) = schema["type"].as_str() {
        return Ok(vec![t.into()]);
    }
    let a = schema["type"].as_array().ok_or(SchemaError::Unsupported)?;
    if a.is_empty() {
        return Err(SchemaError::Unsupported);
    }
    a.iter()
        .map(|v| {
            v.as_str()
                .map(str::to_owned)
                .ok_or(SchemaError::Unsupported)
        })
        .collect()
}

pub fn validate(schema: &Value, value: &Value) -> Result<(), SchemaError> {
    supported(schema, 0)?;
    check(schema, value)
}

fn check(schema: &Value, value: &Value) -> Result<(), SchemaError> {
    if schema
        .get("enum")
        .is_some_and(|a| !a.as_array().unwrap().contains(value))
    {
        return Err(SchemaError::Invalid);
    }
    let matches = types(schema)?.iter().any(|t| match t.as_str() {
        "object" => value.is_object(),
        "array" => value.is_array(),
        "string" => value.is_string(),
        "integer" => {
            value.as_i64().is_some()
                || value.as_u64().is_some()
                || value.as_f64().is_some_and(|v| v.fract() == 0.0)
        }
        "number" => value.is_number(),
        "boolean" => value.is_boolean(),
        "null" => value.is_null(),
        _ => false,
    });
    if !matches {
        return Err(SchemaError::Invalid);
    }
    if let Some(object) = value.as_object() {
        let properties = schema["properties"]
            .as_object()
            .ok_or(SchemaError::Unsupported)?;
        if schema["additionalProperties"] == false
            && object.keys().any(|k| !properties.contains_key(k))
        {
            return Err(SchemaError::Invalid);
        }
        if schema.get("required").is_some_and(|a| {
            a.as_array()
                .unwrap()
                .iter()
                .any(|k| !object.contains_key(k.as_str().unwrap()))
        }) {
            return Err(SchemaError::Invalid);
        }
        for (key, child) in properties {
            if let Some(v) = object.get(key) {
                check(child, v)?;
            }
        }
    }
    if let Some(array) = value.as_array() {
        bounds(schema, "minItems", "maxItems", array.len())?;
        for v in array {
            check(&schema["items"], v)?;
        }
    }
    if let Some(text) = value.as_str() {
        bounds(schema, "minLength", "maxLength", text.chars().count())?;
    }
    Ok(())
}

fn bounds(schema: &Value, min: &str, max: &str, count: usize) -> Result<(), SchemaError> {
    if schema[min].as_u64().is_some_and(|n| (count as u64) < n)
        || schema[max].as_u64().is_some_and(|n| (count as u64) > n)
    {
        return Err(SchemaError::Invalid);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn unsupported_constraints_cannot_disappear() {
        assert_eq!(
            validate(
                &json!({"type":"object","properties":{"x":{"type":"string","pattern":".*"}}}),
                &json!({})
            ),
            Err(SchemaError::Unsupported)
        );
        assert_eq!(
            validate(
                &json!({"type":"object","properties":{},"oneOf":[]}),
                &json!({})
            ),
            Err(SchemaError::Unsupported)
        );
    }
    #[test]
    fn original_schema_checks_required_and_types() {
        let schema = json!({"type":"object","properties":{"slot":{"type":"string","enum":["left","right"]},"n":{"type":"integer"}},"required":["slot"],"additionalProperties":false});
        assert!(validate(&schema, &json!({"slot":"left","n":3})).is_ok());
        for args in [
            json!({}),
            json!({"slot":"wrong"}),
            json!({"slot":"left","n":true}),
            json!({"slot":"left","other":1}),
        ] {
            assert_eq!(validate(&schema, &args), Err(SchemaError::Invalid));
        }
    }
}
