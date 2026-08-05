# คู่มือ setup — ใช้งานครั้งแรก ทีละขั้น

<p align="center"><a href="SETUP.md">English</a> · <b>ภาษาไทย</b></p>

ฝั่ง Mac เหมือนกันทั้งสอง platform ต่างกันที่ฝั่งอุปกรณ์ — Android คือทางลัด (~2 นาที) ส่วน iOS ใช้ได้แต่ setup เยอะกว่า เพราะ Apple บังคับให้แอปต้องถูก sign — อ่าน section ของมันก่อนเริ่ม

## Mac (ครั้งเดียว ใช้ทั้งสอง platform)

```sh
brew install 9zax/tap/aeasy-display     # หรือ: git clone && make install
```

รันครั้งแรกจะมี prompt ขอสิทธิ์ 2 อัน — จำเป็นทั้งคู่ ให้ครั้งเดียวจบ:

| Prompt | เพื่ออะไร | ที่ไหน |
|---|---|---|
| **Screen Recording** | จับภาพ virtual display | System Settings → Privacy & Security → Screen Recording → `aeasy-server` |
| **Accessibility** | แปลงการแตะบนมือถือเป็นคลิกบน Mac | System Settings → Privacy & Security → Accessibility → `aeasy-server` |

มีแค่อันแรกภาพก็มา แต่ touch ต้องมีทั้งคู่ ถ้า build จากซอร์สเอง ต้องให้ Accessibility ใหม่ทุกครั้งที่ rebuild (ลายเซ็น binary เปลี่ยน)

---

## Android (~2 นาที)

1. **เปิด USB debugging** บนมือถือ: Settings → About phone → แตะ **Build number** 7 ครั้ง → กลับ → System → Developer options → เปิด **USB debugging**
2. เสียบสาย แล้วกดยอมรับ **"Allow USB debugging?"** บนมือถือ
3. ```sh
   aeasy install-app     # ติดตั้ง APK ที่แถมมา
   aeasy start
   ```
4. จบ — แอป viewer เด้งขึ้นเอง หมุนเครื่องจอตาม ถอด/เสียบสายได้อิสระ

อยากไร้สาย: `aeasy wifi` (เสียบสายครั้งเดียวตอนเปิดใช้) กลับมาใช้สาย: `aeasy usb`

---

## iPhone / iPad (เบต้า, ครั้งแรก ~15 นาที)

**อ่านก่อน:** Apple บังคับให้แอปบนเครื่องต้องถูก sign ถ้าใช้ Apple ID ฟรี แปลว่า: sign ครั้งเดียวใน Xcode และ cert **หมดอายุทุก 7 วัน** — เมื่อไหร่แอปเปิดไม่ขึ้น = เสียบสายแล้วกด Run ใน Xcode ใหม่ ไม่ต้องจ่ายเงินโปรแกรมนักพัฒนา

