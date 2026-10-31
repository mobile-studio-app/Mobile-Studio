//! For testing on a computer: prepare <program> <output> <certificate.p12> [password]
fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: prepare <program> <output> <certificate.p12> [password]");
        std::process::exit(2);
    }
    let p12 = std::fs::read(&args[3]).expect("certificate");
    let password = args.get(4).map(String::as_str).unwrap_or("");
    match duocode_prepare::team_id(&p12, password) {
        Ok(team) => println!("team {team}"),
        Err(e) => println!("team: {e}"),
    }
    if let Err(e) = duocode_prepare::prepare_file(&args[1], &args[2], &p12, password) {
        eprintln!("{e}");
        std::process::exit(1);
    }
    println!("prepared {}", args[2]);
}
