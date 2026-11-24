use std::time::Duration;

use conjet_launch_service::spec::{VolumeMount, VOLUME_TARGET};
use conjet_launch_service::volume_disk::valid_name;
use conjet_launch_service::wire::{Kind, WireError};
use serde_json::{json, Value};

use super::{client, request, Owner, Rejected};

pub(super) fn requested(config: &Value) -> Result<Option<(&str, bool)>, Rejected> {
    let value = &config["HostConfig"]["Mounts"];
    if value.is_null() || value.as_array().is_some_and(Vec::is_empty) {
        return Ok(None);
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
    if naming("Type") != Some("volume") || naming("Target") != Some(VOLUME_TARGET) {
        return Err(Rejected::bad("require a named volume mounted at /data"));
    }
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
    Ok(Some((name, read_only)))
}

pub(super) fn ask(owner: &Owner, action: &str, name: Option<&str>) -> Result<Value, Rejected> {
    let mut operation = json!({"action":action});
    if let Some(name) = name {
        if !valid_name(name) {
            return Err(Rejected::bad("invalid native volume name"));
        }
        operation["name"] = json!(name);
    }
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

pub(super) fn describe(name: &str) -> Value {
    json!({"Name":name,"Driver":"local","Mountpoint":guest_path(name),"Scope":"local",
           "Options":{},"Labels":{}})
}

fn guest_path(name: &str) -> String {
    format!("/run/conjet/volume-disk/volumes/{name}")
}

pub(super) fn list(owner: &Owner) -> Result<Value, Rejected> {
    let names = ask(owner, "list", None)?;
    let volumes = names["volumes"]
        .as_array()
        .ok_or_else(|| Rejected::internal("invalid native volume inventory"))?
        .iter()
        .map(|name| {
            name.as_str()
                .filter(|name| valid_name(name))
                .map(describe)
                .ok_or_else(|| Rejected::internal("invalid native volume inventory name"))
        })
        .collect::<Result<Vec<_>, _>>()?;
    Ok(json!({"Volumes":volumes,"Warnings":[]}))
}

pub(super) fn create(owner: &Owner, body: &Value) -> Result<Value, Rejected> {
    let data = request::object(body, "Docker volume request")?
        .ok_or_else(|| Rejected::bad("invalid Docker volume request"))?;
    request::options(data, &["Name", "Driver"], "volume ")?;
    if !body["Driver"].is_null() && body["Driver"] != "" && body["Driver"] != "local" {
        return Err(Rejected::bad(
            "only the native local volume driver is supported",
        ));
    }
    let name = body["Name"]
        .as_str()
        .ok_or_else(|| Rejected::bad("native volume creation requires a name"))?;
    ask(owner, "create", Some(name))?;
    Ok(describe(name))
}

pub(super) fn mount_metadata(volume: &VolumeMount) -> Value {
    json!({"Type":"volume","Name":volume.name,"Source":guest_path(&volume.name),
           "Destination":VOLUME_TARGET,"Driver":"local","RW":!volume.read_only,
           "Mode":if volume.read_only {"ro"} else {"rw"},"Propagation":""})
}
