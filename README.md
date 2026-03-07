# Tunnel-Pro 🚀

**极简、轻量、原生的 Linux 网络隧道一键部署工具。请自行搭配CF优选域名/IP使用**

Tunnel-Pro 旨在通过 Cloudflare Tunnel 与 Nginx 反代技术，为 VPS 提供高性能、高隐蔽性的 VLESS 接入。无需 Docker，直接运行于原生 Linux 环境。



### ✨ 核心功能
* **原生引擎**：原生集成 **Sin-box核心** 
* **随机隐蔽**：部署时自动生成随机监听端口与随机 WebSocket 路径，防探测。
* **智能自愈**：全流程 Systemd 守护，自动重启机制，部署后即实现“无人值守”。
* **自动加速**：检测并自动开启 TCP BBR 加速。
* **一键维护**：集成日志查看与全流程卸载功能。
* **系统适配**：智能检测 Debian/Ubuntu (APT) 不支持CentOS。

---

### 🛠️ 快速部署

在你的 VPS (Root 权限) 上执行以下命令：

```
bash <(curl -Ls https://raw.githubusercontent.com/caojiaxia/Tunnel-Pro/main/install.sh)
```


### 🔑 如何获取 Cloudflare Tunnel Token

-1. 登录 [Cloudflare Dashboard](https://dash.cloudflare.com/login)。

-2. 进入 Zero Trust -> Networks -> Tunnels。

-3. 点击 Create a tunnel，选择 cloudflared。

-4. 获得 Token 字符串，填入脚本提示处。

-5. sin-box的隧道端口`（格式 URL=127.0.0.1:随机端口)`必须与nginx一致 （前端是监听端口可随意输入,后端是nginx转发端口必须与隧道一致）

**详细步骤：**

<img width="1510" alt="image" src="https://github.com/fscarmen/sba/assets/62703343/bb2d9c43-3585-4abd-a35b-9cfd7404c87c">

<img width="1638" alt="image" src="https://github.com/fscarmen/sing-box/assets/62703343/a4868388-d6ab-4dc7-929c-88bc775ca851">
