#!/usr/bin/env bash
# Xray VLESS + REALITY + Vision installer. Run on a Linux server, not your Mac.
# Default: install; a second run updates a managed installation without changing keys.
set -Eeuo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin

readonly BIN=/usr/local/bin/xray
readonly CONFIG_DIR=/usr/local/etc/xray
readonly STATE_DIR=/var/lib/xray-reality-installer
readonly UNIT=/etc/systemd/system/xray.service
readonly SERVICE_USER=xray-reality
readonly OWNER=xray-reality-install/v1
WORK='' BACKUP='' TRANSACTION=0 COMMITTED=0 WAS_ACTIVE=0 WAS_ENABLED=0
SERVER_PID='' CLIENT_PID=''
MODE=install DOMAIN=''

log() { printf '[信息] %s\n' "$*" >&2; }
warn() { printf '[提示] %s\n' "$*" >&2; }
die() { printf '[错误] %s\n' "$*" >&2; exit 1; }

help_text() {
  cat <<'HELP'
用法：bash install.sh [选项]
  无参数                  安装最新版稳定 Xray；已有本脚本安装时仅更新内核
  --status                查看环境和已有安装，不修改系统
  --check-domain DOMAIN   仅检测域名的 DNS、TLS 1.3/X25519、h2、证书和重定向
  --help                  显示帮助

支持 Debian 12+、Ubuntu 22.04+，systemd，x86_64 / aarch64。
安装时唯一需要输入的是 REALITY 目标域名，不需要把域名解析到本服务器。
UUID、密钥、shortId、端口、客户端配置和分享链接自动生成。
HELP
}

stop_probes() {
  local pid
  for pid in "$CLIENT_PID" "$SERVER_PID"; do
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  CLIENT_PID='' SERVER_PID=''
}

rollback() {
  local path item failed=0
  warn "部署未完成，正在恢复部署前的文件和服务状态。备份：$BACKUP"
  systemctl stop xray.service >/dev/null 2>&1 || true
  systemctl disable xray.service >/dev/null 2>&1 || true
  for path in "$BIN" "$CONFIG_DIR" "$STATE_DIR" "$UNIT"; do
    item="$BACKUP$path"
    rm -rf -- "$path" || failed=1
    if [[ -e "$item" ]]; then
      mkdir -p -- "$(dirname "$path")" || failed=1
      cp -a -- "$item" "$path" || failed=1
    fi
  done
  systemctl daemon-reload || failed=1
  systemctl reset-failed xray.service >/dev/null 2>&1 || true
  if (( WAS_ENABLED )); then systemctl enable xray.service >/dev/null 2>&1 || failed=1; fi
  if (( WAS_ACTIVE )); then systemctl start xray.service || failed=1; fi
  if (( failed )); then
    warn "自动恢复有失败步骤，请使用上述备份恢复并检查 systemctl status xray。"
  else
    warn '已恢复部署前的文件和服务状态。'
  fi
}

cleanup() {
  local rc=$?
  trap - EXIT ERR INT TERM
  set +e
  stop_probes
  if (( TRANSACTION && ! COMMITTED )); then rollback; fi
  if [[ -n "$WORK" ]]; then rm -rf -- "$WORK"; fi
  if (( TRANSACTION )); then rm -f -- /usr/local/bin/.xray-reality-install."$$"; fi
  exit "$rc"
}

