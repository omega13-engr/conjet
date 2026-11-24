use std::time::Duration;

const PROOF: &[u8] = b"native build snapshot proof\n";
const PATH: &str = "/output/proof";

fn main() -> std::io::Result<()> {
    match std::env::args().nth(1).as_deref() {
        Some("hold") => {
            std::fs::write(PATH, PROOF)?;
            println!("wrote snapshot");
            std::thread::sleep(Duration::from_secs(12));
        }
        Some("verify") => {
            if std::fs::read(PATH)? != PROOF {
                return Err(std::io::Error::other("snapshot payload differs"));
            }
            println!("persisted snapshot");
        }
        _ => return Err(std::io::Error::other("expected hold or verify")),
    }
    Ok(())
}
