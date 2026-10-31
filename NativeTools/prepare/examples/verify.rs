//! cargo run --example verify <signed file>: checks the signature and prints what it says.
use apple_codesign::{MachFile, verify_macho_data};
fn main() {
    let path = std::env::args().nth(1).expect("file");
    let data = std::fs::read(&path).unwrap();
    let problems = verify_macho_data(&data);
    for p in &problems { println!("problem: {p}"); }
    let file = MachFile::parse(&data).unwrap();
    for macho in file.iter_macho() {
        let sig = macho.code_signature().unwrap().unwrap();
        let cd = sig.code_directory().unwrap().unwrap();
        println!("identifier {} team {:?} flags {:?} pages {}", cd.ident, cd.team_name, cd.flags, cd.code_digests.len());
        if let Some(cms) = sig.signature_data().unwrap() { println!("cms {} bytes", cms.len()); }
    }
    println!("{} problems", problems.len());
}
