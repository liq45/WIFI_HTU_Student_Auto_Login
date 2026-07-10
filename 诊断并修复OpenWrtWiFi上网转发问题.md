# 诊断并修复 OpenWrt WiFi 上网转发问题

> **适用场景**：OpenWrt 路由器使用 WiFi Client (STA) 模式连接上级校园网/热点，并通过 AP 模式转发给局域网设备。
>
> **常见故障表现**：
> - AP 客户端能连接 WiFi 但无法上网
> - `ifstatus wwan` 报 `NO_DEVICE`
> - 上级 WiFi 已关联但 DHCP 没拿到 IP
> - 上级 WiFi 已获取 IP 但无法访问外网（Portal 认证问题）
> - 自动认证脚本 `loader.sh` 运行报 wget 参数错误

---

## 📋 快速诊断流程

### 1️⃣ 无线网卡状态

```bash
iwinfo
```

检查 `phy0-ap0`（AP 模式）和 `phy1-sta0`（STA/Client 模式）是否都已关联，信号强度如何。

### 2️⃣ STA 接口 IP 地址

```bash
ip addr show phy1-sta0
```

| 结果 | 含义 |
|---|---|
| `inet 10.104.x.x/17` | ✅ DHCP 成功，已获 IP |
| 只有 `inet6 fe80::...` | ❌ 无 IPv4，需手动 DHCP 续约：`udhcpc -i phy1-sta0 -n -q -t 5` |

### 3️⃣ 网络连通性

```bash
ping -c 3 -W 2 10.104.128.1        # 上级网关
ping -c 3 -W 2 114.114.114.114     # 外网
nslookup baidu.com                  # DNS
```

| 现象 | 结论 |
|---|---|
| ping 网关通，外网/DNS 不通 | Portal 认证问题，需运行 `loader.sh` |
| 全部不通 | 配置或链路问题 |

### 4️⃣ wwan 接口状态

```bash
ifstatus wwan
```

- `"up": true` ✅ 正常
- `"code": "NO_DEVICE"` ❌ 缺少 device 绑定

### 5️⃣ 核心配置检查

#### wireless（`/etc/config/wireless`）

| 接口 | network | 正确值 |
|---|---|---|
| AP (default_radio0) | `lan` | ✅ 桥接到 br-lan |
| STA (wifinet2) | `wwan` | ✅ 外网接口 |

**修复命令**：
```bash
uci set wireless.default_radio0.network='lan'
uci commit wireless
```

#### network（`/etc/config/network`）

```bash
uci set network.wwan.device='phy1-sta0'
uci commit network
```

#### 防火墙（`/etc/config/firewall`）

确保 `wwan` 在 `wan` zone 中（含 masquerade/NAT），且有 `lan → wan` 转发规则。验证命令：

```bash
nft list ruleset 2>/dev/null | grep -A5 'srcnat_wan\|accept_to_wan'
```

正常应看到：
```
chain srcnat_wan {
    meta nfproto ipv4 masquerade
}
chain accept_to_wan {
    oifname { "wan", "phy1-sta0" } accept
}
```

### 6️⃣ 路由表

```bash
ip route show
```

应有两条路由：
```
default via 10.104.128.1 dev phy1-sta0     # 默认路由走 STA
192.168.1.0/24 dev br-lan                  # LAN 网段
```

---

## 🔧 修复步骤

### 修复配置（一行搞定）

```bash
uci set wireless.default_radio0.network='lan'
uci set network.wwan.device='phy1-sta0'
uci commit
```

### 重启网络

```bash
/etc/init.d/network restart
```

等待 10-15 秒重新连上 WiFi 后，检查路由恢复：
```bash
ip route show | grep default
```

如果默认路由未恢复，手动拉起 wwan：
```bash
ifup wwan
```

### 处理 Portal 认证

如果 ping 网关通但外网不通，说明需要 Portal 认证：

```bash
# 上传并运行自动认证脚本
cd /root
chmod +x loader.sh
./loader.sh
# 查看认证结果
cat captive.log
```

认证成功后配置定时任务保持在线：
```bash
crontab -e
*/5 * * * * /root/loader.sh >> /tmp/auth.log 2>&1
```

---

## 🚨 常见问题与修复

### loader.sh 报 wget 参数错误

OpenWrt 的 BusyBox wget 功能受限，不支持以下参数：
- ❌ `--bind-address=IP` → 直接去掉
- ❌ `-S`（显示响应头）→ 去掉
- ❌ `--timeout=秒` → 改为 `-T 秒`
- ❌ `Accept-Encoding: gzip, deflate` header → 去掉（会导致返回空响应）

**loader.sh 已经包含了这些兼容性修复**，如需手动修改可搜索上述关键字。

### 网络重启后默认路由丢失

```bash
ifup wwan
```

### nftables 规则不对

OpenWrt 25.x 使用 nftables，检查：
```bash
nft list ruleset 2>/dev/null | grep -E 'masquerade|accept_to_wan|forward_lan'
```

---

## ✅ 修复验证清单

- [ ] `ifstatus wwan` → `"up": true`
- [ ] `ip addr show phy1-sta0` → 有 IPv4 地址
- [ ] `ip route show` → 有 `default via ... dev phy1-sta0`
- [ ] `ping 10.104.128.1` → 通
- [ ] `ping 114.114.114.114` → 通（或先运行 `loader.sh` 认证）
- [ ] `nslookup baidu.com` → 解析正常
- [ ] AP 客户端连接 WiFi 后能上网

---

## 🏗️ 数据流向

```
[HTU_Student 校园网]
        ↑ 5G STA
  phy1-sta0 (10.104.x.x)
        ↓
  [NAT / MASQUERADE]
        ↓
  br-lan (192.168.1.1/24)
     ↙        ↘
phy0-ap0     LAN 网口
  ↑ WiFi      ↑ 有线
[手机/笔记本]  [电脑]
```

---

## 🆘 常用命令速查

```bash
# 无线
iwinfo                          # 网卡状态
iwinfo phy1 scan                # 扫描 WiFi

# 网络
ifstatus wwan | grep '"up"'     # wwan 状态
ip addr show phy1-sta0          # STA IP
ip route show                   # 路由表
brctl show                      # 网桥

# 连通性
ping -c 2 -W 2 10.104.128.1    # 测网关
ping -c 2 -W 2 114.114.114.114 # 测外网

# 认证
/root/loader.sh                 # 手动认证
cat /root/captive.log           # 认证日志

# 防火墙
nft list ruleset 2>/dev/null | grep -E 'masquerade|accept_to_wan'
```
