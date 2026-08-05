<p align="center">
  <img src="docs/logo.svg" width="160" alt="โลโก้ AEasy Display">
</p>

<h1 align="center">AEasy Display</h1>

<p align="center"><a href="README.md">English</a> · <b>ภาษาไทย</b></p>

**เปลี่ยนมือถือ Android ให้เป็นจอที่สองแบบสัมผัสได้ของ Mac — ผ่านสาย USB-C หรือ Wi-Fi ไม่ต้องสมัครอะไร ไม่มีแอปเสียเงิน**

![Platform](https://img.shields.io/badge/macOS-13%2B-blue) ![Android](https://img.shields.io/badge/Android-8%2B-green) ![License](https://img.shields.io/badge/license-MIT-lightgrey) [![Release](https://img.shields.io/github/v/release/9zax/aeasy-display)](https://github.com/9zax/aeasy-display/releases/latest)

<p align="center">
  <img src="docs/demo.jpg" width="720" alt="ตัวอย่างการใช้งาน AEasy Display — มือถือ Android เป็นจอที่สองของ Mac">
</p>

เสียบสาย → มือถือกลายเป็นจอ macOS จริง ๆ ลากหน้าต่างไปวางได้เลย **แตะจอเพื่อคลิก/ลาก**หน้าต่างบนมือถือได้เหมือนจอ touchscreen หมุนเครื่องแล้วจอหมุนตาม หรือจะ mirror หน้าต่างแอปเดียวก็ได้ ทุกอย่างสตรีมเป็น H.264/HEVC เข้ารหัสด้วยฮาร์ดแวร์ผ่าน `adb reverse` — ค่าเริ่มต้นวิ่งบนสาย USB (ไม่ยุ่งเครือข่าย ใช้นอกบ้านได้) หรือถอดสายเป็นไร้สายด้วย `aeasy wifi`

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

## iPhone และ iPad (เบต้า)

แอป viewer ฝั่ง iOS อยู่ใน [`ios/`](ios/) สตรีมแบบเดียวกัน — แต่แพลตฟอร์มของ Apple ทำให้ต่างไป 3 เรื่อง อ่านก่อนใช้:

- **ติดตั้งผ่าน Xcode ด้วย Apple ID ของคุณเอง (ฟรี)** — `aeasy install-app` จะเปิดโปรเจกต์ให้ ไปที่ Signing & Capabilities ใส่ Apple ID อะไรก็ได้ แล้วกด Run ไม่ต้องเสียเงินโปรแกรมนักพัฒนา แต่ **cert ฟรีหมดอายุทุก 7 วัน**: ถ้าแอปเปิดไม่ขึ้น เสียบสายแล้วกด Run ใหม่
- **สาย USB ต้องมี** `brew install libusbmuxd libimobiledevice socat` (เทียบเท่า `android-platform-tools` ของฝั่ง iOS) เสียบครั้งแรกต้องกด Trust บนเครื่อง
- **ล็อกหน้าจอ = สตรีมหยุด** — iOS พักแอป ปลดล็อกแล้วต่อใหม่เอง และ Mac สั่งเปิดแอปให้ไม่ได้: เสียบสาย เปิดแอป AEasy Display บนเครื่องเอง จบ ส่วนหมุนจอ, สัมผัส, HEVC และโหมดไร้สาย (`aeasy wifi <ip>` — แอปโชว์ IP ให้) ใช้ได้เหมือน Android

**เรื่อง iPad:** [Sidecar](https://support.apple.com/th-th/102597) ของ Apple เองดีกว่าถ้าคุณ sign in Apple ID อยู่แล้ว — ฟรี, native, รองรับ Apple Pencil ที่ AEasy รองรับ iPad ไว้สำหรับคนที่ไม่อยาก sign in ส่วน iPhone ไม่มีทางเลือก first-party เลย นั่นคือเหตุผลที่ฟีเจอร์นี้มีอยู่

สถานะ: **เบต้า** — กำลังพัฒนาต่อเนื่อง ตามได้ที่ [`specs/2026-08-05-ios-client.md`](specs/2026-08-05-ios-client.md)

## สิ่งที่ต้องมี

- macOS 13+ (Apple Silicon หรือ Intel), Xcode Command Line Tools
- Homebrew (สำหรับติดตั้ง `adb` จาก `android-platform-tools`)
- มือถือหรือ tablet Android 8+ ที่เปิด **USB debugging** แล้ว
- สาย USB-C หนึ่งเส้น

## ติดตั้ง

ผ่าน Homebrew:

```sh
brew install 9zax/tap/aeasy-display
aeasy install-app     # ติดตั้งแอป viewer (แนบมากับ formula) ลงมือถือที่เสียบสายอยู่
```

หรือ build จาก source:

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
| `aeasy sources display,window:Safari` | แสดง **ได้สูงสุด 3 แหล่งภาพพร้อมกัน** เป็น pane ซ้อนบนมือถือ ไม่ใส่ค่าคือดูค่าปัจจุบัน |
| `aeasy config` | เปิด GUI ตั้งค่า (เฟรมเรต บิตเรต ความละเอียด แหล่งภาพ และผังการวาง pane) |
| `aeasy tune` | พรีเซ็ตหน่วงต่ำแบบกดทีเดียว (15fps / ความละเอียด 60%) สำหรับมือถือช้า |
| `aeasy wifi` | เปลี่ยนเป็น **โหมดไร้สาย** — เสียบสายครั้งเดียวตอนเปิดใช้ แล้วถอดสายได้เลย |
| `aeasy usb` | กลับมาใช้สาย USB |
| `aeasy restart` | รีสตาร์ต virtual display |
| `aeasy install-app` | ติดตั้ง APK ที่แนบมาลงมือถือ |
| `aeasy log` | ดู log ของเซิร์ฟเวอร์แบบสด |

### แสดงหลายแหล่งภาพพร้อมกัน

`aeasy sources display,window:Safari` จะส่งทั้งจอ extended และหน้าต่าง Safari ไปแสดงเป็น pane ซ้อนกันบนมือถือ ได้สูงสุด 3 อัน แต่ละ pane เป็นสตรีมแยกกัน ถ้าแอปหนึ่งถูกปิด อีก pane จะไม่กระทบ

แตะปุ่ม **จัดวาง** บนมือถือเพื่อลากย้าย pane และลากมุมขวาล่างเพื่อปรับขนาด แตะ **เสร็จ** เพื่อกลับไปควบคุม Mac ผังเดียวกันนี้ลากได้ในหน้า `aeasy config` ด้วย และทั้งสองฝั่ง sync กันแบบเรียลไทม์ การแตะบน pane จะสั่งงานหน้าต่างจริงที่อยู่เบื้องหลัง โดยจะยกหน้าต่างนั้นขึ้นมาก่อน

### คุณภาพเมื่อสายหนืด

AEasy เฝ้าดูอัตราเฟรมตกจริง ถ้าตัวถอดรหัสของมือถือตามไม่ทัน ระบบจะลดบิตเรตและเฟรมเรตของสตรีมนั้นให้เองแบบไม่ต้องรีสตาร์ต และ **จะลด pane รองก่อนเสมอ เพื่อกันจอหลักไว้** ต่อเมื่อทุกตัวลงถึงพื้นแล้วจึงจะแจ้งเตือนให้ลองใช้ `aeasy tune`

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

### สั่งงานด้วยการแตะจอ (touch input)

แตะจอมือถือแล้วเคอร์เซอร์ Mac ขยับตาม — แตะ = คลิก, ลาก = ลากหน้าต่าง มือถือกลายเป็น **จอ touchscreen** ขนาดเล็ก ต้องให้สิทธิ์ **Accessibility** กับ `aeasy-server` (System Settings → Privacy & Security → Accessibility) — เซิร์ฟเวอร์จะเด้งถามและเขียน hint ใน log ให้ตอนรันครั้งแรก หมายเหตุ: ทุกครั้งที่ build ใหม่ (`make build`) ต้องเปิดสิทธิ์ซ้ำ ภาพยังทำงานปกติแม้ไม่ให้สิทธิ์ — มีแค่ touch ที่ต้องใช้ ใช้ได้เฉพาะโหมดต่อจอ ยังไม่รองรับ scroll และหลายนิ้ว

### โหมดไร้สาย

```sh
aeasy wifi     # เสียบสายอยู่: เปิด Wi-Fi adb เสร็จแล้วถอดสายได้เลย
aeasy usb      # กลับมาใช้สาย
```

สตรีมวิ่งผ่าน `adb connect` บน Wi-Fi วงเดียวกัน — คำสั่งเดิม หมุนจออัตโนมัติเหมือนเดิม ถ้าหลุด (มือถือหลับ เน็ตสะดุด) ตัวเฝ้าจะต่อกลับให้เอง สาย USB ยังหน่วงต่ำสุด โหมดไร้สายแลกความหน่วงนิดหน่อยกับอิสระจากสาย

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
| `BITRATE` | `2000000` | บิตเรตวิดีโอ หน่วย bps |
| `SCALE` | `80` | ความละเอียดเข้ารหัสเป็น % ของจอมือถือ ยิ่งต่ำยิ่งถอดรหัสเบา |
| `SOURCES` | `display` | ได้สูงสุด 3 อัน คั่นด้วยจุลภาค: `display` และ/หรือ `window:<ชื่อแอป>` ตั้งผ่าน `aeasy sources`/`mirror`/`screen` — ตัวแรกคือ pane หลัก และ `display` จะถูกเลื่อนขึ้นก่อนเสมอ |
| `CODEC` | `h264` | `h264` หรือ `hevc` — HEVC ภาพสวยกว่าที่บิตเรตเท่ากัน ถ้ามือถือถอดรหัสไม่ได้ (จอดำ) ให้กลับเป็น `h264` |
| `WIFI_ADDR` | – | `aeasy wifi` ตั้งให้เอง / `aeasy usb` ลบให้ — ไม่ต้องแก้เอง |

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

- ไม่มีเสียง และการสัมผัสรองรับแค่แตะ+ลาก — ยังไม่รองรับ scroll หลายนิ้ว หรือแรงกดปากกา (PR ยินดีต้อนรับ)
- ใช้ private API `CGVirtualDisplay` — ตัวเดียวกับที่เครื่องมือ virtual display อื่น ๆ ใช้ อาจเปลี่ยนใน macOS รุ่นถัดไป
- ต่อมือถือได้ทีละเครื่อง (ตัวสตรีมเองรองรับผู้ชมหลายตัว)

## สัญญาอนุญาต

MIT
