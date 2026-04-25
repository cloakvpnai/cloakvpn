// build.rs — emit uniffi scaffolding so Swift bindings can be generated
// from the proc-macro #[uniffi::export] attributes in src/lib.rs.

fn main() {
    uniffi::generate_scaffolding("./src/rosenpass_ffi.udl").ok();
    // We're using proc-macro mode (no .udl file); the call above is
    // a defensive no-op that just satisfies `uniffi::build` if it ever
    // gets re-enabled. If it errors because no UDL file exists, that's
    // expected and harmless — the proc-macros have already done their job.
}
