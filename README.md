# sing-box VPS 一键部署

install.sh 在 systemd Linux VPS 上安装当前稳定版 sing-box，并部署三条独立入口：

| 入口 | 端口 | 客户端方式 |
| --- | --- | --- |
| VLESS + REALITY + XTLS Vision | TCP 443 | 导出完整 sing-box 国内外分流 JSON；同时输出 URI 供兼容客户端手动导入 |
| Hysteria2 + Gecko | UDP 443 | 输出 hysteria2 URI 和二维码 |
| ShadowTLS v3 + Shadowsocks 2022 | TCP 8443 | 导出专用 sing-box JSON；不输出无效的裸 ss URI/二维码 |

默认的 REALITY / ShadowTLS 伪装域名为 www.speedtest.net。--sni 只能传纯域名，例如 www.speedtest.net，不要传 URL、方括号或 Markdown 链接。

## 一条命令部署

在 VPS 的 SSH 终端执行，替换为该 VPS 的公网 IP 或域名：

    curl -fsSL https://raw.githubusercontent.com/xik54/-/main/install.sh -o /tmp/sing-box-vps-installer.sh &&     sudo bash /tmp/sing-box-vps-installer.sh --ip YOUR_VPS_IP

脚本需要 root/sudo、systemd、出站 HTTPS，以及云厂商安全组中允许：

- TCP 443（VLESS）
- UDP 443（Hysteria2）
- TCP 8443（ShadowTLS + SS2022）

如果系统正在运行 UFW 或 firewalld，脚本会仅添加这些端口；云厂商安全组仍需你自行开放。脚本会启用可用的 BBR，并安装 Fail2Ban 的 SSH 防暴力破解 jail（5 次失败 / 10 分钟，封禁 1 小时）。它不会把普通代理握手错误误判为端口扫描而自动封禁来源 IP。

若使用非默认端口：

    sudo bash /tmp/sing-box-vps-installer.sh       --ip YOUR_VPS_IP --vless-port 2443 --hy2-port 2443 --ss-port 18443

--ss-port 必须不同于 VLESS/Hysteria2 端口，且不能使用脚本保留的内部 SS2022 端口 8444。

## 节点与客户端配置

安装后，敏感凭据仅保存在：

    /etc/sing-box/credentials.env

VLESS 的 REALITY short_id 会随机生成并同时写入服务端、凭据和导出的客户端配置，避免服务端与客户端 short ID 不一致造成 reality verification failed。

### VLESS：国内直连、国外代理

脚本自动生成：

    /etc/sing-box/client-profiles/sing-box-vless-cn-bypass.json

该 JSON 包含 TUN、DNS 分流和官方 sing-geosite / sing-geoip 远程规则集：

- 中国大陆域名、国内 IP 与私有网段直连；
- 其余流量走 VLESS + REALITY；
- 规则集通过 VLESS 下载，避免首次更新时裸连 GitHub。

导入到当前 sing-box 客户端并授予 VPN/TUN 权限。首次启动需要 VLESS 本身能连接，以下载远程规则集；如果报出 reality verification failed，优先核对 IP、SNI、UUID、公钥和 short_id 是否来自同一次安装。

VLESS 不生成二维码：节点 URI 无法容纳整套分流、DNS 与规则集配置。脚本仍会在终端输出 VLESS URI，供支持 Reality URI 的其它客户端手动导入。

### Hysteria2

脚本输出 hysteria2 URI，并生成唯一的通用二维码：

    /etc/sing-box/qr/hysteria2.png

默认使用自签名证书，因此 URI 含 insecure=1。若已有受信任证书，可传入：

    sudo bash /tmp/sing-box-vps-installer.sh --ip vpn.example.com       --hy2-cert /etc/letsencrypt/live/vpn.example.com/fullchain.pem       --hy2-key /etc/letsencrypt/live/vpn.example.com/privkey.pem       --hy2-sni vpn.example.com

### ShadowTLS v3 + Shadowsocks 2022