environment_report() {
  printf '系统：%s；架构：%s；用户 UID：%s\n' "$(uname -s)" "$(uname -m)" "$EUID"
  local candidate found=0 units processes
  for candidate in "$(command -v xray || true)" "$BIN" /usr/bin/xray \
    /opt/xray/xray /usr/local/x-ui/bin/xray-linux-amd64 \
    /usr/local/x-ui/bin/xray-linux-arm64; do
    if [[ -n "$candidate" && -e "$candidate" ]]; then
      printf '检测到 Xray 文件：%s\n' "$candidate"
      found=1
    fi
  done
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    units="$(systemctl list-unit-files --no-legend --no-pager 'xray*.service' 'x-ui.service' '3x-ui.service' 2>/dev/null || true)"
    if [[ -n "$units" ]]; then printf '检测到服务：\n%s\n' "$units"; found=1; fi
    printf 'xray.service 状态：%s\n' "$(systemctl is-active xray.service 2>/dev/null || true)"
  fi
  processes="$(ps -eo comm= 2>/dev/null | awk '/(^|\/)xray(-linux-(amd64|arm64))?$/ { print }' || true)"
  if [[ -n "$processes" ]]; then printf '检测到 Xray 进程：\n%s\n' "$processes"; found=1; fi
  for candidate in "$CONFIG_DIR" /etc/xray /usr/local/x-ui /etc/x-ui /opt/3x-ui "$STATE_DIR"; do
    if [[ -e "$candidate" ]]; then printf '检测到配置/数据目录：%s\n' "$candidate"; found=1; fi
  done
  if (( ! found )); then printf '未检测到常见路径中的 Xray 安装。\n'; fi
}

check_host() {
  [[ "$(uname -s)" == Linux ]] || die '安装仅支持 Linux；当前系统不会被修改。'
  [[ "$EUID" -eq 0 ]] || die '请使用 root 运行，例如 sudo bash install.sh。'
  [[ -r /etc/os-release ]] || die '无法识别 Linux 发行版。'
  # This is a trusted operating-system file, never downloaded input.
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}:${VERSION_ID:-}" in
    debian:*) [[ "${VERSION_ID%%.*}" =~ ^[0-9]+$ ]] && (( ${VERSION_ID%%.*} >= 12 )) || die '需要 Debian 12 或更高版本。' ;;
    ubuntu:*) [[ "${VERSION_ID%%.*}" =~ ^[0-9]+$ ]] && (( ${VERSION_ID%%.*} >= 22 )) || die '需要 Ubuntu 22.04 或更高版本。' ;;
    *) die '当前版本仅支持 Debian / Ubuntu。' ;;
  esac
  [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null || die '需要正在运行的 systemd；不支持普通 Docker 容器或 OpenWrt。'
  case "$(uname -m)" in
    x86_64) ARCH=64 ;;
    aarch64|arm64) ARCH=arm64-v8a ;;
    *) die '仅支持 x86_64 或 ARM64。' ;;
  esac
  command -v flock >/dev/null || die '缺少 flock，请先安装 util-linux。'
  exec 9>/run/lock/xray-reality-install.lock
  flock -n 9 || die '另一个安装进程正在运行。'
}

detect_installation() {
  MANAGED=0
  if [[ -f "$STATE_DIR/owner" ]] && [[ "$(cat "$STATE_DIR/owner")" == "$OWNER" ]] \
    && [[ -x "$BIN" && -f "$CONFIG_DIR/config.json" && -f "$UNIT" \
      && -f "$STATE_DIR/client.json" && -f "$STATE_DIR/share-link.txt" ]] \
    && grep -q '^# Managed by xray-reality-install$' "$UNIT"; then
    MANAGED=1
  fi
  local path units dropins processes
  for path in "$BIN" "$CONFIG_DIR" "$STATE_DIR" "$UNIT"; do
    [[ ! -L "$path" ]] || die "发现符号链接，停止自动部署：$path"
  done
  if (( MANAGED )); then
    dropins="$(systemctl show xray.service -p DropInPaths --value)"
    [[ -z "$dropins" ]] || die '发现自定义 systemd drop-in，请先人工检查，避免更新到错误实例。'
    [[ "$(systemctl show xray.service -p FragmentPath --value)" == "$UNIT" ]] || die '实际加载的服务不是本脚本的服务。'
    log "识别到本脚本安装的实例：$("$BIN" version | head -n 1)；更新将保留配置和凭据。"
    return
  fi
  units="$(systemctl list-unit-files --no-legend --no-pager 'xray*.service' 'x-ui.service' '3x-ui.service' 2>/dev/null || true)"
  processes="$(ps -eo comm= 2>/dev/null | awk '/(^|\/)xray(-linux-(amd64|arm64))?$/ { print }' || true)"
  [[ -z "$units$processes" ]] || die '发现已有 Xray/面板服务或进程；请用原安装方式管理，脚本不会接管。'
  [[ -z "$(command -v xray || true)" ]] || die 'PATH 中已有 Xray，脚本不会覆盖。'
  for path in "$BIN" "$CONFIG_DIR" "$STATE_DIR" "$UNIT" /usr/bin/xray /opt/xray \
    /etc/xray /usr/local/x-ui /etc/x-ui /opt/3x-ui; do
    [[ ! -e "$path" ]] || die "发现现有安装文件或配置，请先人工处理：$path"
  done
}

