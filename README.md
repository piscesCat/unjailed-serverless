# Unjailed CGNAT for Serverless
Một Docker image siêu nhẹ được thiết kế tối ưu cho các môi trường **serverless** và **container tạm thời (ephemeral containers)**. Giải pháp này cung cấp một lớp mạng truy cập ổn định xuyên qua CGNAT, cho phép bạn dễ dàng kết nối và quản lý thông qua:
 * **SSH** (Tích hợp sẵn)
 * **Tailscale** (Định tuyến qua sing-box)
 * **Cloudflare Tunnel**
Image này là lựa chọn hoàn hảo để làm node mạng trung gian, thiết bị truy cập từ xa, hoặc thiết lập một lớp CGNAT linh hoạt cho các tác vụ cần duy trì kết nối liên tục nhưng không có IP Public cố định.
## ✨ Tính năng nổi bật
 * **Tích hợp SSH Server:** Truy cập cấu hình nhanh chóng với tài khoản root (đăng nhập bằng mật khẩu).
 * **Hỗ trợ Tailscale:** Dễ dàng kết nối vào mạng riêng ảo thông qua biến TS_AUTHKEY.
 * **Hỗ trợ Cloudflare Tunnel:** Expose dịch vụ an toàn ra internet thông qua biến CF_TUNNEL_TOKEN.
 * **Linh hoạt:** Có thể chạy độc lập với Tailscale, Cloudflare Tunnel, hoặc **chạy song song cả hai** cùng lúc.
 * **Health Check:** Tích hợp sẵn HTTP endpoint để monitor trạng thái của container.
## ⚠️ Yêu cầu hệ thống
Để container có thể khởi chạy, bạn **bắt buộc phải cung cấp ít nhất một trong hai** biến môi trường sau:
 1. TS_AUTHKEY
 2. CF_TUNNEL_TOKEN
> **Lưu ý:** Nếu cả hai biến này đều bị bỏ trống, quá trình khởi động container sẽ thất bại và tự động thoát.
> 
## ⚙️ Biến môi trường (Environment Variables)
| Biến | Giá trị mặc định | Mô tả |
|---|---|---|
| PORT | 8000 | Port HTTP dùng để chạy health check. |
| SSH_PORT | 22 | Port SSH nội bộ của container. |
| ROOT_PASSWORD | root | Mật khẩu đăng nhập SSH cho tài khoản root. |
| TS_AUTHKEY | *Trống* | Authentication Key của Tailscale. |
| TS_HOSTNAME | my-node | Tên thiết bị (hostname) hiển thị trên Tailscale admin console. |
| TS_STATE_DIR | /var/lib/tailscale | Thư mục lưu trữ trạng thái kết nối của Tailscale. |
| CF_TUNNEL_TOKEN | *Trống* | Token xác thực của Cloudflare Tunnel. |
## 🚀 Hướng dẫn sử dụng
### 1. Build Image
```bash
docker build -t unjailed-cgnat .

```
### 2. Khởi chạy Container
Bạn có thể linh hoạt chọn phương thức mạng tùy theo nhu cầu:
**Chỉ dùng Tailscale:**
```bash
docker run -d \
  --name unjailed-cgnat \
  -p 8000:8000 \
  -p 22:22 \
  -e ROOT_PASSWORD=YourStrongPassword \
  -e TS_AUTHKEY=tskey-xxxx \
  -e TS_HOSTNAME=my-tailscale-node \
  unjailed-cgnat

```
**Chỉ dùng Cloudflare Tunnel:**
```bash
docker run -d \
  --name unjailed-cgnat \
  -p 8000:8000 \
  -p 22:22 \
  -e ROOT_PASSWORD=YourStrongPassword \
  -e CF_TUNNEL_TOKEN=xxxxxxx \
  unjailed-cgnat

```
**Chạy đồng thời Tailscale & Cloudflare Tunnel:**
```bash
docker run -d \
  --name unjailed-cgnat \
  -p 8000:8000 \
  -p 22:22 \
  -e ROOT_PASSWORD=YourStrongPassword \
  -e TS_AUTHKEY=tskey-xxxx \
  -e TS_HOSTNAME=my-hybrid-node \
  -e CF_TUNNEL_TOKEN=xxxxxxx \
  unjailed-cgnat

```
## 💻 Truy cập và Kiểm tra
### Kết nối SSH
Bạn có thể SSH trực tiếp vào container:
```bash
ssh root@<SERVER_IP> -p 22

```
*Mẹo: Nếu container đã tham gia vào mạng Tailscale, bạn có thể SSH trực tiếp thông qua IP Tailscale của node đó mà không cần expose port 22 ra internet.*
### HTTP Health Check
Container cung cấp một web server siêu nhẹ để kiểm tra trạng thái sống (uptime):
 * **Endpoint /generate_204**: Trả về HTTP Status 204 No Content (Phù hợp cho các hệ thống load balancer ping kiểm tra).
 * **Các đường dẫn khác (Ví dụ: /)**: Trả về nội dung text Server OK!.
**Ví dụ test:**
```bash
curl -i http://127.0.0.1:8000/generate_204
curl http://127.0.0.1:8000/any-path

```
## 💡 Ứng dụng thực tế (Use Cases)
 * Container trên các nền tảng serverless cần duy trì kết nối mạng ra bên ngoài.
 * Tạo node mạng trung gian (jump host) an toàn qua Tailscale.
 * Thiết lập một đường hầm mạng (tunnel) nhanh chóng qua hạ tầng Cloudflare.
 * Tạo môi trường SSH cực nhẹ, tốc độ khởi động nhanh.
 * Xây dựng hệ thống cần lớp mạng CGNAT linh hoạt, không bị phụ thuộc vào IP Public cố định của nhà mạng.
## 🔒 Lưu ý bảo mật
 * **Bắt buộc:** Luôn thay đổi biến ROOT_PASSWORD thành một mật khẩu mạnh trước khi deploy thực tế.
 * **Bảo mật Token:** Tuyệt đối không hardcode hoặc commit các biến TS_AUTHKEY và CF_TUNNEL_TOKEN lên các repository công khai (public repo).
 * **Quản lý vòng đời:** Với các container dùng một lần (ngắn hạn), khuyến nghị tạo các key/token có vòng đời sử dụng ngắn (ephemeral keys).
 * **Nguyên tắc đặc quyền tối thiểu:** Chỉ bind (mở) các port ra host network khi thực sự cần thiết. Khuyến khích truy cập SSH hoàn toàn qua Tailscale hoặc Cloudflare Access.
## 🐳 Docker Compose
Dưới đây là file docker-compose.yml mẫu giúp bạn triển khai nhanh chóng:
```yaml
services:
  unjailed-cgnat:
    build: .
    container_name: unjailed-cgnat
    ports:
      - "22:22"
      - "8000:8000"
    environment:
      ROOT_PASSWORD: YourStrongPassword
      TS_AUTHKEY: tskey-xxxx
      CF_TUNNEL_TOKEN: xxxxxxxx
    restart: unless-stopped

```
## 📄 License
Dự án được phân phối dưới giấy phép MIT License.
