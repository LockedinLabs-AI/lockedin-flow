//! Developer-only offline inference check. Reports comparison, never transcript content.
//! Usage: cargo run -p lockedin-flow-engine --example recognize_fixture -- MODEL WAV EXPECTED [REPETITIONS]
use lockedin_flow_core::{MAX_RECORDING_SECONDS, SAMPLE_RATE};
use lockedin_flow_engine::speech::SpeechEngine;
use std::{path::Path, time::Instant};

fn repetitions(value: Option<&str>) -> Result<usize, &'static str> {
    match value {
        None => Ok(1),
        Some(value) => value
            .parse::<usize>()
            .ok()
            .filter(|n| (1..=16).contains(n))
            .ok_or("Use 1–16 synthetic test repetitions."),
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args().collect();
    if !(4..=5).contains(&args.len()) {
        return Err("Expected model, synthetic WAV, and expected-text file paths.".into());
    }
    let repetitions = repetitions(args.get(4).map(String::as_str))?;
    let mut wav = hound::WavReader::open(&args[2])?;
    let spec = wav.spec();
    if spec.channels != 1 || spec.sample_rate != 16_000 || spec.bits_per_sample != 16 {
        return Err("Use a 16 kHz mono signed 16-bit synthetic WAV.".into());
    }
    if wav.duration() as usize > MAX_RECORDING_SECONDS * SAMPLE_RATE {
        return Err("The synthetic fixture exceeds the five-minute capture limit.".into());
    }
    let samples = wav
        .samples::<i16>()
        .map(|sample| sample.map(|v| v as f32 / 32768.0))
        .collect::<Result<Vec<_>, _>>()?;
    let expected = std::fs::read_to_string(&args[3])?;
    let words = |value: &str| {
        value
            .to_lowercase()
            .split(|c: char| !c.is_alphanumeric())
            .filter(|v| !v.is_empty())
            .map(str::to_string)
            .collect::<Vec<_>>()
    };
    let expected = words(&expected);
    let started = Instant::now();
    let engine = SpeechEngine::load(Path::new(&args[1]))?;
    let model_seconds = started.elapsed().as_secs_f64();
    let recognition = Instant::now();
    for _ in 0..repetitions {
        let actual = engine.transcribe(&samples)?;
        if words(&actual) != expected {
            return Err("Synthetic speech comparison did not match.".into());
        }
    }
    println!(
        "Synthetic offline speech comparison passed ({} words, {} repetitions; {:.2}s audio; {:.2}s model load; {:.2}s total recognition).",
        expected.len(), repetitions, samples.len() as f64 / SAMPLE_RATE as f64,
        model_seconds, recognition.elapsed().as_secs_f64(),
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repetition_count_is_optional_and_bounded() {
        assert_eq!(repetitions(None), Ok(1));
        assert_eq!(repetitions(Some("16")), Ok(16));
        for value in ["0", "17", "-1", "many", "184467440737095516160"] {
            assert!(repetitions(Some(value)).is_err());
        }
    }
}