ensure_dependencies() {
  local missing=0 tool
  for tool in curl python3 ip ss useradd getent timeout; do
    command -v "$tool" >/dev/null || missing=1
  done
  [[ -s /etc/ssl/certs/ca-certificates.crt ]] || missing=1
  if (( missing )); then
    log '安装必需依赖：curl、CA 证书、Python 3、iproute2、passwd、coreutils。'
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl python3 iproute2 passwd coreutils
  fi
  python3 -c 'import ssl; assert ssl.HAS_TLSv1_3; ssl.create_default_context().set_ecdh_curve("X25519")' \
    || die 'Python/OpenSSL 必须支持 TLS 1.3 和 X25519。'
}

# Embedded helper keeps the raw URL installation self-contained.
write_helper() {
  cat >"$WORK/helper.py" <<'PY'
import hashlib
import http.client
import ipaddress
import json
import os
import re
import secrets
import socket
import ssl
import subprocess
import sys
import time
import uuid
import zipfile
from pathlib import Path
from urllib.parse import urlencode


def dump(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def normalize_domain(value):
    value = value.strip().rstrip(".").lower()
    try:
        value = value.encode("idna").decode("ascii")
    except UnicodeError:
        raise ValueError("域名 IDNA 编码无效")
    labels = value.split(".")
    if len(value) > 253 or len(labels) < 2 or any(
        not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", x) for x in labels
    ):
        raise ValueError("只填写完整域名，不要包含 https://、端口、路径或通配符")
    try:
        ipaddress.ip_address(value)
    except ValueError:
        return value
    raise ValueError("请填写域名，不能填写 IP 地址")


def public_ip(value):
    address = ipaddress.ip_address(value.strip())
    if not address.is_global or address.is_multicast:
        raise ValueError("不是可用于连接的公网 IP")
    return str(address)


def endpoint(ip, port):
    return f"[{ip}]:{port}" if ":" in ip else f"{ip}:{port}"


def tls_context(alpn):
    context = ssl.create_default_context()
    context.minimum_version = context.maximum_version = ssl.TLSVersion.TLSv1_3
    context.set_ecdh_curve("X25519")
    context.set_alpn_protocols([alpn])
    return context


def check_address(domain, ip):
    started = time.monotonic()
    with socket.create_connection((ip, 443), timeout=6) as raw:
        with tls_context("h2").wrap_socket(raw, server_hostname=domain) as tls:
            if tls.selected_alpn_protocol() != "h2":
                raise ValueError("未协商出 HTTP/2 (h2)")
            tls_version = tls.version()
    # Request headers only; do not follow redirects or download a response body.
    with socket.create_connection((ip, 443), timeout=6) as raw:
        with tls_context("http/1.1").wrap_socket(raw, server_hostname=domain) as tls:
            tls.sendall(f"GET / HTTP/1.1\r\nHost: {domain}\r\nConnection: close\r\nUser-Agent: xray-reality-check/1\r\n\r\n".encode("ascii"))
            response = http.client.HTTPResponse(tls)
            response.begin()
            status = response.status
            if 300 <= status < 400:
                raise ValueError(f"根路径发生 HTTP {status} 重定向，请改用最终站点域名")
            if not 200 <= status < 500:
                raise ValueError(f"站点返回异常 HTTP {status}")
    return {"domain": domain, "ip": ip, "target": endpoint(ip, 443), "tls": tls_version,
            "alpn": "h2", "http_status": status, "probe_ms": round((time.monotonic() - started) * 1000)}


def probe(domain, output, excluded):
    domain = normalize_domain(domain)
    addresses = list(dict.fromkeys(x[4][0] for x in socket.getaddrinfo(domain, 443, type=socket.SOCK_STREAM)))
    addresses.sort(key=lambda x: ":" in x)
    if not addresses:
        raise ValueError("DNS 未返回地址")
    # Reject the entire DNS answer if it contains local/private addresses.
    for ip in addresses:
        public_ip(ip)
        if ip in excluded:
            raise ValueError("目标域名指向本服务器，可能形成回环，请换一个目标站点")
    errors = []
    for ip in addresses[:6]:
        try:
            result = check_address(domain, ip)
            dump(output, result)
            print(f"通过：{domain} → {ip}；TLS 1.3 / X25519 / h2 / 证书有效；HTTP {result['http_status']}")
            return
        except (OSError, ValueError, http.client.HTTPException) as exc:
            errors.append(f"{ip}: {exc}")
    raise ValueError("；".join(errors))


def metadata(path, arch, output):
    release = json.loads(Path(path).read_text())
    tag = release.get("tag_name", "")
    if release.get("draft") or release.get("prerelease") or not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        raise ValueError("GitHub 未返回有效的最新稳定发行版")
    name = f"Xray-linux-{arch}.zip"
    url = f"https://github.com/XTLS/Xray-core/releases/download/{tag}/{name}"
    assets = {x["name"]: x for x in release.get("assets", [])}
    if name not in assets or assets[name].get("browser_download_url") != url:
        raise ValueError("该发行版缺少匹配架构的官方安装包")
    checksum = assets[name].get("digest") or ""
    if checksum and not re.fullmatch(r"sha256:[a-fA-F0-9]{64}", checksum):
        raise ValueError("发行版校验信息格式异常")
    if not checksum and name + ".dgst" not in assets:
        raise ValueError("发行版没有 SHA256 校验信息")
    dump(output, {"tag": tag, "url": url, "digest": checksum})


def verify_extract(archive, meta, dgst, output):
    info = json.loads(Path(meta).read_text())
    if info["digest"]:
        expected = info["digest"].split(":", 1)[1].lower()
    else:
        text = Path(dgst).read_text()
        match = re.search(r"(?im)^.*(?:SHA2?-?256)\s*(?:\([^\r\n]*\))?\s*=\s*([0-9a-f]{64})\s*$", text)
        if not match:
            raise ValueError("无法解析官方 .dgst 中的 SHA256")
        expected = match[1].lower()
    with open(archive, "rb") as stream:
        actual = hashlib.file_digest(stream, "sha256").hexdigest() if hasattr(hashlib, "file_digest") else hashlib.sha256(stream.read()).hexdigest()
    if actual != expected:
        raise ValueError("SHA256 校验失败，安装包不会被执行")
    # Extract only the expected executable; archive paths never reach the filesystem.
    with zipfile.ZipFile(archive) as bundle:
        entry = bundle.getinfo("xray")
        if entry.file_size > 160 * 1024 * 1024:
            raise ValueError("安装包内的二进制大小异常")
        Path(output).write_bytes(bundle.read(entry))
    os.chmod(output, 0o755)


def choose_port():
    listen = "0.0.0.0"
    family = socket.AF_INET
    if socket.has_ipv6:
        try:
            with socket.socket(socket.AF_INET6) as test:
                test.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
                test.bind(("::", 0))
            listen, family = "::", socket.AF_INET6
        except OSError:
            pass
    for port in [443] + [secrets.randbelow(40001) + 20000 for _ in range(128)]:
        try:
            with socket.socket(family) as test:
                if family == socket.AF_INET6:
                    test.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
                test.bind((listen, port))
                return listen, port
        except OSError:
            continue
    raise ValueError("找不到可监听的 TCP 端口")


def parse_keys(text):
    values = {}
    for line in text.splitlines():
        key, separator, value = line.partition(":")
        if separator:
            values[re.sub(r"\s+", "", key).lower()] = value.strip()
    private = values.get("privatekey", "")
    password = values.get("password") or values.get("publickey", "")
    if not all(re.fullmatch(r"[A-Za-z0-9_-]{43}", x) for x in (private, password)):
        raise ValueError("无法解析 xray x25519 输出；既支持 Password，也支持旧版 PublicKey")
    return private, password


def make_client(server, port, user_id, password, short_id, domain, local_port=10808):
    return {"log": {"loglevel": "warning"}, "inbounds": [{"listen": "127.0.0.1", "port": local_port,
        "protocol": "socks", "settings": {"auth": "noauth", "udp": True}}], "outbounds": [{
        "protocol": "vless", "settings": {"vnext": [{"address": server, "port": port, "users": [{
            "id": user_id, "encryption": "none", "flow": "xtls-rprx-vision"}]}]},
        "streamSettings": {"network": "raw", "security": "reality", "realitySettings": {
            "serverName": domain, "fingerprint": "chrome", "password": password, "shortId": short_id, "spiderX": "/"}}}]}


def generate(binary, probe_path, address, output):
    address = public_ip(address)
    target = json.loads(Path(probe_path).read_text())
    keys = subprocess.check_output([binary, "x25519"], text=True, timeout=10)
    private, password = parse_keys(keys)
    user_id, short_id = str(uuid.uuid4()), secrets.token_hex(8)
    listen, port = choose_port()
    if ":" in address and listen != "::":
        raise ValueError("检测到 IPv6 公网地址，但内核未提供 IPv6 监听能力")
    server = {"log": {"loglevel": "warning"}, "inbounds": [{"tag": "vless-reality", "listen": listen,
        "port": port, "protocol": "vless", "settings": {"clients": [{"id": user_id, "flow": "xtls-rprx-vision"}],
        "decryption": "none"}, "streamSettings": {"network": "raw", "security": "reality", "realitySettings": {
        "show": False, "target": target["target"], "xver": 0, "serverNames": [target["domain"]],
        "privateKey": private, "shortIds": [short_id]}}}], "outbounds": [{"protocol": "freedom", "tag": "direct"}]}
    client = make_client(address, port, user_id, password, short_id, target["domain"])
    query = urlencode({"encryption": "none", "security": "reality", "sni": target["domain"], "fp": "chrome",
        "pbk": password, "sid": short_id, "type": "tcp", "flow": "xtls-rprx-vision", "spx": "/"})
    uri = f"vless://{user_id}@{endpoint(address, port)}?{query}#Xray-REALITY"
    dump(Path(output) / "config.json", server)
    dump(Path(output) / "client.json", client)
    dump(Path(output) / "probe.json", target)
    Path(output, "share-link.txt").write_text(uri + "\n")


def probe_configs(config_path, client_path, output, installed):
    server = json.loads(Path(config_path).read_text())
    client = json.loads(Path(client_path).read_text())
    # Both sockets are reserved together, so the OS cannot choose the same port twice.
    with socket.socket() as a, socket.socket() as b:
        a.bind(("127.0.0.1", 0))
        b.bind(("127.0.0.1", 0))
        server_port = server["inbounds"][0]["port"] if installed else a.getsockname()[1]
        socks_port = b.getsockname()[1]
    server["inbounds"][0].update(listen="127.0.0.1", port=server_port)
    client["inbounds"][0].update(listen="127.0.0.1", port=socks_port)
    client["outbounds"][0]["settings"]["vnext"][0].update(address="127.0.0.1", port=server_port)
    dump(Path(output) / "probe-server.json", server)
    dump(Path(output) / "probe-client.json", client)
    dump(Path(output) / "probe-ports.json", {"server": server_port, "socks": socks_port,
        "domain": server["inbounds"][0]["streamSettings"]["realitySettings"]["serverNames"][0]})


def wait_port(port):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", int(port)), timeout=0.5):
                return
        except OSError:
            time.sleep(0.15)
    raise ValueError(f"本地端口 {port} 未就绪")


def main():
    action, *args = sys.argv[1:]
    if action == "probe": probe(args[0], args[1], args[2:])
    elif action == "public-ip": print(public_ip(args[0]))
    elif action == "metadata": metadata(*args)
    elif action == "verify": verify_extract(*args)
    elif action == "generate": generate(*args)
    elif action == "probe-configs": probe_configs(*args[:3], installed=args[3] == "installed")
    elif action == "wait-port": wait_port(*args)
    elif action == "field": print(json.loads(Path(args[0]).read_text())[args[1]])
    else: raise ValueError("未知内部命令")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.SubprocessError, zipfile.BadZipFile, http.client.HTTPException) as exc:
        print(f"检测失败：{exc}", file=sys.stderr)
        sys.exit(1)
PY
}

