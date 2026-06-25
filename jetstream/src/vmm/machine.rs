use anyhow::Context;

use crate::hvf::boot::{default_virtio_plan, HvfBootOptions, HvfBootReport, HvfBootRunner};
use crate::vmm::boot::BootPlan;
use crate::vmm::config::JetstreamConfig;

#[derive(Debug)]
pub struct MachineBuilder {
    config: JetstreamConfig,
}

impl MachineBuilder {
    pub fn new(config: JetstreamConfig) -> Self {
        Self { config }
    }

    pub fn build(self) -> anyhow::Result<Machine> {
        let plan = BootPlan::new(&self.config).context("failed to build Jetstream boot plan")?;
        Ok(Machine {
            config: self.config,
            plan,
        })
    }
}

#[derive(Debug)]
pub struct Machine {
    config: JetstreamConfig,
    plan: BootPlan,
}

impl Machine {
    pub fn plan(&self) -> &BootPlan {
        &self.plan
    }

    pub fn run(&self, options: HvfBootOptions) -> HvfBootReport {
        let virtio_devices = default_virtio_plan(&self.config);
        HvfBootRunner::new(
            self.config.clone(),
            self.plan.clone(),
            virtio_devices,
            options,
        )
        .run()
    }
}
