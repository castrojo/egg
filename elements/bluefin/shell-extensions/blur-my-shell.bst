kind: make

sources:
- kind: git_repo
  url: github:aunetx/blur-my-shell.git
  track: v*
  ref: v70-0-g2296e819c4238c4a8f061c4441292b56f00e4f00

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-make.bst

depends:
- freedesktop-sdk.bst:components/gettext.bst
- freedesktop-sdk.bst:components/jq.bst
- gnome-build-meta.bst:core/gnome-shell.bst

variables:
  strip-binaries: ''

config:
  install-commands:
  - |
    %{make}

    _uuid="$(jq -r .uuid metadata.json)"
    install -d "%{install-root}/usr/share/gnome-shell/extensions/${_uuid}"
    bsdtar xvf "build/${_uuid}.shell-extension.zip" -C "%{install-root}/usr/share/gnome-shell/extensions/${_uuid}/" --no-same-owner

    mv "%{install-root}/usr/share/gnome-shell/extensions/${_uuid}/locale" "%{install-root}/usr/share"
    install -Dm644 schemas/*.gschema.xml -t "%{install-root}/usr/share/glib-2.0/schemas/"
    rm -rf "%{install-root}/usr/share/gnome-shell/extensions/${_uuid}/schemas"
  - |
    %{install-extra}
