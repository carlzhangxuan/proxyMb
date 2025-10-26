#!/bin/bash

# 测试环境设置脚本
# 用于验证 ProxyMb 的隧道管理功能

echo "🚀 设置测试环境..."

# 检查并终止可能存在的测试服务
echo "清理旧的测试进程..."
pkill -f "python3 -m http.server 800[1-3]" 2>/dev/null || true

# 启动三个测试服务，模拟公司内部服务
echo "启动测试服务..."
echo "  - 启动模拟 coupon-server (端口 8001)"
python3 -m http.server 8001 --directory /tmp &
COUPON_PID=$!

echo "  - 启动模拟 metadata-api (端口 8002)"
python3 -m http.server 8002 --directory /tmp &
METADATA_PID=$!

echo "  - 启动模拟 incentive-resolver (端口 8003)"
python3 -m http.server 8003 --directory /tmp &
INCENTIVE_PID=$!

# 等待服务启动
sleep 2

echo "✅ 测试服务已启动:"
echo "  - http://localhost:8001 (PID: $COUPON_PID)"
echo "  - http://localhost:8002 (PID: $METADATA_PID)"  
echo "  - http://localhost:8003 (PID: $INCENTIVE_PID)"

echo ""
echo "🔧 测试命令 (复制到 ProxyMb 中测试):"
echo "ssh -L 9280:localhost:8001 -L 40443:localhost:8002 -L 40453:localhost:8003 localhost"

echo ""
echo "🧪 验证隧道工作的命令:"
echo "curl http://localhost:9280   # 应该显示目录列表"
echo "curl http://localhost:40443  # 应该显示目录列表"
echo "curl http://localhost:40453  # 应该显示目录列表"

echo ""
echo "🛑 清理测试环境:"
echo "kill $COUPON_PID $METADATA_PID $INCENTIVE_PID"

# 保存 PID 到文件，方便后续清理
echo "$COUPON_PID $METADATA_PID $INCENTIVE_PID" > /tmp/test_services.pid

echo ""
echo "测试环境准备完成! 现在可以在 ProxyMb 中测试隧道功能了。"