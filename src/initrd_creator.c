#include "initrd_creator.h"
#include "log.h"
#include "tools.h"
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <string.h>

/*
 * 函数 initrd_create() 用于创建initrd
 * 参数:
 *   - const char *tag: 敏感程序标签
 *   - const char *file_name: 传入的文件名
 *   - int mode: 指定传入的是敏感程序（CODE）还是根文件系统（ROOTFS）
 *   - const char *work_path: 工作路径
 *   - const char *aa_path: attestation agent路径
 * 返回值:
 *   - int: 正常结束返回0
 */
int initrd_create(const char *tag, const char *file_name, int mode, const char *work_path, const char *aa_path){
    char path[1024];
    char bin_path[1024];
    char *vguest = VGUEST_DIR;
    
    // 创建构建目录结构
    snprintf(path, sizeof(path), "build/%s", tag);
    create_directory(path);

    snprintf(path, sizeof(path), "build/%s/initrd", tag);
    create_directory(path);
    
    snprintf(bin_path, sizeof(bin_path), "%s/bin", path);
    create_directory(bin_path);

    char commands[4096];

    // 构建initrd需要执行的命令
    // 复制所有必需的文件到initrd的/bin目录
    snprintf(commands, sizeof(commands), 
        "cp %s %s && "                 // 复制busybox
        "cp %s %s/ && "               // 复制docker_init
        "ln -s busybox %s/sh && "     // 创建sh的符号链接
        "cp %s %s/ && "               // 复制vguest_vsock
        "cp %s %s/ && "               // 复制用户提供的文件（敏感程序或rootfs）
        "cp -r /home/a/shelter/default_component/pgms %s/ && "  // 复制pgms目录
        "cp /home/a/shelter/default_component/qemu_init.sh %s/ && "  // 复制qemu_init.sh
        "chmod +x %s/qemu_init.sh",   // 设置qemu_init.sh为可执行
        BUSYBOX, bin_path,
        DOCKER_INIT, bin_path,
        bin_path,
        vguest, bin_path,
        file_name, bin_path,
        bin_path,
        bin_path,
        bin_path
    );  
    
    if (system(commands) == -1) {
        LOG_ERROR("Failed to exec commands: %s", commands);
    }
    
    // 如果有attestation agent，也复制它
    if(aa_path != NULL){
        snprintf(commands, sizeof(commands), "cp %s %s/", aa_path, bin_path);
        if (system(commands) == -1) {
            LOG_ERROR("Failed to copy attestation agent: %s", commands);
        }
    }
    
    // 创建init文件（initrd的初始化脚本）
    char init[512];
    snprintf(init, sizeof(init), "%s/init", path);
    FILE *file = fopen(init, "w");
    if (file == NULL) {
        LOG_ERROR("Failed to create init file: %s", init);
    }
    
    // init脚本的基础部分（所有模式都执行）
    char init_script[8192] = "#!/bin/sh\n"
                "# 初始化网络\n"
                "busybox ip addr add 192.168.50.10/24 dev eth0\n"
                "busybox ip link set eth0 up\n"
                "busybox ip route add default via 192.168.50.1\n"
                "# 创建设备节点\n"
                "busybox mknod /dev/null c 1 3\n"
                "busybox chmod 666 /dev/null\n";

    // 根据输入文件的不同来构建不同的初始进程
    switch (mode)
    {
    case CODE:
        // CODE模式：运行敏感程序
        strcat(init_script,
            "# 挂载必要的文件系统\n"
            "busybox mkdir -p /proc /sys /dev /mnt\n"
            "busybox mount -t proc none /proc\n"
            "busybox mount -t sysfs none /sys\n"
            "busybox mount -t devtmpfs none /dev\n"
            "\n"
            "# 如果有 vda 磁盘，设置 readahead 并挂载\n"
            "if [ -b /dev/vda ]; then\n"
            "  busybox blockdev --setra 4096 /dev/vda || true\n"
            "  busybox mount -t ext4 -o noatime,nodiratime,commit=30 /dev/vda /mnt || true\n"
            "fi\n"
            "\n"
            "# 启动vsock客户端并进入shell\n"
            "/bin/vguest_vsock\n"
            "exec /bin/sh\n"
        );               
        break;
        
    case ROOTFS:
        // ROOTFS模式：运行完整的根文件系统
        char *name = get_file_name(file_name);
        
        // 将大的rootfs文件分割成小块，便于处理
        snprintf(commands, sizeof(commands), 
            "split -b 300M %s/%s %s/rootfs_part_ && rm %s/%s && sed -i '2i cd %s' %s/docker_init", 
            bin_path, name, bin_path, bin_path, name, work_path, bin_path);
        
        if(system(commands) == -1){
            LOG_ERROR("Failed to exec commands: %s", commands);
        }
        
        // 构建ROOTFS模式的init脚本
        snprintf(init_script + strlen(init_script), sizeof(init_script) - strlen(init_script),
                "# 创建目录并挂载proc和sysfs\n"
                "busybox mkdir -p /proc /sys /mnt/rootfs\n"
                "busybox mount -t proc none /proc\n"
                "busybox mount -t sysfs none /sys\n"
                "\n"
                "# 合并并解压rootfs\n"
                "busybox cat /bin/rootfs_part_* > /bin/rootfs.tar\n"
                "busybox rm /bin/rootfs_part_*\n"
                "busybox tar -xpf /bin/rootfs.tar -C /mnt/rootfs\n"
                "\n"
                "# 将 busybox 复制到 chroot 后的文件系统\n"
                "# 这样在chroot后也能访问和执行busybox\n"
                "busybox cp /bin/busybox /mnt/rootfs/bin/\n"
                "busybox chmod +x /mnt/rootfs/bin/busybox\n"
                "\n"
                "# 在chroot环境中为busybox创建符号链接\n"
                "busybox chroot /mnt/rootfs /bin/busybox --install -s /bin\n"
                "\n"
                "# 将 qemu_init.sh 复制到 chroot 后的文件系统\n"
                "# 这样在chroot后也能访问和执行这个脚本\n"
                "busybox cp /bin/qemu_init.sh /mnt/rootfs/bin/\n"
                "busybox chmod +x /mnt/rootfs/bin/qemu_init.sh\n"
                "\n"
                "# 挂载dev文件系统并创建设备\n"
                "busybox mount -t tmpfs none /mnt/rootfs/dev\n"
                "busybox mdev -s\n"
                "\n"
                "# 移动必要的文件到chroot环境\n"
                "busybox mv /bin/vguest_vsock /mnt/rootfs/bin/\n"
                "busybox chmod +x /mnt/rootfs/bin/vguest_vsock\n"
                "busybox mv /bin/docker_init /mnt/rootfs/bin/\n"
                "busybox chmod +x /mnt/rootfs/bin/docker_init\n"
                "\n"
                "# 切换到新的根文件系统并启动docker_init\n"
                "busybox chroot /mnt/rootfs /bin/docker_init\n"
            );
        break;
        
    default:
        LOG_ERROR("Unknown mode: %d", mode);
    }

    // 将init脚本写入文件
    fprintf(file, "%s", init_script);
    fclose(file);

    // 将initrd打包成initrd.img
    snprintf(commands, sizeof(commands), 
        "sudo chmod +x %s && "                    // 设置init脚本可执行
        "cd build/%s/initrd && "                 // 进入initrd目录
        "find . | cpio -o -H newc | gzip > ../initrd.img",  // 打包并压缩
        init, tag);
        
    if(system(commands) == -1){
        LOG_ERROR("Failed to exec commands: %s", commands);
    }

    printf("initrd created successfully for tag: %s\n", tag);
    return 0;
}
