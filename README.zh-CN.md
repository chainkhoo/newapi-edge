# newapi-edge

> 为 [New API](https://github.com/Calcium-Ion/new-api) 站点提供边缘加速节点 —— 为线路不佳地区的用户加速 API 访问，**且不暴露管理后台和管理 API**。

[English](./README.md) · 中文

---

## 这是什么

`newapi-edge` 是一个开箱即用的 Caddy 反向代理容器，部署在一台**到目标用户线路较好的 VPS** 上（例如香港 / 日本 / 新加坡节点，给大陆用户加速）。客户端把请求发到这台边缘节点，节点再直连你的 New API 源站。

- **只转发 API endpoint**：`/v1/*`、`/v1beta/*`、`/mj/*`、`/suno/*` 等。其他路径一律返回 404，**管理后台、登录页、`/api/*` 管理接口完全不暴露**。
- **绕过源站前面的 CDN**：直连源站真实 IP，同时把 `Host` 头和 TLS SNI 改回公开域名，所以源站的 vhost 路由和 HTTPS 证书继续生效。
- **流式响应优化**：`flush_interval -1` + 600s 读写超时，SSE 和长 LLM 请求不会被缓冲或截断。
- **自动 HTTPS**：Caddy 自动申请和续签 Let's Encrypt 证书，零配置。
- **可移植**：三个文件（`docker-compose.yml`、`Caddyfile`、`.env`）。换 VPS 时复制目录、改 `.env`、`docker compose up -d`，30 秒搞定。

## 架构

```
                        ┌──────────────────────────────┐
   线路慢的用户  ─────► │  newapi-edge VPS（本仓库）   │ ─────► 源站真实 IP
                        │  Caddy 反向代理              │       （Host 和 SNI 改回
                        │  - 路径白名单                │        ORIGIN_HOST，所以
                        │  - SSE 流式优化              │        源站 vhost + 证书
                        │  - 自动 HTTPS                │        正常工作）
                        └──────────────────────────────┘
```

工作原理：客户端访问 `CHILD_DOMAIN`（DNS A 记录指向边缘 VPS）。边缘节点通过 TCP/TLS 连接到 `ORIGIN_IP:443`，但 SNI 和 Host 头仍是 `ORIGIN_HOST`，源站 Web 服务器就像看到了一个正常发往 `ORIGIN_HOST` 的请求，照常路由给 New API。

## 安装

提供两种**对等**的部署方式，效果完全一致，按是否需要自定义路径白名单来选择。

|  | 方式 A · Docker Compose | 方式 B · 预构建镜像 |
|---|---|---|
| **适合场景** | 自定义 `Caddyfile`；版本化管理配置 | 最快上手；不需要源码克隆 |
| **需要** | `git` + Docker + Compose 插件 | 仅 Docker |
| **镜像来源** | 拉 `caddy:2-alpine` + 挂载本地 `Caddyfile` | 拉 `ghcr.io/chainkhoo/newapi-edge:<tag>`，`Caddyfile` 已烤进镜像 |
| **改路径白名单** | 改 `Caddyfile` → `docker compose restart caddy` | Fork 仓库（CI 自动重建你的镜像），或切到方式 A |
| **升级** | `git pull && docker compose pull && docker compose up -d` | `docker pull … && docker rm -f … && docker run …` |

### 通用前置条件（两种方式都需要）

- 一台公网 IPv4 的 VPS，**80 + 443/TCP 和 443/UDP** 端口对公网可达
- Docker Engine ≥ 20.10
- 一个你控制的 DNS A 记录，指向本 VPS —— **不要开 CDN 代理**（Cloudflare 用户：灰云图标 / "仅 DNS"）
- 一个你控制的 New API 源站，能通过其公开域名的 HTTPS 证书在真实 IP 上访问

---

### 方式 A · Docker Compose

```bash
# 1. 克隆仓库
git clone https://github.com/chainkhoo/newapi-edge.git
cd newapi-edge

# 2. 填写配置
cp .env.example .env
$EDITOR .env       # 填入 CHILD_DOMAIN、ORIGIN_IP、ORIGIN_HOST、ACME_EMAIL、NODE_NAME

# 3. 配置 DNS
#    A 记录：<CHILD_DOMAIN>  →  本 VPS 的 IPv4     （仅 DNS，不开 CDN 代理）

# 4. 启动
docker compose up -d

# 5. 观察证书签发（约 30 秒）
docker compose logs -f caddy
#    应该看到 "certificate obtained successfully"

# 6. 验证
curl -sS https://<CHILD_DOMAIN>/v1/models     # → New API 的 JSON
curl -sS https://<CHILD_DOMAIN>/              # → 404（管理界面已屏蔽）
curl -sS https://<CHILD_DOMAIN>/healthz       # → "ok"
```

**日常运维：**

```bash
# 看实时日志
docker compose logs -f caddy
tail -f logs/access.log

# 改完 Caddyfile 热加载（零停机）
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile

# 升级 Caddy
docker compose pull && docker compose up -d

# 停止 / 重启
docker compose down
docker compose up -d
```

---

### 方式 B · 预构建镜像（`docker run`）

每次 push 到 `main` 或打 `v*` tag 都会自动构建多架构镜像（`linux/amd64` + `linux/arm64`）推到 GHCR。

```bash
# 1. 创建命名卷（Let's Encrypt 证书跨容器重建持久化）
docker volume create newapi_edge_data
docker volume create newapi_edge_config

# 2. 配置 DNS
#    A 记录：api-cn.example.com  →  本 VPS 的 IPv4     （仅 DNS，不开 CDN 代理）

# 3. 运行容器
docker run -d \
  --name newapi-edge \
  --restart unless-stopped \
  -p 80:80 -p 443:443 -p 443:443/udp \
  -v newapi_edge_data:/data \
  -v newapi_edge_config:/config \
  -e CHILD_DOMAIN=api-cn.example.com \
  -e ORIGIN_IP=203.0.113.10 \
  -e ORIGIN_HOST=api.example.com \
  -e ACME_EMAIL=you@example.com \
  -e NODE_NAME=edge-1 \
  ghcr.io/chainkhoo/newapi-edge:latest

# 4. 观察证书签发（约 30 秒）
docker logs -f newapi-edge

# 5. 验证
curl -sS https://api-cn.example.com/v1/models     # → New API 的 JSON
curl -sS https://api-cn.example.com/              # → 404
curl -sS https://api-cn.example.com/healthz       # → "ok"
```

**日常运维：**

```bash
# 看实时日志
docker logs -f newapi-edge

# 升级到新镜像（数据保留在 named volumes 里）
docker pull ghcr.io/chainkhoo/newapi-edge:latest
docker rm -f newapi-edge
docker run -d ...   # 和安装步骤 3 同一条命令

# 停止 / 重启
docker stop newapi-edge
docker start newapi-edge
```

**可用的镜像 tag：**

| Tag | 含义 |
|---|---|
| `:latest` | `main` 分支最新，每次提交后自动重建 |
| `:X.Y.Z` | 具体 release 版本（如 `:0.1.1`）—— **生产环境推荐** |
| `:X.Y` | minor 轨，自动跟随 `X.Y.*` 发布 |
| `:X` | major 轨，自动跟随 `X.*.*` 发布 |
| `:sha-<短哈希>` | 锁定到具体 commit |

生产建议：锁定具体的 `X.Y.Z`（如 `:0.1.1`），主动控制升级时机，而不是追 `:latest`。

## 配置项

所有运行时配置都在 `.env`：

| 变量 | 用途 | 示例 |
|---|---|---|
| `CHILD_DOMAIN` | 边缘节点对外的公开域名 | `api-cn.example.com` |
| `ORIGIN_IP` | 源站服务器的真实 IPv4 | `203.0.113.10` |
| `ORIGIN_HOST` | 你的 New API 平时对外的公开域名 | `api.example.com` |
| `ACME_EMAIL` | Let's Encrypt 注册和到期通知邮箱 | `you@example.com` |
| `NODE_NAME` | 节点标识，会作为 `X-Origin-Node` 头传给源站 | `hk-1` |
| `ORIGIN_TLS_OPTS` | 注入到 `transport http` 块的源站 TLS 策略指令。默认跳过源站证书校验（New API 源站大多走 Cloudflare 用 Origin Cert）。设为空开启严格校验。详见 FAQ。 | `tls_insecure_skip_verify` |

路径白名单写在 `Caddyfile` 里。默认覆盖了 New API 常见的厂商接口（OpenAI、Gemini、Anthropic、Midjourney、Suno、Luma、SD 等）。如果你的 New API 启用了其他厂商，把对应路径加到 `@api` matcher 然后 `docker compose restart caddy` 即可。

## 加固源站（建议）

默认情况下，只要有人知道你源站的真实 IP，仍然能绕过边缘节点直接访问。要强制流量走边缘节点：

1. **源站的 443 端口加防火墙**，只允许你的边缘节点 IP 访问（如果有 CDN 兜底，也加上 CDN 的 IP 段）。以 UFW 为例：
   ```bash
   ufw allow from <边缘节点 IP> to any port 443 proto tcp
   # ……每个边缘节点和 CDN IP 段都加一条……
   ufw deny 443/tcp
   ```
2. **可选**：源站的反向代理（nginx/openresty/Caddy）检查一个边缘节点注入的共享密钥 header，校验失败就拒绝。比如把 `X-Origin-Node` 当密码使用。

## 多节点部署

同一仓库、同一 `Caddyfile`，每台 VPS 不同的 `.env`：

```bash
# 每台节点上
cp .env.example .env
# 修改：NODE_NAME=hk-1 / jp-tokyo / us-la …
docker compose up -d
```

然后用 GeoDNS / 智能解析服务（Cloudflare Load Balancer 的 Geo Steering、DNSPod 分线路、NS1 等）按地区或运营商把用户路由到最近的节点。

## 切换 VPS（零停机）

```bash
# 在新 VPS 上：
git clone <repo> && cd newapi-edge && cp .env.example .env && $EDITOR .env
docker compose up -d                   # 30 秒左右证书签发完成

# 新节点健康后：
#   - DNS A 记录改向新 VPS 的 IP
#   - 等 TTL 过期（建议提前把 TTL 调成 300s，切换更快）
#   - 旧 VPS 下线：docker compose down
```

DNS 切换期间新旧两台都在服务，零停机。

## 日常运维

```bash
# 看实时日志（Caddy stdout + 结构化访问日志）
docker compose logs -f caddy
tail -f logs/access.log

# 修改 Caddyfile 后热加载（不重启容器，零停机）
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile

# 升级 Caddy 镜像
docker compose pull && docker compose up -d

# 停止 / 启动
docker compose down
docker compose up -d
```

## 常见问题

**证书签发不出来**
- DNS A 记录必须在 `docker compose up -d` **之前**就指向本 VPS，并且**不要开 CDN 代理**。
- 80 端口必须能从公网访问（Let's Encrypt 的 HTTP-01 挑战要用）。
- 看日志：`docker compose logs caddy | grep -i acme`。

**502 / 连不上源站**
- 本 VPS 能连到 `ORIGIN_IP` 吗？测试：`docker compose exec caddy wget -qO- https://<ORIGIN_IP> --header="Host: <ORIGIN_HOST>"`
- 源站防火墙：如果设置了 IP 白名单，把本 VPS 的 IP 加进去。
- Caddy 日志里看到 `x509: certificate signed by unknown authority`？源站返回的证书（多半是 Cloudflare Origin Cert）公网 CA 链验证不了。默认 `ORIGIN_TLS_OPTS=tls_insecure_skip_verify` 就是处理这种情况——确认你没把它清空。详见 FAQ"源站 TLS 验证"那条。

**正常的 endpoint 返回 404**
- 你的 New API 可能用了默认白名单没覆盖的厂商路径。把它加到 `Caddyfile` 的 `@api` matcher 里然后 reload。

**流式响应被截断或卡住**
- 确认 `Caddyfile` 里有 `flush_interval -1`（默认有）。
- 如果源站前面有 CDN 强制缓冲（比如 CF 的某些设置），本方案直连源站 IP 就能绕过。

## FAQ

**和 New API 官方的主从集群方案相比怎么样？**

两者解决的不是同一个问题：

- **官方集群**（主节点 + 从节点 + 共享 MySQL/Redis）解决的是**单机处理能力不够**、需要水平扩展处理量。所有节点共享同一数据库和 Redis。
- **newapi-edge**（本项目）解决的是**网络延迟瓶颈**，为远端用户加速接入。边缘节点完全不接触业务数据。

对于"给某地区用户加速"这种地理加速场景，官方集群方案不仅不更简单，反而**更慢、更危险**：

| 维度 | 官方集群 | newapi-edge |
|---|---|---|
| 边缘节点需要的组件 | 完整 new-api 容器 + 必须能访问源站 MySQL + 必须能访问源站 Redis | 单一 Caddy 容器，零业务依赖 |
| 跨区域延迟影响 | ❌ 严重——每个 LLM 请求边缘节点要做 5–10 次跨区域 DB 往返（查用户/token/channel、写 log、扣配额、退配额等），每次 150ms+，累加 1–2 秒 | ✅ 仅 1 次跨区域（请求打包透传到源站，源站本地完成所有 DB 操作） |
| 配置变更生效 | 默认 60 秒同步一次（改 channel、加用户要等） | 实时（边缘不缓存任何业务状态） |
| 管理界面 | 默认开放（从节点也跑完整 UI） | 默认 404（路径白名单只放 API endpoint） |
| 边缘节点被攻破的影响 | 数据库密码 + `SESSION_SECRET` / `CRYPTO_SECRET` 泄露 → 源站全部数据沦陷 | 仅边缘 VPS 弃用，源站不受影响 |
| 必须开放的网络面 | 源站 MySQL + Redis 必须对所有边缘节点可达（公网或 VPN） | 源站仅 443 端口接入边缘（可用 IP 白名单加固） |
| 节点上下线 | 改 LB upstream、清 Redis 中节点状态 | DNS 切换 + `docker compose down` |

**关键差别在数据库位置**：官方集群要求所有节点共享同一数据库，意味着边缘节点每次 LLM 请求都要跨区域查询源站数据库——这部分延迟会**吃掉甚至超过**边缘加速带来的收益。

两种方案也可以**叠加使用**：源站机房做官方主从集群解决处理量、远端区域用 newapi-edge 解决网络延迟。但如果你的目标只是"给某地用户加速"，本项目更合适。

**什么时候应该用官方集群方案而不是本项目？**
- 源站 CPU/内存扛不住，需要多机分担处理量
- 多个节点在同一机房或同区域（共享低延迟数据库）
- 主要追求高可用而非地理加速

---

**为什么用 Caddy 不用 Nginx？** Caddy 自带 Let's Encrypt 自动签发和流式代理的合理默认值，整个项目用 80 行 `Caddyfile` 就能跑，不需要 certbot/cron 那一套。想用 Nginx 也行，思路一样，配置量差不多。

**为什么默认不验证源站 TLS 证书？怎么开启严格校验？**

边缘节点直连 `ORIGIN_IP`（绕过任何 CDN）。当源站走 Cloudflare 代理时（New API 站长最常见的部署方式），源站上装的是 **Cloudflare Origin Certificate**，只有 CF 网络信任它，公网 CA 链无法验证。如果不跳过校验，每次请求都会失败：HTTP 502 + `x509: certificate signed by unknown authority`。

安全上的含义：

- **客户端 → 边缘的 TLS** *始终*会严格校验 Caddy 为 `CHILD_DOMAIN` 申请的 Let's Encrypt 证书。这是用户能直接感知的部分，完全不受影响。
- **边缘 → 源站的 TLS** 主要为了 SNI / Host 兼容性，通常走机房骨干网（比如两个数据中心之间）。源站用 CF Origin Cert 时校验它价值很低。

如果你的源站**不走 Cloudflare**，且为 `ORIGIN_HOST` 配置了公网可信证书（比如直接的 Let's Encrypt 证书），可以开启严格校验：

```bash
# .env  （方式 A）
ORIGIN_TLS_OPTS=

# 或 docker run  （方式 B）
-e ORIGIN_TLS_OPTS=
```

把 `ORIGIN_TLS_OPTS` 设置为空字符串，会从 transport 块里移除 `tls_insecure_skip_verify` 指令，Caddy 会拒绝任何证书无法回溯到公共可信 CA 的源站。

**这个项目能给非 New API 的后端用吗？** 能。只要后端的 API 路径有固定前缀，改一下 `@api` matcher 就行。

**能把边缘节点放 Cloudflare 后面做 DDoS 防护吗？** 可以，但你部署边缘节点的目的通常**就是**绕开 CF 给国内用户加速（CF 国内线路质量不稳定）。如果两者都要，建议同时维护两个 DNS 记录：`CHILD_DOMAIN`（灰云、直连边缘）给受益于边缘节点的用户，原有 CDN 域名给其他用户。

## 贡献

欢迎 PR。特别欢迎以下方向：
- 各类 New API 衍生版的路径白名单预设。
- 常见 GeoDNS 服务商的配置示例。
- HAProxy / Nginx / Traefik 的等价实现（给已经在用其他反代的用户）。

## 许可

MIT —— 见 [LICENSE](./LICENSE)。

本项目与 New API 项目无隶属关系。New API 版权归原作者所有。
