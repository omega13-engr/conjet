use std::io::Read;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use anyhow::{ensure, Context};
use base64::Engine;
use clap::Args;
use conjet_launch_service::handshake::{hex, random, unhex};
use conjet_launch_service::oci::{Root, PACKAGE_LIMIT};
use conjet_launch_service::wire::Kind;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use super::{admission_lock, client, private_scratch, CHUNK, SCRATCH};

#[derive(Debug, Args)]
pub(in crate::native) struct InstallOptions {
    #[arg(long)]
    session: PathBuf,
    #[arg(long)]
    package: PathBuf,
    #[arg(long)]
    sha256: String,
}

pub(in crate::native) fn install(options: InstallOptions) -> anyhow::Result<()> {
    private_scratch(&options.session)?;
    let path = options.package.canonicalize()?;
    ensure!(
        path == options.package && path.starts_with(SCRATCH),
        "expected ExternalSSD OCI package"
    );
    let file = std::fs::File::open(path)?;
    let metadata = file.metadata()?;
    ensure!(
        metadata.is_file() && metadata.len() <= PACKAGE_LIMIT,
        "invalid OCI package file"
    );
    let mut package = Vec::new();
    file.take(PACKAGE_LIMIT + 1).read_to_end(&mut package)?;
    let digest = unhex::<32>(&options.sha256)?;
    ensure!(
        Sha256::digest(&package)[..] == digest,
        "OCI package SHA-256 mismatch"
    );
    let image = Root::read(&package)?.config_digest;
    let _lock = admission_lock(&options.session)?;
    let (identity, key) = client::load(&options.session)?;
    let mut peer = client::Connection::open(&options.session, &identity, &key)?;
    ensure!(peer.oci, "native guest lacks OCI capability");
    let state = peer.inspect()?;
    ensure!(
        state["workload"].is_null() || state["workload"]["cleanup"] == "complete",
        "native image installation requires an idle Docker guest"
    );
    let response = install_with_peer(&mut peer, &image, &options.sha256, &package)?;
    println!(
        "{}",
        json!({"boot_id":peer.boot,"image":response,"package_sha256":options.sha256})
    );
    Ok(())
}

pub(super) fn image_request(
    peer: &mut client::Connection,
    operation: Value,
    budget_ms: u64,
) -> anyhow::Result<Value> {
    Ok(peer.exchange(
        Kind::Image,
        Kind::Image,
        &json!({"boot_id":peer.boot, "budget_ms":budget_ms, "operation":operation}),
        Duration::from_millis(budget_ms + 1000),
    )?)
}

pub(super) fn install_with_peer(
    peer: &mut client::Connection,
    image: &str,
    sha256: &str,
    package: &[u8],
) -> anyhow::Result<Value> {
    let deadline = Instant::now() + Duration::from_secs(45);
    let transfer = hex(&random::<16>()?);
    let begin = image_request(
        peer,
        json!({
            "action":"begin", "transfer":transfer, "config_digest":image,
            "package_digest":format!("sha256:{sha256}"), "size":package.len()
        }),
        1000,
    )?;
    ensure!(
        begin["offset"] == 0,
        "unexpected initial OCI transfer offset"
    );
    let mut offset = 0;
    for chunk in package.chunks(CHUNK) {
        ensure!(Instant::now() < deadline, "OCI transfer deadline elapsed");
        let reply = image_request(
            peer,
            json!({
                "action":"write", "transfer":transfer, "offset":offset,
                "data":base64::engine::general_purpose::STANDARD.encode(chunk)
            }),
            1000,
        )?;
        offset += chunk.len();
        ensure!(
            reply["offset"].as_u64() == Some(offset as u64),
            "unexpected OCI transfer acknowledgement"
        );
    }
    // A lost commit reply may have published the image. Drop the
    // connection and use Inspect to reconcile before attempting again.
    let budget = deadline
        .saturating_duration_since(Instant::now())
        .as_millis()
        .min(10000) as u64;
    ensure!(budget > 0, "OCI transfer deadline elapsed");
    let reply = image_request(peer, json!({"action":"commit","transfer":transfer}), budget)
        .context("OCI commit outcome requires inspection if the connection was lost")?;
    ensure!(
        reply["state"] == "installed" && reply["config_digest"] == image,
        "invalid OCI installation acknowledgement"
    );
    Ok(reply)
}