helper() { python3 "$WORK/helper.py" "$@"; }
download() {
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 10 --max-time 180 --retry 2 --retry-delay 1 "$@"
}

download_xray() {
  log '查询 XTLS/Xray-core 的最新稳定发行版（不安装预发布版）。'
  download -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
    -o "$WORK/release.json" https://api.github.com/repos/XTLS/Xray-core/releases/latest \
    || die '无法访问 GitHub API；可能是 DNS、网络或匿名 API 限流，请稍后重试。'
  helper metadata "$WORK/release.json" "$ARCH" "$WORK/release-meta.json"
  RELEASE="$(helper field "$WORK/release-meta.json" tag)"
  local url digest
  url="$(helper field "$WORK/release-meta.json" url)"
  digest="$(helper field "$WORK/release-meta.json" digest)"
  log "下载并校验：$RELEASE / $ARCH"
  download -o "$WORK/xray.zip" "$url"
  if [[ -z "$digest" ]]; then download -o "$WORK/xray.zip.dgst" "$url.dgst"; fi
  helper verify "$WORK/xray.zip" "$WORK/release-meta.json" "$WORK/xray.zip.dgst" "$WORK/xray"
  "$WORK/xray" version >"$WORK/version.txt" || die '二进制无法运行，请检查 CPU、内核或 /tmp 的 noexec 挂载选项。'
  log "已验证：$(head -n 1 "$WORK/version.txt")"
}

