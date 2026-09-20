# sing-box VPS 一键部署

install.sh 在 systemd Linux VPS 上安装当前稳定版 sing-box，并部署三条独立入口：

| 入口 | 端口 | 客户端方式 |
| --- | --- | --- |
| VLESS + REALITY + XTLS Vision | TCP 443 | 导出完整 sing-box 国内外分流 JSON；同时输出 URI 和供 Shadowrocket 扫码导入的二维码 |
| Hysteria2 + Salamander | UDP 443 | 输出兼容 Shadowrocket 的 hysteria2 URI 和二维码 |
| ShadowTLS v3 + Shadowsocks 2022 | TCP 8443 | 导出专用 sing-box JSON；不输出无效的裸 ss URI/二维码 |

默认的 REALITY / ShadowTLS 伪装域名为 www.speedtest.net。--sni 只能传纯域名，例如 www.speedtest.net，不要传 URL、方括号或 Markdown 链接。

## 一条命令部署

在 VPS 的 SSH 终端执行，替换为该 VPS 的公网 IP 或域名：

    curl -fsSL https://raw.githubusercontent.com/xik54/-/main/install.sh -o /tmp/sing-box-vps-installer.sh &&     sudo bash /tmp/sing-box-vps-installer.sh --ip YOUR_VPS_IP

脚本需要 root/sudo、systemd、出站 HTTPS，以及云厂商安全组中允许：

- TCP 443（VLESS）
- UDP 443（Hysteria2）
- TCP 8443（ShadowTLS + SS2022）

如果系统正在运行 UFW 或 firewalld，脚本会仅添加这些端口；云厂商安全组仍需你自行开放。脚本会启用可用的 BBR，并创建专用的 Fail2Ban SSH 防暴力破解 jail（5 次失败 / 10 分钟，封禁 1 小时）。它不会覆盖已有的 `sshd-local.conf`，也不会把普通代理握手错误误判为端口扫描而自动封禁来源 IP。

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

脚本还会生成独立的 VLESS URI 二维码，供 Shadowrocket 等支持 Reality URI 的客户端扫码导入：

    /etc/sing-box/qr/vless-reality.png

该二维码只含节点连接参数，不能容纳整套分流、DNS 与规则集；要使用国内直连/国外代理规则，仍应导入上面的 sing-box JSON。

### Hysteria2

脚本输出 hysteria2 URI，并生成唯一的通用二维码：

    /etc/sing-box/qr/hysteria2.png

默认使用自签名证书，因此 URI 含 insecure=1。若已有受信任证书，可传入：

    sudo bash /tmp/sing-box-vps-installer.sh --ip vpn.example.com       --hy2-cert /etc/letsencrypt/live/vpn.example.com/fullchain.pem       --hy2-key /etc/letsencrypt/live/vpn.example.com/privkey.pem       --hy2-sni vpn.example.com

默认使用 `salamander` 混淆，并在二维码 URI 中使用规范的 `:PORT/?` 形式，以优先兼容 Shadowrocket 等 Hysteria2 客户端。`gecko` 是可选的实验性混淆；仅在确认客户端支持时才使用 `--hy2-obfs gecko`。

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

可选 WARP 使用 Cloudflare 官方 `cloudflare-warp` / `warp-cli`：脚本将客户端注册为一个 WARP 设备，设为 `proxy` 模式，并只开启 `127.0.0.1:40000` 的 SOCKS5 监听。sing-box 的最终代理流量转发到该本机端口；不会创建公开 VPN 入站端口，也不会改变 VPS 默认路由或 SSH 管理流量：

    sudo bash /tmp/sing-box-vps-installer.sh --ip YOUR_VPS_IP --with-warp-upstream

此选项代表你接受 Cloudflare WARP 条款。注册或连接失败发生在停止既有 sing-box 服务之前，因此失败不会覆盖已有节点。Cloudflare 仍可能返回 `429 Too Many Requests`；脚本不会循环重试。TCP 18080 由本地健康检查保留，TCP 40000 由 `warp-cli` 的回环 SOCKS5 保留；启用 WARP 时不要将 VLESS 或 ShadowTLS 配置为这两个端口。

之后若以不带 `--with-warp-upstream` 的方式重装，sing-box 会停止使用 WARP 并移除健康检查，但脚本不会擅自断开或卸载现有 `warp-svc`，避免影响该 VPS 上的其它程序。若确认没有其它用途，再手动执行 `sudo warp-cli disconnect` 与 `sudo systemctl disable --now warp-svc`。

启用后检查：

    sudo bash /tmp/sing-box-vps-installer.sh --status
    sudo bash /tmp/sing-box-vps-installer.sh --health-check
    systemctl status warp-svc
    warp-cli status
    journalctl -u sing-box-vps-health.service -n 50 --no-pager

健康检查经 sing-box 的 loopback-only `127.0.0.1:18080` 再转发给 `warp-cli` SOCKS5，确认 Cloudflare trace 返回 `warp=on` 或 `warp=plus`。`warp-cli` 的注册状态由其自身管理；脚本会将 tunnel protocol 明确设为 MASQUE（当前 proxy mode 的要求），并且不再使用或导入 `wgcf-profile.conf`。
## 维护

重新生成客户端 JSON，不改变服务器节点或凭据：

    sudo bash /tmp/sing-box-vps-installer.sh --export-client-profile

仅升级内核，不重建节点：

    sudo bash /tmp/sing-box-vps-installer.sh --upgrade-core

明确需要重新生成所有节点时，才使用 --force。每次安装都会建立一个临时事务：首次安装若在配置校验或 sing-box 启动阶段失败，会移除未完成的配置、凭据和服务文件；--force 覆盖时则恢复原有的 sing-box 配置、凭据与 systemd 服务文件。软件包升级、WARP 注册、主机防火墙规则、BBR 与 Fail2Ban 属于系统级变更，不在自动回滚范围内。

sing-box 通过官方签名软件源安装，不再执行 `curl | sh`。Arch Linux 不在脚本中刷新软件包数据库，以避免部分升级；若系统软件源已过期，应由管理员先自行执行完整的 `pacman -Syu`。

    sudo bash /tmp/sing-box-vps-installer.sh --force --ip YOUR_VPS_IP

## 隔离 Ubuntu 验证

只在可丢弃的 Linux 虚拟机/测试 VPS 中运行，不在 Windows 主机上安装：

    sudo bash install.sh --ip VM_PUBLIC_IP
    sudo bash vm-smoke-test.sh

烟雾测试为只读检查：验证服务、服务端配置、两份客户端 JSON、VLESS 与 Hysteria2 二维码，以及 VLESS TCP、Hysteria2 UDP、ShadowTLS TCP 和内部 SS2022 TCP 监听。

    sudo bash vm-smoke-test.sh       --vless-port 2443 --hy2-port 2443 --ss-port 18443

2026-09-19 已在独立 Ubuntu WSL2 测试环境以 sing-box 1.14.1 完成配置、服务、监听和客户端 JSON 内核校验。该结果不替代真实 VPS 的云安全组与跨网络客户端连通性测试。

## 重要边界

- 伪装与混淆不能保证绕过任何网络审查、探测或服务风控；请遵守当地法律、云厂商条款和服务条款。
- WARP 的可用性、出口区域和 IP 由 Cloudflare 决定，不能保证某个 AI 或网站一定可用。
- 远程规则集由上游维护；规则内容或 URL 变化时应使用 --export-client-profile 重新生成并检查客户端日志。