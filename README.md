# argosbx-min：HY2 + VLESS-Reality + Argo 精简加固版

由 [yonggekkk/argosbx](https://github.com/yonggekkk/argosbx) 精简改造而来（GPL-3.0，见 LICENSE）。只保留三个核心能力：

- **Hysteria2**（sing-box，UDP）——自签 ECDSA 证书 + `pinSHA256` 证书锁定 + salamander 混淆，也支持挂载真实证书
- **VLESS-Reality**（Xray，TCP）——免域名、防探测
- **Cloudflare Argo 隧道**（cloudflared + VLESS Encryption + XHTTP）——无公网 IP / NAT 环境也能用，临时隧道零配置

已移除：Socks5、TUIC、AnyTLS、NaiveProxy、Shadowsocks、WARP 出站、SAP 多账户部署等全部非核心功能。

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
| `ARGO_LISTEN` | `127.0.0.1` | 设 `0.0.0.0` 当有 HTTPS 反代（如 PaaS 公开端点）直连该端口时 |
| `ARGO_PUBLIC_DOMAIN` | 空 | 该反代的域名；设置后 links.txt 会额外生成一条不经 Cloudflare 的直连 vless 链接（需 `ARGO_LISTEN=0.0.0.0`） |
| `ARGO_ADDRESS` | 空 | 可选：客户端连接用的优选 Cloudflare IP/域名 |
| `SERVER_HOST` | 自动 | 公网 IP 或域名；留空会通过 HTTPS 请求 api.ipify.org |
| `NODE_NAME` | `node` | 节点备注名 |
| `HY2_PASSWORD` `HY2_OBFS_PASSWORD` `REALITY_UUID` `ARGO_UUID` | 随机 | 可选覆盖，首次启动自动生成并保存在 `/data/secrets` |
| `REALITY_PRIVATE_KEY` `REALITY_SID` `ARGO_PATH` `ARGO_DEC_KEY` `ARGO_ENC_KEY` | 随机/自动 | 无状态模式的密钥注入，见下文「无状态部署」 |

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

- **临时隧道（不可用）**：`*.trycloudflare.com` 临时域名经 Cloudflare Worker 中转，实测会挂起 XHTTP 的流式下行——请求能到达源站但数据回不到客户端（2026-10 实测，短响应可通、流式响应挂死）。启动日志会给出同样告警。如需 Argo 请使用固定隧道。
- **固定隧道**（必选）：Cloudflare Zero Trust → Networks → Tunnels → 创建隧道，复制 token；在 Public hostname 里填你的域名，Service 选 `HTTP`，URL 填 `localhost:18080`；然后设置 `ARGO_TOKEN` 和 `ARGO_DOMAIN`。若域名解析到的 Cloudflare IP 在你的网络不可达（症状：时通时断、部分 IP 超时），用 `ARGO_ADDRESS` 指定一个可达的 Cloudflare 优选 IP。

**国内 / UDP 受限网络必读**：cloudflared 默认 `ARGO_PROTOCOL=auto`（优先 QUIC/UDP）。若你的网络 UDP 到 Cloudflare 劣化（症状：隧道时通时断、真连接测试超时但偶发能通、容器日志反复出现 `failed to accept QUIC stream: timeout`），请设置 `ARGO_PROTOCOL=http2` 强制走 TCP 443，实测可解决。另外：把代理服务端跑在墙内网络时，`v2rayN 真连接测试`（默认目标 www.google.com）必然失败——出口在墙内，请用国内可达站点（如 baidu.com）测试。

Argo 路径使用 **VLESS Encryption + XHTTP**：

- VLESS Encryption 是端到端加密（X25519 认证、ML-KEM-768 后量子密钥交换、前向保密），Cloudflare 终止 TLS 后也只能看到密文。密钥对由 Xray 自己生成（`xray vlessenc`），保存在 `/data/secrets/argo_dec`（服务端私密）和 `argo_enc`（客户端公开串）。
- XHTTP 使用 `packet-up` 模式，兼容固定隧道这类常规 CDN 回源；路径为随机值，只有拿到链接的人能访问（`*.trycloudflare.com` 临时隧道的 Worker 路径除外，见上文）。
- UDP 无法通过 Argo，所以 HY2 不能走隧道。
- **客户端要求**：需要支持 VLESS Encryption 和 XHTTP 的较新 Xray 内核客户端，请以所用客户端的发布说明为准。
- **从旧版（VMess-WS）升级**：旧的 `vmess://` 链接会失效，重启容器后从 `links.txt` 取新的 `vless://` 链接重新导入；`/data/secrets` 里的 Argo UUID 和路径保持不变，只会新增 `argo_dec` / `argo_enc` 两个文件。

## 部署在容器 PaaS（Northflank 等，只有 public HTTP/HTTPS 端口）

此类平台无法暴露原始 TCP/UDP，直连协议全部关闭，用两条 HTTP 路径：

```
HY2_PORT=0  REALITY_PORT=0  ARGO=1
ARGO_LISTEN=0.0.0.0
ARGO_PUBLIC_DOMAIN=你的平台公网域名   # 例如 xxx.northflank.app
```

- **路径 A（Argo 固定隧道）**：照常配置 `ARGO_TOKEN` / `ARGO_DOMAIN`，纯出站。
- **路径 B（平台 HTTPS 端点直连）**：给容器的 `18080` 建 **HTTP 类型**的 private 端口（不要选 HTTP/2——那会要求源站说 h2c），再把 public HTTPS 端点绑上去；`links.txt` 里 `#node-direct` 结尾的链接即走此路径（平台 TLS + VLESS 端到端加密，与走 Cloudflare 同级安全模型）。
- 注意：反代若缓冲流式响应会挂死 XHTTP 下行（trycloudflare 的 Worker 即如此），平台入口行为需实测；不通就只用路径 A。
- **平台卷权限**：若挂载的卷不属于运行用户（uid 10001），容器不再崩溃——自动回退到临时目录并打印告警（密钥不持久，每次重启需重新取链接）。
- **无状态部署（推荐搭配上一种情况）**：把全部密钥改由环境变量注入，重启后链接完全不变，不再依赖持久卷。以 Argo-only 为例，生成一次密钥后填入：

```bash
# 1) 生成 vlessenc 密钥对（取 X25519 组两条值）：
docker run --rm --entrypoint /opt/bin/xray ghcr.io/gretentgmsg/argosbx-min:latest vlessenc
# 2) 随机 UUID / 路径：uuidgen；openssl rand -hex 8
# 3) Northflank 环境变量：
#    ARGO_UUID=<uuid>
#    ARGO_PATH=<16位hex，不带斜杠>
#    ARGO_DEC_KEY=<vlessenc 的 decryption (.600s.) 值>
#    ARGO_ENC_KEY=<vlessenc 的 encryption (.0rtt.) 值>
```

  开启 Reality 时同理注入 `REALITY_UUID` / `REALITY_PRIVATE_KEY`（`xray x25519` 的 Private key）/ `REALITY_SID`。HY2 的自签证书含 pinSHA256，无持久卷时 pin 每次重启会变，建议 HY2 只在能持久化 `/data` 的环境使用，或挂载真实证书文件。
  密钥出现在平台环境变量里，注意控制面板访问权限。

## 安全设计

- 二进制：官方 Release + 固定版本 + SHA256 校验（构建时验证，失败即中止）；CI 中第三方 Action 固定到提交 SHA。
- HY2：本机生成的 ECDSA P-256 证书，链接带 `insecure=0` 与 `pinSHA256`（hex 指纹）；默认开启混淆；密码全部随机生成。
- 出站屏蔽内网、回环、链路本地、CGNAT 地址（Xray `finalRules` + sing-box 路由双重拦截），防止被用来访问宿主机或云元数据。
- 容器：非 root（uid 10001）、只读根文件系统、`cap_drop: ALL`、`no-new-privileges`；密钥目录权限 700，文件 600。
- 日志里没有密钥；Argo 令牌只通过环境变量传给 cloudflared，Xray 和 sing-box 拿不到。使用的协议和传输均未被 Xray 标记为弃用，启动日志无弃用告警。

## 升级内核版本

同时修改 `Dockerfile` 里的版本号与对应 SHA256 后重新构建：

- sing-box：[Releases](https://github.com/SagerNet/sing-box/releases) 下载 `sing-box-<版本>-linux-<架构>-glibc.tar.gz` 后 `sha256sum`
- Xray：[Releases](https://github.com/XTLS/Xray-core/releases) 页面每个 zip 都带 `.dgst` 文件，取 `SHA2-256` 一行
- cloudflared：[Releases](https://github.com/cloudflare/cloudflared/releases) 下载对应架构二进制后 `sha256sum`

## 致谢

- [yonggekkk/argosbx](https://github.com/yonggekkk/argosbx) —— 原项目
- [XTLS/Xray-core](https://github.com/XTLS/Xray-core) / [SagerNet/sing-box](https://github.com/SagerNet/sing-box) / [cloudflare/cloudflared](https://github.com/cloudflare/cloudflared)


