# argosbx-min：HY2 + VLESS-Reality + Argo 精简加固版

由 [yonggekkk/argosbx](https://github.com/yonggekkk/argosbx) 精简改造而来（GPL-3.0，见 LICENSE）。只保留三个核心能力：

- **Hysteria2**（sing-box，UDP）——自签 ECDSA 证书 + `pinSHA256` 证书锁定 + salamander 混淆，也支持挂载真实证书
- **VLESS-Reality**（Xray，TCP）——免域名、防探测
- **Cloudflare Argo 隧道**（cloudflared + VMess-WS）——无公网 IP / NAT 环境也能用，临时隧道零配置

已移除：Socks5、TUIC、AnyTLS、NaiveProxy、XHTTP、Shadowsocks、WARP 出站、SAP 多账户部署等全部非核心功能。

三个内核 **只从官方 Release 下载**（XTLS/Xray-core、SagerNet/sing-box、cloudflare/cloudflared），构建时固定版本 + SHA256 校验，运行时不下载任何东西。

## 快速开始

```bash
git clone https://github.com/gretentgmsg/argosbx-min.git && cd argosbx-min
docker compose up -d --build        # 或直接用 Actions 构建好的 ghcr.io/gretentgmsg/argosbx:latest
docker exec proxy cat /data/links.txt   # 分享链接（含密钥，不会写进日志）
```

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `HY2_PORT` | `443` | Hysteria2 的 UDP 端口，`0` 关闭 |
| `HY2_SNI` | `www.bing.com` | 自签证书的 SAN；用真实证书时填你的域名 |
| `HY2_OBFS` | `1` | `1` 启用 salamander 混淆；`0` 关闭并启用 `MASQ_URL` 伪装 |
| `MASQ_URL` | `https://www.bing.com` | `HY2_OBFS=0` 时的伪装站点 |
| `REALITY_PORT` | `443` | VLESS-Reality 的 TCP 端口，`0` 关闭 |
| `REALITY_SNI` | `addons.mozilla.org` | Reality 目标站，需支持 TLS 1.3 |
| `ARGO` | `0` | `1` 启用 Argo 隧道 |
| `ARGO_TOKEN` / `ARGO_DOMAIN` | 空 | 固定隧道：令牌 + 你在 Cloudflare 控制台配置的域名；两者都空则用临时隧道 |
| `ARGO_PORT` | `18080` | 仅监听 127.0.0.1，cloudflared 转发到这里 |
| `ARGO_ADDRESS` | 空 | 可选：客户端连接用的优选 Cloudflare IP/域名 |
| `SERVER_HOST` | 自动 | 公网 IP 或域名；留空会通过 HTTPS 请求 api.ipify.org |
| `NODE_NAME` | `node` | 节点备注名 |
| `HY2_PASSWORD` `HY2_OBFS_PASSWORD` `REALITY_UUID` `ARGO_UUID` | 随机 | 可选覆盖，首次启动自动生成并保存在 `/data/secrets` |

## 使用真实域名证书（可选）

默认 HY2 用容器内生成的自签证书 + 证书锁定（链接里带 `pinSHA256`，客户端 `insecure=0`）。
如需真实证书（例如域名已解析到本机），把 `cert.pem` / `key.pem` 挂进 `/data`：

```yaml
    volumes:
      - ./certs/cert.pem:/data/cert.pem:ro
      - ./certs/key.pem:/data/key.pem:ro
```

只要 `/data/cert.selfsigned` 标记文件不存在，容器就按"自定义证书"模式使用它们（链接不再带 pin）。

## 没有公网 IP / 公网 IP 访问不了

HY2（UDP）和 Reality（TCP）都需要入站端口，这种环境只能走 Argo：

```
HY2_PORT=0  REALITY_PORT=0  ARGO=1
```

并删掉 compose 里的 `ports` 段，容器只会主动向外连接。

- **临时隧道**：不用账号，启动后 `links.txt` 里会出现 `*.trycloudflare.com` 的节点；每次重启域名都会变，适合临时使用。
- **固定隧道**（推荐）：Cloudflare Zero Trust → Networks → Tunnels → 创建隧道，复制 token；在 Public hostname 里填你的域名，Service 选 `HTTP`，URL 填 `localhost:18080`；然后设置 `ARGO_TOKEN` 和 `ARGO_DOMAIN`。

Argo 路径使用 VMess-WS（aes-128-gcm 端到端加密，Cloudflare 看不到内容），路径为随机值，只有拿到链接的人能访问。UDP 无法通过 Argo，所以 HY2 不能走隧道。
Xray 已把 WebSocket 传输和 VMess 标记为弃用，升级 Xray 大版本前请先看发布说明。

## 安全设计

- 二进制：官方 Release + 固定版本 + SHA256 校验（构建时验证，失败即中止）；CI 中第三方 Action 固定到提交 SHA。
- HY2：本机生成的 ECDSA P-256 证书，链接带 `insecure=0` 与 `pinSHA256`（hex 指纹）；默认开启混淆；密码全部随机生成。
- 出站屏蔽内网、回环、链路本地、CGNAT 地址（Xray `finalRules` + sing-box 路由双重拦截），防止被用来访问宿主机或云元数据。
- 容器：非 root（uid 10001）、只读根文件系统、`cap_drop: ALL`、`no-new-privileges`；密钥目录权限 700，文件 600。
- 日志里没有密钥；Argo 令牌只通过环境变量传给 cloudflared，Xray 和 sing-box 拿不到。

## 升级内核版本

同时修改 `Dockerfile` 里的版本号与对应 SHA256 后重新构建：

- sing-box：[Releases](https://github.com/SagerNet/sing-box/releases) 下载 `sing-box-<版本>-linux-<架构>-glibc.tar.gz` 后 `sha256sum`
- Xray：[Releases](https://github.com/XTLS/Xray-core/releases) 页面每个 zip 都带 `.dgst` 文件，取 `SHA2-256` 一行
- cloudflared：[Releases](https://github.com/cloudflare/cloudflared/releases) 下载对应架构二进制后 `sha256sum`

## 致谢

- [yonggekkk/argosbx](https://github.com/yonggekkk/argosbx) —— 原项目
- [XTLS/Xray-core](https://github.com/XTLS/Xray-core) / [SagerNet/sing-box](https://github.com/SagerNet/sing-box) / [cloudflare/cloudflared](https://github.com/cloudflare/cloudflared)
