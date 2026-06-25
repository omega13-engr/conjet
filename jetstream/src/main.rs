use std::path::PathBuf;

use anyhow::Context;
use clap::{Parser, Subcommand};
use jetstream::hvf::boot::HvfBootOptions;
use jetstream::hvf::smoke::HvfSmokeRunner;
use jetstream::vmm::config::{BootSource, JetstreamConfig, VmAssetManifest};
use jetstream::vmm::machine::MachineBuilder;

#[derive(Debug, Parser)]
#[command(name = "jetstream")]
#[command(about = "Conjet Jetstream Rust microVM monitor")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Validate the host can create and run a tiny HVF VM.
    Smoke {
        /// Emit machine-readable JSON.
        #[arg(long)]
        json: bool,
    },
    /// Validate a Conjet VM asset manifest and print the Rust VMM boot plan.
    Validate {
        #[arg(long)]
        manifest: PathBuf,
        #[arg(long, default_value_t = 512)]
        memory_mib: u64,
        #[arg(long, default_value_t = 1)]
        cpus: u8,
        /// Emit pretty JSON.
        #[arg(long)]
        json: bool,
    },
    /// Prepare the direct-kernel boot plan. Device execution is still gated.
    Boot {
        #[arg(long)]
        manifest: PathBuf,
        #[arg(long, default_value_t = 512)]
        memory_mib: u64,
        #[arg(long, default_value_t = 1)]
        cpus: u8,
        /// Maximum vCPU exits before stopping the bounded boot attempt.
        #[arg(long, default_value_t = 16_384)]
        max_exits: u64,
        /// Maximum wall-clock runtime for the boot attempt before waking vCPUs.
        #[arg(long, default_value_t = 30_000)]
        max_runtime_ms: u64,
        /// Periodically wake vCPUs so host-driven vsock traffic is serviced while the guest is blocked.
        #[arg(long, default_value_t = 0)]
        host_tick_ms: u64,
        /// Do not require CONJET_INIT_READY; useful for early Linux console bring-up.
        #[arg(long)]
        early_console_only: bool,
        /// Continue after conjet-init and require Docker API /_ping on the isolated socket.
        #[arg(long)]
        require_docker_ready: bool,
        /// Docker API readiness probe timeout. A value of 0 disables the probe unless --require-docker-ready is set.
        #[arg(long, default_value_t = 0)]
        docker_probe_timeout_ms: u64,
        /// Keep the VM running for this long after the requested readiness gate passes.
        #[arg(long, default_value_t = 0)]
        hold_after_ready_ms: u64,
        /// Keep the VM running until the host process is terminated after the readiness gate passes.
        #[arg(long)]
        hold_after_ready_forever: bool,
        /// Initial guest memory target for virtio-balloon QA. Defaults to no balloon target.
        #[arg(long)]
        balloon_target_mib: Option<u64>,
        /// Host Unix socket for live virtio-balloon target updates and metrics.
        #[arg(long)]
        memory_control_socket: Option<PathBuf>,
        /// Emit pretty JSON boot report.
        #[arg(long)]
        json: bool,
        /// Stop after validation and planning.
        #[arg(long)]
        dry_run: bool,
    },
}

fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Smoke { json } => {
            let report = HvfSmokeRunner::default().run();
            if json {
                println!("{}", serde_json::to_string_pretty(&report)?);
            } else {
                println!("{}", report.summary());
            }
            if report.ok {
                Ok(())
            } else {
                anyhow::bail!("{}", report.summary())
            }
        }
        Command::Validate {
            manifest,
            memory_mib,
            cpus,
            json,
        } => {
            let cfg = config_from_manifest(manifest, memory_mib, cpus)?;
            let machine = MachineBuilder::new(cfg).build()?;
            if json {
                println!("{}", serde_json::to_string_pretty(machine.plan())?);
            } else {
                println!("{}", machine.plan().summary());
            }
            Ok(())
        }
        Command::Boot {
            manifest,
            memory_mib,
            cpus,
            max_exits,
            max_runtime_ms,
            host_tick_ms,
            early_console_only,
            require_docker_ready,
            docker_probe_timeout_ms,
            hold_after_ready_ms,
            hold_after_ready_forever,
            balloon_target_mib,
            memory_control_socket,
            json,
            dry_run,
        } => {
            let cfg = config_from_manifest(manifest, memory_mib, cpus)?;
            let machine = MachineBuilder::new(cfg).build()?;
            if dry_run {
                if json {
                    println!("{}", serde_json::to_string_pretty(machine.plan())?);
                } else {
                    println!("{}", machine.plan().summary());
                }
                return Ok(());
            }
            let report = machine.run(HvfBootOptions {
                max_exits,
                max_runtime_ms,
                host_tick_ms,
                require_conjet_ready: !early_console_only,
                require_docker_ready,
                docker_probe_timeout_ms: if require_docker_ready && docker_probe_timeout_ms == 0 {
                    45_000
                } else {
                    docker_probe_timeout_ms
                },
                hold_after_ready_ms,
                hold_after_ready_forever,
                balloon_target_mib,
                memory_control_socket,
            });
            if json {
                println!("{}", serde_json::to_string_pretty(&report)?);
            } else {
                println!("{}", report.message);
                if !report.console_output.is_empty() {
                    println!("{}", report.console_output);
                }
            }
            if report.ok {
                Ok(())
            } else {
                anyhow::bail!("{}", report.message)
            }
        }
    }
}

fn config_from_manifest(
    path: PathBuf,
    memory_mib: u64,
    cpus: u8,
) -> anyhow::Result<JetstreamConfig> {
    let bytes = std::fs::read(&path)
        .with_context(|| format!("failed to read VM asset manifest {}", path.display()))?;
    let mut manifest: VmAssetManifest = serde_json::from_slice(&bytes)
        .with_context(|| format!("failed to decode VM asset manifest {}", path.display()))?;
    let epoch_ms = refresh_host_clock_seed(&manifest)?;
    manifest.kernel_command_line =
        kernel_command_line_with_host_epoch(&manifest.kernel_command_line, epoch_ms);
    Ok(JetstreamConfig {
        memory_mib,
        vcpu_count: cpus,
        boot_source: BootSource::from_manifest(manifest),
    })
}

fn refresh_host_clock_seed(manifest: &VmAssetManifest) -> anyhow::Result<u128> {
    let epoch_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .context("host clock is before UNIX epoch")?
        .as_millis();
    let seed_path = manifest.bootstrap_share_path.join("host-epoch-ms");
    if let Some(parent) = seed_path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("failed to create bootstrap share {}", parent.display()))?;
    }
    std::fs::write(&seed_path, format!("{epoch_ms}\n"))
        .with_context(|| format!("failed to write host clock seed {}", seed_path.display()))?;
    Ok(epoch_ms)
}

fn kernel_command_line_with_host_epoch(command_line: &str, epoch_ms: u128) -> String {
    let mut tokens = command_line
        .split_whitespace()
        .filter(|token| !token.starts_with("conjet.host_epoch_ms="))
        .map(str::to_string)
        .collect::<Vec<_>>();
    tokens.push(format!("conjet.host_epoch_ms={epoch_ms}"));
    tokens.join(" ")
}
