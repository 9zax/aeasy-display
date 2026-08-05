# AEasy Display เทียบกับ open source เจ้าอื่น

<p align="center"><a href="COMPARISON.md">English</a> · <b>ภาษาไทย</b></p>

เทียบกับโปรเจกต์ open source ที่ใกล้เคียงกัน: [scrcpy](https://github.com/Genymobile/scrcpy), [Deskreen](https://github.com/pavlobu/deskreen), [Weylus](https://github.com/H-M-H/Weylus), [VirtScreen](https://github.com/kbumsik/VirtScreen), [Sunshine](https://github.com/LizardByte/Sunshine)+[Moonlight](https://moonlight-stream.org/)
(ตัวดัง ๆ อย่าง Duet Display, superDisplay ไม่รวมเพราะเป็น closed source — ส่วน spacedesk ก็ closed source เหมือนกัน แต่มีคนถามบ่อยมากเลยใส่ในตารางให้เลย)

## ตารางรวม — โจทย์ "เอาอุปกรณ์อื่นมาเป็นจอเสริม"

| | ⭐ AEasy Display | spacedesk | Deskreen | Weylus | VirtScreen | Sunshine + Moonlight |
|---|---|---|---|---|---|---|
| ฝั่งคอม | macOS เท่านั้น | Windows 10/11 เท่านั้น | Win / macOS / Linux | Win / macOS / Linux | Linux (X11) เท่านั้น | Win / macOS / Linux |
| ฝั่งจอเสริม | Android / iOS เบต้า (แอป viewer) | Android / iOS / browser / Windows อีกเครื่อง | ทุกอย่างที่มี browser | ทุกอย่างที่มี browser | ทุกอย่างที่รับ VNC ได้ | Android / iOS / อื่น ๆ (แอป Moonlight) |
| Open source | ✅ MIT | ❌ closed source, ใช้ฟรี | ✅ | ✅ | ✅ | ✅ |
| สร้าง virtual display ให้เอง | ✅ (`CGVirtualDisplay`) | ✅ (Windows display driver) | ❌ ต้องมี dummy plug หรือทำ virtual display เอง | ⚠️ Linux เท่านั้น (macOS = มิเรอร์อย่างเดียว) | ✅ (xrandr) | ❌ ต้องมี dummy plug หรือ BetterDisplay ช่วย |
| การเชื่อมต่อ | USB (zero network) หรือ Wi-Fi (`aeasy wifi`) | Wi-Fi / LAN / USB (ผ่าน USB tethering ของ Android) | Wi-Fi (WebRTC) | Wi-Fi (WebRTC/WebSocket) | Wi-Fi (VNC) | Wi-Fi / LAN (มี hw encode) |
| ความหน่วง | ต่ำ (hw encode/decode ทั้งสาย) | ปานกลาง (ขึ้นกับเครือข่าย; USB/LAN จะต่ำ) | ปานกลาง–สูง (software encode ผ่าน browser) | ปานกลาง (มี hw encode บางแพลตฟอร์ม) | สูง (VNC ไม่เหมาะกับวิดีโอ) | ต่ำมาก (ออกแบบมาเพื่อเกม) |
| ส่ง input กลับ (touch/ปากกา) | ✅ แตะ+ลาก (ไม่มีแรงกดปากกา/scroll) | ✅ touch, stylus แรงกด, คีย์บอร์ด/เมาส์ | ❌ | ✅ จุดขายหลัก (stylus แรงกด — Linux เท่านั้น) | ✅ ผ่าน VNC | ✅ (เมาส์/คีย์/จอย) |
| เสียง | ❌ | ✅ | ❌ | ❌ | ❌ | ✅ |
| หมุนจออัตโนมัติ | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ |
| ต่อหลายเครื่องพร้อมกัน | ✅ สูงสุด 3 เครื่อง แต่ละเครื่องเป็นจอของตัวเอง เพิ่ม/ถอดได้เลย | ⚠️ เดสก์ท็อปเดียวกระจายหลายอุปกรณ์ (video wall) | ❌ | ❌ | ❌ | ❌ |
| หลายแหล่งภาพพร้อมกัน | ✅ สูงสุด 3 pane (จอเสริม, หน้าต่างแอป, กล้อง) ลากจัดวางสดได้จากทั้งสองฝั่ง | ⚠️ เดสก์ท็อปเดียวกระจายหลายอุปกรณ์ (video wall) | ❌ | ❌ | ❌ | ⚠️ สตรีมเดียวต่อ session |
| Mirror รายแอป | ✅ `aeasy mirror <App>` | ❌ ได้ทั้งเดสก์ท็อปเท่านั้น | ✅ เลือกแชร์เฉพาะหน้าต่างแอปได้ | ⚠️ Linux เท่านั้น | ❌ | ❌ ได้ทั้งจอเท่านั้น |
| ปรับคุณภาพตามโหลดอัตโนมัติ | ✅ สด รายสตรีม — ลด bitrate/fps เอง pane รองโดนก่อน | ⚠️ ตั้งคุณภาพเองด้วยมือ | ⚠️ ตามที่ WebRTC จัดการให้ | ❌ | ❌ | ✅ adaptive bitrate |
| เสียบสายแล้วเริ่มเอง | ✅ cable watcher: เสียบปุ๊บสตรีมปั๊บ ต่อใหม่ให้เอง | ❌ ต้องเปิด viewer แล้วกด connect | ❌ | ❌ | ❌ | ❌ |
| สถานะโปรเจกต์ | ใหม่ | โตเต็มวัย พัฒนาต่อเนื่อง | active แต่ virtual display "อยู่ใน roadmap" มานาน | active | ⚠️ หยุดพัฒนา (commit สุดท้าย 2018) | active มาก ชุมชนใหญ่ |

## สรุปรายเจ้า

### Deskreen — จอเสริมผ่าน browser, สาย Wi-Fi
- **เด่น**: ฝั่งรับไม่ต้องลงอะไรเลย เปิด browser ก็ใช้ได้ ใช้ได้กับ iPad/มือถือ/โน้ตบุ๊กอีกเครื่อง, cross-platform
- **ด้อย**: ไม่สร้าง virtual display ให้ — ถ้าอยาก "extend" จริงต้องเสียบ dummy plug เอง ไม่งั้นได้แค่มิเรอร์, encode ด้วยซอฟต์แวร์ผ่าน Electron+WebRTC กิน CPU และหน่วงกว่า, ต้องอยู่ Wi-Fi เดียวกัน

### Weylus — เน้นเป็นเมาส์/ปากกา มากกว่าจอเสริม
- **เด่น**: ส่ง input กลับได้เต็มรูปแบบ — ใช้แท็บเล็ตเป็น graphic tablet แรงกด/tilt ได้ (Linux), เบามาก (Rust binary เดียว), ฝั่งรับใช้ browser
- **ด้อย**: ฟีเจอร์เด็ด ๆ (stylus แรงกด, virtual monitor, window capture) เป็นของ Linux เท่านั้น — บน macOS เหลือแค่มิเรอร์จอ+ควบคุมพื้นฐาน, ผ่าน Wi-Fi

### VirtScreen — แนวคิดเดียวกับ AEasy แต่ฝั่ง Linux
- **เด่น**: สร้าง virtual display จริงด้วย xrandr แล้วแชร์ผ่าน VNC — ครบจบในตัวเหมือนกัน
- **ด้อย**: Linux/X11 เท่านั้น (ไม่รองรับ Wayland), VNC ไม่เหมาะกับภาพเคลื่อนไหว หน่วงสูง, **หยุดพัฒนาไปแล้วตั้งแต่ 2018**

### Sunshine + Moonlight — ท่อวิดีโอที่เร็วที่สุด แต่ต้องประกอบเอง
- **เด่น**: ความหน่วงต่ำสุดในกลุ่ม (ออกแบบมาสตรีมเกม, hw encode H.264/HEVC/AV1), client มีทุกแพลตฟอร์มรวมถึง Android, ชุมชนใหญ่พัฒนาต่อเนื่อง
- **ด้อย**: เป็น game-streaming ไม่ใช่เครื่องมือจอเสริม — บน macOS ต้องหา virtual display เองด้วย dummy plug หรือ [BetterDisplay](https://github.com/waydabber/BetterDisplay) (freemium) แล้วชี้ Sunshine ให้สตรีมจอนั้น, setup หลายชิ้น, ผ่านเครือข่าย

### จุดยืนของ AEasy Display ในกลุ่มนี้
เป็นตัวเดียวที่ **"จอเสริม macOS → Android ผ่านสาย USB จบในคำสั่งเดียว"** — สร้าง virtual display เอง, hw encode/decode ตลอดสาย, ไม่ใช้เครือข่าย, หมุนจอตามเครื่อง และสตรีมได้สูงสุด **3 แหล่งภาพพร้อมกัน**เป็น pane ลากจัดวางได้ (จอเสริม, หน้าต่างแอป หรือกล้อง) แยกสตรีมอิสระต่อ pane รอบ ๆ แกนนี้ยังมี GUI ตั้งค่า (`aeasy config` — fps/bitrate/ความละเอียด/codec พร้อม editor จัดวาง pane สด ๆ), preset หน่วงต่ำกดทีเดียว (`aeasy tune`), ไอคอน tray บนเมนูบาร์ (สถานะ + start/stop) และแอปมือถือที่ขอ permission แค่ `INTERNET` ฟรี, MIT, ไม่มีบัญชีผู้ใช้ แลกกับการที่รองรับแค่ macOS+Android, ไม่มีเสียง และยังไม่รองรับ scroll/หลายนิ้ว

### spacedesk — ไอเดียเดียวกัน แต่เป็นของฝั่ง Windows
- **เด่น**: โตเต็มวัย ขัดเกลามานาน, มีเสียง, ส่ง input กลับได้ทั้ง touch / stylus แรงกด / คีย์บอร์ด-เมาส์, ทำ video wall หลายอุปกรณ์ได้, ฝั่งรับใช้ browser ก็ได้, ใช้ฟรี
- **ด้อย**: **Windows เท่านั้น — ไม่มีเวอร์ชัน macOS** เลยเทียบบนเครื่องเดียวกับ AEasy ไม่ได้ด้วยซ้ำ, closed source, โหมด "USB" จริง ๆ คือ network-over-USB ผ่าน USB tethering ของ Android ไม่ใช่ท่อส่งตรง
- มีคนเทียบ AEasy กับ spacedesk บ่อย ก็สมเหตุผล — โจทย์ "มือถือเป็นจอเสริมผ่าน USB" เดียวกันเป๊ะ แต่ spacedesk ตอบโจทย์ให้คนใช้ Windows ส่วน AEasy ตอบให้คนใช้ Mac — ไม่ได้แข่งกันเลย

---

# ภาคผนวก: เจาะลึก vs scrcpy

> ข้อสำคัญ: สองตัวนี้**แก้ปัญหาคนละโจทย์ ทิศทางตรงกันข้ามกัน**
>
> - **AEasy Display** — ส่งภาพ **Mac → Android**: เปลี่ยนมือถือให้เป็น*จอเสริม*ของ Mac
> - **scrcpy** — ส่งภาพ **Android → PC**: *มิเรอร์และควบคุม*หน้าจอมือถือจากคอมพิวเตอร์
>
> จึงไม่ใช่คู่แข่งกันโดยตรง — ใช้ร่วมกันได้ด้วยซ้ำ ตารางนี้เทียบให้เห็นว่าโจทย์ไหนควรใช้ตัวไหน

## เปรียบเทียบภาพรวม

| | ⭐ AEasy Display | scrcpy |
|---|---|---|
| ทิศทางภาพ | Mac → Android (จอเสริม) | Android → PC (มิเรอร์มือถือ) |
| โจทย์หลัก | เพิ่มพื้นที่หน้าจอให้ Mac | ดู/ควบคุมมือถือจากคอม |
| แพลตฟอร์มฝั่งคอม | macOS 13+ เท่านั้น | Windows / macOS / Linux |
| ฝั่งมือถือ | ต้องติดตั้งแอป viewer (APK) | ไม่ต้องลงแอป (push server ผ่าน adb อัตโนมัติ) |
| การเชื่อมต่อ | USB (`adb reverse`) หรือ Wi-Fi (`aeasy wifi`) | USB หรือ Wi-Fi (TCP/IP) |
| เสียง | ไม่มี | มี (Android 11+, forward เสียงมาที่คอม) |
| ควบคุมอีกฝั่งได้ไหม | touch: แตะ+ลากขยับเคอร์เซอร์ Mac ได้ | ได้เต็มรูปแบบ (เมาส์ คีย์บอร์ด clipboard ลากไฟล์) |
| วิดีโอ | H.264 / HEVC hardware encode/decode | H.264 / H.265 / AV1 |
| ความเสถียร/วุฒิภาวะ | โปรเจกต์ใหม่ ขนาดเล็ก | ใช้กันมานาน ชุมชนใหญ่ (100k+ stars) |

## จุดเด่น AEasy Display

- **ทำสิ่งที่ scrcpy ทำไม่ได้บน macOS** — สร้าง virtual display จริงบน Mac (`CGVirtualDisplay`) ให้ลากหน้าต่างไปวางบนมือถือได้เหมือนจอเสริมแท้ ๆ
- **Zero network** — ทุกอย่างวิ่งผ่านสาย USB (`adb reverse`) ไม่แย่ง Wi-Fi ใช้กลางแจ้ง/บนรถได้
- **หลายแหล่งภาพพร้อมกัน** — `aeasy sources display,window:Safari` แสดงได้สูงสุด 3 pane ซ้อนกัน ลากย้าย/ปรับขนาดสดจากมือถือหรือ `aeasy config` ก็ได้ แตะ pane แล้วสั่งงานหน้าต่างจริงข้างหลังได้เลย
- **ลดคุณภาพตามโหลด** — วัด frame-drop จริงรายสตรีมแล้วลด bitrate/fps ให้ทันที pane รองโดนก่อน pane หลัก และไม่ต้อง restart
- **Auto-rotation** — หมุนมือถือแล้ว virtual display ฝั่ง Mac หมุนตาม (portrait ↔ landscape) ใช้พื้นที่จอเต็มแผง
- **Mirror รายแอป** — `aeasy mirror Safari` ส่งเฉพาะหน้าต่างแอปเดียวไปโชว์บนมือถือ
- **Hardware ทั้งสาย** — ScreenCaptureKit + VideoToolbox ฝั่ง Mac, MediaCodec ฝั่ง Android กิน CPU ต่ำ

## จุดด้อย AEasy Display (เทียบ scrcpy)

- macOS เท่านั้น — ไม่มี Windows/Linux
- ต้อง build/ติดตั้ง APK ลงมือถือก่อน
- ไม่มีเสียง (จอเสริมส่วนใหญ่ไม่จำเป็น แต่ scrcpy มี)
- เฟรมเรตเพดาน 30fps
- โปรเจกต์ใหม่ — ecosystem/เอกสาร/การทดสอบยังเทียบ scrcpy ไม่ได้

## จุดเด่น scrcpy

- **ควบคุมมือถือได้เต็มรูปแบบ** — พิมพ์ คลิก ลากไฟล์ แชร์ clipboard สองทาง
- **ไม่ต้องลงแอปบนมือถือ** — push server binary ผ่าน adb ให้เองทุกครั้ง
- **ครบเครื่อง** — เสียง, บันทึกวิดีโอ, กล้องเป็น webcam, OTG/UHID keyboard, H.265/AV1
- **Cross-platform + Wi-Fi** — ใช้ได้ทุก OS หลัก ทั้งมีสายและไร้สาย
- **แบตเตอรี่ความเชื่อมั่นสูง** — พัฒนาต่อเนื่องหลายปี ผู้ใช้จำนวนมาก บั๊กถูกไล่เก็บไปเยอะแล้ว

## จุดด้อย scrcpy (สำหรับโจทย์ "จอเสริม")

- **ทำมือถือเป็นจอเสริมของ Mac ไม่ได้** — ทิศทางภาพกลับด้านกับ AEasy
  (scrcpy 3.x มี `--new-display` แต่นั่นคือสร้าง virtual display *ฝั่ง Android* เพื่อรันแอป Android แสดงบนคอม — ยังเป็นทิศ Android → PC อยู่ดี)
- เป็น CLI ล้วน ตัวเลือกเยอะ ต้องอ่านเอกสารพอสมควร

## สรุป: เลือกตัวไหน

| อยากทำอะไร | ใช้ |
|---|---|
| เอามือถือมาเป็นจอที่สองของ Mac | **AEasy Display** |
| ดู/เล่น/ควบคุมมือถือจากคอม, demo แอป, ตอบแชตมือถือบนคอม | **scrcpy** |
| ทั้งสองอย่าง | ใช้คู่กันได้ — คนละทิศทาง ไม่ชนกัน |
