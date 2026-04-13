# Nginx-X

一个基于 Bash 的 Nginx 自动化管理交互脚本（Ubuntu / Debian / CentOS）。

## 项目目标

通过数字菜单统一管理 Nginx，重点保证稳定性：
- 所有配置修改后都会先执行 `nginx -t`
- 校验通过才会 `reload`
- 校验失败会自动回滚，避免把服务改挂

## 快速开始

```bash
git clone https://github.com/Xiuyixx/Nginx-X.git
cd Nginx-X
bash install.sh
```

安装后可直接运行：

```bash
nx
```

## 一键安装（推荐）


```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Xiuyixx/Nginx-X/main/install.sh)"
```

说明：
- 首次执行会克隆到 `/opt/Nginx-X`
- 再次执行会自动拉取最新代码
- 如果 `/opt/Nginx-X` 已存在但不是 Git 仓库，安装器会先提示确认，再决定是否清空重装
- 安装完成后自动启动 `nx`

## 当前功能

### 稳定性设计

- 所有配置变更都会先执行 `nginx -t`
- 校验失败自动回滚，避免把在线 Nginx 配挂
- 443 / HTTPS 端口复用场景会优先走更安全的落地流程
- 证书申请前会做 HTTP-01 自检，并区分“软失败可继续”和“硬失败建议先修复”
- 临时文件使用安全随机文件名，降低冲突和误覆盖风险

1. **安装升级Nginx**
   - 自动检查是否已安装 Nginx
   - 未安装时自动安装依赖：`curl` `wget` `socat` `cron`
   - 自动安装 Nginx 官方 stable 版本
   - 安装后自动停用 `default.conf`（改名为 `default.conf.bak`）避免与自定义配置冲突
   - 自动创建证书目录：`/etc/nginx/ssl/`
   - 对比本地版本与 Nginx 官网最新版本
   - 有新版本时先备份 `/etc/nginx/`，再执行升级
   - 升级后自动校验并平滑重载

2. **配置管理**
   - 二级菜单包含：`添加配置` / `外部反代` / `配置列表`
   - 添加配置：输入域名或本机IPv4、监听端口、后端端口，支持端口复用确认
   - 外部反代：输入域名或本机IPv4、监听端口、外部 `http/https` 上游 URL
   - 外部反代支持模式选择：
     - `标准模式`
     - `Stream 模式`
     - `Emby 分离 HTTP 推流`
     - `Emby 分离 HTTPS 推流`
     - `LilyEmby 方案三（支持 sub_filter 响应体替换）`
   - Emby/Lily 模式支持配置主站上游、推流节点 URL、源站公开 URL、Referer URL
   - 同端口多域名场景自动适配：若目标端口已用于 HTTPS，会自动处理为可通过 `nginx -t` 的流程
   - 自动生成标准 Proxy Header，配置写入 `/etc/nginx/conf.d/域名-监听端口.conf`
   - 配置列表中的“修改”支持外部反代配置切换方案，并保留证书/HTTPS 联动逻辑
   - 若修改配置时更换域名且发现没有证书，可直接在流程中申请证书并重新启用 HTTPS
   - 添加完成后自动检测证书：
     - 若已有证书：仅需确认是否启用 HTTPS
     - 若无证书：可一键“自动申请证书 + 自动启用 HTTPS（80→443）”
   - 配置列表：统一管理上述两类配置，按状态浏览并进入三级菜单执行 启用 / 停用 / 修改 / 编辑 / 删除

3. **证书管理**
   - 设置邮箱（持久化到脚本目录 `.email.conf`）
   - 自动安装 acme.sh 并申请证书（HTTP 验证）
   - 申请前自动执行 HTTP-01 自检（DNS/80监听/challenge 路径/域名回源），失败时给出更明确提示
   - 证书列表：按编号展示已有证书，并显示续期任务状态
   - 证书操作：支持按编号执行 重新申请 / 启停续期 / 删除证书
   - 启用证书时先从配置列表选择目标配置
   - 若配置已启用 HTTPS，再次选择该配置可按确认执行“停用 HTTPS”
   - 自动检查是否已有证书：有证书直接启用；无证书先申请再启用
   - 一键启用 HTTPS（自动继承原监听端口；80 自动跳转到对应 HTTPS 端口）

4. **实时信息**
   - 二级菜单包含：`实时信息` / `流量统计`
   - 实时信息：展示连接状态、请求统计、QPS、系统资源、Nginx 信息、网络流量
   - 流量统计：展示系统总流量与当前启用配置的流量估算
   - 若存在 `/var/log/nginx/access.host.log`，会优先按 Host 专用日志做更精确统计
   - 若不存在 Host 专用日志，则回退为基于最近 5000 条 `access.log` 的估算
   - 每 5 秒自动刷新，按回车返回上一级

5. **健康检查**
   - 作为独立菜单提供，不与配置管理混在一起
   - 支持 `检查所有站点` / `检查单个站点`
   - 检查内容包括：入口 URL、HTTP 状态码、DNS 解析结果、命中 IP
   - HTTPS 站点会额外显示证书剩余天数（可获取时）
   - 外部反代会额外显示主上游与推流上游，便于排查

6. **卸载**
   - 选项1：卸载脚本（彻底卸载本脚本并清理）
   - 选项2：卸载 Nginx（彻底卸载并清空 Nginx 及配置）
   - 选项3：卸载 Acme（彻底卸载并清空 Acme 配置/邮箱信息）
   - 选项4：全部卸载（脚本 + Nginx + Acme 一并清理）
   - 高风险卸载操作会显示删除摘要并要求二次确认

## 已知限制

- 证书签发当前只覆盖 `HTTP-01` 场景，不支持 DNS API 自动签发通配符证书。
- 若服务器前面有 CDN、四层转发、NAT 回环限制，HTTP-01 自检可能出现“软失败但实际可签发”或“本机通过但公网不通”的差异，需要结合实际网络环境判断。
- 流量统计默认是轻量实现。若未配置 `/var/log/nginx/access.host.log`，统计结果属于估算值，不适合作为精准计费依据。
- 当前没有完整的端到端自动化测试，仓库内提供的是基础语法检查与 ShellCheck CI。

## 建议的 Host 专用日志格式

如果你希望“流量统计”更准确，可在 Nginx 主配置里增加类似：

```nginx
log_format nginxx_host '$host $body_bytes_sent $remote_addr [$time_local] '
                      '"$request" $status $http_referer "$http_user_agent"';
access_log /var/log/nginx/access.host.log nginxx_host;
```

这样脚本会优先读取 `access.host.log`，按域名做更准确的请求数和下行统计。

## 开发校验

本仓库已包含 GitHub Actions 基础 CI：

- `bash -n nx.sh`
- `bash -n install.sh`
- `shellcheck -x nx.sh install.sh`

本地也可以直接运行：

```bash
bash -n nx.sh
bash -n install.sh
shellcheck -x nx.sh install.sh
```

## 交互规范

- 主菜单使用数字编号
- `0` 表示退出或返回上一级
- 颜色反馈：
  - 绿色：成功
  - 黄色：警告
  - 红色：错误
