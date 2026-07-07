pub fn enabled(name: &str) -> bool {
    std::env::var(name)
        .map(|value| is_enabled_value(&value))
        .unwrap_or(false)
}

fn is_enabled_value(value: &str) -> bool {
    matches!(
        value.trim().to_ascii_lowercase().as_str(),
        "1" | "true" | "yes" | "on"
    )
}

#[cfg(test)]
mod tests {
    use super::is_enabled_value;

    #[test]
    fn parses_enabled_values() {
        for value in ["1", "true", "TRUE", " yes ", "on"] {
            assert!(is_enabled_value(value));
        }
        for value in ["", "0", "false", "off", "no", "enabled"] {
            assert!(!is_enabled_value(value));
        }
    }
}
