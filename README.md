# MicroSocks v3 - SOCKS5 proxy with bandwidth control & Cloudflare WARP

MicroSocks v3 là phiên bản nâng cấp từ v2, tích hợp sẵn **Cloudflare WARP (WireGuard)** và công cụ giới hạn băng thông **`tc` (Traffic Control)** giúp quản lý tốc độ upload/download trực tiếp trong container.

- **Ưu điểm**
  - Hỗ trợ ẩn danh IP gốc của VPS qua mạng Cloudflare WARP (WireGuard kernel-level cực nhẹ và nhanh).
  - Quản lý băng thông ở cấp độ kernel, quản lý trực tiếp qua container, tổng traffic đều được quản lý chính xác.
  - Hỗ trợ đầy đủ IPv4 và IPv6 (Dual-stack).
- **Khuyết điểm**:
  - Cần quyền root ban đầu trên host để thiết lập mạng và nạp module WireGuard.
  - Image có dung lượng khoảng 10MB (chứa thêm các gói `wireguard-tools`, `iproute2`...).

---

## 🚀 Cài đặt nhanh

Chạy script tự động:

```bash
wget -qO microsocks_v3.sh https://go.bibica.net/microsocks_v3 && bash microsocks_v3.sh
```

Script sẽ tự động cài đặt Docker, hỏi tài khoản, giới hạn băng thông, cấu hình có bật WARP hay không và khởi chạy dịch vụ.

---

## 🛠 Cài đặt thủ công

Tạo file `compose.yml`:

```yaml
services:
  taikhoan1:
    image: bibica/microsocks-v3
    container_name: taikhoan1
    restart: always
    ports:
      - "10001:1080"  # Cổng host:container
    cap_add:
      - NET_ADMIN     # Bắt buộc để thiết lập Wireguard và tc
      - SYS_MODULE    # Bắt buộc để nạp module WireGuard
    environment:
      - PORT=1080
      - AUTH_ONCE=true
      - QUIET=true
      - USERNAME=taikhoan1
      - PASSWORD=taikhoan1
      - TUNNEL_PROTOCOL=wireguard  # wireguard (bật WARP) | none (tắt WARP)
      - ENABLE_IPV6=1              # 1 (mặc định) | 0 (chỉ dùng IPv4)
      - DOWNLOAD_RATE=10Mbps       # Giới hạn download
      - UPLOAD_RATE=10Mbps         # Giới hạn upload
    volumes:
      - ./warp-data:/etc/wireguard  # Lưu trữ cấu hình đăng ký WARP
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv6.conf.default.disable_ipv6=0
      - net.ipv6.conf.all.forwarding=1
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
```

Khởi chạy container:

```bash
docker compose up -d
```

---

## 🧪 Kiểm tra hoạt động của proxy

Dùng `curl` để kiểm tra cổng proxy SOCKS5 từ bên ngoài hoặc từ chính VPS:

```bash
curl -x socks5h://taikhoan1:taikhoan1@IP_CUA_VPS:10001 https://ifconfig.me
```
*Nếu bật WARP, kết quả trả về sẽ hiển thị IP của Cloudflare.*

---

## ⚙️ Biến môi trường hỗ trợ

| Biến                   | Mặc định    | Ý nghĩa                                                  |
| ---------------------- | ----------- | -------------------------------------------------------- |
| `PORT`                 | `1080`      | Cổng lắng nghe của SOCKS5                                |
| `USERNAME`, `PASSWORD` | (trống)     | Tài khoản xác thực SOCKS5                                |
| `TUNNEL_PROTOCOL`      | `none`      | Giao thức đường truyền: `wireguard` (bật WARP) hoặc `none` (chạy trực tiếp) |
| `ENABLE_IPV6`          | `1`         | Cho phép kết nối dual-stack IPv4/IPv6 qua WARP           |
| `DOWNLOAD_RATE`        | (trống)     | Giới hạn tốc độ tải xuống (VD: `10Mbps`)                 |
| `UPLOAD_RATE`          | (trống)     | Giới hạn tốc độ tải lên                                  |
| `AUTH_ONCE`            | `false`     | Xác thực một lần duy nhất (`-1` của microsocks)          |
| `QUIET`                | `false`     | Ẩn toàn bộ log đầu ra của container (`true`)             |

---

## 🧰 Yêu cầu hệ thống

* Docker & Docker Compose
* Kernel của Host VPS hỗ trợ WireGuard (các bản Linux kernel mới từ 5.6 trở lên đã được tích hợp sẵn).
* Quyền `NET_ADMIN` và `SYS_MODULE` để cấu hình mạng nâng cao.