Shadowsocks 2022 只在回环地址的内部端口监听，公网 TCP 8443 由 ShadowTLS v3 接收并转发给它。因此裸 ss URI 缺少 ShadowTLS 认证层，不能使用，脚本不会生成这种误导性二维码。

自动生成的专用 sing-box 配置：

    /etc/sing-box/client-profiles/sing-box-shadowtls-ss2022.json

该路径要求使用支持 ShadowTLS v3 的当前 sing-box 客户端。它是兼容性与伪装层的取舍：Shadowrocket 等只识别普通 Shadowsocks URI 的客户端不能使用这一条；请使用 VLESS 或 Hysteria2。

从电脑安全下载配置示例：

    scp root@YOUR_VPS:/etc/sing-box/client-profiles/sing-box-vless-cn-bypass.json .
    scp root@YOUR_VPS:/etc/sing-box/client-profiles/sing-box-shadowtls-ss2022.json .

配置文件和二维码都含凭据，不要放进公开仓库或聊天记录。

## WARP 作为 VPS 出站

可选 WARP 只作为 sing-box 内部的上游出口；不会创建 WireGuard 入站、wg0、新的 VPN 端口，也不会改变 VPS 默认路由或 SSH 管理流量：

    sudo bash /tmp/sing-box-vps-installer.sh --ip YOUR_VPS_IP --with-warp-upstream

首次免费注册依赖 Cloudflare 的服务。如果 wgcf 返回 429 Too Many Requests，安装会在停止已有 sing-box 服务之前退出；稍后再试，或导入你自己的 WARP 配置：

    sudo bash /tmp/sing-box-vps-installer.sh       --ip YOUR_VPS_IP --with-warp-upstream       --warp-profile /root/wgcf-profile.conf

开启后可检查：

    sudo bash /tmp/sing-box-vps-installer.sh --status
    sudo bash /tmp/sing-box-vps-installer.sh --health-check
    journalctl -u sing-box-vps-health.service -n 50 --no-pager

健康检查通过 loopback-only 的 127.0.0.1:18080 请求 Cloudflare trace，确认返回 warp=on 或 warp=plus。

## 维护

重新生成客户端 JSON，不改变服务器节点或凭据：

    sudo bash /tmp/sing-box-vps-installer.sh --export-client-profile

仅升级内核，不重建节点：

    sudo bash /tmp/sing-box-vps-installer.sh --upgrade-core

明确需要重新生成所有节点时，才使用 --force。脚本会制作时间戳备份；如果 --force 过程中下载、配置校验或启动失败，会恢复之前的配置、凭据与服务。

    sudo bash /tmp/sing-box-vps-installer.sh --force --ip YOUR_VPS_IP

## 隔离 Ubuntu 验证

只在可丢弃的 Linux 虚拟机/测试 VPS 中运行，不在 Windows 主机上安装：

    sudo bash install.sh --ip VM_PUBLIC_IP
    sudo bash vm-smoke-test.sh

烟雾测试为只读检查：验证服务、服务端配置、两份客户端 JSON、Hysteria2 二维码，以及 VLESS TCP、Hysteria2 UDP、ShadowTLS TCP 和内部 SS2022 TCP 监听。

    sudo bash vm-smoke-test.sh       --vless-port 2443 --hy2-port 2443 --ss-port 18443

2026-09-19 已在独立 Ubuntu WSL2 测试环境以 sing-box 1.14.1 完成配置、服务、监听和客户端 JSON 内核校验。该结果不替代真实 VPS 的云安全组与跨网络客户端连通性测试。

## 重要边界

- 伪装与混淆不能保证绕过任何网络审查、探测或服务风控；请遵守当地法律、云厂商条款和服务条款。
- WARP 的可用性、出口区域和 IP 由 Cloudflare 决定，不能保证某个 AI 或网站一定可用。
- 远程规则集由上游维护；规则内容或 URL 变化时应使用 --export-client-profile 重新生成并检查客户端日志。