detect_public_address() {
  local url address local_ips
  PUBLIC_ADDRESS=''
  for url in https://api.ipify.org https://checkip.amazonaws.com; do
    address="$(curl --noproxy '*' -4 -fsS --proto '=https' --connect-timeout 4 --max-time 8 "$url" 2>/dev/null || true)"
    if PUBLIC_ADDRESS="$(helper public-ip "$address" 2>/dev/null)"; then break; fi
    PUBLIC_ADDRESS=''
  done
  if [[ -z "$PUBLIC_ADDRESS" ]]; then
    address="$(curl --noproxy '*' -6 -fsS --proto '=https' --connect-timeout 4 --max-time 8 https://api6.ipify.org 2>/dev/null || true)"
    PUBLIC_ADDRESS="$(helper public-ip "$address" 2>/dev/null || true)"
  fi
  [[ -n "$PUBLIC_ADDRESS" ]] || die '无法自动识别公网 IP，请检查服务器的直连网络。'
  local_ips="$(ip -o address show | awk '{print $4}' | cut -d/ -f1)"
  EXCLUDED_IPS=("$PUBLIC_ADDRESS")
  while IFS= read -r address; do
    [[ -z "$address" ]] || EXCLUDED_IPS+=("$address")
  done <<<"$local_ips"
  log "自动识别公网 IP：$PUBLIC_ADDRESS（云 NAT/端口映射仍需由用户确认入站可达）。"
}

