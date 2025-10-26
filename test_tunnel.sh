#!/bin/bash

echo "=== SSH隧道测试脚本 ==="

# 检查模拟服务是否运行
check_services() {
    echo "检查模拟服务状态..."
    for port in 8001 8002 8003; do
        if curl -s http://localhost:$port/ >/dev/null; then
            echo "✓ 服务在端口 $port 运行正常"
        else
            echo "✗ 服务在端口 $port 未运行"
        fi
    done
    echo ""
}

# 测试SSH隧道
test_tunnel() {
    echo "启动SSH隧道..."
    
    # 这就是你要在menubar工具中执行的命令
    ssh -i ~/.ssh/id_test \
        -L 9280:127.0.0.1:8001 \
        -L 40443:127.0.0.1:8002 \
        -L 40453:127.0.0.1:8003 \
        -N -f localhost
    
    TUNNEL_PID=$!
    echo "隧道已启动，PID: $TUNNEL_PID"
    
    # 等待隧道建立
    sleep 2
    
    echo "测试隧道连接..."
    echo "测试 localhost:9280 -> 内部服务8001:"
    curl -s http://localhost:9280/ | head -1
    
    echo "测试 localhost:40443 -> 内部服务8002:"
    curl -s http://localhost:40443/ | head -1
    
    echo "测试 localhost:40453 -> 内部服务8003:"
    curl -s http://localhost:40453/ | head -1
    
    echo ""
    echo "隧道测试完成！"
    echo "要停止隧道，运行: pkill -f 'ssh.*-L.*localhost'"
}

# 主流程
check_services
test_tunnel