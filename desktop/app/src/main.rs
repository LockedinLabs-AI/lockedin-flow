#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod worker;

use lockedin_flow_core::vocabulary::MAX_INPUT;
use std::sync::{
    mpsc::{self, SyncSender},
    Arc, Mutex,
};
use tauri::Manager;
use worker::{Action, Message, View};

struct Services {
    sender: SyncSender<Message>,
    view: Arc<Mutex<View>>,
}

fn own_window(window: &tauri::WebviewWindow) -> Result<(), &'static str> {
    if window.label() == "main" {
        Ok(())
    } else {
        Err("This window cannot control dictation.")
    }
}

fn allowed_navigation(url: &tauri::Url) -> bool {
    let (scheme, host) = if cfg!(target_os = "windows") {
        ("http", "tauri.localhost")
    } else {
        ("tauri", "localhost")
    };
    url.scheme() == scheme
        && url.host_str() == Some(host)
        && url.port().is_none()
        && url.username().is_empty()
        && url.password().is_none()
}

#[tauri::command]
fn get_status(
    window: tauri::WebviewWindow,
    services: tauri::State<'_, Services>,
) -> Result<View, &'static str> {
    own_window(&window)?;
    services
        .view
        .lock()
        .map(|view| view.clone())
        .map_err(|_| "Dictation status is unavailable.")
}

#[tauri::command]
async fn perform_action(
    window: tauri::WebviewWindow,
    services: tauri::State<'_, Services>,
    action: Action,
) -> Result<(), &'static str> {
    own_window(&window)?;
    {
        let view = services
            .view
            .lock()
            .map_err(|_| "Dictation status is unavailable.")?;
        if !action.allowed(view.phase) {
            return Err("This action is not available in the current dictation state.");
        }
    }
    let (completion, receiver) = mpsc::sync_channel(1);
    services
        .sender
        .try_send(Message::Action(action, completion))
        .map_err(|_| "LockedIn Flow is busy. Please wait for the current action.")?;
    tauri::async_runtime::spawn_blocking(move || receiver.recv())
        .await
        .map_err(|_| "The dictation worker is unavailable.")?
        .map_err(|_| "The dictation worker is unavailable.")?
}

#[tauri::command]
async fn set_vocabulary(
    window: tauri::WebviewWindow,
    services: tauri::State<'_, Services>,
    text: String,
) -> Result<(), &'static str> {
    own_window(&window)?;
    {
        let view = services
            .view
            .lock()
            .map_err(|_| "Dictation status is unavailable.")?;
        if view.phase != lockedin_flow_core::Phase::Ready {
            return Err("Finish the current recording before changing vocabulary.");
        }
    }
    if text.len() > MAX_INPUT {
        return Err("Vocabulary is limited to 16 KB.");
    }
    let (completion, receiver) = mpsc::sync_channel(1);
    services
        .sender
        .try_send(Message::Vocabulary(
            zeroize::Zeroizing::new(text),
            completion,
        ))
        .map_err(|_| "LockedIn Flow is busy. Please wait for the current action.")?;
    tauri::async_runtime::spawn_blocking(move || receiver.recv())
        .await
        .map_err(|_| "The dictation worker is unavailable.")?
        .map_err(|_| "The dictation worker is unavailable.")?
}

fn main() {
    let result = tauri::Builder::default()
        .setup(|app| {
            let resources = app.path().resource_dir()?;
            let (sender, view) = worker::spawn(resources)?;
            app.manage(Services { sender, view });
            let configuration = app
                .config()
                .app
                .windows
                .iter()
                .find(|window| window.label == "main")
                .ok_or("The main application window is not configured.")?;
            tauri::WebviewWindowBuilder::from_config(app, configuration)?
                .on_navigation(allowed_navigation)
                .build()?;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_status,
            perform_action,
            set_vocabulary
        ])
        .run(tauri::generate_context!());
    if result.is_err() {
        // Fixed, content-free failure. Never include transcript, device, or filesystem details.
        eprintln!("LockedIn Flow could not start its desktop interface.");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod navigation_tests {
    use super::*;

    #[test]
    fn navigation_is_limited_to_the_platforms_bundled_app_origin() {
        let origin = if cfg!(target_os = "windows") {
            "http://tauri.localhost"
        } else {
            "tauri://localhost"
        };
        for suffix in ["", "/", "/index.html", "/index.html#transcript"] {
            assert!(allowed_navigation(
                &tauri::Url::parse(&format!("{origin}{suffix}")).unwrap()
            ));
        }
        for url in [
            "https://example.com",
            "http://localhost",
            "http://tauri.localhost.example",
            "tauri://localhost.example",
            "tauri://user@localhost",
            "tauri://localhost:1234",
            "file:///synthetic.txt",
            "data:text/plain,synthetic",
        ] {
            assert!(!allowed_navigation(&tauri::Url::parse(url).unwrap()));
        }
    }
}
