# Conjet 3.1.1 — ad-hoc signed

Fix `conjet update` for Native Docker profiles: an ordinary invocation now
succeeds with instructions for updating the installed package instead of an
invalid-argument error. It does not download assets, check remote versions,
restart the VM or claim that the installed package is current. JSON reports
`ok: true`, `updated: false` and `updateCheckPerformed: false`.
Appliance image-update behavior is unchanged. Native image overrides, force
and restart requests remain explicit errors rather than silently ignored options.

This Apple Silicon release is ad-hoc signed and not notarized, as authorized
for the current release lane. Gatekeeper may block first launch. It retains
the native runtime and compatibility limitations documented for 3.1.0; it does
not fix or establish a cause for the separately reported daemon shutdown.
The expanded compatibility work is not included. Core 1.3.1 assets are reused.
