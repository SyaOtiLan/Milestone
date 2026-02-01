# Milestone

## 📖 项目简介

本项目使用 Shelter 容器技术部署已启用 **透明数据加密（TDE）** 的 MySQL 8.0.44 数据库。通过此方案，您可以获得一个数据在存储层自动加密的安全数据库环境，无需修改应用代码。

## 🚀 快速开始

### 1. 安装编译依赖
```bash
sudo apt install -y pkg-config libssl-dev asciidoctor
```

### 2. 编译 Shelter 工具
```bash
make tools
make
```

### 3. 构建 MySQL 容器镜像
```bash
sudo ./shelter build -t mysql-rootfs -r <path/to/your/MySQL.tar> -p /tmp
```

### 4. 运行 MySQL 容器
```bash
sudo ./shelter run -t mysql-rootfs -c "" -i 127.0.0.1 -m 4G
```

### 5. 连接数据库
```bash
mysql -h 192.168.50.10 -u admin -p123456
```

## 🔐 安全特性

- ✅ **透明数据加密**：数据在存储层自动加密
- ✅ **密钥环管理**：加密密钥安全存储
- ✅ **Redo/Undo日志加密**：防止日志泄露敏感信息
- ✅ **默认表加密**：新表自动启用加密

## 📁 目录结构

```
├── shelter                 # Shelter 容器工具
├── rootfs.tar              # MySQL 根文件系统
└── README.md              # 本文档
```

## ⚙️ 配置说明

### MySQL 连接信息
- **主机**: 192.168.50.10
- **端口**: 3306
- **用户**: admin
- **密码**: 123456

