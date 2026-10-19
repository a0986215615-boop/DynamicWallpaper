# DynamicWallpaper

輕量的 macOS 選單列動態桌布程式，以 AppKit 與 AVFoundation 直接播放本機影片。支援 macOS 13 以上，無第三方執行階段依賴。

## 功能

- 多螢幕桌布與點擊穿透，保留桌面圖示操作。
- 播放／暫停、靜音與音量選擇，只有主螢幕輸出音訊。
- 預設啟用省記憶體模式，以單一影片項目循環播放；循環接點可能略有停頓，可從選單關閉以使用無縫循環。
- 記憶體吃緊時釋放播放器，狀況恢復後依原播放設定恢復。
- 配合螢幕與系統休眠、使用者切換及低耗電模式暫停播放。
- 結束程式保留選片、音量與暫停設定；「移除桌布」會清除選片紀錄。
- 非同步檢查影片可播放性，載入失敗時保留既有桌布並顯示原因。

## 建置

需要 macOS 與 Apple Command Line Tools，Swift 5.9 或以上版本：

```sh
bash build.sh
open dist/DynamicWallpaper.app
```

預設為目前機器架構建置 Release 版本。可將第一個參數設為其他輸出目錄。建置腳本會以本機 ad-hoc 方式簽署 App；Apple Developer ID 簽署與公證需另行設定。

程式位於選單列，沒有 Dock 圖示。請一次只執行一個版本，從選單選擇 MP4、MOV 或 M4V 影片；實際支援依 macOS 可用的影片編碼而定。

## 測試

```sh
bash test.sh
bash test.sh --display
bash benchmark.sh
python3 scripts/verify-public-files.py
```

回歸測試以臨時合成影片與獨立偏好設定檢查設定還原、壞檔處理、選片取消、播放循環、模式切換、螢幕切換及記憶體壓力恢復。`--display` 需要桌面工作階段，會短暫建立測試桌布視窗，並驗證連續換片後舊播放器可被回收。部分情境透過通知或螢幕清單注入模擬。

記憶體 benchmark 使用合成的 1080p H.264 影片，量測測試程序的 `TASK_VM_INFO.phys_footprint`。影片先在另一個程序建立，再量測播放與連續換片；結果依影片、系統與顯示器而異，不代表整體系統記憶體用量。

## 資料與發布

程式在本機偏好設定中保存選取影片的 URL、靜音、暫停、音量與節能選項，這些個人設定不屬於原始碼。原始碼沒有網路上傳或遙測功能。

公開版本只收錄原始碼、建置資源、文件與測試程式；影片、備份、測試輸出、編譯快取、私人設定及預編譯執行檔不應提交。`verify-public-files.py` 會檢查可疑路徑、聯絡資訊、常見憑證格式與不應公開的檔案，但不能取代人工檢查。

## 實作說明

省記憶體模式使用單一 AVPlayerItem，以結尾通知與 seek 循環；無縫模式使用 AVPlayerLooper。影片不重新編碼或降低解析度；預載時間是 AVFoundation 的偏好設定，並非記憶體硬上限。系統記憶體壓力警告由 DispatchSourceMemoryPressure 處理。

參考：[Apple AVPlayerLooper](https://developer.apple.com/documentation/avfoundation/avplayerlooper)、[Apple 記憶體壓力通知](https://developer.apple.com/documentation/dispatch/dispatchsourcememorypressure)。

## 授權

[MIT License](LICENSE)。
