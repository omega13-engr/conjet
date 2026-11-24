use std::time::Duration;

use conjet_launch_service::spec::{valid_volume_target, VolumeMount};
use conjet_launch_service::volume_disk::{encode_labels, valid_name, VolumeLabels};
use conjet_launch_service::wire::{Kind, WireError};
use serde_json::{json, Value};

use super::{client, request, Owner, Rejected};

#[derive(Debug, PartialEq)]
pub(super) struct Mount<'a> {
    pub name: &'a str,
    pub target: &'a str,
    pub read_only: bool,
}

pub(super) fn requested(config: &Value) -> Result<Option<Mount<'_>>, Rejected> {
    let value = &config["HostConfig"]["Mounts"];
    let binds = &config["HostConfig"]["Binds"];
    let has_binds = !binds.is_null() && !binds.as_array().is_some_and(Vec::is_empty);
    if value.is_null() || value.as_array().is_some_and(Vec::is_empty) {
        return if has_binds {
            named_bind(binds).map(Some)
        } else {
            Ok(None)
        };
    }
    if has_binds {
        return Err(Rejected::bad("only one native named volume is supported"));
    }
    let Some([mount]) = value.as_array().map(Vec::as_slice) else {
        return Err(Rejected::bad("only one native named volume is supported"));
    };
    let mount = request::object(mount, "Docker mount")?
        .ok_or_else(|| Rejected::bad("invalid Docker mount"))?;
    for key in mount.keys() {
        if !["Type", "Source", "Target", "ReadOnly", "VolumeOptions"].contains(&key.as_str()) {
            return Err(Rejected::bad(format!(
                "unsupported native mount option {key}"
            )));
        }
    }
    let naming = |field: &str| mount.get(field).and_then(Value::as_str);
    if naming("Type") != Some("volume") {
        return Err(Rejected::bad("require a named volume"));
    }
    let target = naming("Target")
        .filter(|target| valid_volume_target(target))
        .ok_or_else(|| Rejected::bad("unsupported native volume target"))?;
    let name = naming("Source")
        .filter(|name| valid_name(name))
        .ok_or_else(|| Rejected::bad("invalid native volume name"))?;
    let read_only = mount.get("ReadOnly").map_or(Ok(false), |flag| {
        flag.as_bool()
            .ok_or_else(|| Rejected::bad("invalid native volume ReadOnly flag"))
    })?;
    if let Some(options) = mount.get("VolumeOptions") {
        if let Some(options) = request::object(options, "Docker VolumeOptions")? {
            if options
                .iter()
                .any(|(key, value)| key != "NoCopy" || !value.is_boolean())
            {
                return Err(Rejected::bad("unsupported native VolumeOptions"));
            }
        }
    }
    Ok(Some(Mount {
        name,
        target,
        read_only,
    }))
}

