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
| `STUN_SERVERS` | Google/Cloudflare STUN | UDP 打洞模式的 STUN 服务器列表（逗号分隔 host[:port]） |
| `HY2_NAT` | `0` | `1` = UDP 打洞模式：perl 中继独占 `HY2_PORT`，20 秒 STUN 保活并把公网映射上报信令服务器，客户端经 NAT 映射直连（无需公网入站端口） |
| `SIGNAL_URL` / `SIGNAL_TOKEN` | 空 | 信令服务器上报地址与 Bearer 令牌（`HY2_NAT=1` 时使用；POST `{"ip","port","uri","time"}`，客户端从其 `/target` 拉最新节点） |
| `TAILSCALE` | `0` | `1` = Tailscale 用户态模式：自动打洞 + DERP 兜底，HY2 经容器稳定的 100.x 内网地址直连（见下文） |
| `TS_AUTHKEY` | 空 | Tailscale Auth Key（首次启动必填；建议勾选 Reusable，节点身份随后持久化在 `/data/tailscale`，重启免 key） |
| `TS_LOGIN_SERVER` | 空 | 可选：自建 Headscale 协调服务器地址 |
| `TS_HOSTNAME` | `NODE_NAME` | 节点在 tailnet 中的名称（仅 `A-Za-z0-9-`） |
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

## HY2 UDP 直连（NAT 打洞模式，无公网入站端口）

适用：容器平台不开放公网 UDP 入站、但允许出站 UDP（GCP 系 PaaS 的 Cloud NAT 若为端点无关映射即可用——判断方法：从同一 UDP 套接字向两个 STUN 服务器发包，映射出的公网 IP:端口一致）。

```yaml
HY2_PORT: "4433"     # perl 中继监听的 UDP 端口（>1024，容器内）
HY2_NAT: "1"
SIGNAL_URL: "https://你的VPS:33443/report"
SIGNAL_TOKEN: "你的令牌"
REALITY_PORT: "0"    # 无公网 TCP 入站的平台关闭
```

原理：perl 中继**独占** `HY2_PORT`（无需 SO_REUSEPORT——sing-box 与官方 hysteria 内核实测都不支持端口共享），sing-box 的 HY2 服务端退到 `127.0.0.1:18081` 由中继按客户端分流转发；中继每 20 秒从同一套接字向 STUN 发包保活 Cloud NAT 映射，映射变化时自动把 `ip/port/完整 hysteria2 链接` POST 到信令服务器并更新 links.txt。客户端从信令服务器的 `/target` 拉最新链接导入（v2rayN 等不支持自动拉取，需手动更新或用脚本）。

注意：信令服务器需自备（POST `/report` 收 `{"ip","port","uri","time"}`，GET `/target` 返回最新值，Bearer 鉴权）；20 秒保活间隔按 GCP Cloud NAT 默认 30 秒 UDP 超时设计，超时更短的 NAT 需相应调小。

## HY2 经 Tailscale 用户态直连（受限 NAT 的兜底方案）

适用于打洞型 NAT（Port Restricted / Symmetric）打不通、或不想依赖信令服务的环境。tailscaled 以 `--tun=userspace-networking` 纯用户态运行（gVisor 网络栈），无 root、无 NET_ADMIN 即可：自动 STUN 探测 + DERP 协调 + 端口预测双向打洞，失败时经 DERP 中转兜底。发到容器 100.x 地址 `HY2_PORT` 的 UDP 会被投递到本地 sing-box。

```yaml
HY2_PORT: "4433"
TAILSCALE: "1"
TS_AUTHKEY: "tskey-auth-..."     # Tailscale 控制台生成，建议 Reusable
# TS_LOGIN_SERVER: "https://你的headscale"   # 可选自建
# TS_HOSTNAME: "gcp-hy2-node"
REALITY_PORT: "0"  ARGO: "0"  HY2_NAT: "0"   # TAILSCALE 与 HY2_NAT 互斥
```

