kind: make

sources:
- kind: git_repo
  url: github:icedman/search-light.git
  track: main
  ref: 2070cd42271eae5aebe64045ec9cbbe8a10b74e6

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
    cp -R ./* "%{install-root}/usr/share/gnome-shell/extensions/${_uuid}/"

    # mv "%{install-root}/usr/share/gnome-shell/extensions/${_uuid}/locale" "%{install-root}/usr/share"
    install -Dm644 schemas/*.gschema.xml -t "%{install-root}/usr/share/glib-2.0/schemas/"
    rm -rf "%{install-root}/usr/share/gnome-shell/extensions/${_uuid}/schemas"
  - |
    %{install-extra}
