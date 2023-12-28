{
  # dbus-broker fails to reload when the tmpfiles service during a nixos switch
  # calls systemd-tmpfiles with the `--boot` option, as that option causes a bunch
  # of things, including the temporary directories of several services, to be wiped.
  # This test ensures that this keeps on working correctly.
  name = "tmpfiles-switch-dbus-broker";

  nodes = {
    machine = {
      services.dbus.implementation = "broker";

      specialisation.second.configuration = {
        # Introduce a change in the dbus-broker service so that it gets reloaded
        # when we switch into this generation.
        systemd.services.dbus-broker.environment = {
          FOO = "bar";
        };
      };
    };
  };

  testScript = { nodes, ... }: ''
    start_all()

    machine.wait_for_unit("default.target")

    toplevel = "${nodes.machine.system.build.toplevel}";
    machine.succeed(f"{toplevel}/specialisation/second/bin/switch-to-configuration switch")
  '';
}
