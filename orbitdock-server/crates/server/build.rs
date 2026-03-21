use std::path::Path;

fn main() {
    // Ensure the web dist directory exists so rust-embed compiles even when
    // the web app hasn't been built yet (dev builds without `make web-build`).
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let dist = Path::new(&manifest_dir).join("../../../orbitdock-web/dist");
    if !dist.exists() {
        std::fs::create_dir_all(&dist).ok();
    }
}