fn named_bind(value: &Value) -> Result<Mount<'_>, Rejected> {
    let Some([binding]) = value.as_array().map(Vec::as_slice) else {
        return Err(Rejected::bad("only one native named volume is supported"));
    };
    let invalid = || Rejected::bad("HostConfig Binds requires a named volume and supported target");
    let mut parts = binding.as_str().ok_or_else(invalid)?.split(':');
    let name = parts
        .next()
        .filter(|name| valid_name(name))
        .ok_or_else(invalid)?;
    let target = parts
        .next()
        .filter(|target| valid_volume_target(target))
        .ok_or_else(invalid)?;
    let read_only = match parts.next() {
        None | Some("rw") => false,
        Some("ro") => true,
        _ => return Err(invalid()),
    };
    if parts.next().is_some() {
        return Err(invalid());
    }
    Ok(Mount {
        name,
        target,
        read_only,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_mount_syntax_keeps_host_paths_and_flags_out() {
        assert_eq!(
            named_bind(&json!(["owned:/data:ro"])).unwrap(),
            Mount {
                name: "owned",
                target: "/data",
                read_only: true
            }
        );
        for input in [
            "/host/path:/data",
            "../relative:/data",
            "owned:/etc",
            "owned:/data:rw,z",
            "owned:/data:ro:rw",
        ] {
            assert!(named_bind(&json!([input])).is_err(), "{input}");
        }
    }
}

pub(super) fn ask(owner: &Owner, action: &str, name: Option<&str>) -> Result<Value, Rejected> {
    let mut operation = json!({"action":action});
    if let Some(name) = name {
        if !valid_name(name) {
            return Err(Rejected::bad("invalid native volume name"));
        }
        operation["name"] = json!(name);
    }
    exchange(owner, operation)
}

fn exchange(owner: &Owner, operation: Value) -> Result<Value, Rejected> {
    let (directory, identity, key, boot) = {
        let native = owner.native.lock().unwrap();
        (
            native.peer_directory.clone(),
            native.identity.clone(),
            native.key,
            native.boot.clone(),
        )
    };
    let mut peer = client::Connection::open(&directory, &identity, &key).map_err(|error| {
        Rejected::internal(format!("native volume channel unavailable ({error})"))
    })?;
    if peer.boot != boot {
        return Err(Rejected::internal("native volume generation changed"));
    }
    match peer.exchange(
        Kind::Volume,
        Kind::Volume,
        &json!({
            "boot_id":boot,"budget_ms":1500,"operation":operation,
        }),
        Duration::from_secs(2),
    ) {
        Ok(value) => Ok(value),
        Err(WireError::PeerError(code)) => Err(match code.as_str() {
            "not_found" => Rejected(404, "native volume was not found".into()),
            "in_use" => Rejected(409, "native volume is in use".into()),
            "capacity" => Rejected(409, "native volume capacity exhausted".into()),
            "unsupported_option" => Rejected(501, "native volume disk is not configured".into()),
            "malformed" => Rejected::bad("invalid native volume request"),
            _ => Rejected::internal(format!("native volume operation failed ({code})")),
        }),
        Err(error) => Err(Rejected::internal(format!(
            "native volume outcome is unknown ({error})"
        ))),
    }
}

fn describe(name: &str, labels: &Value) -> Value {
    json!({"Name":name,"Driver":"local","Mountpoint":guest_path(name),"Scope":"local",
           "Options":{},"Labels":labels})
}

pub(super) fn inspect(owner: &Owner, name: &str) -> Result<Value, Rejected> {
    let info = ask(owner, "inspect", Some(name))?;
    Ok(describe(name, &info["labels"]))
}

fn guest_path(name: &str) -> String {
    format!("/run/conjet/volume-disk/volumes/{name}")
}

pub(super) fn list(owner: &Owner, filters: &super::discovery::Filters) -> Result<Value, Rejected> {
    let names = exchange(owner, json!({"action":"list","details":true}))?;
    let volumes = names["volumes"]
        .as_array()
        .ok_or_else(|| Rejected::internal("invalid native volume inventory"))?
        .iter()
        .map(|info| {
            info["name"]
                .as_str()
                .filter(|name| valid_name(name))
                .map(|name| (name, &info["labels"]))
                .ok_or_else(|| Rejected::internal("invalid native volume inventory name"))
        })
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .filter(|(name, labels)| filters.matches(name, labels))
        .map(|(name, labels)| describe(name, labels))
        .collect::<Vec<_>>();
    Ok(json!({"Volumes":volumes,"Warnings":[]}))
}

pub(super) fn create(owner: &Owner, body: &Value) -> Result<Value, Rejected> {
    let data = request::object(body, "Docker volume request")?
        .ok_or_else(|| Rejected::bad("invalid Docker volume request"))?;
    request::options(data, &["Name", "Driver", "Labels"], "volume ")?;
    if !body["Driver"].is_null() && body["Driver"] != "" && body["Driver"] != "local" {
        return Err(Rejected::bad(
            "only the native local volume driver is supported",
        ));
    }
    let name = body["Name"]
        .as_str()
        .filter(|name| valid_name(name))
        .ok_or_else(|| Rejected::bad("native volume creation requires a name"))?;
    let labels: VolumeLabels = if body["Labels"].is_null() {
        VolumeLabels::new()
    } else {
        serde_json::from_value(body["Labels"].clone())
            .map_err(|_| Rejected::bad("invalid native volume labels"))?
    };
    encode_labels(&labels).map_err(|error| Rejected::bad(error.to_string()))?;
    let info = exchange(
        owner,
        json!({"action":"create","name":name,"labels":labels}),
    )?;
    Ok(describe(name, &info["labels"]))
}

pub(super) fn mount_metadata(volume: &VolumeMount) -> Value {
    json!({"Type":"volume","Name":volume.name,"Source":guest_path(&volume.name),
           "Destination":volume.target,"Driver":"local","RW":!volume.read_only,
           "Mode":if volume.read_only {"ro"} else {"rw"},"Propagation":""})
}
