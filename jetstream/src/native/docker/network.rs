use conjet_launch_service::handshake::hex;
use conjet_launch_service::spec::{valid_service_alias, BridgeScope};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use super::request::{falsey, name, object, options};
use super::{Owner, Rejected};

#[derive(Clone)]
pub(super) struct Network {
    pub id: String,
    pub name: String,
    pub scope: BridgeScope,
    pub(super) labels: Value,
}

#[derive(Clone)]
pub(super) struct Attachment {
    pub network: Network,
    pub aliases: Vec<String>,
    pub alias_project: Option<String>,
}

impl Network {
    pub(super) fn built_in(boot: &str) -> Self {
        Self {
            id: hex(&Sha256::digest(format!("conjet-docker-bridge/{boot}"))),
            name: "bridge".into(),
            scope: BridgeScope::BuiltIn,
            labels: json!({}),
        }
    }

    pub(super) fn new(data: &Value, id: String) -> Result<Self, Rejected> {
        let fields = object(data, "network creation body")?
            .ok_or_else(|| Rejected::bad("expected network creation body"))?;
        options(
            fields,
            &[
                "Name",
                "Driver",
                "Internal",
                "Labels",
                "CheckDuplicate",
                "IPAM",
            ],
            "network ",
        )?;
        let name = data["Name"]
            .as_str()
            .filter(|value| name(value))
            .filter(|value| !matches!(*value, "none" | "host" | "bridge" | "default"))
            .ok_or_else(|| Rejected::bad("invalid private bridge name"))?;
        if !data["Driver"].is_null() && data["Driver"] != "" && data["Driver"] != "bridge" {
            return Err(Rejected::bad(
                "native networking requires the bridge driver",
            ));
        }
        let scope = match &data["Internal"] {
            Value::Bool(true) => BridgeScope::Custom,
            Value::Null | Value::Bool(false) => BridgeScope::CustomRouted,
            _ => return Err(Rejected::bad("invalid bridge Internal option")),
        };
        if let Some(ipam) = object(&data["IPAM"], "IPAM")? {
            options(ipam, &["Driver"], "IPAM ")?;
            if !matches!(data["IPAM"]["Driver"].as_str(), None | Some("" | "default")) {
                return Err(Rejected::bad("custom IPAM drivers are unsupported"));
            }
        }
        let mut labels = json!({});
        if let Some(configured) = object(&data["Labels"], "network labels")? {
            if !configured.values().all(Value::is_string) {
                return Err(Rejected::bad("network label values must be strings"));
            }
            labels = data["Labels"].clone();
        }
        Ok(Self {
            id,
            name: name.to_owned(),
            scope,
            labels,
        })
    }

    pub(super) fn matches(&self, reference: &str) -> bool {
        reference == self.name || reference == self.id || reference == &self.id[..12]
    }

    pub(super) fn inspect(&self, endpoints: Value) -> Value {
        json!({
            "Name": self.name, "Id": self.id, "Scope":"local", "Driver":"bridge",
            "EnableIPv4":true, "EnableIPv6":false,
            "Internal":self.scope != BridgeScope::CustomRouted, "Attachable":false,
            "IPAM":{"Driver":"default","Config":[
                {"Subnet":format!("198.18.{}.0/28", self.scope.subnet()),"Gateway":self.scope.gateway().to_string()}]},
            "Labels":self.labels, "Containers":endpoints
        })
    }
}

impl Attachment {
    pub(super) fn new(
        network: &Network,
        endpoint: &Value,
        default: &str,
    ) -> Result<Self, Rejected> {
        if let Some(fields) = object(endpoint, "network endpoint")? {
            options(fields, &["Aliases", "NetworkID"], "endpoint ")?;
            if !falsey(&endpoint["NetworkID"]) && endpoint["NetworkID"] != network.id {
                return Err(Rejected::bad("network identity mismatch"));
            }
        }
        let aliases = match &endpoint["Aliases"] {
            Value::Null => vec![default.to_owned()],
            Value::Array(names) if names.is_empty() => vec![default.to_owned()],
            Value::Array(names) if names.len() <= 2 => names
                .iter()
                .map(|name| {
                    name.as_str()
                        .map(str::to_owned)
                        .ok_or_else(|| Rejected::bad("invalid endpoint alias"))
                })
                .collect::<Result<Vec<_>, _>>()?,
            _ => {
                return Err(Rejected::bad(
                    "at most two private DNS aliases per endpoint are supported",
                ))
            }
        };
        if aliases.iter().enumerate().any(|(index, alias)| {
            !conjet_launch_service::spec::valid_network_alias(alias)
                || aliases[..index]
                    .iter()
                    .any(|name| name.eq_ignore_ascii_case(alias))
        }) {
            return Err(Rejected::bad("invalid private DNS alias"));
        }
        Ok(Self {
            network: network.clone(),
            aliases,
            alias_project: None,
        })
    }

    pub(super) fn inspect(&self, address: Option<&str>) -> Value {
        json!({"NetworkID":self.network.id, "Aliases":self.aliases,
               "Gateway":address.map(|_| self.network.scope.gateway().to_string()).unwrap_or_default(),
               "IPAddress":address.unwrap_or(""),
               "IPPrefixLen":address.map_or(0, |_| 28)})
    }
}

