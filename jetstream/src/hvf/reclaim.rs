//! Synchronous backing release while the guest has transferred page ownership.

use crate::devices::balloon::ReclaimAuthority;

pub(super) trait ReleaseOperations {
    fn detach(&mut self) -> Result<(), String>;
    fn discard(&mut self) -> Result<(), String>;
    fn restore_mapping(&mut self) -> Result<(), String>;
}

#[derive(Debug, PartialEq, Eq)]
pub(super) enum ReleaseError {
    Recoverable(String),
    // Continuing or acknowledging a report would expose an unmapped GPA.
    MappingUnavailable(String),
}

pub(super) fn release_owned(
    operations: &mut impl ReleaseOperations,
    authority: ReclaimAuthority,
) -> Result<(), ReleaseError> {
    operations.detach().map_err(ReleaseError::Recoverable)?;
    let discarded = operations.discard();
    // Reports end their ownership lease at ACK. Balloon pages stay detached
    // until MUST_TELL_HOST deflate restores them. A failed discard must put
    // either kind back into its original mapped state before a fallback.
    if authority == ReclaimAuthority::ReportInFlight || discarded.is_err() {
        operations
            .restore_mapping()
            .map_err(ReleaseError::MappingUnavailable)?;
    }
    discarded.map_err(ReleaseError::Recoverable)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct Operations {
        calls: Vec<&'static str>,
        fail: Option<&'static str>,
    }

    impl Operations {
        fn call(&mut self, name: &'static str) -> Result<(), String> {
            self.calls.push(name);
            if self.fail == Some(name) {
                Err(name.to_string())
            } else {
                Ok(())
            }
        }
    }

    impl ReleaseOperations for Operations {
        fn detach(&mut self) -> Result<(), String> {
            self.call("detach")
        }
        fn discard(&mut self) -> Result<(), String> {
            self.call("discard")
        }
        fn restore_mapping(&mut self) -> Result<(), String> {
            self.call("restore")
        }
    }

    #[test]
    fn reported_pages_are_remapped_before_success() {
        let mut operations = Operations::default();
        assert_eq!(
            release_owned(&mut operations, ReclaimAuthority::ReportInFlight),
            Ok(())
        );
        assert_eq!(operations.calls, ["detach", "discard", "restore"]);
    }

    #[test]
    fn balloon_pages_remain_detached_until_deflate() {
        let mut operations = Operations::default();
        assert_eq!(
            release_owned(&mut operations, ReclaimAuthority::BalloonOwned),
            Ok(())
        );
        assert_eq!(operations.calls, ["detach", "discard"]);
    }

    #[test]
    fn failed_detach_does_not_discard_or_remap() {
        let mut operations = Operations {
            fail: Some("detach"),
            ..Operations::default()
        };
        assert!(matches!(
            release_owned(&mut operations, ReclaimAuthority::ReportInFlight),
            Err(ReleaseError::Recoverable(_))
        ));
        assert_eq!(operations.calls, ["detach"]);
    }

    #[test]
    fn failed_discard_restores_mapping_before_fallback_for_both_authorities() {
        for authority in [
            ReclaimAuthority::BalloonOwned,
            ReclaimAuthority::ReportInFlight,
        ] {
            let mut operations = Operations {
                fail: Some("discard"),
                ..Operations::default()
            };
            assert!(matches!(
                release_owned(&mut operations, authority),
                Err(ReleaseError::Recoverable(_))
            ));
            assert_eq!(operations.calls, ["detach", "discard", "restore"]);
        }
    }

    #[test]
    fn failed_report_remap_is_fatal_to_the_vm() {
        let mut operations = Operations {
            fail: Some("restore"),
            ..Operations::default()
        };
        assert!(matches!(
            release_owned(&mut operations, ReclaimAuthority::ReportInFlight),
            Err(ReleaseError::MappingUnavailable(_))
        ));
    }
}
