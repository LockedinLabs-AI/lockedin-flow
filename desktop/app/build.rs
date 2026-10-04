fn main() {
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(
        tauri_build::AppManifest::new().commands(&[
            "get_status",
            "perform_action",
            "set_vocabulary",
        ]),
    ))
    .expect("desktop build configuration must be valid");
}
