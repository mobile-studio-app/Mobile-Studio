//! Makes a macOS ARM64 program (from a VS Code extension) loadable in DuoCode on iOS: picks
//! its ARM64 code, rewrites it as a library (see macho.rs), and signs it with the user's own
//! development certificate. iOS loads code signed by the team that signed the app, so this
//! needs no JIT, no debugger and no VPN.

pub mod macho;

use apple_codesign::{
    cryptography::{parse_pfx_data, InMemoryPrivateKey, PrivateKey},
    AppleCertificate, MachOSigner, SettingsScope, SigningSettings,
};
use std::ffi::{c_char, CStr};
use x509_certificate::CapturedX509Certificate;

/// The certificate and private key in a .p12 (PKCS #12) file. Plume Impactor and current
/// tools encrypt them with AES (read with p12-keystore); older ones with legacy ciphers.
pub fn identity(p12: &[u8], password: &str) -> Result<(CapturedX509Certificate, InMemoryPrivateKey), String> {
    let modern = p12_keystore::KeyStore::from_pkcs12(p12, password).map_err(|e| e.to_string()).and_then(|store| {
        let (_, chain) = store.private_key_chain().ok_or("it has no private key")?;
        let certificate = chain.chain().first().ok_or("it has no certificate")?;
        let certificate = CapturedX509Certificate::from_der(certificate.as_der().to_vec()).map_err(|e| e.to_string())?;
        let key = InMemoryPrivateKey::from_pkcs8_der(chain.key()).map_err(|e| e.to_string())?;
        Ok((certificate, key))
    });
    modern.or_else(|modern_error| parse_pfx_data(p12, password).map_err(|e| match e {
        apple_codesign::AppleCodesignError::PfxBadPassword => "The certificate's password is wrong.".to_string(),
        _ => format!("The certificate couldn't be read: {modern_error}"),
    }))
}

/// Signs a Mach-O with the certificate and key in a .p12 file.
pub fn sign(data: &[u8], identifier: &str, p12: &[u8], password: &str) -> Result<Vec<u8>, String> {
    let (certificate, key) = identity(p12, password)?;
    let mut settings = SigningSettings::default();
    settings.set_signing_key(key.as_key_info_signer(), certificate);
    settings.chain_apple_certificates();
    settings.set_team_id_from_signing_certificate();
    settings.set_binary_identifier(SettingsScope::Main, identifier);
    let signer = MachOSigner::new(data).map_err(|e| format!("The program couldn't be read for signing: {e}"))?;
    let mut out = Vec::with_capacity(data.len() + (1 << 20));
    signer.write_signed_binary(&settings, &mut out).map_err(|e| format!("Signing failed: {e}"))?;
    Ok(out)
}

/// The team ID (organizational unit) of the certificate in a .p12, to check it matches the app's.
pub fn team_id(p12: &[u8], password: &str) -> Result<String, String> {
    let (certificate, _) = identity(p12, password)?;
    certificate.apple_team_id().ok_or_else(|| "It isn't an Apple development certificate.".to_string())
}

/// Reads, prepares and signs `input`, writing the library to `output` and the description of
/// its entry point and imports (see Prepared::describe) to `output` + ".imports".
pub fn prepare_file(input: &str, output: &str, p12: &[u8], password: &str) -> Result<(), String> {
    let data = std::fs::read(input).map_err(|e| format!("{input} couldn't be read: {e}"))?;
    let slice = macho::arm64_slice(&data).map_err(|e| e.0)?;
    let id_name = std::path::Path::new(output).file_stem().and_then(|s| s.to_str()).unwrap_or("tool");
    let id_name: String = id_name.chars().take(7).collect();
    let prepared = macho::prepare(slice, &id_name).map_err(|e| e.0)?;
    let identifier = format!("duocode.tool.{}", std::path::Path::new(input).file_name().and_then(|s| s.to_str()).unwrap_or("tool"));
    let signed = sign(&prepared.data, &identifier, p12, password)?;
    // Written under a temporary name first: the loader treats an existing file as ready.
    let temporary = format!("{output}.partial");
    std::fs::write(format!("{output}.imports"), prepared.describe()).map_err(|e| format!("Couldn't save: {e}"))?;
    std::fs::write(&temporary, signed).map_err(|e| format!("Couldn't save: {e}"))?;
    std::fs::rename(&temporary, output).map_err(|e| format!("Couldn't save: {e}"))?;
    Ok(())
}

unsafe fn text(pointer: *const c_char) -> String {
    if pointer.is_null() { String::new() } else { CStr::from_ptr(pointer).to_string_lossy().into_owned() }
}

/// Copies `message` into the caller's buffer (always NUL-terminated).
unsafe fn report(message: &str, error: *mut c_char, capacity: usize) {
    if error.is_null() || capacity == 0 {
        return;
    }
    let bytes = message.as_bytes();
    let length = bytes.len().min(capacity - 1);
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), error as *mut u8, length);
    *error.add(length) = 0;
}

/// C entry point: 0 on success; otherwise the reason is in `error`.
///
/// # Safety
/// Strings must be NUL-terminated, `p12` must point to `p12_length` bytes and `error` to
/// `error_capacity` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn dc_prepare_program(input: *const c_char, output: *const c_char, p12: *const u8, p12_length: usize,
                                            password: *const c_char, error: *mut c_char, error_capacity: usize) -> i32 {
    let input = text(input);
    let output = text(output);
    let password = text(password);
    let p12 = if p12.is_null() { &[][..] } else { std::slice::from_raw_parts(p12, p12_length) };
    match std::panic::catch_unwind(|| prepare_file(&input, &output, p12, &password)) {
        Ok(Ok(())) => 0,
        Ok(Err(message)) => { report(&message, error, error_capacity); 1 }
        Err(_) => { report("Preparing the program failed unexpectedly.", error, error_capacity); 2 }
    }
}

/// C entry point: writes the certificate's team ID to `team` and returns 0, or the reason to
/// `team` and returns 1.
///
/// # Safety
/// As for dc_prepare_program.
#[no_mangle]
pub unsafe extern "C" fn dc_certificate_team(p12: *const u8, p12_length: usize, password: *const c_char,
                                             team: *mut c_char, capacity: usize) -> i32 {
    let password = text(password);
    let p12 = if p12.is_null() { &[][..] } else { std::slice::from_raw_parts(p12, p12_length) };
    match std::panic::catch_unwind(|| team_id(p12, &password)) {
        Ok(Ok(id)) => { report(&id, team, capacity); 0 }
        Ok(Err(message)) => { report(&message, team, capacity); 1 }
        Err(_) => { report("The certificate couldn't be read.", team, capacity); 1 }
    }
}
