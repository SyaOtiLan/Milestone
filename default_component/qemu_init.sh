#!/bin/bash

# MySQL启动脚本
set -e

# ========== 新增：磁盘检测、格式化和挂载 ==========
echo "检查持久化磁盘..."

# 检查/dev/vda是否存在
if [ ! -b "/dev/vda" ]; then
    echo "警告: 持久化磁盘 /dev/vda 不存在"
else
    # 检查并挂载磁盘
    if blkid /dev/vda | grep -q "TYPE="; then
        echo "磁盘已格式化，直接挂载..."
        mount /dev/vda /var/lib/mysql
    else
        echo "磁盘未格式化，首次使用，格式化..."
        busybox mkfs.ext2 /dev/vda
        mount /dev/vda /var/lib/mysql
    fi
fi

echo ""

# ========== 修改的MySQL启动逻辑 ==========
# 1. 如果目录不为空但没有MySQL系统文件，先清空目录
if [ "$(ls -A /var/lib/mysql 2>/dev/null)" ] && [ ! -f "/var/lib/mysql/ibdata1" ]; then
    echo "目录中有非MySQL文件，清理..."
    rm -rf /var/lib/mysql/*
fi

# 2. 创建密钥环目录（必须在MySQL启动前创建）
echo "准备密钥环目录..."
mkdir -p /var/lib/mysql/mysql-keyring
chown mysql:mysql /var/lib/mysql/mysql-keyring
chmod 750 /var/lib/mysql/mysql-keyring

# 3. 检查是否已初始化 - 更严格的检查
if [ ! -f "/var/lib/mysql/ibdata1" ]; then
    echo "MySQL数据目录未初始化，正在初始化..."
    /usr/sbin/mysqld --initialize-insecure --user=mysql --datadir=/var/lib/mysql --console 2>&1
    echo "MySQL初始化完成"
else
    echo "MySQL数据目录已存在，跳过初始化..."
fi

# 4. 启动MySQL服务 - 添加keyring插件参数
echo "启动MySQL服务（加载keyring插件）..."
/usr/sbin/mysqld --user=mysql \
    --datadir=/var/lib/mysql \
    --socket=/var/run/mysqld/mysqld.sock \
    --port=3306 \
    --early-plugin-load="keyring_file=keyring_file.so" \
    --keyring-file-data="/var/lib/mysql/mysql-keyring/keyring_file" \
    --console &

# 5. 等待MySQL启动
echo "等待MySQL启动..."
# 增加等待时间和重试次数
for i in {1..15}; do
    if mysql -u root --skip-password -e "SELECT 1" 2>/dev/null; then
        echo "MySQL启动成功"
        break
    fi
    if [ $i -eq 15 ]; then
        echo "MySQL启动失败，请检查日志"
        exit 1
    fi
    echo "等待MySQL启动 ($i/15)..."
    sleep 2
done

# 6. 配置MySQL用户权限
if [ ! -f "/var/lib/mysql/.user_configured" ]; then
    echo "配置MySQL用户权限..."
    mysql -u root --skip-password <<MYSQL_EOF
CREATE USER IF NOT EXISTS 'admin'@'%' IDENTIFIED BY '123456';
GRANT ALL PRIVILEGES ON *.* TO 'admin'@'%' WITH GRANT OPTION;
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
MYSQL_EOF
    touch /var/lib/mysql/.user_configured
    echo "MySQL用户权限已配置"
else
    echo "MySQL用户权限已配置，跳过..."
fi

# 7. 配置MySQL加密功能（只有第一次启动时配置）
if [ ! -f "/var/lib/mysql/.encryption_configured" ]; then
    echo "配置MySQL加密功能..."
    
    # 等待MySQL完全启动
    sleep 3
    
    mysql -u root --skip-password <<ENCRYPT_EOF
-- 安装插件（如果还没有安装）
INSTALL PLUGIN IF NOT EXISTS keyring_file SONAME 'keyring_file.so';

-- 设置密钥环路径（确保与启动参数一致）
SET GLOBAL keyring_file_data = '/var/lib/mysql/mysql-keyring/keyring_file';

-- 启用加密功能
SET GLOBAL default_table_encryption = ON;
SET GLOBAL innodb_redo_log_encrypt = ON;
SET GLOBAL innodb_undo_log_encrypt = ON;

-- 验证加密配置
SELECT PLUGIN_NAME, PLUGIN_STATUS FROM information_schema.PLUGINS WHERE PLUGIN_NAME LIKE 'keyring%';
SHOW GLOBAL VARIABLES LIKE '%encrypt%';
ENCRYPT_EOF
    
    touch /var/lib/mysql/.encryption_configured
    echo "MySQL加密功能已配置"
else
    echo "MySQL加密功能已配置，跳过..."
fi

echo ""
echo "MySQL启动完成，可以使用以下信息连接："
echo "主机: 192.168.50.10"
echo "端口: 3306"
echo "用户: admin"
echo "密码: 123456"
echo "加密状态: 已启用"
