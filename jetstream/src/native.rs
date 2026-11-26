use std::path::PathBuf;

use anyhow::ensure;
use clap::{Args, Subcommand};

mod client;
mod docker;
mod oci;
mod oci_stage;
mod session;
mod volume_disk;

#[derive(Debug, Args)]
pub struct Arguments {
    /// Explicitly opt in to the unsupported-by-default native runtime.
    #[arg(long, global = true)]
    experimental: bool,
    /// Canonical private profile directory for a managed Docker session.
    #[arg(long, global = true)]
    profile_root: Option<PathBuf>,
    #[command(subcommand)]
    command: Action,
}

#[derive(Debug, Subcommand)]
enum Action {
    /// Boot the isolated Docker OCI candidate.
    DockerBoot(session::Options),
    /// Serve the Docker API against the isolated native OCI guest.
    DockerServe(docker::Options),
    /// Verify and stage an OCI manifest from a private content layout.
    DockerStage(oci_stage::Options),
    /// Install a verified OCI package into an idle candidate guest.
    DockerInstall(docker::InstallOptions),
    /// Drain the isolated native OCI guest.
    DockerStop {
        #[arg(long)]
        session: PathBuf,
    },
    /// Boot a private, no-network guest in this foreground process.
    Serve(session::Options),
    /// Execute the pinned workload with fresh isolation.
    Run(client::Target),
    /// Create one private slot with a five-second lifetime.
    Prepare(client::Target),
    /// Consume a returned slot token once and wait for verified cleanup.
    Claim {
        #[command(flatten)]
        target: client::Target,
        token: String,
    },
    /// Inspect the active or last retained workload.
    Status(client::Target),
    /// Cancel a workload or discard a prepared slot.
    Cancel {
        #[command(flatten)]
        target: client::Target,
        token: String,
    },
    /// Inspect guest memory or request eviction of an unused slot.
    Memory {
        #[command(flatten)]
        target: client::Target,
        #[arg(long, value_enum)]
        pressure: Option<client::Pressure>,
    },
    /// Drain the session and power off its guest.
    Stop {
        #[arg(long)]
        session: PathBuf,
    },
}

pub fn run(args: Arguments) -> anyhow::Result<()> {
    let docker_command = matches!(
        args.command,
        Action::DockerBoot(_)
            | Action::DockerServe(_)
            | Action::DockerStage(_)
            | Action::DockerInstall(_)
            | Action::DockerStop { .. }
    );
    ensure!(
        args.experimental || docker_command,
        "native command requires --experimental"
    );
    ensure!(
        args.profile_root.is_none() || docker_command,
        "profile root applies only to native Docker commands"
    );
    let root = docker::session_root(args.profile_root.as_deref())?;
    let parent = args
        .profile_root
        .as_ref()
        .map(|_| unsafe { libc::getppid() });
    ensure!(
        parent.is_none_or(|pid| pid > 1),
        "managed native Docker requires a live supervisor"
    );
    match args.command {
        Action::DockerBoot(options) => docker::boot(options, root, parent),
        Action::DockerServe(options) => docker::serve(options, root, parent),
        Action::DockerStage(options) => oci_stage::stage(options, root),
        Action::DockerInstall(options) => docker::install(options, root),
        Action::DockerStop { session } => docker::stop(&session, root),
        Action::Serve(options) => session::serve(options, None, None),
        Action::Run(target) => client::invoke(target, client::Operation::Run),
        Action::Prepare(target) => client::invoke(target, client::Operation::Prepare),
        Action::Claim { target, token } => client::invoke(target, client::Operation::Claim(token)),
        Action::Status(target) => client::invoke(target, client::Operation::Status),
        Action::Cancel { target, token } => {
            client::invoke(target, client::Operation::Cancel(token))
        }
        Action::Memory { target, pressure } => {
            client::invoke(target, client::Operation::Memory(pressure))
        }
        Action::Stop { session } => client::stop(&session),
    }
}
