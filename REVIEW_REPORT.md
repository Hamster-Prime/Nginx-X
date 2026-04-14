# Nginx-X 深度代码审查报告

**审查日期:** 2026-04-15
**审查文件:** `nx.sh`, `install.sh`
**审查范围:** 安全性、健壮性、逻辑正确性、代码质量、兼容性

---

## 一、已修复的问题

### A. 安全性审查

#### SEC-1: URL 输入验证不足 -- nginx 配置注入风险 [高]

**问题:** `add_external_url_proxy()` 和 `modify_external_conf()` 中的上游 URL（`upstream_url`、`stream_upstream_url`、`source_site_url`）仅验证是否以 `https?://` 开头，未检查是否包含可注入 nginx 配置的危险字符（如 `{`、`}`、`;`、`\`、`'`、`` ` ``、换行符）。这些 URL 被直接嵌入 nginx 配置的 `proxy_pass`、`proxy_redirect`、`sub_filter` 等指令中。

**风险:** 攻击者可通过构造恶意 URL 注入 nginx 配置指令，例如在 `proxy_redirect` 中插入 `;` 后跟恶意指令。

**修复:** 新增 `valid_url()` 函数，对 URL 进行以下校验：
- 必须以 `https?://` 开头
- 长度不超过 2048 字符
- 不含换行符、回车符
- 不含 `{`、`}`、`\`、`;`、`'`、`` ` ``（nginx 配置注入相关字符）
- 所有上游 URL 输入点均已替换为 `valid_url()` 验证

#### SEC-2: HTTPS 配置缺少显式加密套件限制 [中]

**问题:** HTTPS server 块仅配置了 `ssl_protocols TLSv1.2 TLSv1.3` 和 `ssl_prefer_server_ciphers off`，但未指定 `ssl_ciphers`。这可能导致 nginx 接受弱加密套件（如 RC4、3DES 等，取决于 OpenSSL 版本）。

**修复:**
- 新增全局常量 `SSL_CIPHERS`，包含 Mozilla 推荐的强加密套件列表
- 在 `build_external_proxy_conf()` 和 `enable_https_for_conf_file()` 的 HTTPS server 块中添加 `ssl_ciphers ${SSL_CIPHERS};`
- 加密套件涵盖 AES-GCM、CHACHA20-POLY1305（ECDHE + DHE）

#### SEC-3: EDITOR 环境变量信任 [低]

**问题:** `run_editor()` 直接使用 `$EDITOR` 环境变量，虽有数组分割防止 shell 注入，但恶意编辑器仍可执行任意命令。

**评估:** 当前列表 `read -r -a` 方式安全（不会 shell 注入），`$EDITOR` 仅影响以 root 编辑配置文件的用户自身。风险极低，暂不修复。

### B. 健壮性审查

#### ROB-1: `valid_domain()` 使用 bash 4.3+ 语法 [中]

**问题:** `${labels[-1]}`（负数组索引）需要 bash 4.3+，与脚本声明的 bash 3.2+ 兼容目标不符。虽然目标系统（Ubuntu/Debian/CentOS）均自带 bash 4+，但严格兼容性应避免此写法。

**修复:** 替换为 `${labels[${#labels[@]}-1]}`，兼容 bash 3.2+。

#### ROB-2: `health_check_conf_file()` 使用 bash 4.0+ 大写转换 [中]

**问题:** `${scheme^^}`（变量大写转换）需要 bash 4.0+。

**修复:** 替换为 `$(tr '[:lower:]' '[:upper:]' <<< "$scheme")`，兼容所有 bash 版本。

#### ROB-3: `build_proxy_conf()` 缺少 `stream_mode` 元数据注释 [低]

**问题:** `build_proxy_conf()` 生成的配置不含 `# stream_mode=` 注释，导致后续 `enable_https_for_conf_file()` 在读取 `stream_mode` 时始终为空，stream 优化（`media` 模式）无法在 HTTPS 启用流程中保留。

**修复:** 在 `build_proxy_conf()` 的元数据区添加 `# stream_mode=normal`。

#### ROB-4: HTTP-01 预检挑战文件残留 [低]

**问题:** `precheck_http01()` 创建的测试 token 文件在函数返回前已清理，但如果脚本在清理前被 `set -e` 或信号终止，文件可能残留。影响极低（临时测试文件，无安全风险）。

**评估:** 暂不修复，现有行为已足够。

### C. 逻辑审查

#### LOGIC-1: `issue_cert()` 和 `issue_cert_for_domain()` 重复代码 [中]

**问题:** 两个函数共享约 90% 相同逻辑（ACME 挑战配置、预检、证书签发、安装），仅存在以下差异：
- `issue_cert()` 从用户输入读取域名，`issue_cert_for_domain()` 接受参数
- 部分提示消息的 "自动" 前缀不同
- 成功消息末尾是否提示自动续期

**修复:** 提取共享实现为 `_do_issue_cert()`，参数化 `interactive` 标志（1=手动菜单/0=自动流程），薄包装保留原始错误消息语义。

#### LOGIC-2: 端口复用逻辑正确性 [通过]

