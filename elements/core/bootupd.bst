kind: manual

# Stub bootupd element for systemd-boot based images.
#
# bootc requires bootupd for ostree-based installs, but our freedesktop-sdk
# image uses systemd-boot (not GRUB). This element provides:
#   - A no-op bootupctl wrapper that satisfies bootc's check
#   - The usr/lib/bootupd/updates/ directory bootc probes for
#
# After bootc install-to-disk completes (with the no-op bootupd), the
# Justfile manually installs systemd-boot to the ESP.

variables:
  strip-binaries: "true"

depends:
- freedesktop-sdk.bst:components/systemd.bst
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

config:
  install-commands:
    - mkdir -p "%{install-root}%{prefix}/lib/bootupd/updates"
    - mkdir -p "%{install-root}%{prefix}/bin"
    - mkdir -p "%{install-root}%{prefix}/libexec"
    - |
      cat > "%{install-root}%{prefix}/bin/bootupctl" << 'WRAPPER'
      #!/bin/sh
      # Stub bootupctl for systemd-boot based images.
      # bootc requires bootupd for ostree installs, but our image uses
      # systemd-boot. This wrapper satisfies the bootc check and makes
      # the bootupd install step a no-op.
      exit 0
      WRAPPER
      chmod +x "%{install-root}%{prefix}/bin/bootupctl"
      cp "%{install-root}%{prefix}/bin/bootupctl" "%{install-root}%{prefix}/libexec/bootupd"
