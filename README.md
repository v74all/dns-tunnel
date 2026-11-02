# dns-tunnel

اسکریپت راه‌اندازی تونل اضطراری DNS (`dnstt` + `SSH`) روی سرور مجازی شخصی؛ مخصوص شرایطی که تمام پروتکل‌ها و پورت‌ها بسته شده‌اند و فقط درخواست‌های DNS از شبکه عبور می‌کنند.

آموزش ویدیویی صفر تا صد: [مشاهده در یوتیوب (@V7lthronyx)](https://youtu.be/XuL-Fp3QnwM)

---

## قبل از نصب (تنظیم دامنه در Cloudflare)

در پنل DNS دامنه خود دو رکورد زیر را بسازید (به‌جای `myserver.xyz` دامنه خودتان را بگذارید):

| نوع (Type) | نام (Name) | مقدار / مقصد (Target) | وضعیت ابر (Proxy) |
|---|---|---|---|
| `A` | `tns` | آی‌پی سرور مجازی شما | **خاموش / خاکستری (DNS only)** |
| `NS` | `t` | `tns.myserver.xyz` | DNS only |

---

## نصب روی سرور مجازی لینوکس (Ubuntu / Debian)

از طریق `SSH` وارد سرور خارج خود شوید و دو دستور زیر را اجرا کنید:

```bash
curl -fsSL https://raw.githubusercontent.com/v74all/dns-tunnel/main/install.sh -o install.sh
sudo bash install.sh --domain t.myserver.xyz
```

---

## مدیریت کاربران و بررسی وضعیت

ساخت کاربر اختصاصی و محدودشده برای تونل (بدون دسترسی شل به سرور):

```bash
sudo bash install.sh add sara
```

تست صحت رکوردهای DNS و پاسخ‌گویی سرور از مسیر ریزالورهای عمومی:

```bash
sudo bash install.sh check
```

نمایش کلید عمومی (`Public Key`) و راهنمای اتصال گوشی و کامپیوتر:

```bash
sudo bash install.sh show
```

سایر دستورات مدیریتی:

```bash
sudo bash install.sh status
sudo bash install.sh users
sudo bash install.sh passwd sara
sudo bash install.sh del sara
sudo bash install.sh uninstall
```

---

## اتصال در گوشی اندروید (SlipNet)

۱. برنامه متن‌باز **SlipNet** را فقط از مخزن رسمی گیت‌هاب آن دانلود کنید: `https://github.com/anonvector/SlipNet`
۲. یک پروفایل جدید از نوع **DNSTT + SSH** بسازید و ۴ فیلد را پر کنید:
- **Domain:** `t.myserver.xyz`
- **Public Key:** کلید چاپ‌شده در خروجی دستور `show`
- **DNS Resolver:** آدرس DNS اپراتور یا `1.1.1.1`
- **SSH User & Password:** نام کاربری و رمزی که با دستور `add` ساختید

---

## اتصال در کامپیوتر (Windows / Linux / macOS)

فایل `dnstt-client` مناسب سیستم‌عامل خود را از بخش Releases دانلود کرده و اجرا کنید:

```bash
dnstt-client -udp 1.1.1.1:53 -pubkey YOUR_PUBLIC_KEY t.myserver.xyz 127.0.0.1:7000
ssh -N -D 1080 -p 7000 sara@127.0.0.1
```

سپس پروکسی `SOCKS5` سیستم یا مرورگر را روی `127.0.0.1` پورت `1080` قرار دهید.

---

## نکات امنیتی و محدودیت‌ها

- سرعت تونل DNS حدود `50` تا `150` کیلوبیت بر ثانیه است و مانند جعبه کمک‌های اولیه برای پیام‌رسان‌ها، ایمیل و باز کردن صفحات وب سبک در شرایط اضطراری طراحی شده است (مناسب فیلم و دانلود نیست).
- کاربران ساخته‌شده در گروه `dnstunnel` قرار می‌گیرند، هیچ شل یا دسترسی ترمینالی ندارند، فقط از داخل تونل (`127.0.0.1`) اجازه احراز هویت دارند و دسترسی آن‌ها به شبکه داخلی سرور توسط `nftables` مسدود شده است.
- حتماً **قبل از بروز قطعی اینترنت** سرور را راه‌اندازی و یک بار با گوشی تست کنید.