read_domain() {
  [[ -r /dev/tty && -w /dev/tty ]] || die '需要交互终端输入域名；通过 SSH 登录后执行。'
  while true; do
    printf '\n请输入 REALITY 目标域名（例如 www.example.com；输入 q 退出）：' >/dev/tty
    IFS= read -r DOMAIN </dev/tty || die '域名输入被中断。'
    [[ "$DOMAIN" != q && "$DOMAIN" != Q ]] || exit 0
    if timeout 75s python3 "$WORK/helper.py" probe "$DOMAIN" "$WORK/probe.json" "${EXCLUDED_IPS[@]}"; then
      return
    fi
    warn '域名未通过检测或检测超时，请换一个域名。'
  done
}

smoke_test() {
  local binary=$1 config=$2 client=$3 phase=$4 socks_port server_port domain code
  helper probe-configs "$config" "$client" "$WORK" "$phase" || return 1
  socks_port="$(helper field "$WORK/probe-ports.json" socks)" || return 1
  server_port="$(helper field "$WORK/probe-ports.json" server)" || return 1
  domain="$(helper field "$WORK/probe-ports.json" domain)" || return 1
  if [[ "$phase" != installed ]]; then
    "$binary" run -config "$WORK/probe-server.json" >"$WORK/probe-server.log" 2>&1 &
    SERVER_PID=$!
  fi
  helper wait-port "$server_port" || return 1
  "$binary" run -config "$WORK/probe-client.json" >"$WORK/probe-client.log" 2>&1 &
  CLIENT_PID=$!
  helper wait-port "$socks_port" || return 1
  code="$(curl --silent --show-error --noproxy '' --proxy "socks5h://127.0.0.1:$socks_port" \
    --proto '=https' --connect-timeout 6 --max-time 20 --head --output /dev/null \
    --write-out '%{http_code}' "https://$domain/")" || return 1
  kill -0 "$CLIENT_PID" 2>/dev/null || return 1
  if [[ -n "$SERVER_PID" ]]; then kill -0 "$SERVER_PID" 2>/dev/null || return 1; fi
  [[ "$code" =~ ^[234][0-9][0-9]$ ]] || return 1
  stop_probes
  log 'REALITY + VLESS 本地端到端握手及 HTTPS 转发测试通过。'
}

