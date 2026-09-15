use std::fmt::{self, Display};

pub fn string(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('"');
    for c in value.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if u32::from(c) < 0x20 => out.push_str(&format!("{}u{:04x}", '\\', u32::from(c))),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

pub fn celsius(millidegrees: i64) -> String {
    format!("{:.1}", millidegrees as f64 / 1000.0)
}

pub fn array(items: impl IntoIterator<Item = String>) -> String {
    format!("[{}]", items.into_iter().collect::<Vec<_>>().join(","))
}

#[derive(Default)]
pub struct Object(Vec<String>);

impl Object {
    pub fn raw(mut self, key: &str, value: impl Display) -> Self {
        self.0.push(format!("{}:{value}", string(key)));
        self
    }

    pub fn str(self, key: &str, value: &str) -> Self {
        let value = string(value);
        self.raw(key, value)
    }
}

impl Display for Object {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{{{}}}", self.0.join(","))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn escapes_strings() {
        assert_eq!(string("a\"b\\c\nd"), r#""a\"b\\c\nd""#);
        let control = char::from(1u8).to_string();
        assert_eq!(string(&control), format!("\"{}u0001\"", '\\'));
    }

    #[test]
    fn builds_objects_and_arrays() {
        let inner = Object::default()
            .str("label", "NAND")
            .raw("celsius", celsius(44864));
        let out = Object::default()
            .raw("ok", true)
            .raw("temps", array([inner.to_string()]));
        assert_eq!(
            out.to_string(),
            r#"{"ok":true,"temps":[{"label":"NAND","celsius":44.9}]}"#
        );
    }
}
