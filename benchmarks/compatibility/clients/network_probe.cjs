"use strict";

const assert = require("node:assert/strict");
const { createRequire } = require("node:module");
const net = require("node:net");

const [packageJson, socket, image, prefix] = process.argv.slice(2);

// Testcontainers searches default sockets if discovery fails. Prevent those
// connections before loading the SDK, without changing its Docker requests.
const connect = net.Socket.prototype.connect;
net.Socket.prototype.connect = function (...args) {
    const options = Array.isArray(args[0]) ? args[0][0] : args[0];
    const path = typeof options === "string" ? options : options?.path;
    if (path !== socket) {
        throw new Error("Connection outside the verified fixture socket");
    }
    return connect.apply(this, args);
};

const load = createRequire(packageJson);
assert.equal(load(packageJson).version, "12.2.2");
const { GenericContainer, Network, PullPolicy, Wait } = load("testcontainers");

async function run() {
    const network = await new Network({ nextUuid: () => prefix }).start();
    const make = (name, alias) => new GenericContainer(image)
        .withName(name)
        .withCommand(["/bin/sleep", "120"])
        .withNetwork(network)
        .withNetworkAliases(alias)
        .withAutoCleanup(false)
        .withPullPolicy(PullPolicy.neverPull())
        .withStartupTimeout(8000)
        .withWaitStrategy(Wait.forSuccessfulCommand("/bin/true"));

    let peer;
    let client;
    try {
        peer = await make(prefix + "-peer", "conjet-peer").start();
        client = await make(prefix + "-client", "conjet-client").start();
        const peerIP = peer.getIpAddress(network.getName());
        assert.equal(net.isIP(peerIP), 4);
        const lookup = await client.exec(["/usr/bin/nslookup", "-type=A", "conjet-peer"]);
        assert.equal(lookup.exitCode, 0, lookup.output);
        const answers = lookup.output.split("\n").filter(line => line.startsWith("Address:"));
        assert(answers.some(line => line.slice("Address:".length).trim() === peerIP), lookup.output);
    } finally {
        // A failed startup can occur after create. The Python launcher also
        // removes the known names in that case and verifies the inventory.
        if (client) {
            await client.stop({ timeout: 1, remove: true, removeVolumes: false });
        }
        if (peer) {
            await peer.stop({ timeout: 1, remove: true, removeVolumes: false });
        }
        if (client && peer) {
            await network.stop();
        }
    }
    console.log(JSON.stringify({ client: "testcontainers-node/12.2.2", lookup: "peer-ipv4" }));
}

run().catch(error => {
    console.error(error);
    process.exitCode = 1;
});
