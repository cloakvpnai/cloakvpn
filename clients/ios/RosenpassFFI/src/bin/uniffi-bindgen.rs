// Trampoline binary: invoked by `cargo run --bin uniffi-bindgen ...`
// from build-xcframework.sh. uniffi-rs requires the bindgen CLI to be
// part of YOUR crate (so it can reflect on YOUR procedural macros) —
// we just call into uniffi's main entry point.
fn main() {
    uniffi::uniffi_bindgen_main()
}
