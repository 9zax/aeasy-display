<p align="center">
  <img src="docs/logo.svg" width="160" alt="โลโก้ AEasy Display">
</p>

<h1 align="center">AEasy Display</h1>

<p align="center"><a href="README.md">English</a> · <b>ภาษาไทย</b></p>

**เปลี่ยนมือถือ Android ให้เป็นจอที่สองของ Mac — ผ่านสาย USB-C เส้นเดียว ไม่ใช้ Wi-Fi ไม่ต้องสมัครอะไร ไม่มีแอปเสียเงิน**

![Platform](https://img.shields.io/badge/macOS-13%2B-blue) ![Android](https://img.shields.io/badge/Android-8%2B-green) ![License](https://img.shields.io/badge/license-MIT-lightgrey)

<p align="center">
  <img src="docs/demo.jpg" width="720" alt="ตัวอย่างการใช้งาน AEasy Display — มือถือ Android เป็นจอที่สองของ Mac">
</p>

เสียบสาย → มือถือกลายเป็นจอ macOS จริง ๆ ลากหน้าต่างไปวางได้เลย หมุนมือถือแล้วจอหมุนตาม หรือจะ mirror หน้าต่างแอปเดียวก็ได้ ทุกอย่างสตรีมเป็น H.264 เข้ารหัสด้วยฮาร์ดแวร์ผ่านสาย USB ด้วย `adb reverse` — ไม่ยุ่งกับเครือข่ายเลย ใช้นอกบ้านได้ และไม่แย่ง Wi-Fi

```
┌─────────────────────┐         สาย USB-C            ┌──────────────┐
│        macOS        │  ═══════════════════════════▶│   Android    │
│                     │                              │              │
│  virtual display    │   H.264 20fps ผ่าน           │  MediaCodec  │
│  ScreenCaptureKit   │   TCP :7355 ลอดอุโมงค์        │  hw decode   │
│  VideoToolbox (hw)  │   ด้วย `adb reverse`          │  SurfaceView │
└─────────────────────┘                              └──────────────┘
```

เทียบกับ scrcpy, Deskreen, Weylus และเจ้าอื่น ๆ เป็นยังไง? ดู [COMPARISON.th.md](COMPARISON.th.md)

## ทำงานยังไง

```mermaid
flowchart LR
    subgraph mac [Mac]
        VD[Virtual display\nCGVirtualDisplay] --> CAP[ScreenCaptureKit\ncapture]
        CAP --> ENC[VideoToolbox\nH.264 hw encode]
        ENC --> TCP[TCP server :7355]
    end
    TCP -- adb reverse ผ่าน USB --> DEC
    subgraph phone [Android]
        DEC[MediaCodec\nhw decode] --> SV[Fullscreen\nSurfaceView]
    end
```

- **ฝั่ง Mac** — ไบนารี Swift ตัวเดียวสร้าง virtual display ขนาดเท่าจอมือถือ (ล็อกโหมด Retina ให้ภาพคม) จับภาพด้วย ScreenCaptureKit เข้ารหัส H.264 ด้วยฮาร์ดแวร์ แล้วเสิร์ฟสตรีมที่ TCP `:7355` ถ้าฝั่งรับช้า เฟรมจะถูกทิ้งแทนที่จะสะสมจนหน่วง
- **การส่งข้อมูล** — `adb reverse` ทำอุโมงค์จาก `localhost:7355` บนมือถือมาที่ Mac ผ่านสาย USB ไม่ต้องใช้ไดรเวอร์ USB พิเศษ ไม่ใช้เครือข่าย
- **ฝั่ง Android** — แอปเล็ก ๆ (ขอสิทธิ์แค่ `INTERNET`) เชื่อมต่อ ถอดรหัสด้วยฮาร์ดแวร์ แล้วแสดงเต็มจอ พร้อมเชื่อมต่อใหม่อัตโนมัติทุกครั้งที่สตรีมรีสตาร์ต
- **CLI `aeasy`** — คอยเฝ้าสาย: เสียบปุ๊บทุกอย่างเริ่มเอง หมุนมือถือแล้ว virtual display พลิกตาม

## สิ่งที่ต้องมี

- macOS 13+ (Apple Silicon หรือ Intel), Xcode Command Line Tools
- Homebrew (สำหรับติดตั้ง `adb` จาก `android-platform-tools`)
- มือถือ Android 8+ ที่เปิด **USB debugging** แล้ว
- สาย USB-C หนึ่งเส้น

## ติดตั้ง

```sh
git clone https://github.com/9zax/aeasy-display.git
cd aeasy-display
make install          # build ไบนารีฝั่ง Mac + ติดตั้ง CLI `aeasy` (alias `aez`)
```

Build แอป Android หนึ่งครั้ง (ต้องมี Android SDK) หรือโหลด `app-debug.apk` จาก Releases:

```sh
make apk              # build APK ตัวแสดงผล
make install-app      # ติดตั้งลงมือถือที่เสียบสายอยู่
```

รัน `make` เฉย ๆ เพื่อดูทุกคำสั่ง (`build`, `run`, `start`, `stop`, `status`, `clean`, …)

บนมือถือ: **Settings → About phone → แตะ "Build number" 7 ครั้ง** แล้วไป **Developer options → เปิด USB debugging** ตอนเสียบสายครั้งแรกให้กดยอมรับ "Allow USB debugging?"

> รันครั้งแรก: macOS จะขอสิทธิ์ **Screen Recording** ให้เทอร์มินัลของคุณ — ไปอนุญาตที่ System Settings → Privacy & Security แล้วรัน `aeasy restart`

## วิธีใช้

```sh
aeasy start     # เริ่มทุกอย่าง (มี alias สั้น ๆ ว่า `aez`)
```

| คำสั่ง | ทำอะไร |
|---|---|
| `aeasy start` | สร้าง virtual display เปิดแอปบนมือถือ และเฝ้าสาย ถ้าไม่มีมือถือเสียบอยู่จะเตือนในเทอร์มินัล |
| `aeasy stop` | หยุดเซิร์ฟเวอร์และตัวเฝ้าสาย |
| `aeasy status` | สถานะสาย / เซิร์ฟเวอร์ / แอปบนมือถือ พร้อมค่าคอนฟิกปัจจุบัน |
| `aeasy app` | เปิดแอปแสดงผลบนมือถือ (เตือนถ้าไม่ได้เสียบสาย) |
| `aeasy mirror Safari` | Mirror **หน้าต่างแอปเดียว** แทนการต่อจอ — เหมาะกับการเฝ้าดูแอปใดแอปหนึ่ง |
| `aeasy screen` | กลับสู่โหมดต่อจอ (extended display) |
| `aeasy config` | เปิด GUI ตั้งค่า (เฟรมเรต บิตเรต ความละเอียด โหมด) |
| `aeasy tune` | พรีเซ็ตหน่วงต่ำแบบกดทีเดียว (15fps / ความละเอียด 60%) สำหรับมือถือช้า |
| `aeasy restart` | รีสตาร์ต virtual display |
| `aeasy install-app` | ติดตั้ง APK ที่แนบมาลงมือถือ |
| `aeasy log` | ดู log ของเซิร์ฟเวอร์แบบสด |

### โหมดอัตโนมัติ (การเชื่อมต่อครั้งแรก)

การเชื่อมต่อครั้งแรกสุด AEasy จะทำงานใน **โหมดอัตโนมัติ**: เริ่มที่ 20fps/80% แล้วเฝ้าดูอัตราเฟรมตกจริง ถ้าตัวถอดรหัสของมือถือตามไม่ทัน ระบบจะลดคุณภาพให้เอง (→ 15fps/60% → 12fps/50%) พร้อมแจ้งเตือนบน macOS ว่าปรับอะไรไป แล้วรีสตาร์ตสตรีม ทันทีที่คุณเลือกค่าเอง (`aeasy config` หรือ `aeasy tune`) โหมดอัตโนมัติจะปิดและเคารพค่าที่คุณตั้ง

### หมุนจออัตโนมัติ

ถือมือถือแนวตั้ง Mac จะได้จอ **แนวตั้ง** เอียงเป็นแนวนอนก็กลายเป็น **แนวนอน** — ตัวเฝ้าสายจะสังเกตทิศทางของมือถือ (ขณะแอปแสดงผลอยู่หน้าจอ) แล้วสร้าง virtual display ใหม่ให้ตรงกัน จอมือถือจึงถูกใช้เต็มพื้นที่เสมอ

```
      แนวนอน                          แนวตั้ง
┌───────────────────┐                ┌─────────┐
│  1650 × 720       │    หมุน  ⟳     │ 720     │
│  เดสก์ท็อปกว้าง      │  ───────────▶ │ ×       │
└───────────────────┘                │ 1650    │
                                     │ สูง      │
                                     └─────────┘
```

### Mirror หน้าต่างเดียว

```sh
aeasy mirror "Music"     # มือถือแสดงเฉพาะหน้าต่าง Music
aeasy screen             # กลับเป็นจอ extended เต็มรูปแบบ
```

ถ้าแอปมีหลายหน้าต่าง จะใช้หน้าต่างที่ใหญ่สุดบนจอ ถ้าหาหน้าต่างไม่เจอ AEasy จะกลับไปโหมดต่อจอให้เอง (ดูได้ที่ `aeasy log`)

## ตั้งค่า

`aeasy config` เปิด GUI เล็ก ๆ หรือแก้ไฟล์ `~/.local/share/aeasy/config` เองก็ได้:

| คีย์ | ค่าเริ่มต้น | ความหมาย |
|---|---|---|
| `FPS` | `20` | เฟรมเรตจับภาพ/เข้ารหัส (10–30) ยิ่งต่ำยิ่งหน่วงน้อยบนมือถือช้า |
| `BITRATE` | `2000000` | บิตเรต H.264 หน่วย bps |
| `SCALE` | `80` | ความละเอียดเข้ารหัสเป็น % ของจอมือถือ ยิ่งต่ำยิ่งถอดรหัสเบา |
| `MODE` | `display` | `display` (ต่อจอ) หรือ `window` (mirror แอปเดียว) |
| `WINDOW_APP` | – | ชื่อแอปที่จะ mirror เมื่อ `MODE=window` |

อยากได้ตัวหนังสือใหญ่ขึ้น: System Settings → Displays → **AEasy Display** แล้วเลือกความละเอียด "looks like" ที่ต่ำลง

## แก้ปัญหา

| อาการ | วิธีแก้ |
|---|---|
| เตือน "no phone plugged in" | เช็คสาย และดูว่ามือถือโผล่ใน `adb devices` (กดยอมรับ USB debugging บนมือถือ) |
| จอมือถือดำ | `aeasy restart` และเช็คว่าให้สิทธิ์ Screen Recording แล้ว |
| กระตุก/หน่วง | รัน `aeasy tune` (หรือลด `FPS`/`SCALE` ใน `aeasy config`) ถ้าเฟรมตกเกิน 25% AEasy จะแจ้งเตือนพร้อมวิธีแก้ให้อัตโนมัติ |
| มีจอแต่ว่างเปล่า | มันคือเดสก์ท็อปเสริม — ลากหน้าต่างไปที่ "AEasy Display" หรือใช้ `aeasy mirror <App>` |

## โครงสร้างโปรเจกต์

```
aeasy-display/
├── Makefile                    # make install / make apk / make run ...
├── install.sh                  # build + ติดตั้ง (ใช้โดย `make install`)
├── bin/aeasy                   # CLI (zsh)
├── mac/
│   ├── AEasyServer.swift  # virtual display + จับภาพ + เข้ารหัส + TCP server
│   ├── AEasyConfig.swift  # GUI ตั้งค่า
│   └── virtual-display.h       # อินเทอร์เฟซ CGVirtualDisplay (private API)
└── android/                    # แอปแสดงผล (Kotlin ~200 บรรทัด)
```

## ข้อจำกัด

- ยังสั่งงานแบบสัมผัสกลับไปที่ Mac ไม่ได้ และไม่มีเสียง (PR ยินดีต้อนรับ)
- ใช้ private API `CGVirtualDisplay` — ตัวเดียวกับที่เครื่องมือ virtual display อื่น ๆ ใช้ อาจเปลี่ยนใน macOS รุ่นถัดไป
- ต่อมือถือได้ทีละเครื่อง (ตัวสตรีมเองรองรับผู้ชมหลายตัว)

## สัญญาอนุญาต

MIT
