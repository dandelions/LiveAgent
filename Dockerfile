# syntax=docker/dockerfile:1.7

# 1. 前端构建阶段 (x86 宿主机交叉编译)
FROM --platform=$BUILDPLATFORM node:22-bookworm-slim AS webui

WORKDIR /src
RUN npm install -g pnpm@10.32.1

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY crates/agent-ui/package.json crates/agent-ui/package.json
COPY crates/agent-gui/package.json crates/agent-gui/package.json
COPY crates/agent-gateway/web/package.json crates/agent-gateway/web/package.json
RUN pnpm install --frozen-lockfile --filter @liveagent/gateway-webui...

COPY crates/agent-ui crates/agent-ui
COPY crates/agent-gateway/web crates/agent-gateway/web
RUN pnpm --filter @liveagent/gateway-webui build

# 2. Go 后端编译阶段 (x86 宿主机交叉编译)
FROM --platform=$BUILDPLATFORM golang:1.25-bookworm AS gateway-builder

# Buildx 自动注入参数，保持为空，勿设置默认值
ARG TARGETOS
ARG TARGETARCH

WORKDIR /src/crates/agent-gateway

COPY crates/agent-gateway/go.mod crates/agent-gateway/go.sum ./
RUN go mod download

COPY crates/agent-gateway ./
COPY --from=webui /src/crates/agent-gateway/web/dist ./web/dist

# 静态交叉编译 Go 二进制
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w" -o /out/liveagent-gateway ./cmd/gateway

# 3. 最终运行时阶段 (绑定目标架构，防止多架构镜像层错乱)
FROM --platform=$TARGETPLATFORM debian:bookworm-slim AS runtime

ARG TARGETPLATFORM

# 安装基础依赖与健康检查工具
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# 创建低权限非 root 用户
RUN useradd --system --uid 10001 --user-group --home-dir /nonexistent --shell /usr/sbin/nologin liveagent \
    && install -d -o liveagent -g liveagent -m 0700 /var/lib/liveagent

# 从 builder 复制目标架构的二进制文件
COPY --from=gateway-builder /out/liveagent-gateway /usr/local/bin/liveagent-gateway

USER liveagent

ENV PORT=8080 \
    LIVEAGENT_GATEWAY_DATA_DIR=/var/lib/liveagent

VOLUME ["/var/lib/liveagent"]

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/liveagent-gateway"]