begin_transaction() {
  local path
  BACKUP="/var/backups/xray-reality/$(date -u +%Y%m%dT%H%M%SZ)-$$"
  install -d -m 700 "$BACKUP"
  systemctl is-active --quiet xray.service && WAS_ACTIVE=1
  systemctl is-enabled --quiet xray.service && WAS_ENABLED=1
  for path in "$BIN" "$CONFIG_DIR" "$STATE_DIR" "$UNIT"; do
    if [[ -e "$path" ]]; then
      mkdir -p -- "$BACKUP$(dirname "$path")"
      cp -a -- "$path" "$BACKUP$path"
    fi
  done
  TRANSACTION=1
}

create_service_user() {
  if ! getent passwd "$SERVICE_USER" >/dev/null; then
    useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$SERVICE_USER"
  fi
  [[ "$(id -u "$SERVICE_USER")" -ne 0 && "$(id -g "$SERVICE_USER")" -ne 0 ]] || die '服务账号的 UID/GID 不能为 0。'
  [[ "$(id -gn "$SERVICE_USER")" == "$SERVICE_USER" ]] || die '服务账号必须使用同名的独立主组。'
  [[ "$(getent passwd "$SERVICE_USER" | cut -d: -f6)" == /nonexistent ]] || die '同名账号不是本脚本专用服务账号，停止部署。'
  case "$(getent passwd "$SERVICE_USER" | cut -d: -f7)" in
    /usr/sbin/nologin|/sbin/nologin) ;;
    *) die '同名账号允许交互登录，停止部署。' ;;
  esac
}

write_unit() {
  cat >"$WORK/xray.service" <<'SERVICE'
# Managed by xray-reality-install
[Unit]
Description=Xray VLESS REALITY
Documentation=https://xtls.github.io/
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=xray-reality
Group=xray-reality
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
UMask=0077
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK

[Install]
WantedBy=multi-user.target
SERVICE
  install -m 644 "$WORK/xray.service" "$UNIT"
}

