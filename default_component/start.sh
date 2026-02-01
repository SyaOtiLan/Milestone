#!/bin/bash
set -euo pipefail

# 参数检查
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <ip_address> <memory_size>"
    exit 1
fi
ip_address=$1
memory_size=$2

# 清理文件
rm -f measurement.bin secret_* sev_* qemu.log 2>/dev/null || true

# 杀死可能存在的进程
pidof qemu-system-x86_64 > /dev/null && kill -9 $(pidof qemu-system-x86_64) || true
pidof b_relay > /dev/null && kill -9 $(pidof b_relay) || true

# --- 导出 SEV PDH 并验证证书链 ---
sevctl export /tmp/sev.pdh
check_cert_chain "$ip_address"

# 检查文件是否存在，然后发送 GODH 和 session
for f in sev_godh.b64 sev_session.b64; do
    [ -f "$f" ] || { echo "Error: File $f not exist!"; exit 1; }
done

# QEMU 磁盘检查
RAW=/mnt/fast/guest.raw
[ -f "$RAW" ] || { echo "ERR: $RAW not found (bind-mount 宿主机 /mnt/fast 到容器里)"; exit 1; }

# 设置 QEMU 内存锁定限制
ulimit -l unlimited || true

# --- 启动 QEMU，将输出重定向到文件 ---

# 创建日志目录
mkdir -p /var/log/qemu

echo "启动 QEMU SEV 虚拟机..."
echo "内存: ${memory_size}"
echo "磁盘: ${RAW}"
echo "日志: /var/log/qemu/qemu.log"

qemu-system-x86_64 \
  -enable-kvm \
  -cpu EPYC \
  -smp 4,sockets=1,cores=2,threads=2 \
  -m "$memory_size" \
  -object memory-backend-memfd,id=mem,size="$memory_size",share=on,prealloc=on \
  -numa node,memdev=mem \
  -overcommit mem-lock=on \
  -bios /usr/local/bin/OVMF.fd \
  -kernel /usr/local/bin/bzImage \
  -initrd /usr/local/bin/initrd.img \
  -append "root=/dev/ram rdinit=/init console=ttyS0,115200 clocksource=kvm-clock mitigations=off" \
  -nographic \
  -object sev-guest,id=sev0,cbitpos=47,reduced-phys-bits=1,policy=0x1,dh-cert-file=sev_godh.b64,session-file=sev_session.b64 \
  -machine confidential-guest-support=sev0 \
  -object iothread,id=ioth0 \
  -blockdev driver=file,filename=${RAW},aio=native,cache.direct=on,cache.no-flush=off,node-name=img0 \
  -device virtio-blk-pci,drive=img0,iothread=ioth0,queue-size=1024,num-queues=4 \
  -device vhost-vsock-pci,id=vhost-vsock-pci0,guest-cid=3 \
  -netdev bridge,id=net0,br=br0 \
  -device virtio-net-pci,netdev=net0 \
  -qmp unix:/tmp/qmp-sock,server,nowait \
  -serial telnet:127.0.0.1:5555,server,nowait \
  -monitor telnet:127.0.0.1:4444,server,nowait \
  -vnc :1 \
  -S \
  > /var/log/qemu/qemu.log 2>&1 &

QEMU_PID=$!
echo "QEMU 已启动，PID: $QEMU_PID"

# 等待QEMU启动
sleep 3

# 检查QEMU是否在运行
if ! kill -0 $QEMU_PID 2>/dev/null; then
    echo "错误: QEMU 启动失败"
    echo "查看日志: /var/log/qemu/qemu.log"
    tail -50 /var/log/qemu/qemu.log
    exit 1
fi

echo "QEMU 启动成功，等待 QMP 连接..."

# --- QMP 查询 measurement ---
for attempt in 1 2 3; do
    {
        echo '{"execute": "qmp_capabilities"}'
        sleep 0.5
        echo '{"execute": "query-sev-launch-measure"}'
    } | timeout 10 socat - UNIX-CONNECT:/tmp/qmp-sock > measurement.bin 2>/dev/null

    if grep -q '"data"' measurement.bin; then
        echo "成功获取 measurement"
        break
    else
        echo "尝试 $attempt: 获取 measurement 失败，等待重试..."
        sleep $((attempt * 5))
    fi
done

if [ ! -s measurement.bin ] || ! grep -q '"data"' measurement.bin; then
    echo "错误: 无法获取 SEV measurement"
    exit 1
fi

# --- 发送 measurement 给远程服务获取 secret_header.b64 / secret_payload.b64 ---
remote_attestation "$ip_address"

# 等待 secret_* 文件
for i in {1..10}; do
  [ -f secret_header.b64 ] && [ -f secret_payload.b64 ] && break
  sleep 1
done

if [ ! -f secret_header.b64 ] || [ ! -f secret_payload.b64 ]; then
    echo "错误: secret_* 文件在 attestation 后不存在!"
    exit 1
fi

echo "远程认证成功，准备注入 secret..."

# --- 注入 secret 并继续启动 ---
packet_header=$(<secret_header.b64)
secret=$(<secret_payload.b64)

command="{ \"execute\": \"sev-inject-launch-secret\", \"arguments\": { \"packet-header\": \"$packet_header\", \"secret\": \"$secret\" } }"

{
    echo '{ "execute": "qmp_capabilities" }'
    sleep 0.5
    echo "$command"
    sleep 0.5
    echo '{ "execute": "cont" }'
} | socat - UNIX-CONNECT:/tmp/qmp-sock > /dev/null 2>&1

echo "Secret 已注入，虚拟机继续启动..."
echo ""
echo "访问方式:"
echo "  VNC 图形界面: vncviewer localhost:1"
echo "  串口控制台: telnet localhost 5555"
echo "  QMP 监控: socat - UNIX-CONNECT:/tmp/qmp-sock"
echo "  Monitor: telnet localhost 4444"
echo ""
echo "查看日志: tail -f /var/log/qemu/qemu.log"
echo ""
echo "按 Ctrl+C 停止虚拟机"

# 等待用户中断
wait $QEMU_PID