pub(super) fn configured(
    data: &Value,
    built_in: &Network,
    custom: Option<&Network>,
    name: &str,
) -> Result<Option<Attachment>, Rejected> {
    let mode = match &data["HostConfig"]["NetworkMode"] {
        Value::Null => "bridge",
        Value::String(mode) if matches!(mode.as_str(), "" | "default") => "bridge",
        Value::String(mode) => mode,
        _ => return Err(Rejected::bad("invalid Docker network mode")),
    };
    if mode == "none" {
        return Ok(None);
    }
    let network = std::iter::once(built_in)
        .chain(custom)
        .find(|network| network.matches(mode))
        .ok_or_else(|| Rejected::bad("unknown private bridge or unsupported network mode"))?;
    let config = &data["NetworkingConfig"];
    if let Some(fields) = object(config, "networking configuration")? {
        options(fields, &["EndpointsConfig"], "networking ")?;
    }
    let endpoints = object(&config["EndpointsConfig"], "network endpoints")?;
    let mut endpoint = &Value::Null;
    if let Some(endpoints) = endpoints {
        if endpoints.len() > 1 {
            return Err(Rejected::bad(
                "only one private bridge endpoint is supported",
            ));
        }
        for (reference, data) in endpoints {
            if !network.matches(reference)
                && !(network.scope == BridgeScope::BuiltIn && reference == "default")
            {
                return Err(Rejected::bad(
                    "only one private bridge endpoint is supported",
                ));
            }
            endpoint = data;
        }
    }
    let mut attachment = Attachment::new(network, endpoint, name)?;
    let labels = &data["Labels"];
    attachment.alias_project = match (
        attachment.aliases.as_slice(),
        labels["com.docker.compose.project"].as_str(),
        labels["com.docker.compose.container-number"].as_str(),
    ) {
        ([primary, alias], Some(project), Some(number))
            if network.scope != BridgeScope::BuiltIn
                && network.labels["com.docker.compose.project"] == project
                && labels["com.docker.compose.service"] == alias.as_str()
                && primary == &format!("{project}-{alias}-{number}")
                && valid_service_alias(project, primary, alias) =>
        {
            Some(project.into())
        }
        _ => None,
    };
    Ok(Some(attachment))
}

pub(super) fn change(
    owner: &Owner,
    reference: &str,
    body: &Value,
    connect: bool,
) -> Result<(), Rejected> {
    let fields = object(body, "network change body")?
        .ok_or_else(|| Rejected::bad("expected network change body"))?;
    options(
        fields,
        if connect {
            &["Container", "EndpointConfig"]
        } else {
            &["Container"]
        },
        "network change ",
    )?;
    let container = body["Container"]
        .as_str()
        .filter(|value| name(value))
        .ok_or_else(|| Rejected::bad("invalid Docker container name or ID"))?;
    let item = owner.lookup(container)?;
    owner.change_network(reference, &item, connect.then_some(&body["EndpointConfig"]))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_one_internal_default_ipam_bridge() {
        let body = json!({"Name":"isolated","Driver":"bridge","Internal":true,"IPAM":{"Driver":"default"}});
        let id = "a".repeat(64);
        let network = Network::new(&body, id.clone()).unwrap();
        assert!(network.matches(&id[..12]));
        let routed =
            Network::new(&json!({"Name":"isolated","Internal":false}), id.clone()).unwrap();
        assert_eq!(routed.scope, BridgeScope::CustomRouted);
        assert_eq!(routed.inspect(json!({}))["Internal"], false);
        for invalid in [
            json!({"Name":"none","Internal":true}),
            json!({"Name":"isolated","Driver":"host","Internal":true}),
            json!({"Name":"isolated","Internal":true,"IPAM":{"Config":[{"Subnet":"192.0.2.0/24"}]}}),
            json!({"Name":"isolated","Internal":"false"}),
        ] {
            assert!(Network::new(&invalid, id.clone()).is_err());
        }
    }

    #[test]
    fn rejects_wrong_network_and_duplicate_endpoint_selectors() {
        let id = "a".repeat(64);
        let network =
            Network::new(&json!({"Name":"isolated","Internal":true}), id.clone()).unwrap();
        let mut request = json!({
            "HostConfig":{"NetworkMode":"isolated"},
            "NetworkingConfig":{"EndpointsConfig":{"isolated":{"Aliases":["service"]}}}
        });
        let built_in = Network::built_in("test");
        let entry = configured(&request, &built_in, Some(&network), "default")
            .unwrap()
            .unwrap();
        assert_eq!(entry.aliases, ["service"]);
        assert!(configured(&request, &built_in, None, "default").is_err());
        request["NetworkingConfig"]["EndpointsConfig"][&id] = json!({});
        assert!(configured(&request, &built_in, Some(&network), "default").is_err());
        let two =
            Attachment::new(&network, &json!({"Aliases":["first","second"]}), "default").unwrap();
        assert_eq!(two.aliases, ["first", "second"]);
        for names in [
            json!(["first", "FIRST"]),
            json!(["first", "second", "third"]),
        ] {
            assert!(Attachment::new(&network, &json!({"Aliases":names}), "default").is_err());
        }
        assert!(Attachment::new(&network, &json!({"Aliases":["../outside"]}), "default").is_err());
    }

    #[test]
    fn resolves_default_modes_only_to_the_built_in_bridge() {
        let built_in = Network::built_in("test");
        let custom =
            Network::new(&json!({"Name":"private","Internal":true}), "a".repeat(64)).unwrap();
        for mode in [
            Value::Null,
            json!(""),
            json!("default"),
            json!("bridge"),
            json!(built_in.id),
        ] {
            let data = json!({"HostConfig":{"NetworkMode":mode}});
            let attached = configured(&data, &built_in, Some(&custom), "workload")
                .unwrap()
                .unwrap();
            assert_eq!(attached.network.scope, BridgeScope::BuiltIn);
        }
        let data = json!({"HostConfig":{"NetworkMode":"bridge"},
            "NetworkingConfig":{"EndpointsConfig":{"private":{}}}});
        assert!(configured(&data, &built_in, Some(&custom), "workload").is_err());
    }
}
