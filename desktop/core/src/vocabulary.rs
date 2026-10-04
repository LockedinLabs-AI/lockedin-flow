//! Explicit, session-only spelling corrections. No directory ingestion or model training.
use zeroize::Zeroize;

const MAX_ENTRIES: usize = 128;
const MAX_FIELD: usize = 80;
pub const MAX_INPUT: usize = 16 * 1024;

#[derive(Default)]
pub struct Vocabulary(Vec<(String, String)>);

impl Vocabulary {
    /// One `heard phrase = preferred spelling` per line. No regex or executable expressions.
    pub fn parse(input: &str) -> Result<Self, &'static str> {
        if input.len() > MAX_INPUT {
            return Err("Vocabulary is limited to 16 KB.");
        }
        let mut vocabulary = Self::default();
        for line in input.lines().filter(|line| !line.trim().is_empty()) {
            let (heard, spelling) = line
                .split_once('=')
                .ok_or("Use heard phrase = preferred spelling on each line.")?;
            let (heard, spelling) = (heard.trim(), spelling.trim());
            if [heard, spelling].iter().any(|value| {
                value.is_empty() || value.len() > MAX_FIELD || value.chars().any(char::is_control)
            }) {
                return Err(
                    "Each vocabulary phrase must contain 1–80 bytes without control characters.",
                );
            }
            let key = heard.to_lowercase();
            if vocabulary.0.iter().any(|(existing, _)| existing == &key) {
                return Err("Each heard phrase must be unique.");
            }
            vocabulary.0.push((key, spelling.to_string()));
            if vocabulary.0.len() > MAX_ENTRIES {
                return Err("Use no more than 128 vocabulary entries.");
            }
        }
        // Longest matching phrase wins; output is never reprocessed as another rule.
        vocabulary.0.sort_by(|a, b| b.0.len().cmp(&a.0.len()));
        Ok(vocabulary)
    }

    pub fn count(&self) -> usize {
        self.0.len()
    }

    pub fn apply(&self, input: &str) -> String {
        let mut output = String::with_capacity(input.len());
        let mut cursor = 0;
        while cursor < input.len() {
            let remaining = &input[cursor..];
            let at_boundary = cursor == 0
                || input[..cursor]
                    .chars()
                    .next_back()
                    .is_some_and(|c| !word(c));
            let matched = at_boundary
                .then(|| {
                    self.0.iter().find_map(|(heard, spelling)| {
                        let end = case_insensitive_prefix(remaining, heard)?;
                        let boundary = remaining[end..].chars().next().is_none_or(|c| !word(c));
                        boundary.then_some((end, spelling))
                    })
                })
                .flatten();
            if let Some((end, spelling)) = matched {
                output.push_str(spelling);
                cursor += end;
            } else if let Some(ch) = remaining.chars().next() {
                output.push(ch);
                cursor += ch.len_utf8();
            }
        }
        output
    }
}

fn word(ch: char) -> bool {
    ch.is_alphanumeric() || ch == '_'
}

fn case_insensitive_prefix(input: &str, expected: &str) -> Option<usize> {
    let mut expected = expected.chars();
    for (offset, ch) in input.char_indices() {
        for folded in ch.to_lowercase() {
            if expected.next()? != folded {
                return None;
            }
        }
        if expected.as_str().is_empty() {
            return Some(offset + ch.len_utf8());
        }
    }
    None
}

impl Drop for Vocabulary {
    fn drop(&mut self) {
        for (heard, spelling) in &mut self.0 {
            heard.zeroize();
            spelling.zeroize();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn explicit_terms_match_whole_phrases_without_cascading() {
        let terms = Vocabulary::parse(
            "cube control = kubectl\napi = API\nAPI gateway = API Gateway\nkubectl = wrong",
        )
        .unwrap();
        assert_eq!(
            terms.apply("Cube control uses an api gateway, not rapid."),
            "kubectl uses an API Gateway, not rapid."
        );
    }
    #[test]
    fn unicode_names_and_punctuation_work() {
        let terms = Vocabulary::parse("josé = José\nsree = Sree").unwrap();
        assert_eq!(terms.apply("JOSÉ, sree."), "José, Sree.");
    }
    #[test]
    fn malformed_duplicate_and_oversized_input_is_rejected() {
        for input in [
            "a".into(),
            "a=".into(),
            "a=b\nA=c".into(),
            "a=\0".into(),
            "x".repeat(MAX_INPUT + 1),
        ] {
            assert!(Vocabulary::parse(&input).is_err());
        }
    }
}