**คนใช้ iPad:** ถ้ายอม sign in Apple ID ทั้งสองเครื่อง [Sidecar](https://support.apple.com/th-th/102597) ของ Apple ดีกว่านี้ — ฟรี, native, รองรับ Apple Pencil ที่ AEasy รองรับ iOS ไว้เพื่อ iPhone เป็นหลัก เพราะ iPhone ไม่มีทางเลือก first-party เลย

### 1. เตรียมฝั่ง Mac

```sh
brew install libusbmuxd libimobiledevice socat   # เทียบเท่า android-platform-tools ของฝั่ง iOS
```

ต้องมี Xcode ตัวเต็ม (ไม่ใช่แค่ Command Line Tools) — และ **SDK ของมันต้องใหม่พอกับ iOS บนเครื่อง**: เครื่อง iOS 26 ต้องใช้ Xcode 26 ถ้ากด Run แล้วฟ้องว่า device ไม่รองรับ ให้อัปเดต Xcode จาก App Store ก่อน

### 2. เตรียมฝั่งเครื่อง

- เสียบสาย ปลดล็อก แล้วแตะ **Trust** ตอนถาม "Trust This Computer?"
- iOS 16+: เปิด **Developer Mode** — Settings → Privacy & Security → Developer Mode → เปิด (เครื่องจะ restart)

### 3. ติดตั้งแอป

```sh
aeasy install-app        # เปิดโปรเจกต์ Xcode ให้
```

ใน Xcode (ทำครั้งเดียวทั้งหมด):

1. **Xcode → Settings… → Accounts → +** → sign in ด้วย Apple ID อะไรก็ได้
2. โปรเจกต์ → target **AEasyDisplay** → **Signing & Capabilities** → ติ๊ก **Automatically manage signing** → เลือก **Personal Team** ของคุณ
   - ถ้า Xcode ฟ้องว่า cert ถูก **revoke**: ปกติหลัง cert หมุนเวียน — พอเลือก automatic signing ไว้ Xcode จะออกใบใหม่ให้ทันที
3. เลือกเครื่องของคุณที่แถบบน → กด **▶ Run**
4. ถ้าเครื่องไม่ยอมเปิดแอป: Settings → General → **VPN & Device Management** → แตะ Apple ID ของคุณ → **Trust**

### 4. รัน

```sh
aeasy start
```

เปิดแอป **AEasy Display** บนเครื่องเอง (Mac สั่งเปิดให้ไม่ได้ — มี notification เตือน) แอปจะโชว์ "Waiting for Mac…" ต่อติดในไม่กี่วิ แล้วจอจะ rebuild หนึ่งครั้งเป็นขนาดจริงของเครื่อง แตะจอ = ขยับเคอร์เซอร์ Mac

ไร้สาย: แอปโชว์ IP บนจอ → `aeasy wifi <ip-นั้น>` → ถอดสายได้ (iOS ขอสิทธิ์ Local Network ครั้งเดียว)

### ข้อจำกัดฝั่ง iOS (มาจากตัว platform เอง — ไม่ใช่บั๊ก)

- ล็อกหน้าจอหรือสลับแอป = **สตรีมหยุด** ปลดล็อกแล้วต่อใหม่เอง
- cert ฟรีหมดอายุทุก **7 วัน** → กด Run ใน Xcode ใหม่
- Mac สั่งเปิดแอปให้ไม่ได้
- ขอบจอสุด ๆ บางทีโดน gesture ของ iOS แย่งไปแทนคลิก

---

## Android กับ iOS บน Mac เครื่องเดียว

ระบบเลือก Android ก่อนเสมอเมื่อเสียบทั้งคู่ บังคับ platform ได้ด้วย config บรรทัดเดียว:

```sh
echo "PLATFORM=ios" >> ~/.local/share/aeasy/config && aeasy restart   # ใช้ iPhone/iPad
# ลบบรรทัดนั้น (หรือใส่ PLATFORM=android) แล้ว restart เพื่อสลับกลับ
```

---

## แก้ปัญหา

| อาการ | ทางแก้ |
|---|---|
| จอดำ แต่ต่อติด | เครื่องถอดรหัส HEVC ไม่ได้ → ตั้ง `CODEC=h264` ใน `aeasy config` |
| ภาพมา แตะแล้วเงียบ | ให้สิทธิ์ **Accessibility** กับ `aeasy-server` แล้ว `aeasy restart` |
| `aeasy status` บอก "not trusted" | ปลดล็อกเครื่องตอนเสียบสาย แล้วกดยอมรับ prompt |
| แอป iOS อยู่ ๆ เปิดไม่ขึ้น | cert 7 วันหมดอายุ → เสียบสาย กด Run ใน Xcode |
| Xcode ฟ้อง "certificate revoked" | เลือก team ใหม่โดยติ๊ก **Automatically manage signing** ไว้ — Xcode ออกใบใหม่ให้ |
| Xcode ฟ้อง iOS ของเครื่องใหม่เกินไป | อัปเดต Xcode จาก App Store |
| ภาพหน่วง/กระตุก | ระบบลดคุณภาพรายสตรีมให้อยู่แล้ว เครื่องช้ามากใช้ `aeasy tune` |
| เสียบหลายเครื่องพร้อมกัน | ไม่เป็นปัญหาแล้ว — `aeasy device list` แสดงทุกเครื่อง แล้ว `aeasy device add <id>` เลือกว่าจะใช้เครื่องไหน (สูงสุด 3) |
| แตะจากบางเครื่องแล้วไม่มีอะไรเกิดขึ้น | คุมเมาส์ได้ทีละเครื่อง สลับด้วย `aeasy device input <id>` |
| เห็นเครื่องในลิสต์แต่เพิ่มไม่ได้ | ยังไม่ได้ติดตั้งแอพ (`aeasy install-app <id>`) หรือเครื่องยังเป็น `unauthorized`/ยังไม่ได้กด Trust — กดอนุญาตบนหน้าจอเครื่องก่อน |
| จอ iOS เล็กไป/ตัวหนังสือจิ๋ว | ตั้ง `IOS_SCALE=0.8` (จอเล็กลง ตัวหนังสือใหญ่ขึ้น) ถึง `2.0` ใน config |
| Wi-Fi ต่อไม่ติด (iOS) | เช็ค IP ที่แอปโชว์อีกที ทั้งคู่อยู่เน็ตเดียวกันไหม `aeasy status` ว่า reachable หรือยัง |

ยังติด → `aeasy log` ดูบรรทัดท้ายของเซิร์ฟเวอร์ เปิด issue มาได้เลย