**客户端必须加入同一 tailnet**（官方 Tailscale 客户端或 Headscale）——这是与 HY2_NAT 模式最大的使用差异。链接在容器拿到 100.x 地址后写入 links.txt（`#...-ts-hy2`），**地址重启不变**；配置了 `SIGNAL_URL` 时也会上报一份。`tailscale status` 中该节点显示 `direct` 即 P2P 直连成功、`relay` 为 DERP 中转。内存代价：tailscaled 约 +40MB。

## 安全设计

- 二进制：官方 Release + 固定版本 + SHA256 校验（构建时验证，失败即中止）；CI 中第三方 Action 固定到提交 SHA。
- HY2：本机生成的 ECDSA P-256 证书，链接带 `insecure=0` 与 `pinSHA256`（hex 指纹）；默认开启混淆；密码全部随机生成。
- 出站屏蔽内网、回环、链路本地、CGNAT 地址（Xray `finalRules` + sing-box 路由双重拦截），防止被用来访问宿主机或云元数据。
- 容器：非 root（uid 10001）、只读根文件系统、`cap_drop: ALL`、`no-new-privileges`；密钥目录权限 700，文件 600。
- 日志里没有密钥；Argo 令牌只通过环境变量传给 cloudflared，Xray 和 sing-box 拿不到。使用的协议和传输均未被 Xray 标记为弃用，启动日志无弃用告警。

## 内存占用与按需裁剪

各进程实测稳态 RSS（约值）：sing-box 57MB、cloudflared 42MB、xray 31MB、perl NAT 中继 7MB、supervisor 2MB。入口脚本在完成配置后 `exec` 移交给全新精简 supervisor（启动阶段的 shell 堆膨胀 ~40MB 被整体释放）；geoip/geosite 数据文件已从镜像移除（私网拦截改为显式 CIDR，xray 不再加载 geodata）。

按需关闭不用的业务（入口脚本只启动启用的进程）：

| 部署形态 | 配置 | 预期稳态 |
|---|---|---|
| 只要 HY2 直连（打洞） | `HY2_PORT=4433 HY2_NAT=1 REALITY_PORT=0 ARGO=0` | ~65MB（sing-box+perl+supervisor） |
| 只要反代直连 XHTTP | `ARGO=1 ARGO_PUBLIC_DOMAIN=xxx`（**不设** `ARGO_TOKEN`，自动跳过 cloudflared） | ~33MB（xray+supervisor） |
| HY2 打洞 + 反代直连 | 上面两者相加 | ~100MB |
| 全量（含 Argo 隧道） | 再加 `ARGO_TOKEN/ARGO_DOMAIN` | ~140MB+ |

进一步压缩：给容器加 `GOMEMLIMIT=48MiB`（或按需 32/64），xray/sing-box/cloudflared 三个 Go 进程会各自遵守软上限、更积极归还内存；代价是高负载时多花一点 CPU 做 GC。

## 升级内核版本

同时修改 `Dockerfile` 里的版本号与对应 SHA256 后重新构建：

- sing-box：[Releases](https://github.com/SagerNet/sing-box/releases) 下载 `sing-box-<版本>-linux-<架构>-glibc.tar.gz` 后 `sha256sum`
- Xray：[Releases](https://github.com/XTLS/Xray-core/releases) 页面每个 zip 都带 `.dgst` 文件，取 `SHA2-256` 一行
- cloudflared：[Releases](https://github.com/cloudflare/cloudflared/releases) 下载对应架构二进制后 `sha256sum`

## 致谢

- [yonggekkk/argosbx](https://github.com/yonggekkk/argosbx) —— 原项目
- [XTLS/Xray-core](https://github.com/XTLS/Xray-core) / [SagerNet/sing-box](https://github.com/SagerNet/sing-box) / [cloudflare/cloudflared](https://github.com/cloudflare/cloudflared)


