# sing-box VPS 一键部署

这个目录包含 `install.sh`：在支持的 Linux VPS 上安装当前 stable 版 sing-box，并生成三种接入：

- VLESS + REALITY + Vision（TCP 443）
- Hysteria2 + Gecko 混淆、Chrome QUIC 指纹伪装与 BBR profile（UDP 443）
- Shadowsocks 2022（TCP/UDP 8443）
- 可选 VPS 内部 WARP 出站（`--with-warp-upstream`）

脚本针对采用 `systemd` 的 Debian/Ubuntu、RHEL/Alma/Rocky/Fedora 和 Arch Linux VPS；不支持 LXC/Docker 等没有运行 systemd 的容器，也不声称支持所有操作系统。它不会启用新的主机防火墙；若 UFW 或 firewalld 已经运行，只会添加所需端口。还会启用内核支持时的 BBR，并安装/启用可用的 fail2ban 服务。

## 使用

将脚本传至 VPS 后运行（替换为该 VPS 的公网 IP）：

```bash
curl -fsSLO https://YOUR-DOMAIN.example/install.sh
sudo bash install.sh --ip 203.0.113.10
```

若 443 已被网站占用或云商限制该端口，可换成未占用端口；Shadowsocks 端口必须与前两者不同：

```bash
sudo bash install.sh --ip 203.0.113.10 --vless-port 2443 --hy2-port 2443 --ss-port 8443
```

默认使用 sing-box 1.14+ 的 Hysteria2 `gecko` 混淆、`bbr_profile: standard` 和客户端默认的 Chrome QUIC 指纹伪装。若手机客户端过旧、不支持 Gecko，可明确回退到兼容性更高的 Salamander：

```bash
sudo bash install.sh --ip 203.0.113.10 --hy2-obfs salamander
```

脚本默认会把已有 sing-box 更新到当前 stable。仅在离线测试或你已完成版本管控时，才可使用 `--skip-singbox-update` 跳过该更新；生产部署不建议添加此选项。

如需让进入 sing-box 的代理流量从 WARP 出站，可启用下面选项。它不会开放原生 WireGuard VPN 入站端口、创建 `wg0`，或改变 VPS 的系统默认路由与 SSH 管理流量；仅作为 sing-box 的上游出口。首次运行会校验下载的开源 `wgcf` 工具并创建一个 WARP WireGuard 配置，凭据仅保存于 `/etc/sing-box/warp/`。WARP 还需要 VPS 能出站访问 UDP `2408`。

```bash
sudo bash install.sh --ip 203.0.113.10 --with-warp-upstream
```

## Maintenance

Update only the sing-box core; existing nodes and credentials are preserved:

```bash
sudo bash install.sh --upgrade-core
```

Show status or run a live health check:

```bash
sudo bash install.sh --status
sudo bash install.sh --health-check
```

When WARP is enabled, the installer adds a loopback-only health check on
`127.0.0.1:18080` and a systemd timer that verifies WARP every 10 minutes.
View its results with `journalctl -u sing-box-vps-health.service -n 50 --no-pager`.

默认 Hysteria2 使用自签名 ECDSA 证书，因此导入链接含 `insecure=1`。若已有由可信 CA 签发的域名证书，可改用下列方式；脚本会使用该证书并输出带 SNI、没有 `insecure=1` 的链接：

```bash
sudo bash install.sh --ip vpn.example.com \
  --hy2-cert /etc/letsencrypt/live/vpn.example.com/fullchain.pem \
  --hy2-key /etc/letsencrypt/live/vpn.example.com/privkey.pem \
  --hy2-sni vpn.example.com
```

如果没有托管下载地址，可从本机复制：

```bash
scp ./install.sh root@YOUR_VPS:/root/
ssh root@YOUR_VPS 'bash /root/install.sh --ip YOUR_VPS_IP'
```

完成后脚本会在终端输出导入链接，且将仅限 root 读取的原始凭据写入 `/etc/sing-box/credentials.env`。请同时在云服务商安全组/防火墙中开放 TCP+UDP `443` 与 TCP+UDP `8443`。

脚本还会安装 `qrencode` 并生成标准导入二维码。终端会显示二维码，PNG 文件保存在仅 root 可读的 `/etc/sing-box/qr/`：`vless-reality.png`、`hysteria2.png`、`shadowsocks-2022.png`。可安全复制图片至手机，再用小火箭、sing-box 等客户端的“扫描二维码/从相册导入”功能导入；二维码等同密码，切勿公开分享。

例如从本机安全复制二维码：

```bash
scp root@你的VPS:/etc/sing-box/qr/vless-reality.png .
```

## 国内外分流（sing-box 客户端）

单节点二维码只能保存节点连接参数，不能通用地保存路由规则。脚本会额外生成 `/etc/sing-box/client-profiles/sing-box-vless-cn-bypass.json`：大陆域名、国内 IP 和私有网段直连，其余流量通过 VLESS+REALITY 代理；同时使用官方 `sing-geosite` / `sing-geoip` 远程规则集及 DNS 分流。

```bash
scp root@你的VPS:/etc/sing-box/client-profiles/sing-box-vless-cn-bypass.json .
```

将该 JSON 导入当前 sing-box 客户端并授予 VPN/TUN 权限。首次使用需要客户端能够下载规则集；规则集定义和更新由上游维护。小火箭请扫码导入单节点后，在其应用内单独设置规则；它不能直接导入此 sing-box JSON 作为二维码。

## 在隔离虚拟机验证

不需要、也不应在你的本机执行安装。将整个目录复制到一台可丢弃的 Linux 虚拟机或测试 VPS，在虚拟机内依次运行：

```bash
sudo bash install.sh --ip VM的公网IP
sudo bash vm-smoke-test.sh
```

`vm-smoke-test.sh` 是只读检查：验证 sing-box 配置、systemd 服务状态及 TCP/UDP 443、8443 监听。要验证真实连通性，使用另一台网络中的客户端导入安装输出的三条 URI。若使用自定义端口，请将相同端口值传给验证脚本：

```bash
sudo bash vm-smoke-test.sh --vless-port 2443 --hy2-port 2443 --ss-port 8443
```

## 重要说明

- `--sni` 是 REALITY 的伪装握手域名。默认 `www.cloudflare.com`；如替换，使用一个从 VPS 可访问、正常提供 TLS/443 的域名。
- Hysteria2 默认使用自签名证书，所以链接中带 `insecure=1`。若你有自己的域名和公开可信证书，可把配置中的证书路径换成证书文件，并移除客户端的 `insecure=1`。
- 脚本拒绝覆盖已有 `/etc/sing-box/config.json`；明确需要重新生成时，再增加 `--force`，旧配置会按时间戳备份。
- 使用前确认当地法律、云商条款和网络服务条款允许你的用途。

官方资料：[sing-box 安装](https://sing-box.sagernet.org/installation/package-manager/)、[VLESS 入站](https://sing-box.sagernet.org/configuration/inbound/vless/)、[Hysteria2 入站](https://sing-box.sagernet.org/configuration/inbound/hysteria2/)。

## 已验证环境

2026-09-16 已在独立 Ubuntu 24.04.3 LTS WSL2 环境验证：使用保留测试地址 `198.18.0.1` 和端口 `2443/2443/18443` 完成安装；`sing-box check` 成功，systemd 服务为 active，VLESS TCP、Hysteria2 UDP、Shadowsocks TCP/UDP 监听均存在，三张 PNG 二维码已生成且权限为 `0600`。这不替代真实 VPS 的云安全组和跨网络客户端连通性验证。

