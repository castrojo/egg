kind: manual

sources:
- kind: git_repo
  url: github:projectbluefin/common.git
  track: v2026.01
  ref: v2026.01-0-gc26b63aaf003a38165256fe06bf49c3f891a5080
- kind: git_module
  url: github:projectbluefin/branding/
  path: bluefin-branding
  ref: f5213ca61615bb79a8315fc4c5378a80ca93922e

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ''

config:
  install-commands:
#   - install -Dm644 -t "%{install-root}%{sysconfdir}/" etc/*
#   - install -Dm644 -t "%{install-root}%{sysconfdir}/" etc/*
  - cp -r system_files/bluefin/usr/./ "%{install-root}%{prefix}/"
  - cp -r system_files/shared/usr/./ "%{install-root}%{prefix}/"
  - cp -r system_files/bluefin/etc/./ "%{install-root}%{sysconfdir}/"
  - cp -r system_files/shared/etc/./ "%{install-root}%{sysconfdir}/"
  - cp -r bluefin-branding/system_files/etc/./ "%{install-root}%{sysconfdir}/"
  - "%{install-extra}"
