fn main() {
    std::fs::create_dir_all("target/rel").expect("failed to create target/rel");
    tauri_build::build()
}
