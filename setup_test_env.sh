#!/bin/bash

echo "=== 设置简单的测试环境 ==="

# 1. 启动一个简单的HTTP服务模拟内部服务
echo "启动模拟内部服务..."
python3 -c "
import http.server
import socketserver
import threading

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.end_headers()
        response = '{\"service\": \"mock-internal-api\", \"path\": \"' + self.path + '\", \"status\": \"ok\"}'
        self.wfile.write(response.encode())

# 模拟三个内部服务
ports = [8001, 8002, 8003]
for port in ports:
    server = socketserver.TCPServer(('', port), Handler)
    thread = threading.Thread(target=server.serve_forever)
    thread.daemon = True
    thread.start()
    print(f'Mock service started on port {port}')

print('所有模拟服务已启动，按 Ctrl+C 停止...')
try:
    while True:
        pass
except KeyboardInterrupt:
    print('停止所有服务')
" &

MOCK_PID=$!
echo "模拟服务 PID: $MOCK_PID"

# 2. 确保本机SSH服务开启
echo "检查SSH服务状态..."
if ! sudo systemsetup -getremotelogin | grep -q "On"; then
    echo "启用SSH服务..."
    sudo systemsetup -setremotelogin on
    sleep 2
fi

# 3. 生成测试用的SSH密钥（如果不存在）
if [ ! -f ~/.ssh/id_test ]; then
    echo "生成测试SSH密钥..."
    ssh-keygen -t rsa -b 2048 -f ~/.ssh/id_test -N "" -C "test@local"
    cat ~/.ssh/id_test.pub >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
fi

echo ""
echo "=== 测试环境准备完成 ==="
echo ""
echo "现在你可以测试这些SSH隧道命令："
echo ""
echo "# 基本连接测试："
echo "ssh -i ~/.ssh/id_test localhost 'echo 连接成功'"
echo ""
echo "# 端口转发测试（模拟你的实际需求）："
echo "ssh -i ~/.ssh/id_test -L 9280:127.0.0.1:8001 -L 40443:127.0.0.1:8002 -L 40453:127.0.0.1:8003 localhost"
echo ""
echo "# 测试转发是否工作："
echo "curl http://localhost:9280/"
echo "curl http://localhost:40443/"
echo "curl http://localhost:40453/"
echo ""
echo "要停止测试环境，运行: kill $MOCK_PID"
echo ""