端口复用检测、443 证书缺失回退到 80、SSL listener 检测、`force_enable_https` 状态机均逻辑正确。多站点场景下的 nginx virtual hosting 行为与配置生成一致。

#### LOGIC-3: HTTPS 启用/禁用状态转换 [通过]

- 启用：生成 80（redirect + ACME）+ listen_port（SSL）双 server 块，元数据标记 `https_enabled=true`
- 禁用：读取原上游配置，生成单 server 块（HTTP），移除 HTTPS 标记
- 状态检测：`conf_https_enabled()` 双重检查（注释标记 + listen ssl 模式匹配）
- 循环启用/禁用：每次完整重建配置，不会累积状态

#### LOGIC-4: 证书管理生命周期 [通过]

- 申请：ACME HTTP-01 + 预检 + 挑战服务器自动部署/清理
- 安装：`--install-cert` 安装到 `${SSL_DIR}/${domain}/`
- 续期：`ensure_acme_cron()` 添加 crontab 条目（带去重检查）
- 删除：acme.sh --remove + 清理本地证书目录 + 清理 crontab + 清理 SSL 目录
- 生命周期完整，无泄漏

### D. 代码质量

#### QUAL-1: 端口复用检测逻辑重复 [中]

**问题:** `add_reverse_proxy()` 和 `add_external_url_proxy()` 中的端口占用检测、443 证书回退、SSL listener 检测逻辑几乎完全相同（约 20 行）。

**评估:** 建议后续重构为 `resolve_create_port()` 共享函数，但当前重构风险较高（逻辑敏感），标记为技术债务。

#### QUAL-2: `build_external_proxy_conf()` 函数过长 [低]

**问题:** 该函数约 120 行，处理 5 种外部模式（normal、media、emby_http、emby_https、emby_lily），职责较多。

**评估:** 各模式间差异较大，拆分收益有限。建议保持现状，通过注释提升可读性。

### E. 兼容性审查

#### COMPAT-1: `mapfile -t` 需要 bash 4.0+ [信息]

`mapfile`（`readarray`）在多处使用（`print_conf_list`、`show_traffic_stats`、`list_managed_conf_files` 等）。bash 3.2 不支持。

**评估:** 目标系统（Ubuntu 12.04+、Debian 7+、CentOS 6+）均附带 bash 4.0+。无需修改。

#### COMPAT-2: `ss` filter 语法兼容性 [信息]

`is_port_used_os()` 使用 `ss -lnt "( sport = :${p} )"` 过滤语法，需要 iproute2 较新版本。

**评估:** 所有目标系统均安装足够新的 iproute2。`2>/dev/null` 兜底处理旧版本。

#### COMPAT-3: `install.sh` 无显著问题 [通过]

- `get_script_dir()` 的 `${BASH_SOURCE[0]-}` 语法兼容 bash 3.2+
- `NO_RUN` 环境变量通过 `env` 传递到 sudo 子进程，正确
- Git 仓库检测与克隆逻辑完整

---

## 二、审查通过项（无需修改）

| 项目 | 说明 |
|------|------|
| `set -euo pipefail` 行为 | `(( )) &&` 模式在 `set -e` 下安全（受 `&&` 列表保护） |
| 临时文件安全 | `make_tracked_tmp()` + `trap EXIT` 机制完整，无泄漏 |
| sudo 使用 | `${SUDO}` 变量一致使用，无硬编码 sudo |
| 路径遍历防护 | `valid_domain()`/`valid_server_name_input()` 输入验证充分 |
| 域名/端口输入验证 | 完整（格式、长度、TLD、IP 八位组范围） |
| 确认操作默认安全 | `confirm()` 默认返回 N（需显式输入 Y） |
| 回滚机制 | `apply_conf_with_rollback()` 覆盖所有配置变更操作 |
| 卸载二次确认 | 高危操作均有双重 `confirm()` 检查 |

---

## 三、建议（非必须，可后续迭代）

| 编号 | 建议 | 优先级 |
|------|------|--------|
| SUG-1 | 提取端口复用检测为 `resolve_create_port()` 共享函数 | 中 |
| SUG-2 | HTTPS 配置添加 `add_header Strict-Transport-Security` (HSTS) | 中 |
| SUG-3 | HTTPS 配置添加 `ssl_session_cache shared:SSL:10m` 性能优化 | 低 |
| SUG-4 | 为每个站点配置添加独立 `access_log` 便于日志分析 | 低 |
| SUG-5 | `show_nginx_realtime_status()` 的 TLS 天数计算可简化（避免 `bash -lc`） | 低 |
| SUG-6 | `ensure_http_challenge_server()` 的挑战配置文件应加入全局清理追踪，防止脚本异常退出时残留 | 低 |

---

## 四、验证结果

```
$ bash -n nx.sh          ... OK
$ bash -n install.sh     ... OK
$ shellcheck -x nx.sh    ... OK (0 warnings, 0 errors)
$ shellcheck -x install.sh ... OK
```

URL 验证函数测试结果：
- 合法 URL 通过（http/https、带查询参数、带认证信息）
- 注入字符拒绝（`{}`、`;`、`\`、`'`、`` ` ``、换行符）
- 非 http/https 协议拒绝（ftp://）
- 超长 URL 拒绝（>2048 字节）