deploy() {
  begin_transaction
  create_service_user
  install -d -m 755 /usr/local/bin
  install -m 755 "$WORK/xray" "/usr/local/bin/.xray-reality-install.$$"
  mv -f -- "/usr/local/bin/.xray-reality-install.$$" "$BIN"
  if (( ! MANAGED )); then
    install -d -m 750 -o root -g "$SERVICE_USER" "$CONFIG_DIR"
    install -m 640 -o root -g "$SERVICE_USER" "$WORK/config.json" "$CONFIG_DIR/config.json"
    install -d -m 700 -o root -g root "$STATE_DIR"
    install -m 600 "$WORK/client.json" "$WORK/share-link.txt" "$WORK/probe.json" "$STATE_DIR/"
    printf '%s\n' "$OWNER" >"$STATE_DIR/owner"
    write_unit
  fi
  "$BIN" run -test -config "$CONFIG_DIR/config.json" >"$WORK/config-test.log" 2>&1 \
    || die '配置校验失败，正在自动回滚。'
  systemctl daemon-reload
  systemctl reset-failed xray.service || true
  systemctl restart xray.service
  smoke_test "$BIN" "$CONFIG_DIR/config.json" "$STATE_DIR/client.json" installed \
    || die '部署后的实际握手失败，正在自动回滚；请检查目标站点和 journalctl -u xray。'
  systemctl is-active --quiet xray.service || die '服务未保持运行，正在自动回滚。'
  systemctl enable xray.service
  printf '%s\n' "$RELEASE" >"$STATE_DIR/version"
  COMMITTED=1
  log "部署完成；本次部署前的备份：$BACKUP"
}

show_result() {
  printf '\nXray 配置：%s/config.json\n客户端配置：%s/client.json\n分享链接：\n' "$CONFIG_DIR" "$STATE_DIR"
  cat "$STATE_DIR/share-link.txt"
  local port
  port="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["inbounds"][0]["port"])' "$CONFIG_DIR/config.json")"
  printf '\n请在云安全组及主机防火墙中放行 TCP %s。\n' "$port"
  printf '本地握手已验证；公网可达性请从另一台设备导入链接验证。\n'
  printf '状态：systemctl status xray --no-pager\n日志：journalctl -u xray -n 50 --no-pager\n'
}

main() {
  case "${1:-}" in
    '') [[ $# -eq 0 ]] || die '未知参数。' ;;
    --help|-h) help_text; return ;;
    --status) [[ $# -eq 1 ]] || die '参数数量不正确。'; environment_report; return ;;
    --check-domain) [[ $# -eq 2 ]] || die '用法：bash install.sh --check-domain DOMAIN'; MODE=check; DOMAIN=$2 ;;
    *) help_text; die '未知参数。' ;;
  esac
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'printf "[错误] 步骤失败（第 %s 行），安装未完成。\n" "$LINENO" >&2' ERR
  if [[ "$MODE" == check ]]; then
    command -v python3 >/dev/null || die '域名检测需要 Python 3。'
    WORK="$(mktemp -d)"
    write_helper
    # No dependencies are installed in this read-only mode.
    if command -v timeout >/dev/null; then
      timeout 75s python3 "$WORK/helper.py" probe "$DOMAIN" "$WORK/probe.json"
    else
      helper probe "$DOMAIN" "$WORK/probe.json"
    fi
    return
  fi
  check_host
  environment_report
  detect_installation
  ensure_dependencies
  WORK="$(mktemp -d /tmp/xray-reality.XXXXXXXX)"
  write_helper
  download_xray
  if (( MANAGED )); then
    local current
    current="$("$BIN" version | awk 'NR==1 {print $2}')"
    if [[ "v$current" == "$RELEASE" ]]; then
      log "已经是最新稳定版 $RELEASE，没有更改配置或服务状态。"
      printf '已保存的分享链接：%s/share-link.txt\n' "$STATE_DIR"
      return
    fi
    "$WORK/xray" run -test -config "$CONFIG_DIR/config.json" >"$WORK/config-test.log" 2>&1 \
      || die '新版内核无法加载现有配置；原安装未变更。'
    smoke_test "$WORK/xray" "$CONFIG_DIR/config.json" "$STATE_DIR/client.json" staged \
      || die '新版内核的 REALITY 握手预检失败；原安装未变更。'
  else
    detect_public_address
    while true; do
      read_domain
      helper generate "$WORK/xray" "$WORK/probe.json" "$PUBLIC_ADDRESS" "$WORK"
      "$WORK/xray" run -test -config "$WORK/config.json" >"$WORK/config-test.log" 2>&1 \
        || die '生成的配置未通过 Xray 检查。'
      if smoke_test "$WORK/xray" "$WORK/config.json" "$WORK/client.json" staged; then break; fi
      stop_probes
      warn '域名基础检测通过，但真实 REALITY 握手未通过，请输入另一个目标域名。'
    done
  fi
  deploy
  show_result
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
