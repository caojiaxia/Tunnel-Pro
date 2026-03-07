# Tunnel-Pro 🚀

**极简、轻量、原生的 Linux 网络隧道一键部署工具。**

Tunnel-Pro 旨在通过 Cloudflare Tunnel 与 Nginx 反代技术，为 VPS 提供高性能、高隐蔽性的 VLESS 接入。无需 Docker，直接运行于原生 Linux 环境。



### ✨ 核心功能
* **双核引擎**：原生集成 **Xray-core** 与高性能 **Sing-box**。
* **随机隐蔽**：部署时自动生成随机监听端口与随机 WebSocket 路径，防探测。
* **智能自愈**：全流程 Systemd 守护，自动重启机制，部署后即实现“无人值守”。
* **自动加速**：检测并自动开启 TCP BBR 加速。
* **一键维护**：集成日志查看与全流程卸载功能。
* **全系统适配**：智能检测 Debian/Ubuntu (APT) 与 CentOS (YUM)。

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

-5. sin-box的隧道端口必须与nginx一致

**详细步骤：**

<img width="1409" alt="image" src="https://user-images.githubusercontent.com/92626977/218253461-c079cddd-3f4c-4278-a109-95229f1eb299.png">

<img width="1619" alt="image" src="https://user-images.githubusercontent.com/92626977/218253838-aa73b63d-1e8a-430e-b601-0b88730d03b0.png">

<img width="1155" alt="image" src="https://user-images.githubusercontent.com/92626977/218253971-60f11bbf-9de9-4082-9e46-12cd2aad79a1.png">
