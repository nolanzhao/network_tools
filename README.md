#### 仅供学习研究, 请勿用于非法用途


## server

ubuntu 24.04 lts, root

#### 1. vless + reality
最稳定, TCP

无需个人域名
```
./install_vless_reality.sh
```

#### 1.1 vless + reality 多端口版

使用自有域名作为 SNI，自动配置 Nginx TLS 回落站点并监听 10 个独立 TCP 端口。

```bash
./install_vless_reality_multiport.sh \
  --domain proxy.example.com \
  --email admin@example.com
```

安装时可选择回落网页风格：直接回车使用默认的 `pixel`，输入 `2` 使用 `island`。
也可以在命令中直接指定：

```bash
# 默认明亮像素海岛
./install_vless_reality_multiport.sh --domain proxy.example.com --email admin@example.com --page-style pixel

# 静谧像素海岛
./install_vless_reality_multiport.sh --domain proxy.example.com --email admin@example.com --page-style island
```

#### 2. tuic
速度快, QUIC 协议, UDP

安装过程需填写个人域名和邮箱

```
./install-tuic-server.sh
```

#### 3. hysteria2 (推荐)
速度最快, QUIC 协议, UDP

安装后需修改配置文件, 填写个人域名和邮箱

https://v2.hysteria.network/zh/docs/getting-started/Installation/


## client
windows, Mac, Linux: https://v2rayn.2dust.link/

ios: Shadowrocket

android: https://v2rayng.2dust.link/

