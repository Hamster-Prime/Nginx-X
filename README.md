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
- 安装完成后自动启动 `nx`

## 当前功能

1. **安装升级Nginx**
   - 自动检查是否已安装 Nginx
   - 未安装时自动安装依赖：`curl` `wget` `socat` `cron`
   - 自动安装 Nginx 官方 stable 版本
   - 自动创建证书目录：`/etc/nginx/ssl/`
   - 对比本地版本与 Nginx 官网最新版本
   - 有新版本时先备份 `/etc/nginx/`，再执行升级
   - 升级后自动校验并平滑重载

2. **配置管理**
   - 二级菜单包含：`添加配置` / `配置列表`
   - 添加配置：输入域名、监听端口、后端端口，支持端口复用确认
   - 自动生成标准 Proxy Header，配置写入 `/etc/nginx/conf.d/域名.conf`
   - 可在添加流程中一键“自动申请证书 + 自动启用 HTTPS（80→443）”
   - 配置列表：按状态浏览并进入三级菜单执行 启用 / 停用 / 修改 / 编辑 / 删除

3. **证书管理**
   - 设置邮箱（持久化到脚本目录 `.email.conf`）
   - 自动安装 acme.sh 并申请证书（HTTP 验证）
   - 证书列表与续期任务检查
   - 一键启用 HTTPS（含 80→443 强制跳转）

4. **实时信息**
   - 大屏样式展示连接状态、请求统计、QPS、系统资源、Nginx 信息、网络流量
   - 每 5 秒自动刷新
   - 按回车直接返回主菜单

5. **卸载**
   - 选项1：卸载脚本（彻底卸载本脚本并清理）
   - 选项2：卸载 Nginx（彻底卸载并清空 Nginx 及配置）
   - 选项3：卸载 Acme（彻底卸载并清空 Acme 配置/邮箱信息）
   - 选项4：全部卸载（脚本 + Nginx + Acme 一并清理）

## 交互规范

- 主菜单使用数字编号
- `0` 表示退出或返回上一级
- 颜色反馈：
  - 绿色：成功
  - 黄色：警告
  - 红色：错误
