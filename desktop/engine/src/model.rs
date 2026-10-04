use sha2::{Digest, Sha256};
use std::{fs::File, io::Read, path::Path};

pub const MODEL_NAME: &str = "Whisper Base English";
pub const MODEL_FILE: &str = "ggml-base.en.bin";
pub const MODEL_BYTES: u64 = 147_964_211;
pub const MODEL_SHA256: &str = "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002";

/// Verify the bytes that the decoder actually consumes, not a path opened a second time.
/// Models are loaded only from the package resource directory, never through IPC paths.
pub fn read_verified(path: &Path) -> Result<Vec<u8>, &'static str> {
    let metadata = std::fs::symlink_metadata(path)
        .map_err(|_| "The bundled speech model is missing. Reinstall the complete package.")?;
    if !metadata.is_file() || metadata.file_type().is_symlink() || metadata.len() != MODEL_BYTES {
        return Err("The bundled speech model has an unexpected format or size. Reinstall the complete package.");
    }
    let file = File::open(path).map_err(|_| "The bundled speech model could not be opened.")?;
    let mut bytes = Vec::new();
    bytes
        .try_reserve_exact(MODEL_BYTES as usize + 1)
        .map_err(|_| "Not enough memory to load the speech model.")?;
    file.take(MODEL_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "The bundled speech model could not be read.")?;
    validate_bytes(&bytes, MODEL_BYTES, MODEL_SHA256)?;
    Ok(bytes)
}

fn validate_bytes(bytes: &[u8], size: u64, digest: &str) -> Result<(), &'static str> {
    if bytes.len() as u64 != size || format!("{:x}", Sha256::digest(bytes)) != digest {
        return Err("Speech model integrity check failed. Reinstall from the verified release.");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn exact_bytes_required_before_decoding() {
        let expected = format!("{:x}", Sha256::digest(b"synthetic fixture"));
        assert!(validate_bytes(b"synthetic fixture", 17, &expected).is_ok());
        assert!(validate_bytes(b"synthetic fixture!", 17, &expected).is_err());
        assert!(validate_bytes(b"synthetic fixturE", 17, &expected).is_err());
        assert!(validate_bytes(b"synthetic fixture", 18, &expected).is_err());
    }
    #[test]
    fn missing_model_never_falls_back_to_network() {
        assert!(read_verified(Path::new("nonexistent-synthetic-model.bin")).is_err());
    }
}
