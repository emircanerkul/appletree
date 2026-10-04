//! Minimal JSON writing and the equally minimal parsing the harness needs for
//! its own runner output. Keeping this in-tree avoids pulling a JSON crate
//! into a benchmark that measures process overhead.

/// Escape a string for embedding in JSON.
pub fn escape(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for c in value.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

/// Decode one escape sequence, including `\uXXXX`, into `out`.
///
/// The runner output goes through `escape()`, which emits `\u00xx` for control
/// characters, so the parser must decode what the writer produces.
fn read_escape(
    chars: &mut std::iter::Peekable<std::str::Chars<'_>>,
    out: &mut String,
) -> Option<()> {
    match chars.next()? {
        'n' => out.push('\n'),
        't' => out.push('\t'),
        'r' => out.push('\r'),
        'b' => out.push('\u{0008}'),
        'f' => out.push('\u{000c}'),
        'u' => {
            let mut code = 0u32;
            for _ in 0..4 {
                code = code * 16 + chars.next()?.to_digit(16)?;
            }
            out.push(char::from_u32(code)?);
        }
        other => out.push(other),
    }
    Some(())
}

/// Read a top-level JSON object into key -> raw-value-text pairs.
///
/// Deliberately small: the only input is this harness's own one-line runner
/// output (strings and unsigned integers), never third-party JSON.
pub fn parse_flat_object(text: &str) -> Option<Vec<(String, String)>> {
    let mut chars = text.trim().chars().peekable();
    if chars.next()? != '{' {
        return None;
    }
    let mut pairs = Vec::new();
    loop {
        while matches!(chars.peek(), Some(c) if c.is_whitespace()) {
            chars.next();
        }
        match chars.peek() {
            Some('}') => return Some(pairs),
            Some(',') => {
                chars.next();
                continue;
            }
            Some('"') => {}
            _ => return None,
        }
        chars.next(); // opening quote
        let mut key = String::new();
        loop {
            match chars.next()? {
                '"' => break,
                '\\' => read_escape(&mut chars, &mut key)?,
                c => key.push(c),
            }
        }
        while matches!(chars.peek(), Some(c) if c.is_whitespace() || *c == ':') {
            chars.next();
        }
        let value = if chars.peek() == Some(&'"') {
            chars.next();
            let mut s = String::new();
            loop {
                match chars.next()? {
                    '"' => break,
                    '\\' => read_escape(&mut chars, &mut s)?,
                    c => s.push(c),
                }
            }
            format!("\"{}\"", escape(&s))
        } else {
            let mut s = String::new();
            while let Some(&c) = chars.peek() {
                if c == ',' || c == '}' {
                    break;
                }
                s.push(c);
                chars.next();
            }
            s.trim().to_string()
        };
        pairs.push((key, value));
    }
}

/// Fetch an unsigned integer field, accepting a JSON string or number form.
pub fn get_u64(pairs: &[(String, String)], key: &str) -> Option<u64> {
    let raw = pairs.iter().find(|(k, _)| k == key)?.1.clone();
    raw.trim_matches('"').parse().ok()
}

/// Fetch a string field.
pub fn get_str(pairs: &[(String, String)], key: &str) -> Option<String> {
    let raw = pairs.iter().find(|(k, _)| k == key)?.1.clone();
    Some(raw.trim_matches('"').to_string())
}

/// Fetch a floating-point field, accepting a JSON string or number form.
pub fn get_f64(pairs: &[(String, String)], key: &str) -> Option<f64> {
    let raw = pairs.iter().find(|(k, _)| k == key)?.1.clone();
    raw.trim_matches('"').parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_runner_style_output() {
        let line = r#"{"tool":"appletree","seconds":0.607,"files":247465,"bytes":12618919936,"path":"/Applications/R\u00e9sum\u00e9"}"#;
        let pairs = parse_flat_object(line).expect("parses");
        assert_eq!(get_str(&pairs, "tool").unwrap(), "appletree");
        assert_eq!(get_u64(&pairs, "files").unwrap(), 247465);
        assert_eq!(get_u64(&pairs, "bytes").unwrap(), 12618919936);
        assert_eq!(get_f64(&pairs, "seconds").unwrap(), 0.607);
        assert_eq!(get_str(&pairs, "path").unwrap(), "/Applications/Résumé");
    }

    #[test]
    fn escapes_control_characters() {
        assert_eq!(escape("a\"b\\c\nd"), "a\\\"b\\\\c\\nd");
    }
}
