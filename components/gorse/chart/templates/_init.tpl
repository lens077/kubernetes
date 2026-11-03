{{- /* 共享的 config 渲染 init 容器：把 config.toml.tpl 的占位符换成 Secret 值。
     DSN 里有 / 和 &，替换前先转义 sed 特殊字符(& \ |)，换分隔符 | */ -}}
{{- define "gorse.initContainer" -}}
name: render-config
image: busybox:1.37
command: [sh, -c]
args:
  - >-
    esc() { sed 's/[&\|]/\\&/g' "$1"; };
    sed -e "s|__GORSE_CACHE_STORE__|$(esc /secrets/cache-store)|"
    -e "s|__GORSE_DATA_STORE__|$(esc /secrets/data-store)|"
    -e "s|__GORSE_API_KEY__|$(esc /secrets/api-key)|"
    -e "s|__GORSE_ADMIN_API_KEY__|$(esc /secrets/admin-api-key)|"
    /config-src/config.toml.tpl > /config/config.toml
volumeMounts:
  - { name: config-src, mountPath: /config-src }
  - { name: config,     mountPath: /config }
  - { name: store-secret, mountPath: /secrets, readOnly: true }
{{- end -}}
