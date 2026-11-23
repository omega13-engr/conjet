use std::path::PathBuf;

use clap::{Args, Subcommand};

mod client;
mod oci;
mod session;

#[derive(Debug, Args)]
pub struct Arguments {
    /// Explicitly opt in to the unsupported-by-default native runtime.
    #[arg(long, required = true)]
    experimental: bool,
    #[command(subcommand)]
    command: Action,
}

#[derive(Debug, Subcommand)]
enum Action {
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
    assert!(args.experimental, "clap enforces explicit opt-in");
    match args.command {
        Action::Serve(options) => session::serve(options),
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
