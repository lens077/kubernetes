#!/bin/bash
# 此文件用于配置Containerd的国内源, 也可以直接配置系统层面的代理
# 当镜像的路径是server的某一条时,
# 就会通过这些源进行代理

#declare http_proxy="http://192.168.3.220:7890"
#declare https_proxy="http://192.168.3.220:7890"
#while [[ $# -gt 0 ]]; do
#  case $1 in
#    --http_proxy=*)
#      http_proxy="${1#*=}"
#      ;;
#     --https_proxy=*)
#      https_proxy="${1#*=}"
#      ;;
#    *)
#      echo "未知的命令行选项参数: $1"
#      exit 1
#      ;;
#  esac
#  shift
#done
## 返回解析后的参数值
#echo "http_proxy:$http_proxy https_proxy:$https_proxy"

# 此命令用于生成containerd默认的配置文件
addCertsPath () {
  mkdir /etc/containerd/certs.d
  sudo sed -i "s|^\([[:space:]]*config_path = \)''$|\1'/etc/containerd/certs.d'|" /etc/containerd/config.toml

  systemctl daemon-reload
  systemctl restart containerd
}

http_proxy () {
  #export https_proxy=http://192.168.3.220:7890
  #export http_proxy=http://192.168.3.220:7890
  mkdir -pv /etc/systemd/system/containerd.service.d/
  cat <<EOF >/etc/systemd/system/containerd.service.d/http-proxy.conf
[Service]
Environment="HTTP_PROXY=${http_proxy:-}"
Environment="HTTPS_PROXY=${https_proxy:-}"
Environment="NO_PROXY=${NO_PROXY:-localhost},${LOCAL_NETWORK}"
EOF
 cat /etc/systemd/system/containerd.service.d/http-proxy.conf
 systemctl daemon-reload
 systemctl restart containerd
}

verify () {

  cat -n /etc/containerd/config.toml | grep -A 1 config_path

  if [[ -d /etc/containerd/certs.d ]];then
    echo "目录生成成功"
  fi

#  ctr --debug  i pull \
#    registry.k8s.io/prometheus-adapter/prometheus-adapter:v0.11.2 || true
}

main () {
  addCertsPath
  #http_proxy "$https_proxy" "$http_proxy"
  verify
}

main
