use std::collections::BTreeMap;

use serde_json::Value;

use super::Rejected;

#[derive(Default)]
pub(super) struct Filters {
    names: Vec<String>,
    labels: Vec<String>,
}

impl Filters {
    pub(super) fn parse(encoded: Option<&String>) -> Result<Self, Rejected> {
        let mut result = Self::default();
        for (key, values) in parse_filters(encoded)? {
            match key.as_str() {
                "name" => result.names = values,
                "label" => result.labels = values,
                _ => {
                    return Err(Rejected::bad(format!(
                        "unsupported Docker discovery filter {key}"
                    )))
                }
            }
        }
        Ok(result)
    }

    pub(super) fn matches(&self, name: &str, labels: &Value) -> bool {
        (self.names.is_empty()
            || self
                .names
                .iter()
                .any(|filter| filter.trim_start_matches('/') == name))
            && labels_match(&self.labels, labels)
    }
}

pub(super) fn parse_filters(
    encoded: Option<&String>,
) -> Result<BTreeMap<String, Vec<String>>, Rejected> {
    let Some(encoded) = encoded else {
        return Ok(BTreeMap::new());
    };
    let raw: Value =
        serde_json::from_str(encoded).map_err(|_| Rejected::bad("invalid Docker filters"))?;
    let raw = raw
        .as_object()
        .ok_or_else(|| Rejected::bad("invalid Docker filters"))?;
    let mut result = BTreeMap::new();
    for (key, value) in raw {
        let values: Vec<&str> = if let Some(values) = value.as_array() {
            values
                .iter()
                .map(|value| {
                    value
                        .as_str()
                        .ok_or_else(|| Rejected::bad("invalid Docker filter value"))
                })
                .collect::<Result<_, _>>()?
        } else if let Some(values) = value.as_object() {
            if values.values().any(|value| value.as_bool() != Some(true)) {
                return Err(Rejected::bad("invalid Docker filter set"));
            }
            values.keys().map(String::as_str).collect()
        } else {
            return Err(Rejected::bad("invalid Docker filter set"));
        };
        if values.len() > 16
            || values
                .iter()
                .any(|value| value.is_empty() || value.len() > 256 || value.starts_with('='))
        {
            return Err(Rejected::bad("Docker filter exceeds the supported scope"));
        }
        result.insert(key.clone(), values.into_iter().map(str::to_owned).collect());
    }
    Ok(result)
}

pub(super) fn labels_match(filters: &[String], labels: &Value) -> bool {
    filters.iter().all(|filter| {
        let (key, expected) = filter
            .split_once('=')
            .map_or((filter.as_str(), None), |(key, value)| (key, Some(value)));
        labels
            .get(key)
            .and_then(Value::as_str)
            .is_some_and(|value| expected.map_or(true, |expected| value == expected))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn exact_labels_and_names_are_project_scoped() {
        let query = json!({"name":{"shared":true},"label":["project=alpha","service"]}).to_string();
        let filters = Filters::parse(Some(&query)).unwrap();
        assert!(filters.matches("shared", &json!({"project":"alpha","service":"app"})));
        assert!(!filters.matches("shared", &json!({"project":"beta","service":"app"})));
        assert!(!filters.matches("shared", &json!({"project":"alpha"})));
        assert!(!filters.matches("shared-other", &json!({"project":"alpha","service":"app"})));
        assert!(Filters::parse(Some(&r#"{"unimplemented":["true"]}"#.into())).is_err());
    }
}
